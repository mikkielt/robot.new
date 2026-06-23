<#
    .SYNOPSIS
    Runspace-based worker pool management for the REST API plugin.

    .DESCRIPTION
    This file contains Start-ApiWorkerPool and Stop-ApiWorkerPool — lifecycle
    functions for the PowerShell workers that execute API handler functions.

    Each worker owns an independent Runspace with the Robot module imported
    and handler files dot-sourced (api-handlers-read, api-handlers-write,
    api-handlers-auth, api-handlers-dashboard, api-token-helpers). Workers
    dequeue ApiRequest objects from the C# server's BlockingCollection via
    Take() (blocking), invoke the named handler function directly within
    the runspace, and set the TaskCompletionSource result to unblock the
    awaiting HTTP thread.

    Cache coherence: each worker tracks a local cache version counter.
    Before processing a request, it compares against the shared static
    [Robot.ApiServer]::CacheVersion (bumped by Interlocked.Increment
    after POST/PUT/DELETE operations). On version mismatch, the worker
    calls Clear-ParseCaches to refresh its runspace's entity/session
    data, ensuring read-after-write consistency across worker threads.

    Thread model: each worker runs via PowerShell.BeginInvoke() on its
    dedicated Runspace. BeginInvoke dispatches the dequeue loop to a
    background thread with the Runspace attached, so all PS commands
    (handler calls, Clear-ParseCaches) execute natively. Worker count
    is configurable via plugin config (default 8).

    Request processing pipeline per dequeue:
    1. Cache version check + optional Clear-ParseCaches
    2. Handler name validation against $HandlerMap (rejects stale routes)
    3. Build $ApiContext hashtable from ApiRequest fields
    4. Parse JSON body from BodyBytes if present (400 on invalid JSON)
    5. Invoke handler directly via & $HandlerName
    6. Increment CacheVersion for write methods (POST/PUT/DELETE)
    7. Set [Robot.ApiResponse] on TaskCompletionSource

    Helpers:
    - Start-ApiWorkerPool: creates N runspaces, starts dequeue loops via BeginInvoke
    - Stop-ApiWorkerPool: stops pipelines, disposes runspaces

    Module-level data:
    - $script:ApiWorkerRunspaces: List of {Runspace, PowerShell, AsyncResult}
      entries for lifecycle management
#>

# Worker pool state — initialized by Start-ApiWorkerPool, cleared by Stop-ApiWorkerPool
$script:ApiWorkerRunspaces = $null

function Start-ApiWorkerPool {
    param(
        [Parameter(Mandatory)] [Robot.ApiServer]$Server,
        [Parameter(Mandatory)] [hashtable]$HandlerMap,
        [int]$WorkerCount = 8
    )

    $ModRoot          = $script:ModuleRoot
    $Queue            = $Server.RequestQueue
    $RepoRootOverride = $script:RepoRootOverride

    $script:ApiWorkerRunspaces = [System.Collections.Generic.List[object]]::new()

    # Dequeue loop script — runs inside each worker's dedicated Runspace via
    # BeginInvoke, so handler functions and Clear-ParseCaches are callable
    # directly without PS.AddCommand/Invoke round-trips.
    $WorkerLoopScript = @'
        param($Queue, $HandlerMap)
        $LocalCacheVersion = 0

        while (-not $Queue.IsCompleted) {
            $Req = $null
            try {
                $Req = $Queue.Take()
            } catch [System.OperationCanceledException] {
                break
            } catch [System.InvalidOperationException] {
                break
            }

            if ($null -eq $Req) { continue }

            try {
                # Cache coherence: check shared version
                $SharedVersion = [System.Threading.Interlocked]::Read(
                    [ref][Robot.ApiServer]::CacheVersion)
                if ($SharedVersion -ne $LocalCacheVersion) {
                    Clear-ParseCaches
                    $LocalCacheVersion = $SharedVersion
                }

                # Reject unknown handlers early (routing mismatch or stale HandlerMap)
                $HandlerName = $Req.HandlerName
                if (-not $HandlerMap.ContainsKey($HandlerName)) {
                    $Req.ResponseSource.SetResult([Robot.ApiResponse]@{
                        StatusCode = 500
                        RawJson = '{"error":"Handler not found: ' + $HandlerName + '","status":500}'
                    })
                    continue
                }

                # Build context hashtable for the handler
                $Ctx = @{
                    PathParams  = $Req.PathParams
                    QueryParams = $Req.QueryParams
                    Body        = $null
                    Method      = $Req.Method
                    Path        = $Req.Path
                    TokenName   = $Req.TokenName
                    TokenScopes = $Req.TokenScopes
                }

                # Parse JSON body if present
                if ($Req.BodyBytes -and $Req.BodyBytes.Length -gt 0) {
                    $BodyText = [System.Text.Encoding]::UTF8.GetString($Req.BodyBytes)
                    try {
                        $Ctx.Body = $BodyText | ConvertFrom-Json
                    } catch {
                        $Req.ResponseSource.SetResult([Robot.ApiResponse]@{
                            StatusCode = 400
                            RawJson = '{"error":"Invalid JSON body","status":400}'
                        })
                        continue
                    }
                }

                # Invoke handler directly — runspace has all handlers loaded
                $HandlerResult = & $HandlerName -ApiContext $Ctx

                if ($null -eq $HandlerResult) {
                    $HandlerResult = @{ StatusCode = 204 }
                }

                # Invalidate caches after mutations so next read sees fresh data
                if ($Req.Method -in @('POST', 'PUT', 'DELETE')) {
                    [System.Threading.Interlocked]::Increment(
                        [ref][Robot.ApiServer]::CacheVersion)
                }

                $Resp = [Robot.ApiResponse]::new()
                $Resp.StatusCode = if ($HandlerResult.StatusCode) {
                    $HandlerResult.StatusCode
                } else { 200 }
                $Resp.Body = $HandlerResult.Body

                # IncludeLabels tells the C# serializer to emit field name annotations
                if ($HandlerResult.IncludeLabels) {
                    $Resp.IncludeLabels = $true
                }

                # RawBody + ContentType for non-JSON responses (HTML, binary, etc.)
                if ($HandlerResult.RawBody) {
                    $Resp.RawBody     = $HandlerResult.RawBody
                    $Resp.ContentType = $HandlerResult.ContentType
                }

                $Req.ResponseSource.SetResult($Resp)

            } catch {
                try {
                    $ErrResp = [Robot.ApiResponse]::new()
                    $ErrResp.StatusCode = 500
                    $ErrResp.RawJson = '{"error":"' +
                        ($_.Exception.Message -replace '"', '\\"') + '","status":500}'
                    $Req.ResponseSource.SetResult($ErrResp)
                } catch { }
            }
        }
'@

    for ($i = 0; $i -lt $WorkerCount; $i++) {
        # Each worker gets its own runspace with the module imported
        $ISS = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($ISS)
        $Runspace.Open()

        # Import module into this runspace
        $PS = [System.Management.Automation.PowerShell]::Create()
        $PS.Runspace = $Runspace
        [void]$PS.AddScript("Import-Module '$ModRoot/Robot.PowerShell.psm1' -Force -WarningAction SilentlyContinue")
        [void]$PS.Invoke()
        $PS.Commands.Clear()

        # Propagate repo root override so workers resolve the same root
        if ($RepoRootOverride) {
            $PS.Commands.Clear()
            [void]$PS.AddCommand('Set-RepoRoot')
            [void]$PS.AddParameter('Path', $RepoRootOverride)
            [void]$PS.Invoke()
            $PS.Commands.Clear()
        }

        # Dot-source handler files so each runspace has all API functions available
        $HandlerDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
        $HandlerFiles = @(
            "$HandlerDir/private/api-handlers-read.ps1"
            "$HandlerDir/private/api-handlers-write.ps1"
            "$HandlerDir/private/api-handlers-auth.ps1"
            "$HandlerDir/private/api-handlers-dashboard.ps1"
            "$HandlerDir/private/api-handlers-analytics.ps1"
            "$HandlerDir/private/api-token-helpers.ps1"  # needed by auth handlers
            "$HandlerDir/private/margonem-audit.ps1"     # WP-16 audit log helper
        )
        foreach ($HF in $HandlerFiles) {
            if ([System.IO.File]::Exists($HF)) {
                $PS.Commands.Clear()
                [void]$PS.AddScript(". '$HF'")
                [void]$PS.Invoke()
                $PS.Commands.Clear()
            }
        }

        # Run dequeue loop asynchronously in the dedicated runspace
        $PS.Commands.Clear()
        [void]$PS.AddScript($WorkerLoopScript)
        [void]$PS.AddParameter('Queue', $Queue)
        [void]$PS.AddParameter('HandlerMap', $HandlerMap)
        $AsyncResult = $PS.BeginInvoke()

        [void]$script:ApiWorkerRunspaces.Add(@{
            Runspace    = $Runspace
            PowerShell  = $PS
            AsyncResult = $AsyncResult
        })
    }
}

function Stop-ApiWorkerPool {
    if ($script:ApiWorkerRunspaces) {
        foreach ($Entry in $script:ApiWorkerRunspaces) {
            try { $Entry.PowerShell.Stop() } catch { }
            try {
                $Entry.PowerShell.Dispose()
                $Entry.Runspace.Close()
                $Entry.Runspace.Dispose()
            } catch { }
        }
        $script:ApiWorkerRunspaces = $null
    }
}

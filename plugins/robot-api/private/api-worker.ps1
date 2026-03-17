<#
    .SYNOPSIS
    RunspacePool-based worker thread management for the REST API plugin.

    .DESCRIPTION
    This file contains Start-ApiWorkerPool and Stop-ApiWorkerPool — lifecycle
    functions for the PowerShell worker threads that execute API handler
    functions.

    Each worker thread owns an independent Runspace with the Robot module
    imported and four handler files dot-sourced (api-handlers-read,
    api-handlers-write, api-handlers-auth, api-token-helpers). Workers
    dequeue ApiRequest objects from the C# server's BlockingCollection
    via Take() (blocking), invoke the named handler function, and set
    the TaskCompletionSource result to unblock the awaiting HTTP thread.

    Cache coherence: each worker tracks a local cache version counter.
    Before processing a request, it compares against the shared static
    [Robot.ApiServer]::CacheVersion (bumped by Interlocked.Increment
    after POST/PUT/DELETE operations). On version mismatch, the worker
    calls Clear-ParseCaches to refresh its runspace's entity/session
    data, ensuring read-after-write consistency across worker threads.

    Thread model: N background .NET Threads (not ThreadPool) with
    dedicated runspaces. Background threads auto-terminate when the
    process exits. Worker count is configurable via plugin config
    (default 8). Each thread is named "RobotApiWorker-{i}" for
    diagnostics.

    Request processing pipeline per dequeue:
    1. Cache version check + optional Clear-ParseCaches
    2. Handler name validation against $HandlerMap (rejects stale routes)
    3. Build $ApiContext hashtable from ApiRequest fields
    4. Parse JSON body from BodyBytes if present (400 on invalid JSON)
    5. Invoke handler, extract StatusCode/Body from result hashtable
    6. Increment CacheVersion for write methods (POST/PUT/DELETE)
    7. Set [Robot.ApiResponse] on TaskCompletionSource

    Helpers:
    - Start-ApiWorkerPool: creates N runspaces + threads, starts dequeue loops
    - Stop-ApiWorkerPool: disposes runspaces and nulls thread references

    Module-level data:
    - $script:ApiWorkerThreads: List of active worker Thread objects
    - $script:ApiWorkerRunspaces: List of {Runspace, PowerShell} entries
      (each entry is a hashtable with Runspace and PowerShell keys)
#>

# Worker pool state — initialized by Start-ApiWorkerPool, cleared by Stop-ApiWorkerPool
$script:ApiWorkerThreads   = $null
$script:ApiWorkerRunspaces = $null

function Start-ApiWorkerPool {
    param(
        [Parameter(Mandatory)] [Robot.ApiServer]$Server,
        [Parameter(Mandatory)] [hashtable]$HandlerMap,
        [int]$WorkerCount = 8
    )

    $ModRoot = $script:ModuleRoot
    $Queue   = $Server.RequestQueue

    $script:ApiWorkerThreads   = [System.Collections.Generic.List[System.Threading.Thread]]::new()
    $script:ApiWorkerRunspaces = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $WorkerCount; $i++) {
        # Each worker gets its own runspace with the module imported
        $ISS = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($ISS)
        $Runspace.Open()

        # Import module into this runspace
        $PS = [System.Management.Automation.PowerShell]::Create()
        $PS.Runspace = $Runspace
        [void]$PS.AddScript("Import-Module '$ModRoot/robot.psm1' -Force -WarningAction SilentlyContinue")
        [void]$PS.Invoke()
        $PS.Commands.Clear()

        # Dot-source handler files so each runspace has all API functions available
        $HandlerDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
        $HandlerFiles = @(
            "$HandlerDir/private/api-handlers-read.ps1"
            "$HandlerDir/private/api-handlers-write.ps1"
            "$HandlerDir/private/api-handlers-auth.ps1"
            "$HandlerDir/private/api-token-helpers.ps1"  # needed by auth handlers
        )
        foreach ($HF in $HandlerFiles) {
            if ([System.IO.File]::Exists($HF)) {
                $PS.Commands.Clear()
                [void]$PS.AddScript(". '$HF'")
                [void]$PS.Invoke()
                $PS.Commands.Clear()
            }
        }

        $script:ApiWorkerRunspaces.Add(@{ Runspace = $Runspace; PowerShell = $PS })

        # Capture state for the ParameterizedThreadStart closure
        $WorkerState = @{
            Queue      = $Queue
            HandlerMap = $HandlerMap
            PS         = $PS
            WorkerId   = $i
        }

        $ThreadStart = {
            param($State)
            $Q  = $State.Queue
            $HM = $State.HandlerMap
            $PS = $State.PS
            $LocalCacheVersion = 0  # compared against shared [Robot.ApiServer]::CacheVersion

            while (-not $Q.IsCompleted) {
                $Req = $null
                try {
                    $Req = $Q.Take()  # blocks until item available or CompleteAdding called
                } catch [System.OperationCanceledException] {
                    break
                } catch [System.InvalidOperationException] {
                    break  # BlockingCollection was completed
                }

                if ($null -eq $Req) { continue }

                try {
                    # Cache coherence: check shared version
                    $SharedVersion = [System.Threading.Interlocked]::Read(
                        [ref][Robot.ApiServer]::CacheVersion)
                    if ($SharedVersion -ne $LocalCacheVersion) {
                        $PS.Commands.Clear()
                        [void]$PS.AddCommand('Clear-ParseCaches')
                        [void]$PS.Invoke()
                        $PS.Commands.Clear()
                        $LocalCacheVersion = $SharedVersion
                    }

                    # Reject unknown handlers early (routing mismatch or stale HandlerMap)
                    $HandlerName = $Req.HandlerName
                    if (-not $HM.ContainsKey($HandlerName)) {
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

                    # Invoke handler via PowerShell
                    $PS.Commands.Clear()
                    [void]$PS.AddCommand($HandlerName)
                    [void]$PS.AddParameter('ApiContext', $Ctx)
                    $Result = $PS.Invoke()
                    $PS.Commands.Clear()

                    # Handler returns hashtable with StatusCode + Body; default 204 for empty
                    $HandlerResult = if ($Result -and $Result.Count -gt 0) {
                        $Result[0]
                    } else {
                        @{ StatusCode = 204 }
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
        }

        $Thread = [System.Threading.Thread]::new(
            [System.Threading.ParameterizedThreadStart]$ThreadStart)
        $Thread.IsBackground = $true
        $Thread.Name = "RobotApiWorker-$i"
        $Thread.Start($WorkerState)

        $script:ApiWorkerThreads.Add($Thread)
    }
}

function Stop-ApiWorkerPool {
    if ($script:ApiWorkerRunspaces) {
        foreach ($Entry in $script:ApiWorkerRunspaces) {
            try {
                $Entry.PowerShell.Dispose()
                $Entry.Runspace.Close()
                $Entry.Runspace.Dispose()
            } catch { }
        }
        $script:ApiWorkerRunspaces = $null
    }
    $script:ApiWorkerThreads = $null
}

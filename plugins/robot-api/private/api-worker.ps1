<#
    .SYNOPSIS
    RunspacePool-based worker thread management for the REST API plugin.

    .DESCRIPTION
    This file contains Start-ApiWorkerPool and Stop-ApiWorkerPool — lifecycle
    functions for the PowerShell worker threads that execute API handler
    functions.

    Each worker thread owns an independent Runspace with the Robot module
    imported and handler files dot-sourced. Workers dequeue ApiRequest objects
    from the C# server's BlockingCollection, invoke the named handler function,
    and set the TaskCompletionSource result to unblock the awaiting HTTP thread.

    Cache coherence: each worker tracks a local cache version counter. Before
    processing a request, it compares against the shared ApiServer.CacheVersion
    (updated by Interlocked.Increment after writes). On version mismatch, the
    worker calls Clear-ParseCaches to refresh its runspace's entity/session data.

    Thread model: N background .NET Threads (not ThreadPool) with dedicated
    runspaces. Background threads auto-terminate when the process exits.
    Worker count is configurable via plugin config (default 8).

    Helpers:
    - Start-ApiWorkerPool: creates N runspaces + threads, starts dequeue loops
    - Stop-ApiWorkerPool: disposes runspaces and nulls thread references

    Module-level data:
    - $script:ApiWorkerThreads: List of active worker Thread objects
    - $script:ApiWorkerRunspaces: List of {Runspace, PowerShell} entries
#>

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

        # Dot-source the handler files into each runspace
        $HandlerDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
        $HandlerFiles = @(
            "$HandlerDir/private/api-handlers-read.ps1"
            "$HandlerDir/private/api-handlers-write.ps1"
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

        # Worker thread: dequeue requests, invoke handlers, return results
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
            $LocalCacheVersion = 0

            while (-not $Q.IsCompleted) {
                $Req = $null
                try {
                    $Req = $Q.Take()  # Blocks until item available or completed
                } catch [System.OperationCanceledException] {
                    break
                } catch [System.InvalidOperationException] {
                    break  # CompleteAdding was called
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

                    # Extract result (handler returns hashtable with StatusCode, Body)
                    $HandlerResult = if ($Result -and $Result.Count -gt 0) {
                        $Result[0]
                    } else {
                        @{ StatusCode = 204 }
                    }

                    # Increment cache version after write operations
                    if ($Req.Method -in @('POST', 'PUT', 'DELETE')) {
                        [System.Threading.Interlocked]::Increment(
                            [ref][Robot.ApiServer]::CacheVersion)
                    }

                    $Resp = [Robot.ApiResponse]::new()
                    $Resp.StatusCode = if ($HandlerResult.StatusCode) {
                        $HandlerResult.StatusCode
                    } else { 200 }
                    $Resp.Body = $HandlerResult.Body

                    # Pass through labels flag from handler
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

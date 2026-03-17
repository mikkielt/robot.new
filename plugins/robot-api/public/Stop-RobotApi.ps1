<#
    .SYNOPSIS
    Graceful REST API server shutdown and resource cleanup.

    .DESCRIPTION
    This file contains Stop-RobotApi — shuts down the API server in the
    correct order to avoid request loss:

    1. Worker pool shutdown: Stop-ApiWorkerPool disposes runspaces, which
       causes worker threads to exit their dequeue loops.
    2. HTTP engine stop: ApiServer.Stop() cancels the accept loop, drains
       in-flight requests, disconnects SSE clients, and closes the listener.
    3. Resource disposal: disposes the ApiServer and nulls the instance
       reference so Get-RobotApiStatus reports offline state.

    Module-level data:
    - $script:ApiServerInstance: cleared to $null after shutdown
#>

function Stop-RobotApi {
    <#
        .SYNOPSIS
        Gracefully shuts down the REST API server and worker pool.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [switch]$Quiet
    )

    if (-not $script:ApiServerInstance) {
        if (-not $Quiet) { Write-RobotInfo '[Stop-RobotApi] No server instance running' }
        return @{ Status = 'NotRunning' }
    }

    if (-not $PSCmdlet.ShouldProcess('REST API server', 'Stop')) { return }

    # Stop worker pool first (drains queue)
    . "$PSScriptRoot/../private/api-worker.ps1"
    Stop-ApiWorkerPool

    # Stop C# HTTP engine
    $script:ApiServerInstance.Stop()
    $script:ApiServerInstance.Dispose()
    $script:ApiServerInstance = $null

    if (-not $Quiet) {
        Write-RobotInfo '[Stop-RobotApi] Server stopped and resources released'
    }

    return @{ Status = 'Stopped' }
}

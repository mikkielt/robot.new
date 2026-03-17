<#
    .SYNOPSIS
    Status snapshot for the REST API server.

    .DESCRIPTION
    This file contains Get-RobotApiStatus — returns a PSCustomObject
    (PSTypeName 'Robot.ApiStatus') with the server's running state, request
    statistics, queue depth, SSE client count, and cache version.

    When no server instance exists ($script:ApiServerInstance is $null),
    returns a default offline snapshot. Otherwise delegates to
    ApiServer.GetStatus() and wraps the C# dictionary result in a typed
    PSCustomObject for pipeline-friendly output.
#>

function Get-RobotApiStatus {
    <#
        .SYNOPSIS
        Returns a status snapshot of the REST API server.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:ApiServerInstance) {
        return [PSCustomObject]@{
            PSTypeName    = 'Robot.ApiStatus'
            IsRunning     = $false
            RequestCount  = 0
            StartedAt     = $null
            UptimeSeconds = 0
            QueuedRequests = 0
            SseClients    = 0
            CacheVersion  = [System.Threading.Interlocked]::Read(
                [ref][Robot.ApiServer]::CacheVersion)
        }
    }

    $Status = $script:ApiServerInstance.GetStatus()

    return [PSCustomObject]@{
        PSTypeName     = 'Robot.ApiStatus'
        IsRunning      = $Status['isRunning']
        RequestCount   = $Status['requestCount']
        StartedAt      = $Status['startedAt']
        UptimeSeconds  = [math]::Round($Status['uptimeSeconds'], 1)
        QueuedRequests = $Status['queuedRequests']
        SseClients     = $Status['sseClients']
        CacheVersion   = $Status['cacheVersion']
    }
}

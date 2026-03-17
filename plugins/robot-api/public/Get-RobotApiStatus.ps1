<#
    .SYNOPSIS
    Status snapshot for the REST API server.

    .DESCRIPTION
    This file contains Get-RobotApiStatus — returns a PSCustomObject
    (PSTypeName 'Robot.ApiStatus') with the server's running state, request
    statistics, queue depth, SSE client count, cache version, and active
    token count.

    When no server instance exists ($script:ApiServerInstance is $null),
    returns a default offline snapshot with zeroed counters but a live
    CacheVersion (read atomically from [Robot.ApiServer]::CacheVersion
    via Interlocked.Read). Otherwise delegates to ApiServer.GetStatus()
    and wraps the C# dictionary result in a typed PSCustomObject for
    pipeline-friendly output.

    Module-level data:
    - $script:ApiServerInstance: active [Robot.ApiServer] set by Start-RobotApi
    - $script:ApiTokenStore: active [Robot.ApiTokenStore] for live token count
#>

function Get-RobotApiStatus {
    <#
        .SYNOPSIS
        Returns a status snapshot of the REST API server.
    #>
    [CmdletBinding()]
    param()

    # Offline path — return zeroed snapshot when server hasn't been started
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
                [ref][Robot.ApiServer]::CacheVersion)  # static field survives server stop/restart
            TokenCount    = 0
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
        TokenCount     = if ($script:ApiTokenStore) { $script:ApiTokenStore.Count } else { 0 }  # store only exists when server has been started
    }
}

<#
    .SYNOPSIS
    Opens the Robot dashboard in the default browser.

    .DESCRIPTION
    This file contains Invoke-RobotDashboard.

    Invoke-RobotDashboard ensures the API server is running, determines the
    correct port, and opens the dashboard URL in the default browser via
    platform-specific open commands (open/xdg-open/Start-Process).
#>

function Invoke-RobotDashboard {
    <#
        .SYNOPSIS
        Opens the Robot dashboard in the default browser. Starts the API
        server if it is not already running.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override the API port (default: from plugin config or 8642)")]
        [int]$Port,
        [switch]$Force
    )

    # Resolve effective port — needed for external probe and URL construction
    $EffectivePort = $Port
    if (-not $EffectivePort) {
        $Config = Get-PluginConfig -PluginName 'robot-api'
        $EffectivePort = if ($Config.ListenPort) { $Config.ListenPort } else { 8642 }
    }

    # Ensure API is running (in-process or external)
    $Status = Get-RobotApiStatus
    if ($Force -or -not $Status.IsRunning) {
        # Probe port for an external API instance (e.g. from a previous session)
        $ExternalApi = $false
        if (-not $Status.IsRunning) {
            try {
                $TcpProbe = [System.Net.Sockets.TcpClient]::new()
                $TcpProbe.Connect('localhost', $EffectivePort)
                [void]$TcpProbe.Dispose()
                $ExternalApi = $true
            } catch { }
        }

        if ($ExternalApi -and -not $Force) {
            # External process is serving on this port — reuse it
            Write-RobotInfo "[Invoke-RobotDashboard] Reusing existing API on port $EffectivePort"
        } else {
            $StartParams = @{ Quiet = $true }
            if ($Port)  { $StartParams.Port  = $Port }
            if ($Force) { $StartParams.Force = $true }
            Start-RobotApi @StartParams
        }
    }

    $Url = "http://localhost:$EffectivePort/api/dashboard"

    # Cross-platform browser open
    if ($IsMacOS -or ($PSVersionTable.OS -and $PSVersionTable.OS.Contains('Darwin'))) {
        Start-Process 'open' -ArgumentList $Url
    }
    elseif ($IsLinux -or ($PSVersionTable.OS -and $PSVersionTable.OS.Contains('Linux'))) {
        Start-Process 'xdg-open' -ArgumentList $Url
    }
    else {
        Start-Process $Url
    }

    return [PSCustomObject]@{
        Url     = $Url
        Status  = 'Opened'
    }
}

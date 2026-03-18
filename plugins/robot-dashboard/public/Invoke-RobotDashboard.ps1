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
        [int]$Port
    )

    # Ensure API is running
    $Status = Get-RobotApiStatus
    if (-not $Status.IsRunning) {
        $StartParams = @{ Quiet = $true }
        if ($Port) { $StartParams.Port = $Port }
        Start-RobotApi @StartParams
        $Status = Get-RobotApiStatus
    }

    # Determine actual port from status or config
    if (-not $Port) {
        $Config = Get-PluginConfig -PluginName 'robot-api'
        $Port = if ($Config.ListenPort) { $Config.ListenPort } else { 8642 }
    }

    $Url = "http://localhost:$Port/api/dashboard"

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

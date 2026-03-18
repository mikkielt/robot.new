<#
    .SYNOPSIS
    CLI workflow function for the robot-dashboard plugin.

    .DESCRIPTION
    Invoke-DashboardOpen is registered as a CLI menu item via the plugin
    manifest. Starts the API server if not running and opens the dashboard
    in the default browser.
#>

function Invoke-DashboardOpen {
    <#
        .SYNOPSIS
        Opens the dashboard in the default browser from the CLI menu.
    #>

    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor   = Get-CLIColor -Role 'Error'
    $DimColor     = Get-CLIColor -Role 'Disabled'

    Write-Host ''

    try {
        $Result = Invoke-RobotDashboard
        Write-CLILine -Text "  Dashboard: $($Result.Url)" -Color $SuccessColor
    } catch {
        Write-CLILine -Text "  Blad: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text '  [Enter] Powrot' -Color $DimColor
    [void][System.Console]::ReadKey($true)
}

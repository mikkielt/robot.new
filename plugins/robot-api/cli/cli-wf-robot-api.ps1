<#
    .SYNOPSIS
    CLI workflow functions for the robot-api plugin.

    .DESCRIPTION
    This file defines interactive TUI workflow functions registered as CLI
    menu items via the plugin manifest's MenuItems array. Dot-sourced at
    Layer 6.5 when Invoke-RobotCLI starts, making them available for
    keyboard-driven navigation.

    Each workflow takes $State (CLI state object) and $Entry (menu item
    hashtable), uses CLI primitive functions for colored output, and blocks
    on Read-ArrowKey before returning to the menu.

    Helpers:
    - Invoke-ApiStartWorkflow: displays resolved config, starts API server
      via Start-RobotApi, shows success/error status
    - Invoke-ApiStopWorkflow: captures final statistics, stops API server
      via Stop-RobotApi
    - Invoke-ApiStatusWorkflow: displays running state, uptime, request
      count, queue depth, SSE clients, and cache version
#>

function Invoke-ApiStartWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor   = Get-CLIColor -Role 'Error'
    $InfoColor    = Get-CLIColor -Role 'Info'
    $DimColor     = Get-CLIColor -Role 'Disabled'

    Write-Host ''

    # Guard: if server is already active, show current status and return
    if ($script:ApiServerInstance -and $script:ApiServerInstance.IsRunning) {
        Write-CLILine -Text '  REST API jest juz aktywne.' -Color $InfoColor
        $S = $script:ApiServerInstance.GetStatus()
        $Uptime = [math]::Round($S['uptimeSeconds'] / 60, 1)
        Write-CLILine -Text "  Czas dzialania: $Uptime min, zapytan: $($S['requestCount'])" -Color $DimColor
        Write-Host ''
        Write-CLILine -Text '  Nacisnij dowolny klawisz...' -Color $DimColor
        [void](Read-ArrowKey)
        return
    }

    # Show resolved config so the user can verify settings before start
    $Config = Get-PluginConfig -PluginName 'robot-api'
    $Port = $Config.ListenPort
    $Address = $Config.ListenAddress
    $Workers = $Config.WorkerCount

    Write-CLILine -Text '  Uruchamianie REST API...' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Adres:    http://${Address}:${Port}/api/" -Color $InfoColor
    Write-CLILine -Text "  Workery:  $Workers" -Color $InfoColor
    Write-CLILine -Text "  Auth:     $(if ($Config.AuthToken) { 'Bearer token' } else { 'brak (otwarty)' })" -Color $InfoColor
    Write-CLILine -Text "  Tryb:     $(if ($Config.ReadOnly) { 'tylko odczyt' } else { 'odczyt + zapis' })" -Color $InfoColor
    Write-Host ''

    try {
        Start-RobotApi -Quiet -Confirm:$false
        Write-CLILine -Text '  Status: AKTYWNY' -Color $SuccessColor
        Write-CLILine -Text "  Serwer nasluchuje na http://${Address}:${Port}/api/" -Color $InfoColor
    }
    catch {
        Write-CLILine -Text "  BLAD: $($_.Exception.Message)" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text '  Nacisnij dowolny klawisz...' -Color $DimColor
    [void](Read-ArrowKey)
}

function Invoke-ApiStopWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor   = Get-CLIColor -Role 'Error'
    $InfoColor    = Get-CLIColor -Role 'Info'
    $DimColor     = Get-CLIColor -Role 'Disabled'

    Write-Host ''

    if (-not $script:ApiServerInstance -or -not $script:ApiServerInstance.IsRunning) {
        Write-CLILine -Text '  REST API nie jest aktywne.' -Color $InfoColor
        Write-Host ''
        Write-CLILine -Text '  Nacisnij dowolny klawisz...' -Color $DimColor
        [void](Read-ArrowKey)
        return
    }

    # Capture final stats before shutdown (unavailable after Stop-RobotApi)
    $S = $script:ApiServerInstance.GetStatus()
    $Uptime = [math]::Round($S['uptimeSeconds'] / 60, 1)

    Write-CLILine -Text '  Zatrzymywanie REST API...' -Color $AccentColor
    Write-CLILine -Text "  Obsluzono zapytan: $($S['requestCount']), czas dzialania: $Uptime min" -Color $DimColor
    Write-Host ''

    try {
        Stop-RobotApi -Confirm:$false
        Write-CLILine -Text '  Status: ZATRZYMANY' -Color $SuccessColor
    }
    catch {
        Write-CLILine -Text "  BLAD: $($_.Exception.Message)" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text '  Nacisnij dowolny klawisz...' -Color $DimColor
    [void](Read-ArrowKey)
}

function Invoke-ApiStatusWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor   = Get-CLIColor -Role 'Error'
    $InfoColor    = Get-CLIColor -Role 'Info'
    $DimColor     = Get-CLIColor -Role 'Disabled'

    Write-Host ''

    if (-not $script:ApiServerInstance -or -not $script:ApiServerInstance.IsRunning) {
        Write-CLILine -Text '  REST API: NIEAKTYWNE' -Color $ErrorColor
        Write-Host ''
        Write-CLILine -Text '  Uzyj "Uruchom REST API" aby wystartowac serwer.' -Color $DimColor
        Write-Host ''
        Write-CLILine -Text '  Nacisnij dowolny klawisz...' -Color $DimColor
        [void](Read-ArrowKey)
        return
    }

    $S = $script:ApiServerInstance.GetStatus()
    $Uptime = [math]::Round($S['uptimeSeconds'] / 60, 1)

    Write-CLILine -Text '  REST API: AKTYWNE' -Color $SuccessColor
    Write-Host ''
    Write-CLILine -Text "  Czas dzialania:   $Uptime min" -Color $InfoColor
    Write-CLILine -Text "  Zapytan:          $($S['requestCount'])" -Color $InfoColor
    Write-CLILine -Text "  W kolejce:        $($S['queuedRequests'])" -Color $InfoColor
    Write-CLILine -Text "  Klienci SSE:      $($S['sseClients'])" -Color $InfoColor
    Write-CLILine -Text "  Wersja cache:     $($S['cacheVersion'])" -Color $DimColor

    Write-Host ''
    Write-CLILine -Text '  Nacisnij dowolny klawisz...' -Color $DimColor
    [void](Read-ArrowKey)
}

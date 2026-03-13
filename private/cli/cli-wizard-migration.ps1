<#
    .SYNOPSIS
    Migration phase integration for the Robot CLI - data-driven phase registry
    and dynamic menu item generation.

    .DESCRIPTION
    This file bridges the CLI menu with the migration subsystem. It:
    1. Dot-sources migration-phases.ps1 (which provides $script:PhaseRegistry)
    2. Dot-sources migration-state.ps1 (which provides Get-MigrationState, Get-PhaseStatus)
    3. Builds menu items dynamically from the phase registry + current state
    4. Delegates execution to phase functions via the registry

    Loaded on demand by Invoke-RobotCLI when this file exists.

    Helpers:
    - Get-MigrationMenuItems:        returns dynamic menu items with status badges
    - Invoke-MigrationPhaseAction:   dispatches a phase by registry ID

    Dependencies: cli-primitives.ps1, cli-routing.ps1 (overrides stubs)
#>

# Load migration subsystem
$MigrationRoot = [System.IO.Path]::Combine($script:ModuleRoot, 'migration')

$MigrationStatePath = [System.IO.Path]::Combine($MigrationRoot, 'migration-state.ps1')
$MigrationPhasesPath = [System.IO.Path]::Combine($MigrationRoot, 'migration-phases.ps1')
$MigrationUIPath = [System.IO.Path]::Combine($MigrationRoot, 'migration-ui.ps1')

$script:MigrationAvailable = $false

if ([System.IO.File]::Exists($MigrationStatePath) -and [System.IO.File]::Exists($MigrationPhasesPath)) {
    try {
        . $MigrationUIPath
        . $MigrationStatePath
        . $MigrationPhasesPath
        $script:MigrationAvailable = $true
    }
    catch {
        [System.Console]::Error.WriteLine("[WARN cli-wizard-migration] Nie udało się załadować migracji: $_")
    }
}

# Override the stub from cli-routing.ps1
function Get-MigrationMenuItems {
    param([object]$State)

    if (-not $script:MigrationAvailable) {
        return @([PSCustomObject]@{
            ID          = '__migration-unavailable__'
            Label       = 'Migracja niedostępna'
            Description = 'Brak plików migracji'
            RoleTag     = $null
            InfoText    = $null
            Disabled    = $true
        })
    }

    $Items = [System.Collections.Generic.List[PSCustomObject]]::new()
    $MigrationState = Get-MigrationState

    # Build items from phase registry (if available)
    if ($script:PhaseRegistry) {
        foreach ($Phase in $script:PhaseRegistry) {
            $PhaseStatus = Get-PhaseStatus -State $MigrationState -Phase $Phase.ID
            $StatusInfo = $script:StatusDisplay[$PhaseStatus]
            $StatusSymbol = if ($StatusInfo) { "$($StatusInfo.Symbol) " } else { '' }
            $StatusText = if ($StatusInfo) { $StatusInfo.Text } else { '' }

            [void]$Items.Add([PSCustomObject]@{
                ID          = "migration-phase-$($Phase.ID)"
                Label       = "${StatusSymbol}Faza $($Phase.ID): $($Phase.Name)"
                Description = $StatusText
                RoleTag     = 'K'
                InfoText    = $null
                Disabled    = $false
            })
        }
    } else {
        # Fallback: hardcoded phase 0-6
        for ($I = 0; $I -le 6; $I++) {
            $PhaseStatus = Get-PhaseStatus -State $MigrationState -Phase $I
            $StatusInfo = $script:StatusDisplay[$PhaseStatus]
            $StatusSymbol = if ($StatusInfo) { "$($StatusInfo.Symbol) " } else { '' }
            $StatusText = if ($StatusInfo) { $StatusInfo.Text } else { '' }

            [void]$Items.Add([PSCustomObject]@{
                ID          = "migration-phase-$I"
                Label       = "${StatusSymbol}Faza $I`: $(Get-PhaseName -Phase $I)"
                Description = $StatusText
                RoleTag     = 'K'
                InfoText    = $null
                Disabled    = $false
            })
        }
    }

    return $Items
}

# Override the stub from cli-routing.ps1
function Invoke-MigrationPhaseAction {
    param([string]$PhaseID, [object]$State)

    # Clear engine-rendered screen before switching to console-mode output
    [System.Console]::Clear()

    if (-not $script:MigrationAvailable) {
        Write-CLILine -Text 'Migracja nie jest dostępna.' -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
        return
    }

    # Extract phase number from ID like "migration-phase-3"
    $PhaseNum = -1
    if ($PhaseID -match 'migration-phase-(\d+)') {
        $PhaseNum = [int]$Matches[1]
    }

    if ($PhaseNum -lt 0) {
        Write-CLILine -Text "Nieznana faza: $PhaseID" -Color (Get-CLIColor -Role 'Error')
        [void][System.Console]::ReadKey($true)
        return
    }

    $MigrationState = Get-MigrationState

    # Look up in registry first
    $PhaseEntry = $null
    if ($script:PhaseRegistry) {
        $PhaseEntry = $script:PhaseRegistry | Where-Object { $_.ID -eq $PhaseNum } | Select-Object -First 1
    }

    $FunctionName = if ($PhaseEntry -and $PhaseEntry.Function) {
        $PhaseEntry.Function
    } else {
        "Invoke-MigrationPhase$PhaseNum"
    }

    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        Write-CLILine -Text "Funkcja '$FunctionName' nie jest dostępna." -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
        return
    }

    # Show phase header
    $PhaseName = if ($PhaseEntry) { $PhaseEntry.Name } else { Get-PhaseName -Phase $PhaseNum }
    Write-Host ''
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor (Get-CLIColor -Role 'Accent')
    Write-CLILine -Text "FAZA $PhaseNum`: $PhaseName" -Color (Get-CLIColor -Role 'Accent')
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        & $FunctionName -State $MigrationState
    }
    catch {
        Write-Host ''
        Write-CLILine -Text "$([char]0x2717) Błąd w Fazie $PhaseNum`: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

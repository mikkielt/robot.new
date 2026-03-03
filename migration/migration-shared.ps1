<#
    .SYNOPSIS
    Shared diagnostic display and menu helper functions for migration.

    .DESCRIPTION
    Non-exported helpers consumed by multiple phases and the main menu
    via dot-sourcing. Provides diagnostic result rendering and menu shortcuts.

    Uses Resolve-MigrationColor (from migration-ui.ps1) for background-adaptive
    colors when CLI engine is available, falling back to hardcoded colors otherwise.

    Helpers:
    - Show-DiagnosticResults:  renders PU diagnostic report (used by Phase 3, 4, 8, Quick Diagnostics)
    - Invoke-QuickDiagnostics: main menu shortcut for quick health check
    - Invoke-FullReport:       main menu shortcut for per-phase status report

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# Shared diagnostic result renderer (used by Phase 3, Phase 4, and Quick Diagnostics)
function Show-DiagnosticResults {
    param([Parameter(Mandatory)] $Diagnostics)

    $Diag = $Diagnostics

    if ($Diag.OK) {
        Write-StepOK 'Diagnostyka: OK'
        return
    }

    # Category: unresolved character names
    if ($Diag.UnresolvedCharacters -and $Diag.UnresolvedCharacters.Count -gt 0) {
        Write-SectionHeader "NIEROZWIĄZANE NAZWY POSTACI ($($Diag.UnresolvedCharacters.Count))"
        foreach ($Item in $Diag.UnresolvedCharacters) {
            Write-Host "    '$($Item.Character)' w sesji: $($Item.SessionHeader)" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
            if ($Item.FilePath) {
                Write-Host "      Plik: $($Item.FilePath)" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
            }
            Write-Host '      Opcja A: Popraw literówkę w pliku sesji' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
            Write-Host "      Opcja B: Dodaj alias komendą:" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
            Write-CommandHint "Set-PlayerCharacter -PlayerName `"...`" -CharacterName `"...`" -Aliases @(`"$($Item.Character)`")"
        }
    }

    # Category: malformed PU values
    if ($Diag.MalformedPU -and $Diag.MalformedPU.Count -gt 0) {
        Write-SectionHeader "BŁĘDNE WARTOŚCI PU ($($Diag.MalformedPU.Count))"
        foreach ($Item in $Diag.MalformedPU) {
            Write-Host "    Postać '$($Item.Character)' w sesji '$($Item.SessionHeader)'" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
            Write-Host "      Wartość: '$($Item.Value)' (oczekiwana: liczba, np. 0.3)" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
        }
    }

    # Category: duplicate PU entries
    if ($Diag.DuplicateEntries -and $Diag.DuplicateEntries.Count -gt 0) {
        Write-SectionHeader "DUPLIKATY PU ($($Diag.DuplicateEntries.Count))"
        foreach ($Item in $Diag.DuplicateEntries) {
            Write-Host "    '$($Item.CharacterName)' x$($Item.Count) w sesji: $($Item.SessionHeader)" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
            Write-Host '      Usuń zduplikowane wpisy (zachowaj poprawną wartość)' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
        }
    }

    # Category: sessions with malformed dates
    if ($Diag.FailedSessionsWithPU -and $Diag.FailedSessionsWithPU.Count -gt 0) {
        Write-SectionHeader "SESJE Z BŁĘDNĄ DATĄ ($($Diag.FailedSessionsWithPU.Count))"
        foreach ($Item in $Diag.FailedSessionsWithPU) {
            Write-Host "    Nagłówek: '$($Item.Header)'" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
            if ($Item.FilePath) {
                Write-Host "      Plik: $($Item.FilePath)" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
            }
            Write-Host '      Poprawka: zmień datę na format YYYY-MM-DD' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
        }
    }

    # Category: stale history entries (informational only, non-blocking)
    if ($Diag.StaleHistoryEntries -and $Diag.StaleHistoryEntries.Count -gt 0) {
        Write-SectionHeader "PRZESTARZAŁE WPISY HISTORII ($($Diag.StaleHistoryEntries.Count))"
        foreach ($Item in $Diag.StaleHistoryEntries) {
            $Header = if ($Item -is [string]) { $Item } else { $Item.Header }
            Write-Host "    '$Header'" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
        }
        Write-Host '    Status: informacyjny (nie blokuje operacji)' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
    }
}

# ============================================================================
# QUICK DIAGNOSTICS - main menu shortcut
# ============================================================================

function Invoke-QuickDiagnostics {
    $AccentColor = Resolve-MigrationColor -Role 'Accent'

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor $AccentColor
    Write-Host '  SZYBKA DIAGNOSTYKA' -ForegroundColor $AccentColor
    Write-Host ('=' * 60) -ForegroundColor $AccentColor

    Write-Step -Number 1 -Text 'Diagnostyka PU...'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs
    Show-DiagnosticResults -Diagnostics $Diag

    Write-Step -Number 2 -Text 'Rekoncyliacja walut...'
    try {
        $Recon = Test-CurrencyReconciliation
        if ($Recon.WarningCount -eq 0) {
            Write-StepOK 'Waluty: brak ostrzeżeń'
        } else {
            Write-StepWarning "Waluty: $($Recon.WarningCount) ostrzeżeń"
        }
    }
    catch {
        Write-Host '  Waluty: nie skonfigurowane (brak encji walutowych)' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
    }

    Write-Step -Number 3 -Text 'Format sesji...'
    $Sessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs
    $FormatGroups = $Sessions | Group-Object Format | Sort-Object Name
    foreach ($Group in $FormatGroups) {
        Write-Host "    $($Group.Name): $($Group.Count)" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
    }

    Write-Host ''
    if ($Diag.OK) {
        Write-StepOK 'OGÓLNY STATUS: OK'
    } else {
        $Total = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                 $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
        Write-StepWarning "OGÓLNY STATUS: $Total problemów do rozwiązania"
    }
}

# ============================================================================
# FULL REPORT - per-phase status with checklists
# ============================================================================

function Invoke-FullReport {
    param([Parameter(Mandatory)] [hashtable]$State)

    $AccentColor = Resolve-MigrationColor -Role 'Accent'

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor $AccentColor
    Write-Host '  PEŁNY RAPORT MIGRACJI' -ForegroundColor $AccentColor
    Write-Host ('=' * 60) -ForegroundColor $AccentColor

    # Use registry if available, fallback to hardcoded 0-8
    $Phases = if ($script:PhaseRegistry) {
        $script:PhaseRegistry
    } else {
        0..8 | ForEach-Object { @{ ID = $_; Name = $script:PhaseNames[$_] } }
    }

    foreach ($Phase in $Phases) {
        $Status = Get-PhaseStatus -State $State -Phase $Phase.ID
        $StatusInfo = $script:StatusDisplay[$Status]
        $StatusColor = Resolve-MigrationColor -Role $StatusInfo.Role

        Write-Host ''
        Write-Host "  Faza $($Phase.ID): $($Phase.Name) - $($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusColor

        $PhaseData = $State.Phases["$($Phase.ID)"]
        if ($PhaseData -and $PhaseData.Checklist) {
            foreach ($Key in ($PhaseData.Checklist.Keys | Sort-Object)) {
                $Val = $PhaseData.Checklist[$Key]
                $Icon = if ($Val -eq $true) { "$([char]0x2713)" } else { '[ ]' }
                $Color = if ($Val -eq $true) { Resolve-MigrationColor -Role 'Success' } else { Resolve-MigrationColor -Role 'Disabled' }
                Write-Host "    $Icon $Key`: $Val" -ForegroundColor $Color
            }
        }
    }

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor $AccentColor
}

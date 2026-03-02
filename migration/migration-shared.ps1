<#
    .SYNOPSIS
    Shared diagnostic display and menu helper functions for migration.

    .DESCRIPTION
    Non-exported helpers consumed by multiple phases and the main menu
    via dot-sourcing. Provides diagnostic result rendering and menu shortcuts.

    Helpers:
    - Show-DiagnosticResults:  renders PU diagnostic report (used by Phase 2, 3, 7, Quick Diagnostics)
    - Invoke-QuickDiagnostics: main menu shortcut for quick health check
    - Invoke-FullReport:       main menu shortcut for per-phase status report

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# Shared diagnostic result renderer (used by Phase 2, Phase 3, and Quick Diagnostics)
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
            Write-Host "    '$($Item.Character)' w sesji: $($Item.SessionHeader)" -ForegroundColor Yellow
            if ($Item.FilePath) {
                Write-Host "      Plik: $($Item.FilePath)" -ForegroundColor DarkGray
            }
            Write-Host '      Opcja A: Popraw literówkę w pliku sesji' -ForegroundColor DarkGray
            Write-Host "      Opcja B: Dodaj alias komendą:" -ForegroundColor DarkGray
            Write-CommandHint "Set-PlayerCharacter -PlayerName `"...`" -CharacterName `"...`" -Aliases @(`"$($Item.Character)`")"
        }
    }

    # Category: malformed PU values
    if ($Diag.MalformedPU -and $Diag.MalformedPU.Count -gt 0) {
        Write-SectionHeader "BŁĘDNE WARTOŚCI PU ($($Diag.MalformedPU.Count))"
        foreach ($Item in $Diag.MalformedPU) {
            Write-Host "    Postać '$($Item.Character)' w sesji '$($Item.SessionHeader)'" -ForegroundColor Yellow
            Write-Host "      Wartość: '$($Item.Value)' (oczekiwana: liczba, np. 0.3)" -ForegroundColor DarkGray
        }
    }

    # Category: duplicate PU entries
    if ($Diag.DuplicateEntries -and $Diag.DuplicateEntries.Count -gt 0) {
        Write-SectionHeader "DUPLIKATY PU ($($Diag.DuplicateEntries.Count))"
        foreach ($Item in $Diag.DuplicateEntries) {
            Write-Host "    '$($Item.CharacterName)' x$($Item.Count) w sesji: $($Item.SessionHeader)" -ForegroundColor Yellow
            Write-Host '      Usuń zduplikowane wpisy (zachowaj poprawną wartość)' -ForegroundColor DarkGray
        }
    }

    # Category: sessions with malformed dates
    if ($Diag.FailedSessionsWithPU -and $Diag.FailedSessionsWithPU.Count -gt 0) {
        Write-SectionHeader "SESJE Z BŁĘDNĄ DATĄ ($($Diag.FailedSessionsWithPU.Count))"
        foreach ($Item in $Diag.FailedSessionsWithPU) {
            Write-Host "    Nagłówek: '$($Item.Header)'" -ForegroundColor Yellow
            if ($Item.FilePath) {
                Write-Host "      Plik: $($Item.FilePath)" -ForegroundColor DarkGray
            }
            Write-Host '      Poprawka: zmień datę na format YYYY-MM-DD' -ForegroundColor DarkGray
        }
    }

    # Category: stale history entries (informational only, non-blocking)
    if ($Diag.StaleHistoryEntries -and $Diag.StaleHistoryEntries.Count -gt 0) {
        Write-SectionHeader "PRZESTARZAŁE WPISY HISTORII ($($Diag.StaleHistoryEntries.Count))"
        foreach ($Item in $Diag.StaleHistoryEntries) {
            $Header = if ($Item -is [string]) { $Item } else { $Item.Header }
            Write-Host "    '$Header'" -ForegroundColor DarkGray
        }
        Write-Host '    Status: informacyjny (nie blokuje operacji)' -ForegroundColor DarkGray
    }
}

# ============================================================================
# QUICK DIAGNOSTICS - main menu shortcut
# ============================================================================

function Invoke-QuickDiagnostics {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host '  SZYBKA DIAGNOSTYKA' -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan

    Write-Step -Number 1 -Text 'Diagnostyka PU...'
    $Diag = Test-PlayerCharacterPUAssignment
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
        Write-Host '  Waluty: nie skonfigurowane (brak encji walutowych)' -ForegroundColor DarkGray
    }

    Write-Step -Number 3 -Text 'Format sesji...'
    $Sessions = Get-Session
    $FormatGroups = $Sessions | Group-Object Format | Sort-Object Name
    foreach ($Group in $FormatGroups) {
        Write-Host "    $($Group.Name): $($Group.Count)" -ForegroundColor DarkGray
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

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host '  PEŁNY RAPORT MIGRACJI' -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan

    for ($I = 0; $I -le 7; $I++) {
        $Status = Get-PhaseStatus -State $State -Phase $I
        $StatusInfo = $script:StatusDisplay[$Status]
        $Name = $script:PhaseNames[$I]

        Write-Host ''
        Write-Host "  Faza $I`: $Name - $($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusInfo.Color

        $PhaseData = $State.Phases["$I"]
        if ($PhaseData -and $PhaseData.Checklist) {
            foreach ($Key in ($PhaseData.Checklist.Keys | Sort-Object)) {
                $Val = $PhaseData.Checklist[$Key]
                $Icon = if ($Val -eq $true) { "[$(([char]0x2713))]" } else { '[ ]' }
                $Color = if ($Val -eq $true) { 'Green' } else { 'DarkGray' }
                Write-Host "    $Icon $Key`: $Val" -ForegroundColor $Color
            }
        }
    }

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

<#
    .SYNOPSIS
    PU-domain CLI workflows - assignment wizard, pre-assignment diagnostics,
    and diagnostic display.

    .DESCRIPTION
    This file contains workflow functions for PU (Punkty Umiejętności) management,
    consumed by the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-PUAssignmentWorkflow:  dry-run -> preview -> multi-select -> execute
    - Invoke-PrePUDiagnostics:      composite PU diagnostics with name suggestions
    - Invoke-PUDiagnosticsDisplay:  formatted PU diagnostic report

    Dependencies: cli-primitives.ps1, cli-wizard.ps1, cli-display.ps1
#>

# ── PU Assignment Workflow ───────────────────────────────────────────────────

function Invoke-PUAssignmentWorkflow {
    param([object]$State, [hashtable]$Entry)

    $Colors = Initialize-WorkflowScreen -Title 'Przydział miesięczny PU' -NoSeparator
    $AccentColor   = $Colors.Accent
    $SuccessColor  = $Colors.Success
    $ErrorColor    = $Colors.Error
    $WarningColor  = $Colors.Warning
    $DisabledColor = $Colors.Disabled

    # ── Step 1: Year ──

    if ($Entry.PreChecks) {
        Show-InfoBox -Checks $Entry.PreChecks
    }

    $YearStep = New-WizardNumberStep -Name 'Year' -Label 'Rok' -Required -Default ([string](Get-Date).Year)
    $Year = Invoke-WizardStep -Step $YearStep -State $State
    if ($Year -eq '__back__') { return }

    # ── Step 2: Month ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Rok: $Year" -Color $DisabledColor
    Write-Host ''

    $MonthStep = New-WizardNumberStep -Name 'Month' -Label 'Miesiąc (1-12)' -Required -Default ([string](Get-Date).Month)
    $Month = Invoke-WizardStep -Step $MonthStep -State $State
    if ($Month -eq '__back__') { return }

    # ── Step 3: Session integrity pre-check ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Rok: $Year  Miesiąc: $Month" -Color $DisabledColor
    Write-Host ''
    $PUProg = New-ProgressState -Title 'Sprawdzanie integralności sesji' -TotalSteps 1
    Start-ProgressStep -State $PUProg -Label 'Integralność'
    $IntegrityPassed = $true
    try {
        $IntCB = { param($C,$T,$D); Update-ProgressStep -State $PUProg -Detail "$C/$T" }.GetNewClosure()
        $Integrity = Test-SessionIntegrity -ProgressCallback $IntCB

        if (-not $Integrity.OK) {
            Complete-ProgressStep -State $PUProg -Detail 'Problemy' -Failed
        } else {
            Complete-ProgressStep -State $PUProg -Detail 'OK'
        }
        Complete-ProgressGroup -State $PUProg

        if (-not $Integrity.OK) {
            Write-Host ''
            Write-CLILine -Text "$([char]0x26A0) Wykryto problemy integralności sesji:" -Color $WarningColor

            # High-severity issues first
            if ($Integrity.PUAffectedSessions -and $Integrity.PUAffectedSessions.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x2717) Zmodyfikowane sesje z danymi PU: $($Integrity.PUAffectedSessions.Count)" -Color $ErrorColor
                foreach ($Item in $Integrity.PUAffectedSessions | Select-Object -First 5) {
                    Write-CLILine -Text "      $($Item.Header)" -Color $ErrorColor
                }
            }
            if ($Integrity.DuplicatePUMarkers -and $Integrity.DuplicatePUMarkers.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x2717) Duplikaty znaczników PU: $($Integrity.DuplicatePUMarkers.Count)" -Color $ErrorColor
                foreach ($Item in $Integrity.DuplicatePUMarkers | Select-Object -First 5) {
                    Write-CLILine -Text "      $($Item.Header) (x$($Item.PUMarkerCount))" -Color $ErrorColor
                }
            }
            if ($Integrity.FutureDatedSessions -and $Integrity.FutureDatedSessions.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x2717) Sesje z przyszłą datą: $($Integrity.FutureDatedSessions.Count)" -Color $ErrorColor
            }

            # Lower-severity issues
            if ($Integrity.ModifiedSessions -and $Integrity.ModifiedSessions.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x26A0) Zmodyfikowane sesje: $($Integrity.ModifiedSessions.Count)" -Color $WarningColor
            }
            if ($Integrity.MalformedHeaders -and $Integrity.MalformedHeaders.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x26A0) Nieprawidłowe nagłówki: $($Integrity.MalformedHeaders.Count)" -Color $WarningColor
            }
            if ($Integrity.FormatAnomalies -and $Integrity.FormatAnomalies.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x26A0) Anomalie formatu: $($Integrity.FormatAnomalies.Count)" -Color $WarningColor
            }
            if ($Integrity.MissingHashFiles -and $Integrity.MissingHashFiles.Count -gt 0) {
                Write-CLILine -Text "  $([char]0x25CB) Brak plików hashy: $($Integrity.MissingHashFiles.Count)" -Color $DisabledColor
            }

            Write-Host ''
            $ContinueComponent = New-WizardStepComponent -Label 'Kontynuować mimo problemów?' `
                -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
            $Continue = Invoke-EngineLifecycle -Component $ContinueComponent -State $State
            if ($Continue -eq '__quit__') { return '__quit__' }
            if ($Continue -ne $true) { return }
        } else {
            Write-CLILine -Text "$([char]0x2713) Integralność sesji: OK" -Color $SuccessColor
        }
    }
    catch {
        Complete-ProgressStep -State $PUProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $PUProg
        Write-CLILine -Text "$([char]0x26A0) Nie udało się sprawdzić integralności: $_" -Color $WarningColor
    }

    # ── Step 4: Dry run ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Rok: $Year  Miesiąc: $Month" -Color $DisabledColor
    Write-Host ''
    $DryProg = New-ProgressState -Title "Obliczanie PU za $Month/$Year" -TotalSteps 1
    Start-ProgressStep -State $DryProg -Label 'Symulacja'

    try {
        $DryResults = Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month -WhatIf *>&1 | Out-String
        Complete-ProgressStep -State $DryProg -Detail 'OK'
        Complete-ProgressGroup -State $DryProg

        Write-Host ''
        Write-CLILine -Text 'Wynik próbny:' -Color $WarningColor
        foreach ($Line in $DryResults.Split("`n")) {
            if (-not [string]::IsNullOrWhiteSpace($Line)) {
                Write-Host "    $($Line.Trim())" -ForegroundColor $WarningColor
            }
        }
    }
    catch {
        Complete-ProgressStep -State $DryProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $DryProg
        Write-CLILine -Text "Błąd: $_" -Color $ErrorColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz, aby przejść do opcji...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)

    # ── Step 5: Flags ──
    $Flags = [ordered]@{
        'UpdatePlayerCharacters' = $true
        'SendToDiscord'          = $true
        'AppendToLog'            = $true
        'ReconcileCurrency'      = $true
    }
    $FlagLabels = [ordered]@{
        'UpdatePlayerCharacters' = 'Aktualizuj postacie'
        'SendToDiscord'          = 'Wyślij na Discord'
        'AppendToLog'            = 'Dodaj do dziennika'
        'ReconcileCurrency'      = 'Uzgodnij waluty'
    }

    foreach ($FlagKey in @($Flags.Keys)) {
        [System.Console]::Clear()
        Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
        Write-Host ''
        Write-CLILine -Text "  Rok: $Year  Miesiąc: $Month" -Color $DisabledColor
        Write-Host ''

        # Show already-set flags as context
        foreach ($SetKey in @($Flags.Keys)) {
            if ($SetKey -eq $FlagKey) { break }
            $SetLabel = $FlagLabels[$SetKey]
            $SetVal = if ($Flags[$SetKey]) { "$([char]0x2713) Tak" } else { "$([char]0x2717) Nie" }
            Write-CLILine -Text "  $SetLabel`: $SetVal" -Color $DisabledColor
        }
        Write-Host ''

        $FlagLabel = $FlagLabels[$FlagKey]
        $FlagComponent = New-WizardStepComponent -Label $FlagLabel `
            -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
        $FlagChoice = Invoke-EngineLifecycle -Component $FlagComponent -State $State
        if ($FlagChoice -eq '__quit__') { return '__quit__' }
        if ($FlagChoice -eq '__back__') { return }
        $Flags[$FlagKey] = $FlagChoice
    }

    # ── Step 6: Confirmation ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Rok: $Year  Miesiąc: $Month" -Color $DisabledColor
    Write-Host ''
    foreach ($FlagKey in @($Flags.Keys)) {
        $FlagLabel = $FlagLabels[$FlagKey]
        $FlagVal = if ($Flags[$FlagKey]) { "$([char]0x2713) Tak" } else { "$([char]0x2717) Nie" }
        Write-CLILine -Text "  $FlagLabel`: $FlagVal" -Color $DisabledColor
    }
    Write-Host ''

    $ConfirmComponent = New-WizardStepComponent -Label 'Wykonać przydział PU?' `
        -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
    $Confirm = Invoke-EngineLifecycle -Component $ConfirmComponent -State $State
    if ($Confirm -eq '__quit__') { return '__quit__' }

    if ($Confirm -ne $true) {
        Write-CLILine -Text 'Anulowano.' -Color $DisabledColor
        return
    }

    try {
        $ExecParams = @{ Year = $Year; Month = $Month }
        foreach ($FlagKey in $Flags.Keys) {
            if ($Flags[$FlagKey]) {
                $ExecParams[$FlagKey] = [switch]$true
            }
        }

        $ExecResult = Invoke-PlayerCharacterPUAssignment @ExecParams

        Write-Host ''
        Write-CLILine -Text "$([char]0x2713) Przydział PU zakończony pomyślnie." -Color $SuccessColor

        try { Refresh-NavState -State $State } catch {}
    }
    catch {
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

# ── Pre-PU Diagnostics ───────────────────────────────────────────────────────

function Invoke-PrePUDiagnostics {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $WarningColor = Get-CLIColor -Role 'Warning'
    $ErrorColor = Get-CLIColor -Role 'Error'

    Write-CLILine -Text 'Diagnostyka przed przydziałem PU' -Color $AccentColor

    if ($Entry.PreChecks) {
        Show-InfoBox -Checks $Entry.PreChecks
    }

    $DiagProg = New-ProgressState -Title 'Diagnostyka PU' -TotalSteps 1
    Start-ProgressStep -State $DiagProg -Label 'Walidacja'
    try {
        $DiagCB = { param($C,$T,$D); Update-ProgressStep -State $DiagProg -Detail "$C/$T" }.GetNewClosure()
        $Diag = Test-PlayerCharacterPUAssignment -ProgressCallback $DiagCB

        if ($Diag.OK) {
            Complete-ProgressStep -State $DiagProg -Detail 'OK'
        } else {
            Complete-ProgressStep -State $DiagProg -Detail 'Problemy' -Failed
        }
        Complete-ProgressGroup -State $DiagProg

        if ($Diag.OK) {
            Write-CLILine -Text "$([char]0x2713) Diagnostyka PU: brak problemów." -Color $SuccessColor
        } else {
            Write-CLILine -Text "$([char]0x26A0) Wykryto problemy:" -Color $WarningColor

            if ($Diag.UnresolvedCharacters -and $Diag.UnresolvedCharacters.Count -gt 0) {
                Write-Host ''
                Write-CLILine -Text 'Nierozwiązane postacie:' -Color $ErrorColor
                foreach ($Unresolved in $Diag.UnresolvedCharacters) {
                    $CharName = if ($Unresolved.CharacterName) { $Unresolved.CharacterName } else { [string]$Unresolved }
                    Write-CLILine -Text "  $([char]0x2717) $CharName"

                    # Attempt to suggest matches
                    if ($State.NameIndex) {
                        $Suggestion = Resolve-Name -Query $CharName `
                            -Index $State.NameIndex.Index `
                            -StemIndex $State.NameIndex.StemIndex `
                            -BKTree $State.NameIndex.BKTree `
                            -Cache $State.ResolveCache

                        if ($Suggestion) {
                            $SugName = if ($Suggestion.Name) { $Suggestion.Name } else { [string]$Suggestion }
                            Write-CLILine -Text "    Sugestia: $SugName" -Color (Get-CLIColor -Role 'Info')
                        }
                    }
                }
            }

            if ($Diag.Warnings -and $Diag.Warnings.Count -gt 0) {
                Write-Host ''
                Write-CLILine -Text 'Ostrzeżenia:' -Color $WarningColor
                foreach ($Warn in $Diag.Warnings) {
                    Write-CLILine -Text "  $([char]0x26A0) $Warn" -Color $WarningColor
                }
            }
        }
    }
    catch {
        Complete-ProgressStep -State $DiagProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $DiagProg
        Write-CLILine -Text "$([char]0x2717) Błąd diagnostyki: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

# ── PU Diagnostics Display ───────────────────────────────────────────────────

function Invoke-PUDiagnosticsDisplay {
    param([object]$State, [hashtable]$Entry)

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $WarningColor = Get-CLIColor -Role 'Warning'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-Host ''
    Write-CLILine -Text 'Diagnostyka PU' -Color $AccentColor
    Write-Host ''

    try {
        $Diag = Test-PlayerCharacterPUAssignment

        if ($Diag.OK) {
            Write-CLILine -Text "$([char]0x2713) Diagnostyka: OK - brak problemów." -Color $SuccessColor
        }
        else {
            if ($Diag.UnresolvedCharacters -and $Diag.UnresolvedCharacters.Count -gt 0) {
                Write-CLILine -Text "Nierozwiązane nazwy postaci ($($Diag.UnresolvedCharacters.Count)):" -Color $WarningColor
                foreach ($Item in $Diag.UnresolvedCharacters) {
                    Write-CLILine -Text "    '$($Item.Character)' w sesji: $($Item.SessionHeader)" -Color $WarningColor
                }
                Write-Host ''
            }

            if ($Diag.MalformedPU -and $Diag.MalformedPU.Count -gt 0) {
                Write-CLILine -Text "Błędne wartości PU ($($Diag.MalformedPU.Count)):" -Color $WarningColor
                foreach ($Item in $Diag.MalformedPU) {
                    Write-CLILine -Text "    '$($Item.Character)' = '$($Item.Value)' w: $($Item.SessionHeader)" -Color $WarningColor
                }
                Write-Host ''
            }

            if ($Diag.DuplicateEntries -and $Diag.DuplicateEntries.Count -gt 0) {
                Write-CLILine -Text "Duplikaty PU ($($Diag.DuplicateEntries.Count)):" -Color $WarningColor
                foreach ($Item in $Diag.DuplicateEntries) {
                    Write-CLILine -Text "    '$($Item.CharacterName)' x$($Item.Count) w: $($Item.SessionHeader)" -Color $WarningColor
                }
                Write-Host ''
            }

            if ($Diag.FailedSessionsWithPU -and $Diag.FailedSessionsWithPU.Count -gt 0) {
                Write-CLILine -Text "Sesje z błędną datą ($($Diag.FailedSessionsWithPU.Count)):" -Color $WarningColor
                foreach ($Item in $Diag.FailedSessionsWithPU) {
                    Write-CLILine -Text "    '$($Item.Header)'" -Color $WarningColor
                }
                Write-Host ''
            }

            if ($Diag.StaleHistoryEntries -and $Diag.StaleHistoryEntries.Count -gt 0) {
                Write-CLILine -Text "Przestarzałe wpisy ($($Diag.StaleHistoryEntries.Count)):" -Color $DisabledColor
                foreach ($Item in $Diag.StaleHistoryEntries) {
                    $Header = if ($Item -is [string]) { $Item } else { $Item.Header }
                    Write-CLILine -Text "    '$Header'" -Color $DisabledColor
                }
                Write-CLILine -Text '    (informacyjne - nie blokuje operacji)' -Color $DisabledColor
                Write-Host ''
            }

            $Total = ($Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                     $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count)
            Write-CLILine -Text "$([char]0x26A0) Łącznie: $Total problemów do rozwiązania" -Color $WarningColor
        }
    }
    catch {
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

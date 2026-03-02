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

    $AccentColor = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor = Get-CLIColor -Role 'Error'
    $WarningColor = Get-CLIColor -Role 'Warning'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    # ── Step 1: Year ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''

    if ($Entry.PreChecks) {
        Show-InfoBox -Checks $Entry.PreChecks
    }

    $YearStep = [PSCustomObject]@{
        Name = 'Year'; Label = 'Rok'; StepType = 'number'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = [string](Get-Date).Year
    }
    $Year = Invoke-WizardStep -Step $YearStep -State $State
    if ($Year -eq '__back__' -or $Year -eq '__quit__') { return }

    # ── Step 2: Month ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Rok: $Year" -Color $DisabledColor
    Write-Host ''

    $MonthStep = [PSCustomObject]@{
        Name = 'Month'; Label = 'Miesiąc (1-12)'; StepType = 'number'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = [string](Get-Date).Month
    }
    $Month = Invoke-WizardStep -Step $MonthStep -State $State
    if ($Month -eq '__back__' -or $Month -eq '__quit__') { return }

    # ── Step 3: Dry run ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Przydział miesięczny PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Rok: $Year  Miesiąc: $Month" -Color $DisabledColor
    Write-Host ''
    Write-Host "  Obliczanie PU za $Month/$Year..." -ForegroundColor $DisabledColor

    try {
        $DryResults = Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month -WhatIf *>&1 | Out-String

        Write-Host ''
        Write-CLILine -Text 'Wynik próbny:' -Color $WarningColor
        foreach ($Line in $DryResults.Split("`n")) {
            if (-not [string]::IsNullOrWhiteSpace($Line)) {
                Write-Host "    $($Line.Trim())" -ForegroundColor $WarningColor
            }
        }
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color $ErrorColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void](Read-ArrowKey)
        return
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz, aby przejść do opcji...' -Color $DisabledColor
    [void](Read-ArrowKey)

    # ── Step 4: Flags ──
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
        Write-CLILine -Text "$FlagLabel`:" -Color $AccentColor
        $FlagChoice = Show-ArrowMenu -Items @(
            [PSCustomObject]@{ ID = 'yes'; Label = 'Tak'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
            [PSCustomObject]@{ ID = 'no';  Label = 'Nie'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        ) -ShowBack
        if ($FlagChoice -eq '__back__' -or $FlagChoice -eq '__quit__') { return }
        $Flags[$FlagKey] = ($FlagChoice -eq 'yes')
    }

    # ── Step 5: Confirmation ──
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

    Write-CLILine -Text 'Wykonać przydział PU?' -Color $AccentColor
    $Confirm = Show-ArrowMenu -Items @(
        [PSCustomObject]@{ ID = 'yes'; Label = 'Tak, wykonaj'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'no';  Label = 'Anuluj';       Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
    ) -ShowBack

    if ($Confirm -ne 'yes') {
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
    [void](Read-ArrowKey)
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

    Write-Host '  Uruchamianie diagnostyki...' -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-Host ''

    try {
        $Diag = Test-PlayerCharacterPUAssignment

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
        Write-CLILine -Text "$([char]0x2717) Błąd diagnostyki: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
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
    [void](Read-ArrowKey)
}

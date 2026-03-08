<#
    .SYNOPSIS
    Phase 2: Data validation & repair (iterative).

    .DESCRIPTION
    Loads players/characters, spot-checks PU values, verifies aliases and
    webhooks, runs full PU diagnostics. If issues are found, offers repair:
    soft-delete for characters with PU=BRAK, narrator normalization with
    interactive mapping. Designed to be run repeatedly until all issues
    are resolved.

    Dependencies: migration-ui.ps1, migration-state.ps1, migration-shared.ps1,
                  narrator-normalization.ps1, robot module imported.
#>

# ============================================================================
# PHASE 2 - Data validation & repair (iterative)
# ============================================================================

function Invoke-MigrationPhase2 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 2)) {
        Write-StepWarning 'Faza 1 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 2
    Write-PhaseHeader -Phase 2 -Status $PhaseStatus

    # ── Validation ────────────────────────────────────────────────────────────

    # Step 1: Load and count players/characters
    Write-Step -Number 1 -Text 'Ładowanie danych graczy...'
    $Players = Get-Player
    $PlayerCount = ($Players | Measure-Object).Count
    $CharCount = ($Players | ForEach-Object { $_.Characters } | Measure-Object).Count
    Write-StepOK "Załadowano: $PlayerCount graczy, $CharCount postaci"
    Update-PhaseChecklist -State $State -Phase 2 -Item 'PlayerCount' -Value $PlayerCount
    Update-PhaseChecklist -State $State -Phase 2 -Item 'CharacterCount' -Value $CharCount

    # Step 2: Show per-player character counts (first 10)
    Write-Step -Number 2 -Text 'Liczba postaci per gracz (przykład)...'
    $Shown = 0
    foreach ($Player in $Players) {
        if ($Shown -ge 10) { break }
        $Count = ($Player.Characters | Measure-Object).Count
        Write-Host "    $($Player.Name): $Count postaci" -ForegroundColor DarkGray
        $Shown++
    }
    if ($PlayerCount -gt 10) {
        Write-Host "    ... (i $($PlayerCount - 10) więcej)" -ForegroundColor DarkGray
    }

    # Step 3: Spot-check PU values on sample characters
    Write-Step -Number 3 -Text 'Wyrywkowa weryfikacja wartości PU...'
    $PUShown = 0
    foreach ($Player in $Players) {
        foreach ($Char in $Player.Characters) {
            if ($null -ne $Char.PUSum -and $PUShown -lt 5) {
                Write-Host "    $($Char.Name): SUMA=$($Char.PUSum) STARTOWE=$($Char.PUStart) NADMIAR=$($Char.PUExceeded)" -ForegroundColor DarkGray
                $PUShown++
            }
        }
    }
    Update-PhaseChecklist -State $State -Phase 2 -Item 'PUSpotCheck' -Value $true

    # Step 4: Count characters with aliases
    Write-Step -Number 4 -Text 'Sprawdzanie aliasów...'
    $AliasCount = 0
    $AliasShown = 0
    foreach ($Player in $Players) {
        foreach ($Char in $Player.Characters) {
            if ($Char.Aliases -and $Char.Aliases.Count -gt 0) {
                $AliasCount++
                if ($AliasShown -lt 3) {
                    Write-Host "    $($Char.Name): $($Char.Aliases -join ', ')" -ForegroundColor DarkGray
                    $AliasShown++
                }
            }
        }
    }
    Write-StepOK "Postaci z aliasami: $AliasCount"
    Update-PhaseChecklist -State $State -Phase 2 -Item 'AliasesChecked' -Value $true

    # Step 5: Check players missing Discord webhooks (only Active players)
    Write-Step -Number 5 -Text 'Sprawdzanie webhooków (aktywni gracze)...'

    # Build player status lookup from entity data (use config-resolved path
    # so the manifest-redirected entities.md is read, not the submodule default)
    $PlayerStatusMap = @{}
    $EntitiesConfig = Get-AdminConfig
    foreach ($E in (Get-Entity -Path $EntitiesConfig.EntitiesFile)) {
        if ([string]::Equals($E.Type, 'Gracz', [System.StringComparison]::OrdinalIgnoreCase)) {
            $PlayerStatusMap[$E.Name] = $E.Status
        }
    }

    $NoWebhook = [System.Collections.Generic.List[string]]::new()
    $SkippedInactive = 0
    foreach ($Player in $Players) {
        $PlayerStatus = $PlayerStatusMap[$Player.Name]
        if (-not $PlayerStatus) { $PlayerStatus = 'Aktywny' }

        if (-not [string]::Equals($PlayerStatus, 'Aktywny', [System.StringComparison]::OrdinalIgnoreCase)) {
            $SkippedInactive++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Player.PRFWebhook) -or $Player.PRFWebhook -eq 'BRAK') {
            $NoWebhook.Add($Player.Name)
        }
    }

    if ($NoWebhook.Count -gt 0) {
        Write-StepWarning "Aktywnych graczy bez webhooka: $($NoWebhook.Count)"
        if ($SkippedInactive -gt 0) {
            Write-Host "    (pominięto $SkippedInactive nieaktywnych graczy)" -ForegroundColor DarkGray
        }
        foreach ($Name in ($NoWebhook | Select-Object -First 5)) {
            Write-Host "    - $Name" -ForegroundColor DarkGray
        }
        if ($NoWebhook.Count -gt 5) {
            Write-Host "    ... (i $($NoWebhook.Count - 5) więcej)" -ForegroundColor DarkGray
        }

        # Offer to mark webhook-less active players as inactive
        $WebhooksResolved = $false
        if (-not $WhatIf) {
            $MarkInactive = Request-YesNo -Prompt 'Czy chcesz oznaczyć ich jako nieaktywnych?' -Default $false -HelpText @(
                'Oznaczenie aktywnych graczy bez webhooka Discord',
                'jako nieaktywnych (@status: Nieaktywny) w entities.md.',
                '',
                'Gracze bez webhooka nie mogą otrzymywać powiadomień PU.',
                'Oznaczenie ich jako nieaktywnych zapobiega błędom',
                'przy późniejszym przydzielaniu PU.',
                '',
                'Tak = ustaw @status: Nieaktywny dla wylistowanych graczy',
                'Nie = pomiń — gracze pozostaną aktywni bez webhooka'
            )
            if ($MarkInactive) {
                $MarkedCount = 0
                foreach ($PlayerName in $NoWebhook) {
                    try {
                        Set-Player -Name $PlayerName -Status 'Nieaktywny' -Confirm:$false
                        $MarkedCount++
                    }
                    catch {
                        Write-StepError "Nie udało się oznaczyć '$PlayerName': $($_.Exception.Message)"
                    }
                }
                if ($MarkedCount -gt 0) {
                    Write-StepOK "Oznaczono $MarkedCount graczy jako nieaktywnych"
                    $WebhooksResolved = ($MarkedCount -eq $NoWebhook.Count)
                }
            }
        }
    } else {
        $WebhooksResolved = $true
        $OkMsg = 'Wszyscy aktywni gracze mają webhook'
        if ($SkippedInactive -gt 0) {
            $OkMsg += " (pominięto $SkippedInactive nieaktywnych)"
        }
        Write-StepOK $OkMsg
    }
    Update-PhaseChecklist -State $State -Phase 2 -Item 'WebhooksChecked' -Value $true

    # Step 6: Run full PU diagnostics
    Write-Step -Number 6 -Text 'Uruchamianie diagnostyki PU...'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs
    Show-DiagnosticResults -Diagnostics $Diag
    Update-PhaseChecklist -State $State -Phase 2 -Item 'DiagnosticsRun' -Value $true
    Update-PhaseChecklist -State $State -Phase 2 -Item 'DiagnosticsOK' -Value $Diag.OK

    # ── Repair (if diagnostics found issues) ──────────────────────────────────

    if ($Diag.OK) {
        # No issues — check narrator normalization and complete
        $NarratorNormDone = $State.Phases.ContainsKey('2') -and $State.Phases['2'].ContainsKey('Checklist') -and $State.Phases['2'].Checklist.ContainsKey('NarratorNormalizationDone') -and $State.Phases['2'].Checklist['NarratorNormalizationDone']
        if ($NarratorNormDone) {
            Set-PhaseCompleted -State $State -Phase 2
            Add-DiagnosticSnapshot -State $State -OK $true -IssueCount 0
            Write-PhaseSummary -Phase 2 -Status 'Completed' -Lines @(
                "[OK] Graczy: $PlayerCount, Postaci: $CharCount",
                '[OK] Diagnostyka PU: OK',
                '[OK] Normalizacja narratorów wykonana'
            )
            if (-not $WhatIf) { Save-MigrationState -State $State }
            return
        }
        # If diagnostics OK but narrator normalization not done, fall through to narrator step
    }

    Set-PhaseInProgress -State $State -Phase 2

    # Step 7: Show characters with PU=BRAK and offer to soft-delete
    if (-not $WhatIf -and -not $Diag.OK) {
        Show-BRAKCharacters -State $State
    }

    # Step 8: Narrator normalization
    $NarratorNormDone = $State.Phases.ContainsKey('2') -and $State.Phases['2'].ContainsKey('Checklist') -and $State.Phases['2'].Checklist.ContainsKey('NarratorNormalizationDone') -and $State.Phases['2'].Checklist['NarratorNormalizationDone']
    $UnresolvedNarratorCount = 0

    if (-not $NarratorNormDone) {
        Write-Step -Number 8 -Text 'Diagnostyka narratorów...'

        $NarrSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs
        $NarrReport = Get-NarratorReport -Sessions $NarrSessions -UnresolvedOnly
        # Filter to Confidence = None and no existing mapping
        $UnresolvedNarrators = @($NarrReport | Where-Object { $_.Confidence -eq 'None' -and -not $_.HasMapping })
        $UnresolvedNarratorCount = $UnresolvedNarrators.Count

        if ($UnresolvedNarratorCount -eq 0) {
            Write-StepOK 'Wszyscy narratorzy rozwiązani lub zamapowani'
            Update-PhaseChecklist -State $State -Phase 2 -Item 'NarratorNormalizationDone' -Value $true
        } else {
            Write-StepWarning "$UnresolvedNarratorCount nierozwiązanych narratorów"

            if (-not $WhatIf) {
                $NarrMappings = Import-NarratorMappings
                $MappingsChanged = $false

                foreach ($U in $UnresolvedNarrators) {
                    Write-Host ''
                    Write-Host "      $($U.RawText) ($($U.OccurrenceCount)x)" -ForegroundColor White
                    if ($U.NearDuplicates.Count -gt 0) {
                        $NDs = ($U.NearDuplicates | ForEach-Object { "$($_.Target) (d=$($_.EditDistance))" }) -join ', '
                        Write-Host "        Podobne: $NDs" -ForegroundColor DarkGray
                    }

                    $Choice = Request-UserChoice `
                        -Prompt "Narrator: $($U.RawText)" `
                        -ValidChoices @('A', 'M', 'P', 'K') `
                        -Labels @{ 'A' = 'Dodaj alias do gracza'; 'M' = 'Mapuj ręcznie na kanoniczne nazwy'; 'P' = 'Pomiń tego narratora'; 'K' = 'Kontynuuj (zakończ przegląd)' } `
                        -HelpText @(
                            'Rozwiązywanie nierozpoznanego narratora sesji.',
                            'Narrator nie został dopasowany do żadnego gracza.',
                            '',
                            'A = dodaj alias (@alias) do istniejącego gracza w entities.md',
                            '    oraz zapisz mapowanie w narrator-mappings.txt',
                            'M = podaj ręcznie kanoniczne nazwy (oddzielone przecinkami)',
                            '    i zapisz mapowanie w narrator-mappings.txt',
                            'P = pomiń tego narratora (nie twórz mapowania)',
                            'K = zakończ przegląd — pozostali narratorzy nie zostaną rozwiązani',
                            '',
                            'Patrz: docs/Migration.md (Faza 2 — Normalizacja narratorów)'
                        )

                    if ($Choice -eq 'K' -or $Choice -eq 'Q') { break }
                    if ($Choice -eq 'P') { continue }

                    if ($Choice -eq 'A') {
                        $PlayerName = Request-StringInput -Prompt 'Nazwa Gracza'
                        if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
                            Set-Player -Name $PlayerName -Aliases @($U.RawText)
                            Write-Host "        → Dodano alias '$($U.RawText)' do gracza '$PlayerName'" -ForegroundColor DarkGray
                            # Also add mapping for @Narrator override
                            $NarrMappings[$U.RawText] = @($PlayerName)
                            $MappingsChanged = $true
                        }
                    }

                    if ($Choice -eq 'M') {
                        $MapInput = Request-StringInput -Prompt 'Kanoniczne nazwy (oddzielone przecinkami)'
                        if (-not [string]::IsNullOrWhiteSpace($MapInput)) {
                            $CanonNames = @($MapInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
                            if ($CanonNames.Count -gt 0) {
                                $NarrMappings[$U.RawText] = $CanonNames
                                $MappingsChanged = $true
                                Write-Host "        → Zamapowano '$($U.RawText)' na: $($CanonNames -join ', ')" -ForegroundColor DarkGray
                            }
                        }
                    }
                }

                if ($MappingsChanged) {
                    Export-NarratorMappings -Mappings $NarrMappings
                    Write-Host "    Zapisano mapowania do narrator-mappings.txt" -ForegroundColor DarkGray
                }
            }

            Update-PhaseChecklist -State $State -Phase 2 -Item 'NarratorNormalizationDone' -Value $true
        }
    } else {
        Write-Step -Number 8 -Text 'Diagnostyka narratorów...'
        Write-StepOK 'Normalizacja narratorów już wykonana'
    }

    # Record diagnostic snapshot and calculate totals
    $TotalIssues = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                   $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count +
                   $UnresolvedNarratorCount
    Add-DiagnosticSnapshot -State $State -OK $Diag.OK -IssueCount $TotalIssues

    # Show diagnostic trend across iterations
    $History = $State.Phases['2'].DiagnosticHistory
    if ($History -and $History.Count -gt 1) {
        Write-SectionHeader 'Trend diagnostyki'
        for ($I = 0; $I -lt $History.Count; $I++) {
            $Entry = $History[$I]
            $IssuesVal = if ($Entry -is [hashtable]) { $Entry.Issues } else { $Entry.Issues }
            $Marker = if ($I -eq ($History.Count - 1)) { '>>>' } else { '   ' }
            Write-Host "  $Marker Przebieg $($I + 1): $IssuesVal problemów" -ForegroundColor DarkGray
        }
    }

    # Phase summary
    $SummaryLines = @(
        "[OK] Graczy: $PlayerCount, Postaci: $CharCount",
        "[OK] PU zweryfikowane (wyrywkowo)",
        "[OK] Aliasy: $AliasCount postaci"
    )
    if ($NoWebhook.Count -gt 0 -and -not $WebhooksResolved) {
        $SummaryLines += "[!!] Aktywnych graczy bez webhooka: $($NoWebhook.Count)"
    } elseif ($NoWebhook.Count -gt 0 -and $WebhooksResolved) {
        $SummaryLines += "[OK] Gracze bez webhooka oznaczeni jako nieaktywni ($($NoWebhook.Count))"
    }

    if ($Diag.OK) {
        $SummaryLines += '[OK] Diagnostyka PU: OK'
        # Check if all repair steps are also done
        $AllRepairDone = $State.Phases['2'].Checklist.ContainsKey('NarratorNormalizationDone') -and $State.Phases['2'].Checklist['NarratorNormalizationDone']
        if ($AllRepairDone) {
            Set-PhaseCompleted -State $State -Phase 2
            Write-PhaseSummary -Phase 2 -Status 'Completed' -Lines $SummaryLines
        } else {
            Write-PhaseSummary -Phase 2 -Status 'InProgress' -Lines $SummaryLines
        }
    } else {
        $IssueCount = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                      $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
        $SummaryLines += "[!!] Diagnostyka PU: $IssueCount problemów"
        Write-PhaseSummary -Phase 2 -Status 'InProgress' -Lines $SummaryLines

        Write-Host ''
        Write-Host '  Po naprawieniu problemów uruchom Fazę 2 ponownie.' -ForegroundColor Cyan
        Write-Host '  Wzorzec: diagnostyka → naprawa → diagnostyka → ... aż OK = True' -ForegroundColor DarkGray
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# Display characters with PU=BRAK and offer to soft-delete them all at once
function Show-BRAKCharacters {
    param([Parameter(Mandatory)] [hashtable]$State)

    $Players = Get-Player
    $BRAKChars = [System.Collections.Generic.List[object]]::new()

    foreach ($Player in $Players) {
        foreach ($Char in $Player.Characters) {
            if ($null -eq $Char.PUSum -and $null -eq $Char.PUStart) {
                $BRAKChars.Add([PSCustomObject]@{
                    PlayerName    = $Player.Name
                    CharacterName = $Char.Name
                })
            }
        }
    }

    if ($BRAKChars.Count -eq 0) { return }

    Write-SectionHeader "POSTACIE Z PU = BRAK ($($BRAKChars.Count))"
    foreach ($Item in $BRAKChars) {
        Write-Host "    $($Item.PlayerName) / $($Item.CharacterName) - brak wartości PU" -ForegroundColor Yellow
    }

    $Choice = Request-YesNo -Prompt "    Czy chcesz oznaczyć te postacie jako nieaktywne?" -Default $false -HelpText @(
        'Soft-delete postaci z wartością PU = BRAK.',
        'Postacie te nie mają przypisanych punktów umiejętności,',
        'co powoduje błędy w diagnostyce PU.',
        '',
        'Oznaczenie jako nieaktywne (@status: Nieaktywny)',
        'wyłączy je z obliczeń PU i rozwiąże błędy diagnostyczne.',
        '',
        'Tak = ustaw @status: Nieaktywny dla wylistowanych postaci',
        'Nie = pomiń — postacie pozostaną aktywne z PU = BRAK'
    )
    if ($null -eq $Choice) { return }
    if ($Choice) {
        foreach ($Item in $BRAKChars) {
            try {
                Set-PlayerCharacter -PlayerName $Item.PlayerName -CharacterName $Item.CharacterName -Status 'Nieaktywny' -Confirm:$false
                Write-StepOK "Oznaczono '$($Item.CharacterName)' jako nieaktywną"
            }
            catch {
                Write-StepError "Nie udało się oznaczyć '$($Item.CharacterName)' jako nieaktywną: $($_.Exception.Message)"
            }
        }
    }
}

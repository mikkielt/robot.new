<#
    .SYNOPSIS
    Phase 6: Session format upgrade to Gen4.

    .DESCRIPTION
    Identifies non-Gen4 sessions in active files (2024+), upgrades them
    to Gen4 format, resolves format dedup conflicts across duplicate sessions,
    verifies narrator resolution, reviews location names, and commits the changes.

    Dependencies: migration-ui.ps1, migration-state.ps1,
                  narrator-normalization.ps1, robot module imported.
#>

# ============================================================================
# PHASE 6 - Session format upgrade to Gen4
# ============================================================================

function Invoke-MigrationPhase6 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 6
    Write-PhaseHeader -Phase 6 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot

    # Step 1: Show current session format distribution
    Write-Step -Number 1 -Text 'Sprawdzanie dystrybucji formatów sesji...'
    $AllSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs
    $FormatGroups = $AllSessions | Group-Object Format | Sort-Object Name
    foreach ($Group in $FormatGroups) {
        Write-Host "    $($Group.Name): $($Group.Count) sesji" -ForegroundColor DarkGray
    }
    Update-PhaseChecklist -State $State -Phase 6 -Item 'FormatDistribution' -Value $true

    # Step 2: Resolve format dedup conflicts across duplicate sessions
    $FormatDedupDone = $State.Phases.ContainsKey('4') -and $State.Phases['6'].ContainsKey('Checklist') -and $State.Phases['6'].Checklist.ContainsKey('FormatDedupResolved') -and $State.Phases['6'].Checklist['FormatDedupResolved']
    if (-not $FormatDedupDone) {
        Write-Step -Number 2 -Text 'Konflikty formatu w zdeduplikowanych sesjach...'
        $MergedSessions = @($AllSessions | Where-Object { $_.IsMerged })

        if ($MergedSessions.Count -eq 0) {
            Write-StepOK 'Brak zdeduplikowanych sesji'
            Update-PhaseChecklist -State $State -Phase 6 -Item 'FormatDedupResolved' -Value $true
        } else {
            # Collect unique file paths from all merged sessions
            $DedupFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($M in $MergedSessions) {
                foreach ($FP in $M.FilePaths) { [void]$DedupFiles.Add($FP) }
            }

            # Scan each file individually to get per-copy format
            $PerFileSessions = @{}
            foreach ($FPath in $DedupFiles) {
                $PerFileSessions[$FPath] = @(Get-Session -File $FPath)
            }

            # Detect format conflicts
            $FormatConflicts = [System.Collections.Generic.List[object]]::new()
            foreach ($M in $MergedSessions) {
                $CopyFormats = [System.Collections.Generic.HashSet[string]]::new()
                $CopyDetails = [System.Collections.Generic.List[object]]::new()
                foreach ($FP in $M.FilePaths) {
                    if (-not $PerFileSessions.ContainsKey($FP)) { continue }
                    $FileSess = $PerFileSessions[$FP] | Where-Object { $_.Header -eq $M.Header } | Select-Object -First 1
                    if ($FileSess) {
                        [void]$CopyFormats.Add($FileSess.Format)
                        $CopyDetails.Add([PSCustomObject]@{ FilePath = $FP; Format = $FileSess.Format })
                    }
                }
                if ($CopyFormats.Count -gt 1) {
                    $FormatConflicts.Add([PSCustomObject]@{
                        Header  = $M.Header
                        Merged  = $M
                        Copies  = $CopyDetails
                        Formats = ($CopyFormats -join ' vs ')
                    })
                }
            }

            if ($FormatConflicts.Count -eq 0) {
                Write-StepOK "Brak konfliktów formatu w $($MergedSessions.Count) zdeduplikowanych sesjach"
                Update-PhaseChecklist -State $State -Phase 6 -Item 'FormatDedupResolved' -Value $true
            } else {
                Write-StepWarning "$($FormatConflicts.Count) sesji z konfliktami formatu:"
                foreach ($FC in $FormatConflicts) {
                    Write-Host "    $($FC.Header)" -ForegroundColor Yellow
                    foreach ($Copy in $FC.Copies) {
                        $RelPath = $Copy.FilePath
                        if ($RelPath.StartsWith($RepoRoot)) { $RelPath = $RelPath.Substring($RepoRoot.Length + 1) }
                        Write-Host "      $($Copy.Format) - $RelPath" -ForegroundColor DarkGray
                    }
                }

                $DedupChoice = Request-UserChoice -Prompt 'Rozwiązać konflikty przez upgrade do Gen4?' -ValidChoices @('T', 'S', 'N') `
                    -Labels @{ 'T' = 'Tak, zaktualizuj'; 'S' = 'Suchy przebieg (dry run)'; 'N' = 'Nie, pomiń' } `
                    -HelpText @(
                        'Sesje zdeduplikowane istnieją w kilku plikach w różnych',
                        'formatach (np. Gen2 vs Gen4). Upgrade ujednolici format',
                        'do Gen4 i zsynchronizuje metadane między kopiami.',
                        '',
                        'Tak = upgrade wszystkich kopii do Gen4 (zapis na dysk)',
                        'Suchy przebieg = podgląd zmian bez zapisu',
                        'Nie = pomiń, konflikty pozostaną do ręcznego rozwiązania'
                    )

                if ($DedupChoice -eq 'N') {
                    Write-Host '  Pominięto rozwiązywanie konfliktów formatu.' -ForegroundColor DarkGray
                } else {
                    $DedupDryRun = ($DedupChoice -eq 'S') -or $WhatIf
                    $DedupResolved = 0
                    $DedupFailed = 0

                    foreach ($FC in $FormatConflicts) {
                        $M = $FC.Merged
                        if ($DedupDryRun) {
                            Write-Host "    [SUCHY] $($FC.Header)" -ForegroundColor DarkGray
                            $DedupResolved++
                            continue
                        }

                        try {
                            # Propagate merged metadata to all copies and upgrade to Gen4
                            $SetParams = @{ UpgradeFormat = $true }
                            if ($M.Locations -and $M.Locations.Count -gt 0) {
                                $SetParams.Locations = $M.Locations
                            }
                            if ($M.Logs -and $M.Logs.Count -gt 0) {
                                $SetParams.Logs = $M.Logs
                            }
                            if ($M.PU -and $M.PU.Count -gt 0) {
                                $SetParams.PU = $M.PU
                            }

                            $M | Set-Session @SetParams
                            Write-Host "    [OK] $($FC.Header)" -ForegroundColor Green
                            $DedupResolved++
                        }
                        catch {
                            Write-StepError "  $($FC.Header): $_"
                            $DedupFailed++
                        }
                    }

                    if ($DedupDryRun) {
                        Write-StepWarning "[SUCHY PRZEBIEG] Rozwiązałbym $DedupResolved konfliktów"
                    } else {
                        $ResultMsg = "Rozwiązano $DedupResolved konfliktów"
                        if ($DedupFailed -gt 0) { $ResultMsg += ", $DedupFailed nieudanych" }

                        if ($DedupFailed -eq 0) {
                            Write-StepOK $ResultMsg
                            Update-PhaseChecklist -State $State -Phase 6 -Item 'FormatDedupResolved' -Value $true
                        } else {
                            Write-StepWarning $ResultMsg
                        }
                    }
                }
            }
        }
    } else {
        Write-Step -Number 2 -Text 'Konflikty formatu w duplikatach...'
        Write-StepOK 'Konflikty formatu już rozwiązane'
    }

    # Step 3: Identify active files (sessions from 2024 onwards)
    Write-Step -Number 3 -Text 'Identyfikacja aktywnych plików (sesje od 2024)...'
    $Cutoff = [datetime]::new(2024, 1, 1)
    $ActiveSessions = $AllSessions | Where-Object { $_.Date -and $_.Date -ge $Cutoff }
    $ActiveFiles = $ActiveSessions | Select-Object -ExpandProperty FilePath -Unique
    Write-StepOK "Aktywnych plików: $($ActiveFiles.Count)"

    # Step 4: Count non-Gen4 sessions in active files
    $NonGen4 = $ActiveSessions | Where-Object { $_.Format -ne 'Gen4' }
    $NonGen4Count = ($NonGen4 | Measure-Object).Count

    if ($NonGen4Count -eq 0) {
        Write-StepOK 'Wszystkie aktywne sesje już w formacie Gen4'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'UpgradeDone' -Value $true
        $DedupAlsoResolved = $State.Phases.ContainsKey('4') -and $State.Phases['6'].ContainsKey('Checklist') -and $State.Phases['6'].Checklist.ContainsKey('FormatDedupResolved') -and $State.Phases['6'].Checklist['FormatDedupResolved']
        if ($DedupAlsoResolved) {
            Set-PhaseCompleted -State $State -Phase 6
            Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @('[OK] Wszystkie aktywne sesje w Gen4', '[OK] Konflikty formatu rozwiązane')
        } else {
            Set-PhaseInProgress -State $State -Phase 6
        }
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    Write-StepWarning "$NonGen4Count sesji do aktualizacji w $($ActiveFiles.Count) plikach"

    # Display upgrade plan: files and session counts
    $NonGen4ByFile = $NonGen4 | Group-Object FilePath
    foreach ($FileGroup in $NonGen4ByFile) {
        $RelPath = $FileGroup.Name
        if ($RelPath.StartsWith($RepoRoot)) {
            $RelPath = $RelPath.Substring($RepoRoot.Length + 1)
        }
        Write-Host "    $RelPath`: $($FileGroup.Count) sesji" -ForegroundColor DarkGray
    }

    # Step 5: Prompt for upgrade action
    Write-Step -Number 4 -Text 'Upgrade sesji...'
    $Choice = Request-UserChoice -Prompt 'Czy zaktualizować aktywne sesje do Gen4?' -ValidChoices @('T', 'S', 'N') `
        -Labels @{ 'T' = 'Tak, zaktualizuj'; 'S' = 'Suchy przebieg (dry run)'; 'N' = 'Nie, pomiń' } `
        -HelpText @(
            'Upgrade aktywnych sesji (od 2024) do formatu Gen4.',
            'Gen4 używa prefiksów @Lokacja, @PU, @Log, @Narrator',
            'w bloku metadanych pod nagłówkiem sesji.',
            '',
            'Tak = zaktualizuj wszystkie aktywne sesje (zapis na dysk)',
            'Suchy przebieg = podgląd ile sesji zostanie zmienionych',
            'Nie = pomiń upgrade, sesje pozostaną w starym formacie',
            '',
            'Patrz: docs/Sessions.md (Format Gen4)'
        )

    if ($Choice -eq 'N') {
        Write-Host '  Pominięto upgrade sesji.' -ForegroundColor DarkGray
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    $DryRun = ($Choice -eq 'S') -or $WhatIf

    # Execute format upgrade per file
    $UpgradeCount = 0
    $FailedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($File in $ActiveFiles) {
        $RelPath = $File
        if ($File.StartsWith($RepoRoot)) {
            $RelPath = $File.Substring($RepoRoot.Length + 1)
        }
        Write-Host "  Plik: $RelPath" -ForegroundColor Cyan -NoNewline

        $FileSessions = $NonGen4 | Where-Object { $_.FilePath -eq $File }
        $Count = ($FileSessions | Measure-Object).Count

        if ($DryRun) {
            Write-Host " - $Count sesji (suchy przebieg)" -ForegroundColor DarkGray
        } else {
            try {
                $FileSessions | Set-Session -UpgradeFormat
                Write-Host " - $Count sesji zaktualizowanych" -ForegroundColor Green
            }
            catch {
                Write-Host " - BŁĄD" -ForegroundColor Red
                Write-StepError "  Plik $RelPath`: $_"
                $FailedFiles.Add($RelPath)
            }
        }
        $UpgradeCount += $Count
    }

    if ($FailedFiles.Count -gt 0) {
        Write-StepWarning "Nie udało się zaktualizować $($FailedFiles.Count) plików:"
        foreach ($F in $FailedFiles) { Write-Host "    - $F" -ForegroundColor Yellow }
    }

    if ($DryRun) {
        Write-StepWarning "[SUCHY PRZEBIEG] Zaktualizowałbym $UpgradeCount sesji"
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # Step 6: Verify post-upgrade format distribution
    Write-Step -Number 5 -Text 'Weryfikacja po upgrade...'
    $PostSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs
    $PostActive = $PostSessions | Where-Object { $_.Date -and $_.Date -ge $Cutoff }
    $StillNonGen4 = ($PostActive | Where-Object { $_.Format -ne 'Gen4' } | Measure-Object).Count

    if ($StillNonGen4 -eq 0) {
        Write-StepOK 'Weryfikacja: wszystkie aktywne sesje w Gen4'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'UpgradeDone' -Value $true
    } else {
        Write-StepWarning "Wciąż $StillNonGen4 sesji nie w Gen4"
    }

    # Step 7: Narrator verification (non-blocking - informational only)
    $NarratorReviewDone = $State.Phases.ContainsKey('4') -and $State.Phases['6'].ContainsKey('Checklist') -and $State.Phases['6'].Checklist.ContainsKey('NarratorReviewDone') -and $State.Phases['6'].Checklist['NarratorReviewDone']
    if (-not $NarratorReviewDone) {
        Write-Step -Number 6 -Text 'Weryfikacja narratorów po upgrade...'

        # Check narrator mappings count for display
        . "$PSScriptRoot/narrator-normalization.ps1"
        $NarrMappings = Import-NarratorMappings
        if ($NarrMappings.Count -gt 0) {
            Write-Host "    Mapowania narratorów: $($NarrMappings.Count) wpisów" -ForegroundColor DarkGray
        }

        $NarrReport = Get-NarratorReport -Sessions $PostActive -UnresolvedOnly
        $StillUnresolved = @($NarrReport | Where-Object { $_.Confidence -eq 'None' -and -not $_.HasMapping })

        if ($StillUnresolved.Count -eq 0) {
            Write-StepOK 'Wszyscy narratorzy rozwiązani lub zamapowani'
        } else {
            Write-StepWarning "$($StillUnresolved.Count) narratorów wciąż nierozwiązanych (informacyjnie)"
            $ShowCount = [Math]::Min($StillUnresolved.Count, 10)
            for ($k = 0; $k -lt $ShowCount; $k++) {
                Write-Host "      - $($StillUnresolved[$k].RawText) ($($StillUnresolved[$k].OccurrenceCount)x)" -ForegroundColor DarkGray
            }
            if ($StillUnresolved.Count -gt 10) {
                Write-Host "      ... i $($StillUnresolved.Count - 10) więcej" -ForegroundColor DarkGray
            }
        }

        Update-PhaseChecklist -State $State -Phase 6 -Item 'NarratorReviewDone' -Value $true
    } else {
        Write-Step -Number 6 -Text 'Weryfikacja narratorów...'
        Write-StepOK 'Weryfikacja narratorów już wykonana'
    }

    # Step 8: Location report review
    $LocationReviewDone = $State.Phases.ContainsKey('4') -and $State.Phases['6'].ContainsKey('Checklist') -and $State.Phases['6'].Checklist.ContainsKey('LocationReviewDone') -and $State.Phases['6'].Checklist['LocationReviewDone']
    if (-not $LocationReviewDone) {
        Write-Step -Number 7 -Text 'Raport lokalizacji - przegląd nazw...'

        $LocationReportResult = Get-NamedLocationReport -Sessions $PostActive -Entities (Get-Entity)
        $LocationReport = $LocationReportResult.Locations

        # Load exclusions (non-locations marked by coordinator on previous runs)
        $ExclusionsPath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'location-exclusions.txt')
        $Exclusions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ([System.IO.File]::Exists($ExclusionsPath)) {
            foreach ($ExLine in [System.IO.File]::ReadAllLines($ExclusionsPath)) {
                $ExTrimmed = $ExLine.Trim()
                if ($ExTrimmed.Length -gt 0 -and -not $ExTrimmed.StartsWith('#')) {
                    [void]$Exclusions.Add($ExTrimmed)
                }
            }
        }

        # Categorize report entries
        $Unresolved = [System.Collections.Generic.List[object]]::new()
        $Warnings   = [System.Collections.Generic.List[object]]::new()
        $Resolved   = 0

        foreach ($Loc in $LocationReport) {
            if ($Exclusions.Contains($Loc.Name)) { continue }
            if ($null -eq $Loc.EntityMatch) {
                $Unresolved.Add($Loc)
            } elseif ($Loc.Conflicts.Count -gt 0) {
                $Warnings.Add($Loc)
            } else {
                $Resolved++
            }
        }

        Write-Host "    Rozwiązane: $Resolved | Ostrzeżenia: $($Warnings.Count) | Nierozwiązane: $($Unresolved.Count)" -ForegroundColor Cyan
        if ($Exclusions.Count -gt 0) {
            Write-Host "    Wykluczone (nie-lokacje): $($Exclusions.Count)" -ForegroundColor DarkGray
        }

        if ($Warnings.Count -gt 0) {
            Write-Host ''
            Write-Host '    Ostrzeżenia (dopasowanie rozmyte lub konflikty):' -ForegroundColor Yellow
            foreach ($W in ($Warnings | Select-Object -First 10)) {
                $ConflictTypes = ($W.Conflicts | ForEach-Object { $_.Type }) -join ', '
                Write-Host "      - $($W.Name) ($($W.OccurrenceCount)x) [$ConflictTypes]" -ForegroundColor Yellow
            }
            if ($Warnings.Count -gt 10) {
                Write-Host "      ... i $($Warnings.Count - 10) więcej" -ForegroundColor DarkGray
            }
        }

        if ($Unresolved.Count -gt 0) {
            Write-Host ''
            Write-StepWarning "Nierozwiązane lokalizacje ($($Unresolved.Count)):"

            $NewExclusions = [System.Collections.Generic.List[string]]::new()

            foreach ($U in $Unresolved) {
                Write-Host "      $($U.Name) ($($U.OccurrenceCount)x)" -ForegroundColor White
                if ($U.Variants.Count -gt 0) {
                    Write-Host "        Warianty: $($U.Variants -join ', ')" -ForegroundColor DarkGray
                }

                $Choice = Request-UserChoice `
                    -Prompt "Lokacja: $($U.Name)" `
                    -ValidChoices @('P', 'N', 'K') `
                    -Labels @{ 'P' = 'Pomiń'; 'N' = 'Oznacz jako nie-lokację'; 'K' = 'Kontynuuj (zakończ przegląd)' }

                if ($Choice -eq 'K') { break }
                if ($Choice -eq 'N') {
                    $NewExclusions.Add($U.Name)
                    Write-Host "        → Oznaczono jako nie-lokację" -ForegroundColor DarkGray
                }
            }

            # Save new exclusions
            if ($NewExclusions.Count -gt 0) {
                $ResDir = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res')
                if (-not [System.IO.Directory]::Exists($ResDir)) {
                    [void][System.IO.Directory]::CreateDirectory($ResDir)
                }

                $AppendLines = [System.Collections.Generic.List[string]]::new()
                if (-not [System.IO.File]::Exists($ExclusionsPath)) {
                    $AppendLines.Add('# Wartości oznaczone jako nie-lokacje podczas migracji')
                }
                foreach ($Ex in $NewExclusions) {
                    $AppendLines.Add($Ex)
                    [void]$Exclusions.Add($Ex)
                }
                [System.IO.File]::AppendAllLines($ExclusionsPath, $AppendLines, [System.Text.UTF8Encoding]::new($false))
                Write-Host "    Zapisano $($NewExclusions.Count) wykluczeń do location-exclusions.txt" -ForegroundColor DarkGray
            }

            # Re-check: are there still truly unresolved locations?
            $StillUnresolved = 0
            foreach ($U in $Unresolved) {
                if (-not $Exclusions.Contains($U.Name)) { $StillUnresolved++ }
            }

            if ($StillUnresolved -gt 0) {
                Write-StepWarning "$StillUnresolved lokalizacji wciąż nierozwiązanych - utwórz brakujące encje typu Lokacja lub oznacz jako nie-lokacje"
                Write-ActionRequired 'Commit zostanie zablokowany do rozwiązania nierozwiązanych lokalizacji.'
                if (-not $WhatIf) { Save-MigrationState -State $State }
                return
            }
        }

        # Offer full report export
        if ($LocationReport.Count -gt 0 -and (Request-YesNo -Prompt 'Czy wyeksportować pełny raport lokalizacji?' -Default $false -HelpText @(
            'Eksport pełnego raportu lokalizacji do pliku tekstowego',
            'w .robot/res/location-report.txt.',
            '',
            'Raport zawiera wszystkie nazwy lokalizacji z sesji,',
            'ich status dopasowania do encji oraz ewentualne konflikty.',
            '',
            'Tak = zapisz raport do pliku',
            'Nie = pomiń eksport'
        ))) {
            $ReportPath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'location-report.txt')
            $ReportLines = [System.Collections.Generic.List[string]]::new()
            $ReportLines.Add("# Raport lokalizacji - $([datetime]::Now.ToString('yyyy-MM-dd HH:mm'))")
            $ReportLines.Add("# Sesje od: $($Cutoff.ToString('yyyy-MM-dd'))")
            $ReportLines.Add('')
            foreach ($Loc in $LocationReport) {
                $Status = if ($Exclusions.Contains($Loc.Name)) { '[WYKLUCZONA]' }
                          elseif ($null -eq $Loc.EntityMatch) { '[NIEROZWIĄZANA]' }
                          elseif ($Loc.Conflicts.Count -gt 0) { '[OSTRZEŻENIE]' }
                          else { '[OK]' }
                $ReportLines.Add("$Status $($Loc.Name) ($($Loc.OccurrenceCount)x)")
                if ($Loc.Variants.Count -gt 0) {
                    $ReportLines.Add("  Warianty: $($Loc.Variants -join ', ')")
                }
                if ($null -ne $Loc.EntityMatch) {
                    $ReportLines.Add("  Encja: $($Loc.EntityMatch.EntityName) (etap: $($Loc.EntityMatch.MatchStage))")
                }
                foreach ($C in $Loc.Conflicts) {
                    $ReportLines.Add("  Konflikt [$($C.Type)]: $($C.Details)")
                }
            }
            [System.IO.File]::WriteAllLines($ReportPath, $ReportLines, [System.Text.UTF8Encoding]::new($false))
            Write-StepOK "Raport zapisany: $ReportPath"
        }

        Write-StepOK 'Przegląd lokalizacji zakończony'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'LocationReviewDone' -Value $true
    } else {
        Write-Step -Number 7 -Text 'Raport lokalizacji...'
        Write-StepOK 'Przegląd lokalizacji już wykonany'
    }

    # Step 9: Prompt to commit upgraded sessions
    Write-Step -Number 8 -Text 'Commit...'
    if (Request-YesNo -Prompt 'Czy zacommitować upgrade sesji?' -Default $true -HelpText @(
        'Zapisanie zmian do repozytorium git.',
        '',
        'Wykona: git add . + git commit z komunikatem',
        '"Upgrade aktywnych sesji do formatu Gen4".',
        '',
        'Tak = git add + git commit',
        'Nie = pominięcie, zmiany zostają niezacommitowane'
    )) {
        & git -C $RepoRoot add . 2>&1
        & git -C $RepoRoot commit -m 'Upgrade aktywnych sesji do formatu Gen4' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-StepOK 'Zacommitowano'
            Update-PhaseChecklist -State $State -Phase 6 -Item 'Committed' -Value $true
        } else {
            Write-StepError 'Nie udało się zacommitować'
        }
    }

    # Phase summary and state persistence
    $DedupAlsoResolved = $State.Phases.ContainsKey('4') -and $State.Phases['6'].ContainsKey('Checklist') -and $State.Phases['6'].Checklist.ContainsKey('FormatDedupResolved') -and $State.Phases['6'].Checklist['FormatDedupResolved']
    if ($StillNonGen4 -eq 0 -and $DedupAlsoResolved) {
        Set-PhaseCompleted -State $State -Phase 6
        Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @("[OK] $UpgradeCount sesji zaktualizowanych do Gen4", '[OK] Konflikty formatu rozwiązane')
    } else {
        Set-PhaseInProgress -State $State -Phase 6
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

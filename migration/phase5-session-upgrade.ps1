<#
    .SYNOPSIS
    Phase 5: Session format upgrade to Gen4.

    .DESCRIPTION
    Identifies non-Gen4 sessions in active files (2024+), upgrades them
    to Gen4 format, resolves format dedup conflicts across duplicate sessions,
    verifies narrator resolution, reviews location names, and commits the changes.

    Dependencies: migration-ui.ps1, migration-state.ps1,
                  narrator-normalization.ps1, robot module imported.
#>

# Dot-source log fetch helpers (provides Normalize-LogUrl, ConvertTo-LogFileName
# for URL localization of @Logi: blocks)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'log-fetchhelpers.ps1'))

# Dot-source admin config (provides Get-AdminConfig for ResDir path)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'admin-config.ps1'))

# ============================================================================
# PHASE 5 - Session format upgrade to Gen4
# ============================================================================

function Invoke-MigrationPhase5 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 5)) {
        Write-StepWarning 'Faza 4 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 5
    Write-PhaseHeader -Phase 5 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $PhaseEntities = Get-Entity -Quiet
    $PhasePlayers  = Get-Player -Entities $PhaseEntities

    # Step 1: Show current session format distribution
    Write-Step -Number 1 -Text 'Sprawdzanie dystrybucji formatów sesji...'
    $AllSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs -Entities $PhaseEntities -Players $PhasePlayers -Quiet
    $FormatGroups = $AllSessions | Group-Object Format | Sort-Object Name
    foreach ($Group in $FormatGroups) {
        Write-Host "    $($Group.Name): $($Group.Count) sesji" -ForegroundColor DarkGray
    }
    Update-PhaseChecklist -State $State -Phase 5 -Item 'FormatDistribution' -Value $true

    # Step 2: Resolve format dedup conflicts across duplicate sessions
    $FormatDedupDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('FormatDedupResolved') -and $State.Phases['5'].Checklist['FormatDedupResolved']
    if (-not $FormatDedupDone) {
        Write-Step -Number 2 -Text 'Konflikty formatu w zdeduplikowanych sesjach...'
        $MergedSessions = @($AllSessions | Where-Object { $_.IsMerged })

        if ($MergedSessions.Count -eq 0) {
            Write-StepOK 'Brak zdeduplikowanych sesji'
            Update-PhaseChecklist -State $State -Phase 5 -Item 'FormatDedupResolved' -Value $true
        } else {
            # Detect format conflicts using CopyFormats from merge data
            $FormatConflicts = [System.Collections.Generic.List[object]]::new()
            foreach ($M in $MergedSessions) {
                if (-not $M.CopyFormats -or $M.CopyFormats.Count -le 1) { continue }
                $DistinctFormats = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($CF in $M.CopyFormats) { [void]$DistinctFormats.Add($CF.Format) }
                if ($DistinctFormats.Count -gt 1) {
                    $FormatConflicts.Add([PSCustomObject]@{
                        Header  = $M.Header
                        Merged  = $M
                        Copies  = $M.CopyFormats
                        Formats = ($DistinctFormats -join ' vs ')
                    })
                }
            }

            if ($FormatConflicts.Count -eq 0) {
                Write-StepOK "Brak konfliktów formatu w $($MergedSessions.Count) zdeduplikowanych sesjach"
                Update-PhaseChecklist -State $State -Phase 5 -Item 'FormatDedupResolved' -Value $true
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
                            Update-PhaseChecklist -State $State -Phase 5 -Item 'FormatDedupResolved' -Value $true
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
        Update-PhaseChecklist -State $State -Phase 5 -Item 'UpgradeDone' -Value $true

        # URL localization for already-Gen4 sessions
        $UrlsLocalizedDone = $Checklist.ContainsKey('UrlsLocalized') -and $Checklist['UrlsLocalized']
        if (-not $UrlsLocalizedDone -and -not $WhatIf) {
            Write-Step -Number 4 -Text 'Lokalizacja URL w sesjach Gen4...'
            $Config = Get-AdminConfig
            $LogDir = [System.IO.Path]::Combine($Config.ResDir, 'logs')
            $LocalizedCount = 0

            if ([System.IO.Directory]::Exists($LogDir)) {
                $Gen4WithUrls = @($ActiveSessions.Where({
                    $_.Format -eq 'Gen4' -and $null -ne $_.Logs -and $_.Logs.Count -gt 0 -and
                    $_.Logs.Where({ $_.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                }))
                foreach ($S in $Gen4WithUrls) {
                    $NewLogs = [System.Collections.Generic.List[string]]::new()
                    $AnyChanged = $false
                    foreach ($LogEntry in $S.Logs) {
                        if ($LogEntry.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                            $Normalized = Normalize-LogUrl -Url $LogEntry
                            $FileName = ConvertTo-LogFileName -NormalizedUrl $Normalized
                            $FilePath = [System.IO.Path]::Combine($LogDir, $FileName)
                            if ([System.IO.File]::Exists($FilePath)) {
                                $NewLogs.Add("res/logs/$FileName")
                                $AnyChanged = $true
                            } else {
                                $NewLogs.Add($LogEntry)
                            }
                        } else {
                            $NewLogs.Add($LogEntry)
                        }
                    }
                    if ($AnyChanged) {
                        $S | Set-Session -Logs $NewLogs.ToArray()
                        $LocalizedCount++
                    }
                }
            }

            if ($LocalizedCount -gt 0) {
                Write-StepOK "Zlokalizowano URL w $LocalizedCount sesjach Gen4"
                # Hashes need refresh after localization
                Update-PhaseChecklist -State $State -Phase 5 -Item 'HashesRefreshed' -Value $false
            } else {
                Write-StepOK 'Brak URL do lokalizacji'
                # Hashes still valid (no content change)
                Update-PhaseChecklist -State $State -Phase 5 -Item 'HashesRefreshed' -Value $true
            }
            Update-PhaseChecklist -State $State -Phase 5 -Item 'UrlsLocalized' -Value $true
        } else {
            # Hashes still valid (no format change occurred)
            Update-PhaseChecklist -State $State -Phase 5 -Item 'HashesRefreshed' -Value $true
        }

        # Generate session review file if not already generated
        $ReviewDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('SessionReviewFileGenerated') -and $State.Phases['5'].Checklist['SessionReviewFileGenerated']
        if (-not $ReviewDone -and -not $WhatIf) {
            Write-Step -Number 4 -Text 'Generowanie pliku przeglądu sesji...'
            $Count = Export-SessionReviewFile -RepoRoot $RepoRoot -Entities $PhaseEntities -Players $PhasePlayers
            Write-StepOK "Plik przeglądu: $Count sesji → all-sessions-to-review.md"
            Update-PhaseChecklist -State $State -Phase 5 -Item 'SessionReviewFileGenerated' -Value $true
        }

        # Build session graph if not already built
        $GraphDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('SessionGraphBuilt') -and $State.Phases['5'].Checklist['SessionGraphBuilt']
        if (-not $GraphDone -and -not $WhatIf) {
            Write-Step -Number 5 -Text 'Budowanie grafu sesji...'
            try {
                $GraphResult = Set-SessionGraph -Full -Confirm:$false
                Write-StepOK "Graf sesji: $($GraphResult.SessionsProcessed) sesji, $($GraphResult.ParticipantsFound) uczestników"
                Update-PhaseChecklist -State $State -Phase 5 -Item 'SessionGraphBuilt' -Value $true
            }
            catch {
                Write-StepWarning "Budowanie grafu sesji nie powiodło się: $_"
            }
        }

        $DedupAlsoResolved = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('FormatDedupResolved') -and $State.Phases['5'].Checklist['FormatDedupResolved']
        $GraphBuilt = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('SessionGraphBuilt') -and $State.Phases['5'].Checklist['SessionGraphBuilt']
        if ($DedupAlsoResolved -and $GraphBuilt) {
            Set-PhaseCompleted -State $State -Phase 5
            Write-PhaseSummary -Phase 5 -Status 'Completed' -Lines @('[OK] Wszystkie aktywne sesje w Gen4', '[OK] Konflikty formatu rozwiązane', '[OK] Plik przeglądu sesji wygenerowany', '[OK] Graf sesji zbudowany')
        } else {
            Set-PhaseInProgress -State $State -Phase 5
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
                Write-StepError "  Plik $RelPath`: $_" -LogDetails @(
                    "Plik: $RelPath ($Count sesji)",
                    "Blad: $($_.Exception.Message)",
                    "Naprawa: Sprawdz strukture plikow Markdown — naglowki sesji",
                    "         musza miec format '### YYYY-MM-DD, Tytul, Narrator'",
                    "         Jesli plik jest bardzo duzy, sprobuj podzielic go na mniejsze."
                )
                $FailedFiles.Add($RelPath)
            }
        }
        $UpgradeCount += $Count
    }

    if ($FailedFiles.Count -gt 0) {
        $FailDetails = [System.Collections.Generic.List[string]]::new()
        foreach ($F in $FailedFiles) { $FailDetails.Add("- $F") }
        $FailDetails.Add('')
        $FailDetails.Add('Naprawa: Sprawdz czy pliki nie sa zbyt duze lub nie zawieraja')
        $FailDetails.Add('         blednych naglowkow sesji. Uruchom Faze 4 ponownie')
        $FailDetails.Add('         po naprawieniu plikow.')
        Write-StepWarning "Nie udało się zaktualizować $($FailedFiles.Count) plików:" -LogDetails $FailDetails.ToArray()
        foreach ($F in $FailedFiles) { Write-Host "    - $F" -ForegroundColor Yellow }
    }

    if ($DryRun) {
        Write-StepWarning "[SUCHY PRZEBIEG] Zaktualizowałbym $UpgradeCount sesji"
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # Step 5b: URL localization for already-Gen4 sessions
    Write-Step -Number '5b' -Text 'Lokalizacja URL w sesjach Gen4...'

    $Config = Get-AdminConfig
    $LogDir = [System.IO.Path]::Combine($Config.ResDir, 'logs')
    $LocalizedCount = 0

    if ([System.IO.Directory]::Exists($LogDir)) {
        $PostUpgradeSessions = @(Get-Session -ExcludeDirectory $script:MigrationExcludeDirs -Entities $PhaseEntities -Players $PhasePlayers -Quiet)
        $Gen4WithUrls = @($PostUpgradeSessions.Where({
            $_.Format -eq 'Gen4' -and $null -ne $_.Logs -and $_.Logs.Count -gt 0 -and
            $_.Logs.Where({ $_.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        }))

        foreach ($S in $Gen4WithUrls) {
            $NewLogs = [System.Collections.Generic.List[string]]::new()
            $AnyChanged = $false
            foreach ($LogEntry in $S.Logs) {
                if ($LogEntry.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Normalized = Normalize-LogUrl -Url $LogEntry
                    $FileName = ConvertTo-LogFileName -NormalizedUrl $Normalized
                    $FilePath = [System.IO.Path]::Combine($LogDir, $FileName)
                    if ([System.IO.File]::Exists($FilePath)) {
                        $NewLogs.Add("res/logs/$FileName")
                        $AnyChanged = $true
                    } else {
                        $NewLogs.Add($LogEntry)
                    }
                } else {
                    $NewLogs.Add($LogEntry)
                }
            }
            if ($AnyChanged) {
                $S | Set-Session -Logs $NewLogs.ToArray()
                $LocalizedCount++
            }
        }
    }

    if ($LocalizedCount -gt 0) {
        Write-StepOK "Zlokalizowano URL w $LocalizedCount sesjach Gen4"
    } else {
        Write-StepOK 'Brak URL do lokalizacji (wszystkie już lokalne)'
    }
    Update-PhaseChecklist -State $State -Phase 5 -Item 'UrlsLocalized' -Value $true

    # Step 6: Verify post-upgrade format distribution
    Write-Step -Number 6 -Text 'Weryfikacja po upgrade...'
    # Reuse $PostUpgradeSessions — URL localization only changes .Logs, not .Format
    if (-not $PostUpgradeSessions) {
        $PostUpgradeSessions = @(Get-Session -ExcludeDirectory $script:MigrationExcludeDirs -Entities $PhaseEntities -Players $PhasePlayers -Quiet)
    }
    $PostActive = @($PostUpgradeSessions.Where({ $_.Date -and $_.Date -ge $Cutoff }))
    $StillNonGen4 = ($PostActive | Where-Object { $_.Format -ne 'Gen4' } | Measure-Object).Count

    if ($StillNonGen4 -eq 0) {
        Write-StepOK 'Weryfikacja: wszystkie aktywne sesje w Gen4'
        Update-PhaseChecklist -State $State -Phase 5 -Item 'UpgradeDone' -Value $true
    } else {
        Write-StepWarning "Wciąż $StillNonGen4 sesji nie w Gen4"
    }

    # Step 7: Narrator verification (non-blocking - informational only)
    $NarratorReviewDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('NarratorReviewDone') -and $State.Phases['5'].Checklist['NarratorReviewDone']
    if (-not $NarratorReviewDone) {
        Write-Step -Number 6 -Text 'Weryfikacja narratorów po upgrade...'

        # Check narrator mappings count for display
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

        Update-PhaseChecklist -State $State -Phase 5 -Item 'NarratorReviewDone' -Value $true
    } else {
        Write-Step -Number 6 -Text 'Weryfikacja narratorów...'
        Write-StepOK 'Weryfikacja narratorów już wykonana'
    }

    # Step 8: Location report review
    $LocationReviewDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('LocationReviewDone') -and $State.Phases['5'].Checklist['LocationReviewDone']
    if (-not $LocationReviewDone) {
        Write-Step -Number 7 -Text 'Raport lokalizacji - przegląd nazw...'

        $LocationReportResult = Get-NamedLocationReport -Sessions $PostActive -Entities $PhaseEntities
        $LocationReport = $LocationReportResult.Locations

        # Load exclusions (non-locations marked by coordinator on previous runs)
        $ExclusionsPath = [System.IO.Path]::Combine($script:MigrationResDir, 'location-exclusions.txt')
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
                $ResDir = $script:MigrationResDir
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
            'w .robot.local/res/location-report.txt.',
            '',
            'Raport zawiera wszystkie nazwy lokalizacji z sesji,',
            'ich status dopasowania do encji oraz ewentualne konflikty.',
            '',
            'Tak = zapisz raport do pliku',
            'Nie = pomiń eksport'
        ))) {
            $ReportPath = [System.IO.Path]::Combine($script:MigrationResDir, 'location-report.txt')
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
        Update-PhaseChecklist -State $State -Phase 5 -Item 'LocationReviewDone' -Value $true
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
            Update-PhaseChecklist -State $State -Phase 5 -Item 'Committed' -Value $true
        } else {
            Write-StepError 'Nie udało się zacommitować'
        }
    }

    # Step 9: Session review file (generate / apply / refresh)
    $ReviewDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('SessionReviewFileGenerated') -and $State.Phases['5'].Checklist['SessionReviewFileGenerated']
    $ReviewPath = [System.IO.Path]::Combine($script:MigrationResDir, 'all-sessions-to-review.md')

    if (-not $ReviewDone) {
        # FIRST RUN: Generate review file
        Write-Step -Number 9 -Text 'Generowanie pliku przeglądu sesji...'
        $Count = Export-SessionReviewFile -RepoRoot $RepoRoot -Entities $PhaseEntities -Players $PhasePlayers -WhatIf:$WhatIf
        if (-not $WhatIf) {
            Write-StepOK "Plik przeglądu: $Count sesji → all-sessions-to-review.md"
            Update-PhaseChecklist -State $State -Phase 5 -Item 'SessionReviewFileGenerated' -Value $true
        }
    } else {
        # SUBSEQUENT RUNS: Review file exists — offer apply/regenerate/skip
        Write-Step -Number 9 -Text 'Plik przeglądu sesji...'
        Write-StepOK 'Plik przeglądu sesji już wygenerowany'

        $Choice = Request-UserChoice `
            -Prompt 'Plik przeglądu sesji' `
            -ValidChoices @('P', 'Z', 'R', 'H') `
            -Labels @{
                'P' = 'Pomiń'
                'Z' = 'Zastosuj zmiany z pliku przeglądu'
                'R' = 'Regeneruj plik przeglądu'
                'H' = 'Odśwież hashe (po ręcznej edycji źródeł)'
            } `
            -HelpText @(
                'Plik all-sessions-to-review.md został już wygenerowany.',
                '',
                'P = kontynuuj bez zmian',
                'Z = wczytaj edycje z pliku przeglądu i zastosuj do plików źródłowych',
                '    (modyfikacje, nowe sesje, usunięcia, deduplikacja)',
                'R = nadpisz plik przeglądu (jeśli sesje źródłowe się zmieniły)',
                'H = odśwież hashe sesji po ręcznej edycji plików źródłowych'
            )

        if ($Choice -eq 'Z') {
            $Result = Import-SessionReviewFile -RepoRoot $RepoRoot -Entities $PhaseEntities -Players $PhasePlayers -WhatIf:$WhatIf
        } elseif ($Choice -eq 'R') {
            $Count = Export-SessionReviewFile -RepoRoot $RepoRoot -Entities $PhaseEntities -Players $PhasePlayers -WhatIf:$WhatIf
            if (-not $WhatIf) {
                Write-StepOK "Plik przeglądu zregenerowany: $Count sesji"
            }
        } elseif ($Choice -eq 'H') {
            Set-SessionHash -Full -Confirm:$false
            Update-PhaseChecklist -State $State -Phase 5 -Item 'HashesRefreshed' -Value $true
            Write-StepOK 'Hashe sesji odświeżone'
        }
    }

    # Step 10: Refresh session hashes (format change invalidates Phase 1 baseline)
    Write-Step -Number 10 -Text 'Odświeżenie hashy sesji po upgrade formatu...'
    try {
        Set-SessionHash -Full -Confirm:$false
        Write-StepOK 'Hashe sesji odświeżone'
        Update-PhaseChecklist -State $State -Phase 5 -Item 'HashesRefreshed' -Value $true
    }
    catch {
        Write-StepError "Odświeżenie hashy nie powiodło się: $_"
    }

    # Step 11: Build session graph index
    Write-Step -Number 11 -Text 'Budowanie grafu sesji...'
    try {
        $GraphResult = Set-SessionGraph -Full -Confirm:$false
        Write-StepOK "Graf sesji: $($GraphResult.SessionsProcessed) sesji, $($GraphResult.ParticipantsFound) uczestników"
        Update-PhaseChecklist -State $State -Phase 5 -Item 'SessionGraphBuilt' -Value $true
    }
    catch {
        Write-StepError "Budowanie grafu sesji nie powiodło się: $_"
    }

    # Phase summary and state persistence
    $DedupAlsoResolved = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('FormatDedupResolved') -and $State.Phases['5'].Checklist['FormatDedupResolved']
    $HashesDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('HashesRefreshed') -and $State.Phases['5'].Checklist['HashesRefreshed']
    $GraphDone = $State.Phases.ContainsKey('4') -and $State.Phases['5'].ContainsKey('Checklist') -and $State.Phases['5'].Checklist.ContainsKey('SessionGraphBuilt') -and $State.Phases['5'].Checklist['SessionGraphBuilt']
    if ($StillNonGen4 -eq 0 -and $DedupAlsoResolved -and $HashesDone -and $GraphDone) {
        Set-PhaseCompleted -State $State -Phase 5
        Write-PhaseSummary -Phase 5 -Status 'Completed' -Lines @("[OK] $UpgradeCount sesji zaktualizowanych do Gen4", '[OK] Konflikty formatu rozwiązane', '[OK] Plik przeglądu sesji wygenerowany', '[OK] Hashe sesji odświeżone', '[OK] Graf sesji zbudowany')
    } else {
        Set-PhaseInProgress -State $State -Phase 5
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# ============================================================================
# HELPER: Export-SessionReviewFile
# ============================================================================

function Export-SessionReviewFile {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [switch]$WhatIf,
        [object[]]$Entities,
        [object[]]$Players
    )

    $SessionArgs = @{ ExcludeDirectory = $script:MigrationExcludeDirs; IncludeContent = $true; IncludeMentions = $true; Quiet = $true }
    if ($Entities) { $SessionArgs['Entities'] = $Entities }
    if ($Players)  { $SessionArgs['Players']  = $Players }
    $AllSessions = Get-Session @SessionArgs
    $Sorted = $AllSessions | Sort-Object { $_.Header }

    $Lines = [System.Collections.Generic.List[string]]::new()
    [void]$Lines.Add('# Przegląd wszystkich sesji')
    [void]$Lines.Add("<!-- Wygenerowano: $([datetime]::Now.ToString('yyyy-MM-dd HH:mm')) -->")
    [void]$Lines.Add("<!-- Sesji: $($Sorted.Count) -->")
    [void]$Lines.Add('<!-- ARTEFAKT PRZEGLĄDU — edytuj treść sesji, a następnie zastosuj zmiany w Fazie 4. -->')
    [void]$Lines.Add('<!-- Instrukcje:')
    [void]$Lines.Add('     - Edytuj treść sesji bezpośrednio w tym pliku')
    [void]$Lines.Add('     - Aby USUNĄĆ sesję: usuń cały blok (od --- do następnego ---)')
    [void]$Lines.Add('     - Aby DODAĆ sesję: wstaw nowy blok z nagłówkiem ### i komentarzem Źródło')
    [void]$Lines.Add('       (nowe sesje trafią do .robot.local/res/review-additions/)')
    [void]$Lines.Add('     - Duplikaty: edytuj treść — zmiany trafią do wylistowanych plików źródłowych')
    [void]$Lines.Add('       (usuwanie duplikatów z innych plików — ręcznie po zastosowaniu)')
    [void]$Lines.Add('     - Po edycji uruchom Fazę 4 → wybierz Z (Zastosuj zmiany)')
    [void]$Lines.Add('-->')

    foreach ($S in $Sorted) {
        [void]$Lines.Add('')
        [void]$Lines.Add('---')
        [void]$Lines.Add('')
        [void]$Lines.Add("### $($S.Header)")
        [void]$Lines.Add('')

        # Split content into lines
        if ($S.Content) {
            $ContentLines = $S.Content.Split([char]10)
            foreach ($CL in $ContentLines) {
                [void]$Lines.Add($CL.TrimEnd([char]13))
            }
        }

        [void]$Lines.Add('')

        # Build relative source paths
        $SourcePaths = [System.Collections.Generic.List[string]]::new()
        $Paths = if ($S.FilePaths) { $S.FilePaths } else { @($S.FilePath) }
        foreach ($FP in $Paths) {
            $RelPath = $FP
            if ($RelPath.StartsWith($RepoRoot)) { $RelPath = $RelPath.Substring($RepoRoot.Length + 1) }
            [void]$SourcePaths.Add($RelPath)
        }
        [void]$Lines.Add("<!-- Źródło: $($SourcePaths -join ', ') -->")

        # Resolved entity mentions (informational for reviewer)
        if ($S.Mentions -and $S.Mentions.Count -gt 0) {
            $SortedMentions = @([System.Linq.Enumerable]::OrderBy([object[]]$S.Mentions, [Func[object,string]]{ param($X) $X.Name }))
            $MentionTexts = ($SortedMentions.ForEach({ "$($_.Name) ($($_.Type))" })) -join ', '
            [void]$Lines.Add("<!-- Wzmianki: $MentionTexts -->")
        }
    }

    if (-not $WhatIf) {
        $ResDir = $script:MigrationResDir
        if (-not [System.IO.Directory]::Exists($ResDir)) {
            [void][System.IO.Directory]::CreateDirectory($ResDir)
        }
        $OutPath = [System.IO.Path]::Combine($ResDir, 'all-sessions-to-review.md')
        [System.IO.File]::WriteAllLines($OutPath, $Lines, [System.Text.UTF8Encoding]::new($false))
    }

    return $Sorted.Count
}

# ============================================================================
# HELPER: Import-SessionReviewFile
# ============================================================================

function Import-SessionReviewFile {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [switch]$WhatIf,
        [object[]]$Entities,
        [object[]]$Players
    )

    $ReviewPath = [System.IO.Path]::Combine($script:MigrationResDir, 'all-sessions-to-review.md')
    if (-not [System.IO.File]::Exists($ReviewPath)) {
        Write-StepError 'Plik przeglądu sesji nie istnieje'
        return $null
    }

    $ReviewLines = [System.IO.File]::ReadAllLines($ReviewPath)

    # Parse review file into session blocks
    $ReviewSessions = [System.Collections.Generic.List[object]]::new()
    $HeaderPattern = [regex]'^###\s+(.+)$'
    $SourcePattern = [regex]'^<!--\s*Źródło:\s*(.+?)\s*-->$'
    $MentionsPattern = [regex]'^<!--\s*Wzmianki:\s*(.+?)\s*-->$'

    $CurrentHeader = $null
    $CurrentBody = [System.Collections.Generic.List[string]]::new()
    $CurrentSource = $null
    $InBlock = $false
    $PastFileHeader = $false

    foreach ($Line in $ReviewLines) {
        # Skip file header (lines before first ---)
        if (-not $PastFileHeader) {
            if ($Line.Trim() -eq '---') { $PastFileHeader = $true }
            continue
        }

        # Block separator
        if ($Line.Trim() -eq '---') {
            # Save previous block if any
            if ($CurrentHeader) {
                $ReviewSessions.Add([PSCustomObject]@{
                    Header     = $CurrentHeader
                    Body       = ($CurrentBody -join "`n").Trim()
                    SourceLine = $CurrentSource
                })
            }
            $CurrentHeader = $null
            $CurrentBody = [System.Collections.Generic.List[string]]::new()
            $CurrentSource = $null
            $InBlock = $true
            continue
        }

        # Header line
        $HMatch = $HeaderPattern.Match($Line)
        if ($HMatch.Success -and -not $CurrentHeader) {
            $CurrentHeader = $HMatch.Groups[1].Value
            continue
        }

        # Source comment
        $SMatch = $SourcePattern.Match($Line)
        if ($SMatch.Success) {
            $CurrentSource = $SMatch.Groups[1].Value
            continue
        }

        # Mentions comment (informational, skip on import)
        if ($MentionsPattern.IsMatch($Line)) { continue }

        # Body line
        if ($CurrentHeader) {
            [void]$CurrentBody.Add($Line)
        }
    }

    # Save last block
    if ($CurrentHeader) {
        $ReviewSessions.Add([PSCustomObject]@{
            Header     = $CurrentHeader
            Body       = ($CurrentBody -join "`n").Trim()
            SourceLine = $CurrentSource
        })
    }

    # Fetch current state from source files
    $ImportArgs = @{ ExcludeDirectory = $script:MigrationExcludeDirs; IncludeContent = $true; Quiet = $true }
    if ($Entities) { $ImportArgs['Entities'] = $Entities }
    if ($Players)  { $ImportArgs['Players']  = $Players }
    $CurrentSessions = Get-Session @ImportArgs
    $CurrentByHeader = @{}
    foreach ($CS in $CurrentSessions) {
        $CurrentByHeader[$CS.Header] = $CS
    }

    $ReviewByHeader = @{}
    foreach ($RS in $ReviewSessions) {
        $ReviewByHeader[$RS.Header] = $RS
    }

    # Classify changes
    $Modified = [System.Collections.Generic.List[object]]::new()
    $New      = [System.Collections.Generic.List[object]]::new()
    $Deleted  = [System.Collections.Generic.List[object]]::new()
    $Unchanged = 0

    foreach ($RS in $ReviewSessions) {
        if ($CurrentByHeader.ContainsKey($RS.Header)) {
            $CS = $CurrentByHeader[$RS.Header]
            $CurrentBody = if ($CS.Content) { $CS.Content.TrimEnd() } else { '' }
            if ($RS.Body -ne $CurrentBody) {
                $Modified.Add([PSCustomObject]@{
                    Header      = $RS.Header
                    NewBody     = $RS.Body
                    SourceLine  = $RS.SourceLine
                    CurrentSession = $CS
                })
            } else {
                $Unchanged++
            }
        } else {
            $New.Add($RS)
        }
    }

    foreach ($CS in $CurrentSessions) {
        if (-not $ReviewByHeader.ContainsKey($CS.Header)) {
            $Deleted.Add($CS)
        }
    }

    # Display summary
    Write-Host ''
    Write-Host "    Podsumowanie zmian:" -ForegroundColor Cyan
    Write-Host "      Zmodyfikowanych: $($Modified.Count)" -ForegroundColor $(if ($Modified.Count -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Host "      Nowych:          $($New.Count)" -ForegroundColor $(if ($New.Count -gt 0) { 'Green' } else { 'DarkGray' })
    Write-Host "      Usuniętych:      $($Deleted.Count)" -ForegroundColor $(if ($Deleted.Count -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host "      Bez zmian:       $Unchanged" -ForegroundColor DarkGray

    if ($Modified.Count -eq 0 -and $New.Count -eq 0 -and $Deleted.Count -eq 0) {
        Write-StepOK 'Brak zmian do zastosowania'
        return [PSCustomObject]@{ Modified = 0; New = 0; Deleted = 0; Unchanged = $Unchanged }
    }

    # Show deletions prominently
    if ($Deleted.Count -gt 0) {
        Write-Host ''
        Write-Host '    USUNIĘCIA:' -ForegroundColor Red
        foreach ($D in $Deleted) {
            $RelPath = $D.FilePath
            if ($RelPath.StartsWith($RepoRoot)) { $RelPath = $RelPath.Substring($RepoRoot.Length + 1) }
            Write-Host "      - $($D.Header) ($RelPath)" -ForegroundColor Red
        }
    }

    # Confirmation gate
    if (-not $WhatIf) {
        if (-not (Request-YesNo -Prompt 'Zastosować zmiany?' -Default $false -HelpText @(
            "Zmodyfikowanych: $($Modified.Count), Nowych: $($New.Count), Usuniętych: $($Deleted.Count)",
            '',
            'Tak = zastosuj wszystkie zmiany do plików źródłowych',
            'Nie = anuluj, pliki źródłowe pozostaną bez zmian'
        ))) {
            Write-Host '  Anulowano zastosowanie zmian.' -ForegroundColor DarkGray
            return [PSCustomObject]@{ Modified = 0; New = 0; Deleted = 0; Unchanged = $Unchanged }
        }
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $ModifiedCount = 0
    $DeletedCount = 0
    $NewCount = 0

    # Group all modifications and deletions by target file for batched I/O.
    # Each file is read once, all changes applied in-memory, then written once.
    $FileOps = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Collect modification ops
    foreach ($M in $Modified) {
        $TargetPaths = @()
        if ($M.SourceLine) {
            $TargetPaths = @($M.SourceLine.Split(',') | ForEach-Object { $_.Trim() } | ForEach-Object {
                [System.IO.Path]::Combine($RepoRoot, $_)
            })
        } else {
            $CS = $M.CurrentSession
            $TargetPaths = if ($CS.FilePaths) { @($CS.FilePaths) } else { @($CS.FilePath) }
        }
        foreach ($TP in $TargetPaths) {
            if (-not $FileOps.ContainsKey($TP)) {
                $FileOps[$TP] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$FileOps[$TP].Add(@{ Type = 'Modify'; Header = $M.Header; NewBody = $M.NewBody })
        }
        $ModifiedCount++
    }

    # Collect deletion ops
    foreach ($D in $Deleted) {
        $FP = $D.FilePath
        if (-not $FileOps.ContainsKey($FP)) {
            $FileOps[$FP] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$FileOps[$FP].Add(@{ Type = 'Delete'; Header = $D.Header })
        $DeletedCount++
    }

    # Apply batched operations: one read + one write per file
    foreach ($FilePath in $FileOps.Keys) {
        if (-not [System.IO.File]::Exists($FilePath)) { continue }
        $FileLines = [System.IO.File]::ReadAllLines($FilePath)

        # Apply ops in reverse section order to preserve line indices
        $Ops = $FileOps[$FilePath]
        $OpMatches = [System.Collections.Generic.List[object]]::new()
        foreach ($Op in $Ops) {
            $Matches = Find-SessionInFile -Lines $FileLines -TargetHeader $Op.Header
            if ($Matches.Count -gt 0) {
                [void]$OpMatches.Add(@{ Op = $Op; Match = $Matches[0] })
            }
        }
        # Sort by HeaderLineIdx descending so later sections are processed first
        $OpMatches.Sort([System.Comparison[object]]{ param($a, $b) $b.Match.HeaderLineIdx.CompareTo($a.Match.HeaderLineIdx) })

        foreach ($OM in $OpMatches) {
            $Match = $OM.Match
            if ($OM.Op.Type -eq 'Modify') {
                $NewBodyLines = @($OM.Op.NewBody.Split("`n"))
                $Before = @()
                if ($Match.HeaderLineIdx -ge 0) { $Before = $FileLines[0..$Match.HeaderLineIdx] }
                $After = @()
                if ($Match.SectionEndIdx -lt $FileLines.Count) { $After = $FileLines[$Match.SectionEndIdx..($FileLines.Count - 1)] }
                $FileLines = @($Before) + @('') + $NewBodyLines + @('') + @($After)
            }
            elseif ($OM.Op.Type -eq 'Delete') {
                $Before = @()
                if ($Match.HeaderLineIdx -gt 0) { $Before = $FileLines[0..($Match.HeaderLineIdx - 1)] }
                $After = @()
                if ($Match.SectionEndIdx -lt $FileLines.Count) { $After = $FileLines[$Match.SectionEndIdx..($FileLines.Count - 1)] }
                $FileLines = @($Before) + @($After)
            }
        }

        if (-not $WhatIf) {
            [System.IO.File]::WriteAllLines($FilePath, $FileLines, $UTF8NoBOM)
        }
    }

    # Create new session files
    if ($New.Count -gt 0) {
        $AdditionsDir = [System.IO.Path]::Combine($script:MigrationResDir, 'review-additions')
        if (-not $WhatIf -and -not [System.IO.Directory]::Exists($AdditionsDir)) {
            [void][System.IO.Directory]::CreateDirectory($AdditionsDir)
        }

        foreach ($N in $New) {
            # Generate filename from header: YYYY-MM-DD-slugified-title.md
            $Parts = $N.Header -split ',\s*'
            $DatePart = if ($Parts.Count -gt 0) { $Parts[0].Trim() } else { 'unknown' }
            $TitlePart = if ($Parts.Count -gt 1) { $Parts[1].Trim() } else { 'session' }
            $Slug = ($TitlePart -replace '[^\w\s-]', '' -replace '\s+', '-').ToLower()
            if ($Slug.Length -gt 50) { $Slug = $Slug.Substring(0, 50) }
            $FileName = "$DatePart-$Slug.md"

            $NewFileLines = @("### $($N.Header)", '', $N.Body)

            if (-not $WhatIf) {
                $NewFilePath = [System.IO.Path]::Combine($AdditionsDir, $FileName)
                [System.IO.File]::WriteAllLines($NewFilePath, $NewFileLines, $UTF8NoBOM)
            }
            $NewCount++
        }
    }

    $ActionLabel = if ($WhatIf) { '[SUCHY PRZEBIEG] ' } else { '' }
    Write-StepOK "${ActionLabel}Zastosowano: $ModifiedCount zmodyfikowanych, $NewCount nowych, $DeletedCount usuniętych"

    return [PSCustomObject]@{ Modified = $ModifiedCount; New = $NewCount; Deleted = $DeletedCount; Unchanged = $Unchanged }
}

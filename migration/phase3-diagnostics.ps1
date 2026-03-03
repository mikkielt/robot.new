<#
    .SYNOPSIS
    Phase 3: Diagnostics & data repair (iterative).

    .DESCRIPTION
    Runs PU diagnostics, offers soft-delete for characters with PU=BRAK,
    handles narrator normalization with interactive mapping. Designed to
    be run repeatedly until all issues are resolved.

    Dependencies: migration-ui.ps1, migration-state.ps1, migration-shared.ps1,
                  narrator-normalization.ps1, robot module imported.
#>

# ============================================================================
# PHASE 3 - Diagnostics & data repair (iterative)
# ============================================================================

function Invoke-MigrationPhase3 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 3
    Write-PhaseHeader -Phase 3 -Status $PhaseStatus

    Write-Step -Number 1 -Text 'Uruchamianie diagnostyki...'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs

    if ($Diag.OK) {
        Write-StepOK 'Diagnostyka: OK - brak problemów'
        Set-PhaseCompleted -State $State -Phase 3
        Add-DiagnosticSnapshot -State $State -OK $true -IssueCount 0
        Write-PhaseSummary -Phase 3 -Status 'Completed' -Lines @('[OK] Wszystkie dane poprawne')
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    Set-PhaseInProgress -State $State -Phase 3
    Show-DiagnosticResults -Diagnostics $Diag

    # Show characters with PU=BRAK and offer to soft-delete
    if (-not $WhatIf) {
        Show-BRAKCharacters -State $State
    }

    # Narrator normalization step
    $NarratorNormDone = $State.Phases.ContainsKey('3') -and $State.Phases['3'].ContainsKey('Checklist') -and $State.Phases['3'].Checklist.ContainsKey('NarratorNormalizationDone') -and $State.Phases['3'].Checklist['NarratorNormalizationDone']
    $UnresolvedNarratorCount = 0

    if (-not $NarratorNormDone) {
        Write-Step -Number 2 -Text 'Diagnostyka narratorów...'

        $NarrSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs
        $NarrReport = Get-NarratorReport -Sessions $NarrSessions -UnresolvedOnly
        # Filter to Confidence = None and no existing mapping
        $UnresolvedNarrators = @($NarrReport | Where-Object { $_.Confidence -eq 'None' -and -not $_.HasMapping })
        $UnresolvedNarratorCount = $UnresolvedNarrators.Count

        if ($UnresolvedNarratorCount -eq 0) {
            Write-StepOK 'Wszyscy narratorzy rozwiązani lub zamapowani'
            Update-PhaseChecklist -State $State -Phase 3 -Item 'NarratorNormalizationDone' -Value $true
        } else {
            Write-StepWarning "$UnresolvedNarratorCount nierozwiązanych narratorów"

            if (-not $WhatIf) {
                . "$PSScriptRoot/narrator-normalization.ps1"
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
                        -Prompt "      [A] Dodaj alias  [M] Mapuj ręcznie  [P] Pomiń  [K] Kontynuuj >" `
                        -ValidChoices @('A', 'M', 'P', 'K')

                    if ($Choice -eq 'K') { break }
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

            Update-PhaseChecklist -State $State -Phase 3 -Item 'NarratorNormalizationDone' -Value $true
        }
    } else {
        Write-Step -Number 2 -Text 'Diagnostyka narratorów...'
        Write-StepOK 'Normalizacja narratorów już wykonana'
    }

    # Record diagnostic snapshot and calculate totals
    $TotalIssues = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                   $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count +
                   $UnresolvedNarratorCount
    Add-DiagnosticSnapshot -State $State -OK $false -IssueCount $TotalIssues

    # Show diagnostic trend across iterations
    $History = $State.Phases['3'].DiagnosticHistory
    if ($History -and $History.Count -gt 1) {
        Write-SectionHeader 'Trend diagnostyki'
        for ($I = 0; $I -lt $History.Count; $I++) {
            $Entry = $History[$I]
            $IssuesVal = if ($Entry -is [hashtable]) { $Entry.Issues } else { $Entry.Issues }
            $Marker = if ($I -eq ($History.Count - 1)) { '>>>' } else { '   ' }
            Write-Host "  $Marker Przebieg $($I + 1): $IssuesVal problemów" -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '  Po naprawieniu problemów uruchom Fazę 3 ponownie.' -ForegroundColor Cyan
    Write-Host '  Wzorzec: diagnostyka → naprawa → diagnostyka → ... aż OK = True' -ForegroundColor DarkGray

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# Display characters with PU=BRAK and offer to soft-delete them
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
        $Choice = Request-YesNo -Prompt "    Czy oznaczyć '$($Item.CharacterName)' jako nieaktywną?" -Default $false
        if ($Choice) {
            try {
                Set-PlayerCharacter -PlayerName $Item.PlayerName -CharacterName $Item.CharacterName -Status 'Nieaktywny' -Confirm:$false
                Write-StepOK "Oznaczono '$($Item.CharacterName)' jako nieaktywną"
            }
            catch {
                Write-StepError "Nie udało się oznaczyć jako nieaktywną: $($_.Exception.Message)"
            }
        }
    }
}

<#
    .SYNOPSIS
    Phase 6: Cutover (readiness check, freeze legacy, first standalone PU run).

    .DESCRIPTION
    First runs readiness checks (PU diagnostics, PU simulation, session format,
    currency reconciliation, cutover criteria) and blocks if not met. Once all
    criteria pass, proceeds to cutover steps: final PU diagnostics, freeze
    Gracze.md, mark legacy deprecated, first standalone PU assignment, post-
    migration tag, Discord announcement template, and final verification.

    Dependencies: migration-ui.ps1, migration-state.ps1, migration-shared.ps1,
                  robot module imported.
#>

# ============================================================================
# PHASE 6 - Cutover (readiness check, freeze legacy, first standalone PU run)
# ============================================================================

function Invoke-MigrationPhase6 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    # Predecessor guard: Phase 5 must be completed
    if (-not (Test-PhasePredecessor -State $State -Phase 6)) {
        Write-StepWarning 'Faza 5 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 6
    Write-PhaseHeader -Phase 6 -Status $PhaseStatus

    # ========================================================================
    # READINESS GATE
    # ========================================================================

    # Initialize parallel period start timestamp on first run
    if ($PhaseStatus -eq 'NotStarted') {
        Set-PhaseInProgress -State $State -Phase 6
        $State.Phases['6'].ParallelStartedAt = [datetime]::UtcNow.ToString('o')
    }

    # Display parallel period duration
    $StartStr = $State.Phases['6'].ParallelStartedAt
    if ($StartStr) {
        $Start = [datetime]::Parse($StartStr)
        $Days = ([datetime]::UtcNow - $Start).Days
        Write-Host "  Okres równoległy trwa od: $($Start.ToString('yyyy-MM-dd')), dzień $Days" -ForegroundColor Cyan
    }

    # Dashboard section 1: PU diagnostics
    Write-SectionHeader 'Diagnostyka PU'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs
    if ($Diag.OK) {
        Write-StepOK 'Test-PlayerCharacterPUAssignment: OK'
    } else {
        $IssueCount = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                      $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
        Write-StepWarning "Test-PlayerCharacterPUAssignment: $IssueCount problemów"
    }
    Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_DiagnosticsOK' -Value $Diag.OK

    # Dashboard section 2: PU simulation (dry-run for current month)
    Write-SectionHeader 'Symulacja PU (bieżący miesiąc)'
    $Now = [datetime]::Now
    try {
        $PUResults = Invoke-PlayerCharacterPUAssignment -Year $Now.Year -Month $Now.Month -ExcludeDirectory $script:MigrationExcludeDirs -WhatIf 2>$null
        if ($PUResults -and $PUResults.Count -gt 0) {
            Write-TableRow -Columns @('Postać', 'Przyznane PU', 'Nadmiar', 'Wyk. nadmiar') -Widths @(25, 15, 12, 15) -Color 'White'
            Write-Host ('  ' + ('-' * 67)) -ForegroundColor DarkGray
            foreach ($Result in $PUResults) {
                Write-TableRow -Columns @(
                    $Result.CharacterName,
                    "$($Result.GrantedPU)",
                    "$($Result.OverflowPU)",
                    "$($Result.UsedExceeded)"
                ) -Widths @(25, 15, 12, 15) -Color 'DarkGray'
            }
        } else {
            Write-Host '  Brak sesji z PU do przetworzenia w bieżącym miesiącu.' -ForegroundColor DarkGray
        }
    }
    catch {
        Write-StepWarning "Symulacja PU nie powiodła się: $($_.Exception.Message)"
    }

    # Dashboard section 3: Recent session format check
    Write-SectionHeader 'Format sesji'
    $RecentSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs -Quiet | Where-Object { $_.Date -and $_.Date -ge [datetime]::Now.AddMonths(-2) }
    $NonGen4Recent = $RecentSessions | Where-Object { $_.Format -ne 'Gen4' }
    $NonGen4Count = ($NonGen4Recent | Measure-Object).Count
    if ($NonGen4Count -eq 0) {
        Write-StepOK 'Wszystkie ostatnie sesje w formacie Gen4'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_AllGen4' -Value $true
    } else {
        Write-StepWarning "$NonGen4Count ostatnich sesji nie w formacie Gen4"
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_AllGen4' -Value $false
    }

    # Dashboard section 4: Currency reconciliation
    Write-SectionHeader 'Rekoncyliacja walut'
    $Recon = Test-CurrencyReconciliation
    if ($Recon.WarningCount -eq 0) {
        Write-StepOK 'Brak ostrzeżeń'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_CurrencyOK' -Value $true
    } else {
        Write-StepWarning "$($Recon.WarningCount) ostrzeżeń"
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_CurrencyOK' -Value $false
    }

    # Dashboard section 5: Session graph integrity
    Write-SectionHeader 'Integralność grafu sesji'
    $GraphInteg = Test-SessionGraphIntegrity -ExcludeDirectory $script:MigrationExcludeDirs -Quiet
    if ($GraphInteg.IndexMissing) {
        Write-StepWarning 'Graf sesji nie został zbudowany — uruchom fazę 4'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_SessionGraphOK' -Value $false
    } elseif ($GraphInteg.OK) {
        Write-StepOK 'Test-SessionGraphIntegrity: OK'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_SessionGraphOK' -Value $true
    } else {
        $GraphIssueCount = $GraphInteg.OrphanedSessions.Count + $GraphInteg.MissingSessions.Count +
                           $GraphInteg.EmptySessions.Count + $GraphInteg.StaleNameVersion.Count
        Write-StepWarning "Test-SessionGraphIntegrity: $GraphIssueCount problemów"
        Update-PhaseChecklist -State $State -Phase 6 -Item 'Readiness_SessionGraphOK' -Value $false
    }

    # Dashboard section 6: Cutover readiness criteria
    Write-SectionHeader 'Kryteria przełączenia'
    $Criteria = @{
        'Min. 1 pełny cykl PU bez rozbieżności'  = $State.Phases['6'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['6'].Checklist['PUCycleValidated']
        'Wszyscy aktywni narratorzy stosują Gen4'  = $NonGen4Count -eq 0
        'Test-PUAssignment: OK = True'             = $Diag.OK
        'Test-CurrencyReconciliation: brak błędów' = $Recon.WarningCount -eq 0
        'Test-SessionGraphIntegrity: OK'            = -not $GraphInteg.IndexMissing -and $GraphInteg.OK
    }
    Write-ChecklistReport -Checklist $Criteria -Title 'KRYTERIA PRZEŁĄCZENIA'

    # Ask coordinator to confirm PU cycle validation (one-time gate)
    if ($Diag.OK -and -not ($State.Phases['6'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['6'].Checklist['PUCycleValidated'])) {
        if (Request-YesNo -Prompt 'Czy porównano wyniki PU z starym systemem i są zgodne?' -Default $false -HelpText @(
            'Potwierdzenie, że wyniki przydziału PU z nowego systemu',
            '(.robot.new) zgadzają się z wynikami starego systemu.',
            '',
            'To jednorazowa bramka — po potwierdzeniu kryterium',
            '"Min. 1 pełny cykl PU bez rozbieżności" zostanie',
            'oznaczone jako spełnione.',
            '',
            'Tak = potwierdzam zgodność wyników PU',
            'Nie = jeszcze nie porównano lub są rozbieżności'
        )) {
            Update-PhaseChecklist -State $State -Phase 6 -Item 'PUCycleValidated' -Value $true
        }
    }

    # Append dashboard run timestamp to history
    if (-not $State.Phases['6'].ContainsKey('DashboardRuns')) {
        $State.Phases['6'].DashboardRuns = @()
    }
    $State.Phases['6'].DashboardRuns = @($State.Phases['6'].DashboardRuns) + @([datetime]::UtcNow.ToString('o'))

    # Evaluate all criteria — if any fail, save state and return (don't proceed to cutover)
    $FailedCriteria = $Criteria.Values | Where-Object { $_ -eq $false }
    if (($FailedCriteria | Measure-Object).Count -gt 0) {
        Write-Host ''
        Write-StepWarning 'Nie wszystkie kryteria spełnione. Przełączenie zablokowane.'
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    Write-Host ''
    Write-StepOK 'Wszystkie kryteria spełnione. Przejście do przełączenia...'

    # ========================================================================
    # CUTOVER
    # ========================================================================

    $RepoRoot = Get-RepoRoot

    # Step 5: Run final PU diagnostics (must pass to proceed)
    Write-Step -Number 5 -Text 'Ostateczna diagnostyka...'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs
    if ($Diag.OK) {
        Write-StepOK 'Diagnostyka: OK'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'FinalDiagnostics' -Value $true
    } else {
        Write-StepError 'Diagnostyka: PROBLEMY - napraw je przed przełączeniem'
        Show-DiagnosticResults -Diagnostics $Diag
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # Step 6: Freeze Gracze.md with read-only comment header
    Write-Step -Number 6 -Text 'Zamrożenie Gracze.md...'
    $GraczePath = [System.IO.Path]::Combine($RepoRoot, 'Gracze.md')
    $FreezeComment = "<!-- UWAGA: Ten plik jest zamrożony (read-only) od $([datetime]::Now.ToString('yyyy-MM-dd')).`n     Wszelkie zmiany wprowadzaj przez moduł .robot.new i plik entities.md.`n     Ten plik zachowany jest wyłącznie jako archiwum historyczne. -->"

    if ([System.IO.File]::Exists($GraczePath)) {
        $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
        $GraczeContent = [System.IO.File]::ReadAllText($GraczePath, $UTF8NoBOM)

        if ($GraczeContent.Contains('zamrożony (read-only)')) {
            Write-StepOK 'Gracze.md już zamrożony'
            Update-PhaseChecklist -State $State -Phase 6 -Item 'GraczeFrozen' -Value $true
        } else {
            if ($WhatIf) {
                Write-StepWarning '[SUCHY PRZEBIEG] Dodałbym komentarz zamrożenia do Gracze.md'
            } elseif (Request-YesNo -Prompt 'Czy dodać komentarz zamrożenia do Gracze.md?' -Default $true -HelpText @(
                'Dodanie komentarza HTML na początku Gracze.md',
                'oznaczającego plik jako zamrożony (read-only).',
                '',
                'Od tego momentu Gracze.md staje się archiwum.',
                'Wszelkie zmiany danych graczy odbywają się',
                'wyłącznie przez entities.md i moduł .robot.new.',
                '',
                'Tak = dodaj komentarz i zacommituj zmianę',
                'Nie = pomiń, Gracze.md pozostanie bez oznaczenia'
            )) {
                $NewContent = "$FreezeComment`n`n$GraczeContent"
                [System.IO.File]::WriteAllText($GraczePath, $NewContent, $UTF8NoBOM)
                & git -C $RepoRoot add 'Gracze.md' 2>&1
                & git -C $RepoRoot commit -m 'Zamrożenie Gracze.md - migracja zakończona' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Gracze.md zamrożony i zacommitowany'
                    Update-PhaseChecklist -State $State -Phase 6 -Item 'GraczeFrozen' -Value $true
                }
            }
        }
    } else {
        Write-StepWarning 'Plik Gracze.md nie znaleziony'
    }

    # Step 7: Mark legacy .robot/ system as deprecated
    Write-Step -Number 7 -Text 'Oznaczenie starego systemu jako deprecated...'
    Write-Host '  Dodaj notatkę deprecation do .robot/README.md (jeśli istnieje)' -ForegroundColor DarkGray
    Write-Host '  lub poinformuj zespół, że .robot/robot.ps1 nie jest już używany.' -ForegroundColor DarkGray
    Update-PhaseChecklist -State $State -Phase 6 -Item 'OldSystemDeprecated' -Value $true

    # Step 8: Execute first standalone PU assignment
    Write-Step -Number 8 -Text 'Pierwszy samodzielny przydział PU...'
    $Now = [datetime]::Now
    $Year = $Now.Year
    $Month = $Now.Month

    Write-Host "  Rok: $Year, Miesiąc: $Month" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Suchy przebieg:' -ForegroundColor Cyan
    Write-CommandHint "Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month -WhatIf"

    try {
        $DryResults = Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month -ExcludeDirectory $script:MigrationExcludeDirs -WhatIf 2>$null
        if ($DryResults -and $DryResults.Count -gt 0) {
            Write-Host ''
            foreach ($Result in $DryResults) {
                Write-Host "    $($Result.CharacterName): Przyznane=$($Result.GrantedPU), Nadmiar=$($Result.OverflowPU)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host '  Brak sesji z PU do przetworzenia.' -ForegroundColor DarkGray
        }
    }
    catch {
        Write-StepWarning "Suchy przebieg nie powiódł się: $($_.Exception.Message)"
    }

    if (-not $WhatIf -and $DryResults -and $DryResults.Count -gt 0) {
        if (Request-YesNo -Prompt 'Czy wykonać właściwy przydział PU z powiadomieniami Discord?' -Default $false -HelpText @(
            'UWAGA: To jest operacja produkcyjna z rzeczywistymi',
            'skutkami ubocznymi!',
            '',
            'Wykona pełny przydział PU za bieżący miesiąc:',
            '- zaktualizuje pliki postaci (Postaci/Gracze/*.md)',
            '- wyśle powiadomienia Discord do graczy',
            '- dopisze wpis do logu PU (.robot/res/pu-sessions.md)',
            '',
            'Tak = wykonaj przydział PU i wyślij powiadomienia',
            'Nie = pomiń, przydział PU można wykonać później ręcznie'
        )) {
            try {
                Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month `
                    -ExcludeDirectory $script:MigrationExcludeDirs `
                    -UpdatePlayerCharacters `
                    -SendToDiscord `
                    -AppendToLog `
                    -Confirm:$false
                Write-StepOK 'Przydział PU wykonany, powiadomienia wysłane'
                Update-PhaseChecklist -State $State -Phase 6 -Item 'FirstPURun' -Value $true
            }
            catch {
                Write-StepError "Przydział PU nie powiódł się: $($_.Exception.Message)"
            }
        }
    }

    # Step 9: Create post-migration git tag
    Write-Step -Number 9 -Text 'Tag post-migration...'
    $PostTag = & git -C $RepoRoot tag -l 'post-migration' 2>&1
    if ($PostTag) {
        Write-StepOK "Tag 'post-migration' już istnieje"
    } else {
        if ($WhatIf) {
            Write-StepWarning "[SUCHY PRZEBIEG] Utworzyłbym tag 'post-migration'"
        } else {
            & git -C $RepoRoot tag 'post-migration' -m 'Migracja na .robot.new zakończona' 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-StepOK "Utworzono tag 'post-migration'"
            }
        }
    }
    Update-PhaseChecklist -State $State -Phase 6 -Item 'PostMigrationTag' -Value $true

    # Step 10: Show Discord announcement template
    Write-Step -Number 10 -Text 'Szablon ogłoszenia...'
    Write-Host ''
    Write-Host '  Skopiuj i wyślij na Discord:' -ForegroundColor White
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  Migracja systemu administracyjnego zakończona.' -ForegroundColor Cyan
    Write-Host '  Od teraz wszystkie operacje przez moduł .robot.new.' -ForegroundColor Cyan
    Write-Host '  Sesje prosimy zapisywać w formacie z prefiksem @.' -ForegroundColor Cyan
    Write-Host '  Stary system (.robot/robot.ps1) nie jest już używany.' -ForegroundColor Cyan
    Write-Host '  W razie pytań - kontakt z koordynatorem.' -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor DarkGray
    Update-PhaseChecklist -State $State -Phase 6 -Item 'Announcement' -Value $true

    # Step 11: Display final verification checklist
    Write-Step -Number 11 -Text 'Weryfikacja końcowa...'
    $FinalChecklist = @{
        'entities.md wygenerowany i zacommitowany'           = (Get-PhaseStatus -State $State -Phase 0) -eq 'Completed'
        'Test-PUAssignment: OK = True'                       = $Diag.OK
        'Aktywne sesje w Gen4'                               = (Get-PhaseStatus -State $State -Phase 4) -eq 'Completed'
        'Waluty zarejestrowane'                               = (Get-PhaseStatus -State $State -Phase 5) -eq 'Completed'
        'Min. 1 cykl PU bez rozbieżności'                    = $State.Phases['6'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['6'].Checklist['PUCycleValidated']
        'Gracze.md zamrożony'                                = $State.Phases['6'].Checklist.ContainsKey('GraczeFrozen') -and $State.Phases['6'].Checklist['GraczeFrozen']
        'Stary system deprecated'                            = $true
        'Tag post-migration istnieje'                        = $true
        'Zespół poinformowany'                               = $true
    }
    Write-ChecklistReport -Checklist $FinalChecklist -Title 'WERYFIKACJA KOŃCOWA'

    # Phase summary and state persistence
    Set-PhaseCompleted -State $State -Phase 6
    Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @(
        '[OK] Migracja zakończona!',
        '[OK] System .robot.new jest aktywny',
        '[OK] Gracze.md zamrożony jako archiwum'
    )

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

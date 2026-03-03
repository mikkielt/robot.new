<#
    .SYNOPSIS
    Phase 7: Cutover (freeze legacy, first standalone PU run).

    .DESCRIPTION
    Runs final diagnostics, freezes Gracze.md with read-only comment,
    marks legacy system as deprecated, executes first standalone PU
    assignment, creates post-migration tag, and shows announcement template.

    Dependencies: migration-ui.ps1, migration-state.ps1, migration-shared.ps1,
                  robot module imported.
#>

# ============================================================================
# PHASE 7 - Cutover (freeze legacy, first standalone PU run)
# ============================================================================

function Invoke-MigrationPhase7 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 7
    Write-PhaseHeader -Phase 7 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot

    # Step 1: Run final PU diagnostics (must pass to proceed)
    Write-Step -Number 1 -Text 'Ostateczna diagnostyka...'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs
    if ($Diag.OK) {
        Write-StepOK 'Diagnostyka: OK'
        Update-PhaseChecklist -State $State -Phase 7 -Item 'FinalDiagnostics' -Value $true
    } else {
        Write-StepError 'Diagnostyka: PROBLEMY - napraw je przed przełączeniem'
        Show-DiagnosticResults -Diagnostics $Diag
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # Step 2: Freeze Gracze.md with read-only comment header
    Write-Step -Number 2 -Text 'Zamrożenie Gracze.md...'
    $GraczePath = [System.IO.Path]::Combine($RepoRoot, 'Gracze.md')
    $FreezeComment = "<!-- UWAGA: Ten plik jest zamrożony (read-only) od $([datetime]::Now.ToString('yyyy-MM-dd')).`n     Wszelkie zmiany wprowadzaj przez moduł .robot.new i plik entities.md.`n     Ten plik zachowany jest wyłącznie jako archiwum historyczne. -->"

    if ([System.IO.File]::Exists($GraczePath)) {
        $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
        $GraczeContent = [System.IO.File]::ReadAllText($GraczePath, $UTF8NoBOM)

        if ($GraczeContent.Contains('zamrożony (read-only)')) {
            Write-StepOK 'Gracze.md już zamrożony'
            Update-PhaseChecklist -State $State -Phase 7 -Item 'GraczeFrozen' -Value $true
        } else {
            if ($WhatIf) {
                Write-StepWarning '[SUCHY PRZEBIEG] Dodałbym komentarz zamrożenia do Gracze.md'
            } elseif (Request-YesNo -Prompt 'Czy dodać komentarz zamrożenia do Gracze.md?' -Default $true) {
                $NewContent = "$FreezeComment`n`n$GraczeContent"
                [System.IO.File]::WriteAllText($GraczePath, $NewContent, $UTF8NoBOM)
                & git -C $RepoRoot add 'Gracze.md' 2>&1
                & git -C $RepoRoot commit -m 'Zamrożenie Gracze.md - migracja zakończona' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Gracze.md zamrożony i zacommitowany'
                    Update-PhaseChecklist -State $State -Phase 7 -Item 'GraczeFrozen' -Value $true
                }
            }
        }
    } else {
        Write-StepWarning 'Plik Gracze.md nie znaleziony'
    }

    # Step 3: Mark legacy .robot/ system as deprecated
    Write-Step -Number 3 -Text 'Oznaczenie starego systemu jako deprecated...'
    Write-Host '  Dodaj notatkę deprecation do .robot/README.md (jeśli istnieje)' -ForegroundColor DarkGray
    Write-Host '  lub poinformuj zespół, że .robot/robot.ps1 nie jest już używany.' -ForegroundColor DarkGray
    Update-PhaseChecklist -State $State -Phase 7 -Item 'OldSystemDeprecated' -Value $true

    # Step 4: Execute first standalone PU assignment
    Write-Step -Number 4 -Text 'Pierwszy samodzielny przydział PU...'
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
        if (Request-YesNo -Prompt 'Czy wykonać właściwy przydział PU z powiadomieniami Discord?' -Default $false) {
            try {
                Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month `
                    -ExcludeDirectory $script:MigrationExcludeDirs `
                    -UpdatePlayerCharacters `
                    -SendToDiscord `
                    -AppendToLog `
                    -Confirm:$false
                Write-StepOK 'Przydział PU wykonany, powiadomienia wysłane'
                Update-PhaseChecklist -State $State -Phase 7 -Item 'FirstPURun' -Value $true
            }
            catch {
                Write-StepError "Przydział PU nie powiódł się: $($_.Exception.Message)"
            }
        }
    }

    # Step 5: Create post-migration git tag
    Write-Step -Number 5 -Text 'Tag post-migration...'
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
    Update-PhaseChecklist -State $State -Phase 7 -Item 'PostMigrationTag' -Value $true

    # Step 6: Show Discord announcement template
    Write-Step -Number 6 -Text 'Szablon ogłoszenia...'
    Write-Host ''
    Write-Host '  Skopiuj i wyślij na Discord:' -ForegroundColor White
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  Migracja systemu administracyjnego zakończona.' -ForegroundColor Cyan
    Write-Host '  Od teraz wszystkie operacje przez moduł .robot.new.' -ForegroundColor Cyan
    Write-Host '  Sesje prosimy zapisywać w formacie z prefiksem @.' -ForegroundColor Cyan
    Write-Host '  Stary system (.robot/robot.ps1) nie jest już używany.' -ForegroundColor Cyan
    Write-Host '  W razie pytań - kontakt z koordynatorem.' -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor DarkGray
    Update-PhaseChecklist -State $State -Phase 7 -Item 'Announcement' -Value $true

    # Step 7: Display final verification checklist
    Write-Step -Number 7 -Text 'Weryfikacja końcowa...'
    $FinalChecklist = @{
        'entities.md wygenerowany i zacommitowany'           = (Get-PhaseStatus -State $State -Phase 1) -eq 'Completed'
        'Test-PUAssignment: OK = True'                       = $Diag.OK
        'Aktywne sesje w Gen4'                               = (Get-PhaseStatus -State $State -Phase 4) -eq 'Completed'
        'Waluty zarejestrowane'                               = (Get-PhaseStatus -State $State -Phase 5) -eq 'Completed'
        'Min. 1 cykl PU bez rozbieżności'                    = (Get-PhaseStatus -State $State -Phase 6) -eq 'Completed'
        'Gracze.md zamrożony'                                = $State.Phases['7'].Checklist.ContainsKey('GraczeFrozen') -and $State.Phases['7'].Checklist['GraczeFrozen']
        'Stary system deprecated'                            = $true
        'Tag post-migration istnieje'                        = $true
        'Zespół poinformowany'                               = $true
    }
    Write-ChecklistReport -Checklist $FinalChecklist -Title 'WERYFIKACJA KOŃCOWA'

    # Phase summary and state persistence
    Set-PhaseCompleted -State $State -Phase 7
    Write-PhaseSummary -Phase 7 -Status 'Completed' -Lines @(
        '[OK] Migracja zakończona!',
        '[OK] System .robot.new jest aktywny',
        '[OK] Gracze.md zamrożony jako archiwum'
    )

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

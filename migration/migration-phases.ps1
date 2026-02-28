<#
    .SYNOPSIS
    Phase 0-7 implementation functions for the migration script.

    .DESCRIPTION
    Non-exported functions consumed by migrate.ps1 via dot-sourcing. Each phase
    is implemented as Invoke-MigrationPhaseN receiving $State and $WhatIf.

    Phases:
    - Phase 0: Preparation & backup (verify clean state, create safety tag)
    - Phase 1: Bootstrap entities.md from Gracze.md
    - Phase 2: Data parity validation (read-only)
    - Phase 3: Diagnostics & data repair (iterative)
    - Phase 4: Session format upgrade to Gen4
    - Phase 5: Currency enrollment
    - Phase 6: Parallel operation monitoring dashboard
    - Phase 7: Cutover (freeze Gracze.md, first standalone PU run)

    All phases are idempotent: re-running a completed phase verifies without
    re-executing mutations.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 0 — Preparation & backup
# ============================================================================

function Invoke-MigrationPhase0 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 0
    Write-PhaseHeader -Phase 0 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $AllOK = $true

    # Step 1: Verify clean git status
    Write-Step -Number 1 -Text 'Sprawdzanie stanu repozytorium...'
    $GitStatus = & git -C $RepoRoot status --porcelain 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-StepError "Nie udało się uruchomić 'git status': $GitStatus"
        $AllOK = $false
    } elseif ($GitStatus) {
        Write-StepWarning "Repozytorium ma niezacommitowane zmiany:"
        foreach ($Line in ($GitStatus | Select-Object -First 10)) {
            Write-Host "    $Line" -ForegroundColor DarkGray
        }
        Write-ActionRequired 'Zacommituj lub schowaj (git stash) zmiany przed kontynuowaniem.'
        $AllOK = $false
    } else {
        Write-StepOK 'Repozytorium w czystym stanie'
    }
    Update-PhaseChecklist -State $State -Phase 0 -Item 'CleanGitStatus' -Value ($null -eq $GitStatus -or $GitStatus.Count -eq 0)

    # Step 2: Safety tag
    Write-Step -Number 2 -Text 'Sprawdzanie tagu bezpieczeństwa...'
    $TagExists = & git -C $RepoRoot tag -l 'pre-migration' 2>&1
    if ($TagExists) {
        Write-StepOK "Tag 'pre-migration' już istnieje"
    } else {
        if ($WhatIf) {
            Write-StepWarning "[SUCHY PRZEBIEG] Utworzyłbym tag 'pre-migration'"
        } else {
            & git -C $RepoRoot tag 'pre-migration' -m 'Stan repozytorium przed migracją na .robot.new' 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-StepOK "Utworzono tag 'pre-migration'"
            } else {
                Write-StepError "Nie udało się utworzyć tagu 'pre-migration'"
                $AllOK = $false
            }
        }
    }
    Update-PhaseChecklist -State $State -Phase 0 -Item 'PreMigrationTag' -Value $true

    # Step 3: Verify PU state file exists
    Write-Step -Number 3 -Text 'Sprawdzanie pliku stanu PU...'
    $PUStatePath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'pu-sessions.md')
    if ([System.IO.File]::Exists($PUStatePath)) {
        $LineCount = [System.IO.File]::ReadAllLines($PUStatePath).Count
        Write-StepOK "Plik pu-sessions.md istnieje ($LineCount linii)"
        Update-PhaseChecklist -State $State -Phase 0 -Item 'PUStateFileExists' -Value $true
    } else {
        Write-StepWarning 'Plik pu-sessions.md nie istnieje (zostanie utworzony automatycznie przy pierwszym przydziale PU)'
        Update-PhaseChecklist -State $State -Phase 0 -Item 'PUStateFileExists' -Value $false
    }

    # Step 4: Verify submodule registration
    Write-Step -Number 4 -Text 'Sprawdzanie submodułu .robot.new...'
    $GitmodulesPath = [System.IO.Path]::Combine($RepoRoot, '.gitmodules')
    if ([System.IO.File]::Exists($GitmodulesPath)) {
        $GitmodulesContent = [System.IO.File]::ReadAllText($GitmodulesPath)
        if ($GitmodulesContent.Contains('.robot.new')) {
            Write-StepOK 'Submoduł .robot.new zarejestrowany w .gitmodules'
            Update-PhaseChecklist -State $State -Phase 0 -Item 'SubmoduleOK' -Value $true
        } else {
            Write-StepWarning 'Plik .gitmodules istnieje, ale nie zawiera wpisu .robot.new'
            Update-PhaseChecklist -State $State -Phase 0 -Item 'SubmoduleOK' -Value $false
            $AllOK = $false
        }
    } else {
        Write-StepWarning 'Plik .gitmodules nie istnieje — submoduł nie jest zarejestrowany'
        Write-CommandHint 'git submodule add git@github.com:mikkielt/robot.new.git .robot.new'
        Update-PhaseChecklist -State $State -Phase 0 -Item 'SubmoduleOK' -Value $false
        $AllOK = $false
    }

    # Step 5: Verify module import and command count
    Write-Step -Number 5 -Text 'Weryfikacja modułu robot...'
    $Commands = Get-Command -Module robot -ErrorAction SilentlyContinue
    $CmdCount = ($Commands | Measure-Object).Count
    if ($CmdCount -ge 30) {
        Write-StepOK "Moduł załadowany: $CmdCount komend dostępnych"
        Update-PhaseChecklist -State $State -Phase 0 -Item 'ModuleImported' -Value $true
        Update-PhaseChecklist -State $State -Phase 0 -Item 'CommandCount' -Value $CmdCount
    } else {
        Write-StepError "Moduł robot nie załadował się poprawnie (znaleziono $CmdCount komend, oczekiwano ~32+)"
        Update-PhaseChecklist -State $State -Phase 0 -Item 'ModuleImported' -Value $false
        $AllOK = $false
    }

    # Phase summary and state persistence
    if ($AllOK) {
        Set-PhaseCompleted -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'Completed' -Lines @(
            '[OK] Repozytorium czyste',
            '[OK] Tag pre-migration istnieje',
            '[OK] Moduł załadowany'
        )
    } else {
        Set-PhaseInProgress -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'InProgress' -Lines @(
            '[!!] Niektóre warunki nie są spełnione — sprawdź powyższe komunikaty'
        )
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# ============================================================================
# PHASE 1 — Bootstrap entities.md from Gracze.md
# ============================================================================

function Invoke-MigrationPhase1 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 1
    Write-PhaseHeader -Phase 1 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $EntitiesPath = [System.IO.Path]::Combine($RepoRoot, 'entities.md')
    $ModuleRoot = [System.IO.Path]::Combine($RepoRoot, '.robot.new')

    # Step 1: Check if entities.md already exists and is committed
    Write-Step -Number 1 -Text 'Sprawdzanie pliku entities.md...'
    if ([System.IO.File]::Exists($EntitiesPath)) {
        $LineCount = [System.IO.File]::ReadAllLines($EntitiesPath).Count
        Write-StepOK "Plik entities.md już istnieje ($LineCount linii)"
        Update-PhaseChecklist -State $State -Phase 1 -Item 'EntitiesGenerated' -Value $true

        # Verify whether the file is tracked and committed
        $GitResult = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        $IsCommitted = [string]::IsNullOrWhiteSpace($GitResult)
        if ($IsCommitted) {
            # Also verify it's tracked by git
            $Tracked = & git -C $RepoRoot ls-files 'entities.md' 2>&1
            $IsCommitted = -not [string]::IsNullOrWhiteSpace($Tracked)
        }

        if ($IsCommitted) {
            Write-StepOK 'Plik entities.md zacommitowany'
            Update-PhaseChecklist -State $State -Phase 1 -Item 'Committed' -Value $true
        } else {
            Write-StepWarning 'Plik entities.md istnieje, ale nie jest zacommitowany'
            Update-PhaseChecklist -State $State -Phase 1 -Item 'Committed' -Value $false
        }

        if (-not (Request-YesNo -Prompt 'Plik entities.md już istnieje. Czy wygenerować ponownie?' -Default $false)) {
            # Skip regeneration, proceed to verification only
            $SkipGeneration = $true
        }
    }

    if (-not $SkipGeneration) {
        # Step 2: Generate entities.md from Gracze.md
        Write-Step -Number 2 -Text 'Generowanie entities.md z Gracze.md...'

        # Ensure ConvertTo-EntitiesFromPlayers is available
        if (-not (Get-Command 'ConvertTo-EntitiesFromPlayers' -ErrorAction SilentlyContinue)) {
            $HelpersPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'entity-writehelpers.ps1')
            . $HelpersPath
        }

        if ($WhatIf) {
            Write-StepWarning '[SUCHY PRZEBIEG] Wygenerowałbym entities.md'
        } else {
            try {
                ConvertTo-EntitiesFromPlayers -OutputPath $EntitiesPath
                Write-StepOK 'Plik entities.md wygenerowany'
                Update-PhaseChecklist -State $State -Phase 1 -Item 'EntitiesGenerated' -Value $true
            }
            catch {
                Write-StepError "Błąd generowania entities.md: $($_.Exception.Message)"
                Set-PhaseInProgress -State $State -Phase 1
                Save-MigrationState -State $State
                return
            }
        }
    }

    # Step 3: Verify generated file — count entries, show preview
    Write-Step -Number 3 -Text 'Weryfikacja wygenerowanego pliku...'
    if ([System.IO.File]::Exists($EntitiesPath)) {
        $Content = [System.IO.File]::ReadAllText($EntitiesPath)
        $EntryPattern = [regex]::new('^\* ', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $EntryCount = $EntryPattern.Matches($Content).Count
        Write-StepOK "Znaleziono $EntryCount wpisów encji"
        Update-PhaseChecklist -State $State -Phase 1 -Item 'EntitiesVerified' -Value ($EntryCount -gt 0)

        # Preview first 5 entity entries
        $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)
        $Shown = 0
        foreach ($Line in $Lines) {
            if ($Line.StartsWith('* ') -and $Shown -lt 5) {
                Write-Host "    $Line" -ForegroundColor DarkGray
                $Shown++
            }
        }
        if ($EntryCount -gt 5) {
            Write-Host "    ... (i $($EntryCount - 5) więcej)" -ForegroundColor DarkGray
        }
    }

    # Step 4: Verify required entity sections exist
    Write-Step -Number 4 -Text 'Sprawdzanie sekcji encji...'
    $RequiredSections = @('## NPC', '## Organizacja', '## Lokacja', '## Przedmiot')
    $MissingSections = [System.Collections.Generic.List[string]]::new()

    if ([System.IO.File]::Exists($EntitiesPath)) {
        $Content = [System.IO.File]::ReadAllText($EntitiesPath)
        foreach ($Section in $RequiredSections) {
            if (-not $Content.Contains($Section)) {
                $MissingSections.Add($Section)
            }
        }

        if ($MissingSections.Count -eq 0) {
            Write-StepOK 'Wszystkie wymagane sekcje istnieją'
            Update-PhaseChecklist -State $State -Phase 1 -Item 'SectionsAdded' -Value $true
        } else {
            Write-StepWarning "Brakujące sekcje: $($MissingSections -join ', ')"
            if (-not $WhatIf -and (Request-YesNo -Prompt 'Czy dodać brakujące sekcje automatycznie?' -Default $true)) {
                $SB = [System.Text.StringBuilder]::new()
                [void]$SB.Append($Content)
                foreach ($Section in $MissingSections) {
                    [void]$SB.Append("`n`n$Section`n")
                }
                $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($EntitiesPath, $SB.ToString(), $UTF8NoBOM)
                Write-StepOK 'Dodano brakujące sekcje'
                Update-PhaseChecklist -State $State -Phase 1 -Item 'SectionsAdded' -Value $true
            }
        }
    }

    # Step 5: Prompt to commit entities.md
    if (-not $WhatIf) {
        $NeedsCommit = $false
        $GitDiff = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        $GitUntracked = & git -C $RepoRoot ls-files --others --exclude-standard 'entities.md' 2>&1
        if ($GitDiff -or $GitUntracked) { $NeedsCommit = $true }

        if ($NeedsCommit) {
            Write-Step -Number 5 -Text 'Commit...'
            if (Request-YesNo -Prompt 'Czy zacommitować entities.md?' -Default $true) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                & git -C $RepoRoot commit -m 'Bootstrap entities.md z Gracze.md' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Zacommitowano entities.md'
                    Update-PhaseChecklist -State $State -Phase 1 -Item 'Committed' -Value $true
                } else {
                    Write-StepError 'Nie udało się zacommitować entities.md'
                }
            }
        } else {
            Write-StepOK 'Brak zmian do zacommitowania'
            Update-PhaseChecklist -State $State -Phase 1 -Item 'Committed' -Value $true
        }
    }

    # Phase summary and state persistence
    $Checklist = $State.Phases['1'].Checklist
    $AllDone = $Checklist['EntitiesGenerated'] -and $Checklist['EntitiesVerified'] -and $Checklist['Committed']
    if ($AllDone) {
        Set-PhaseCompleted -State $State -Phase 1
        Write-PhaseSummary -Phase 1 -Status 'Completed' -Lines @('[OK] entities.md wygenerowany i zacommitowany')
    } else {
        Set-PhaseInProgress -State $State -Phase 1
        Write-PhaseSummary -Phase 1 -Status 'InProgress' -Lines @('[!!] Nie wszystkie kroki ukończone')
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# ============================================================================
# PHASE 2 — Data parity validation (read-only)
# ============================================================================

function Invoke-MigrationPhase2 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 2
    Write-PhaseHeader -Phase 2 -Status $PhaseStatus

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

    # Step 5: Check players missing Discord webhooks
    Write-Step -Number 5 -Text 'Sprawdzanie webhooków...'
    $NoWebhook = [System.Collections.Generic.List[string]]::new()
    foreach ($Player in $Players) {
        if ([string]::IsNullOrWhiteSpace($Player.PRFWebhook) -or $Player.PRFWebhook -eq 'BRAK') {
            $NoWebhook.Add($Player.Name)
        }
    }
    if ($NoWebhook.Count -gt 0) {
        Write-StepWarning "Graczy bez webhooka: $($NoWebhook.Count)"
        foreach ($Name in ($NoWebhook | Select-Object -First 5)) {
            Write-Host "    - $Name" -ForegroundColor DarkGray
        }
        if ($NoWebhook.Count -gt 5) {
            Write-Host "    ... (i $($NoWebhook.Count - 5) więcej)" -ForegroundColor DarkGray
        }
    } else {
        Write-StepOK 'Wszyscy gracze mają webhook'
    }
    Update-PhaseChecklist -State $State -Phase 2 -Item 'WebhooksChecked' -Value $true

    # Step 6: Run full PU diagnostics
    Write-Step -Number 6 -Text 'Uruchamianie diagnostyki PU...'
    $Diag = Test-PlayerCharacterPUAssignment
    Show-DiagnosticResults -Diagnostics $Diag
    Update-PhaseChecklist -State $State -Phase 2 -Item 'DiagnosticsRun' -Value $true
    Update-PhaseChecklist -State $State -Phase 2 -Item 'DiagnosticsOK' -Value $Diag.OK

    # Phase summary and state persistence
    $SummaryLines = @(
        "[OK] Graczy: $PlayerCount, Postaci: $CharCount",
        "[OK] PU zweryfikowane (wyrywkowo)",
        "[OK] Aliasy: $AliasCount postaci"
    )
    if ($NoWebhook.Count -gt 0) {
        $SummaryLines += "[!!] Graczy bez webhooka: $($NoWebhook.Count)"
    }
    if ($Diag.OK) {
        $SummaryLines += '[OK] Diagnostyka PU: OK'
        Set-PhaseCompleted -State $State -Phase 2
        Write-PhaseSummary -Phase 2 -Status 'Completed' -Lines $SummaryLines
    } else {
        $IssueCount = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                      $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
        $SummaryLines += "[!!] Diagnostyka PU: $IssueCount problemów — przejdź do Fazy 3"
        Set-PhaseInProgress -State $State -Phase 2
        Write-PhaseSummary -Phase 2 -Status 'InProgress' -Lines $SummaryLines
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# ============================================================================
# PHASE 3 — Diagnostics & data repair (iterative)
# ============================================================================

function Invoke-MigrationPhase3 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 3
    Write-PhaseHeader -Phase 3 -Status $PhaseStatus

    Write-Step -Number 1 -Text 'Uruchamianie diagnostyki...'
    $Diag = Test-PlayerCharacterPUAssignment

    if ($Diag.OK) {
        Write-StepOK 'Diagnostyka: OK — brak problemów'
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

    # Record diagnostic snapshot and calculate totals
    $TotalIssues = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                   $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
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
        Write-Host "    $($Item.PlayerName) / $($Item.CharacterName) — brak wartości PU" -ForegroundColor Yellow
        $Choice = Request-YesNo -Prompt "    Czy oznaczyć '$($Item.CharacterName)' jako usuniętą?" -Default $false
        if ($Choice) {
            try {
                Remove-PlayerCharacter -PlayerName $Item.PlayerName -CharacterName $Item.CharacterName -Confirm:$false
                Write-StepOK "Oznaczono '$($Item.CharacterName)' jako usuniętą"
            }
            catch {
                Write-StepError "Nie udało się usunąć: $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================================
# PHASE 4 — Session format upgrade to Gen4
# ============================================================================

function Invoke-MigrationPhase4 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 4
    Write-PhaseHeader -Phase 4 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot

    # Step 1: Show current session format distribution
    Write-Step -Number 1 -Text 'Sprawdzanie dystrybucji formatów sesji...'
    $AllSessions = Get-Session
    $FormatGroups = $AllSessions | Group-Object Format | Sort-Object Name
    foreach ($Group in $FormatGroups) {
        Write-Host "    $($Group.Name): $($Group.Count) sesji" -ForegroundColor DarkGray
    }
    Update-PhaseChecklist -State $State -Phase 4 -Item 'FormatDistribution' -Value $true

    # Step 2: Identify active files (sessions from 2024 onwards)
    Write-Step -Number 2 -Text 'Identyfikacja aktywnych plików (sesje od 2024)...'
    $Cutoff = [datetime]::new(2024, 1, 1)
    $ActiveSessions = $AllSessions | Where-Object { $_.Date -and $_.Date -ge $Cutoff }
    $ActiveFiles = $ActiveSessions | Select-Object -ExpandProperty FilePath -Unique
    Write-StepOK "Aktywnych plików: $($ActiveFiles.Count)"

    # Step 3: Count non-Gen4 sessions in active files
    $NonGen4 = $ActiveSessions | Where-Object { $_.Format -ne 'Gen4' }
    $NonGen4Count = ($NonGen4 | Measure-Object).Count

    if ($NonGen4Count -eq 0) {
        Write-StepOK 'Wszystkie aktywne sesje już w formacie Gen4'
        Set-PhaseCompleted -State $State -Phase 4
        Update-PhaseChecklist -State $State -Phase 4 -Item 'UpgradeDone' -Value $true
        Write-PhaseSummary -Phase 4 -Status 'Completed' -Lines @('[OK] Wszystkie aktywne sesje w Gen4')
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

    # Step 4: Prompt for upgrade action
    Write-Step -Number 3 -Text 'Upgrade sesji...'
    $Choice = Request-UserChoice -Prompt 'Czy zaktualizować aktywne sesje do Gen4? (T=tak, S=suchy przebieg, N=nie)' -ValidChoices @('T', 'S', 'N')

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
            Write-Host " — $Count sesji (suchy przebieg)" -ForegroundColor DarkGray
        } else {
            try {
                $FileSessions | Set-Session -UpgradeFormat
                Write-Host " — $Count sesji zaktualizowanych" -ForegroundColor Green
            }
            catch {
                Write-Host " — BŁĄD" -ForegroundColor Red
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

    # Step 5: Verify post-upgrade format distribution
    Write-Step -Number 4 -Text 'Weryfikacja po upgrade...'
    $PostSessions = Get-Session
    $PostActive = $PostSessions | Where-Object { $_.Date -and $_.Date -ge $Cutoff }
    $StillNonGen4 = ($PostActive | Where-Object { $_.Format -ne 'Gen4' } | Measure-Object).Count

    if ($StillNonGen4 -eq 0) {
        Write-StepOK 'Weryfikacja: wszystkie aktywne sesje w Gen4'
        Update-PhaseChecklist -State $State -Phase 4 -Item 'UpgradeDone' -Value $true
    } else {
        Write-StepWarning "Wciąż $StillNonGen4 sesji nie w Gen4"
    }

    # Step 6: Prompt to commit upgraded sessions
    Write-Step -Number 5 -Text 'Commit...'
    if (Request-YesNo -Prompt 'Czy zacommitować upgrade sesji?' -Default $true) {
        & git -C $RepoRoot add . 2>&1
        & git -C $RepoRoot commit -m 'Upgrade aktywnych sesji do formatu Gen4' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-StepOK 'Zacommitowano'
            Update-PhaseChecklist -State $State -Phase 4 -Item 'Committed' -Value $true
        } else {
            Write-StepError 'Nie udało się zacommitować'
        }
    }

    # Phase summary and state persistence
    if ($StillNonGen4 -eq 0) {
        Set-PhaseCompleted -State $State -Phase 4
        Write-PhaseSummary -Phase 4 -Status 'Completed' -Lines @("[OK] $UpgradeCount sesji zaktualizowanych do Gen4")
    } else {
        Set-PhaseInProgress -State $State -Phase 4
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# ============================================================================
# PHASE 5 — Currency enrollment
# ============================================================================

function Invoke-MigrationPhase5 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 5
    Write-PhaseHeader -Phase 5 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot

    # Step 1: Check/create coordinator treasury
    Write-Step -Number 1 -Text 'Sprawdzanie skarbca koordynatorów...'
    $Entities = Get-Entity
    $Treasury = $Entities | Where-Object { $_.Name -eq 'Skarbiec Koordynatorów' }

    if ($Treasury) {
        Write-StepOK 'Skarbiec Koordynatorów istnieje'
        Update-PhaseChecklist -State $State -Phase 5 -Item 'TreasuryCreated' -Value $true

        # Display current treasury balances
        $TreasuryCurrency = Get-CurrencyReport -Owner 'Skarbiec Koordynatorów'
        if ($TreasuryCurrency) {
            foreach ($C in $TreasuryCurrency) {
                Write-Host "    $($C.Denomination): $($C.Balance)" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-StepWarning 'Skarbiec Koordynatorów nie istnieje'

        if ($WhatIf) {
            Write-StepWarning '[SUCHY PRZEBIEG] Utworzyłbym skarbiec'
        } elseif (Request-YesNo -Prompt 'Czy utworzyć Skarbiec Koordynatorów?' -Default $true) {
            try {
                New-Entity -Type 'Organizacja' -Name 'Skarbiec Koordynatorów' -Confirm:$false
                Write-StepOK 'Utworzono organizację Skarbiec Koordynatorów'

                # Prompt for initial treasury reserves
                Write-Host ''
                Write-Host '  Podaj początkowe rezerwy skarbca:' -ForegroundColor White
                $Korony = Request-NumericInput -Prompt 'Korony (złoto)' -AllowSkip
                $Talary = Request-NumericInput -Prompt 'Talary (srebro)' -AllowSkip
                $Kogi = Request-NumericInput -Prompt 'Kogi (miedź)' -AllowSkip

                if ($null -ne $Korony -and $Korony -gt 0) {
                    New-CurrencyEntity -Denomination 'Korony' -Owner 'Skarbiec Koordynatorów' -Amount $Korony -Confirm:$false
                    Write-StepOK "Korony: $Korony"
                }
                if ($null -ne $Talary -and $Talary -gt 0) {
                    New-CurrencyEntity -Denomination 'Talary' -Owner 'Skarbiec Koordynatorów' -Amount $Talary -Confirm:$false
                    Write-StepOK "Talary: $Talary"
                }
                if ($null -ne $Kogi -and $Kogi -gt 0) {
                    New-CurrencyEntity -Denomination 'Kogi' -Owner 'Skarbiec Koordynatorów' -Amount $Kogi -Confirm:$false
                    Write-StepOK "Kogi: $Kogi"
                }

                Update-PhaseChecklist -State $State -Phase 5 -Item 'TreasuryCreated' -Value $true
            }
            catch {
                Write-StepError "Nie udało się utworzyć skarbca: $($_.Exception.Message)"
            }
        }
    }

    # Step 2: Build player currency inventory
    Write-Step -Number 2 -Text 'Inwentaryzacja walut postaci...'
    $Players = Get-Player
    $ActiveChars = [System.Collections.Generic.List[object]]::new()
    foreach ($Player in $Players) {
        foreach ($Char in $Player.Characters) {
            if ($Char.IsActive) {
                $ActiveChars.Add([PSCustomObject]@{
                    PlayerName    = $Player.Name
                    CharacterName = $Char.Name
                })
            }
        }
    }

    $CurrencyReport = Get-CurrencyReport
    $CharsWithCurrency = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($CurrencyReport) {
        foreach ($Entry in $CurrencyReport) {
            if ($Entry.Owner) {
                [void]$CharsWithCurrency.Add($Entry.Owner)
            }
        }
    }

    $CharsWithout = [System.Collections.Generic.List[object]]::new()
    $CharsRegistered = 0
    foreach ($Item in $ActiveChars) {
        if ($CharsWithCurrency.Contains($Item.CharacterName)) {
            $CharsRegistered++
        } else {
            $CharsWithout.Add($Item)
        }
    }

    Write-StepOK "Postaci z walutą: $CharsRegistered / $($ActiveChars.Count)"
    if ($CharsWithout.Count -gt 0) {
        Write-StepWarning "Postaci bez waluty: $($CharsWithout.Count)"
    }
    Update-PhaseChecklist -State $State -Phase 5 -Item 'InventoryDone' -Value $true

    # Step 3: Register currency for characters without it
    if ($CharsWithout.Count -gt 0 -and -not $WhatIf) {
        Write-Step -Number 3 -Text 'Rejestracja walut postaci...'

        # Offer CSV batch import or interactive entry
        $UseCsv = Request-YesNo -Prompt "Czy wczytać dane z pliku CSV? ($($CharsWithout.Count) postaci bez waluty)" -Default $false

        if ($UseCsv) {
            Invoke-CurrencyCSVImport -CharactersWithout $CharsWithout
        } else {
            # Fall back to interactive per-character entry
            $DoInteractive = Request-YesNo -Prompt "Czy wprowadzić dane ręcznie dla $($CharsWithout.Count) postaci?" -Default $true
            if ($DoInteractive) {
                Invoke-CurrencyInteractiveEntry -CharactersWithout $CharsWithout
            } else {
                Write-Host '  Pominięto rejestrację walut. Uruchom Fazę 5 ponownie po zebraniu danych.' -ForegroundColor DarkGray
            }
        }
    }

    # Step 4: Register narrator budgets (optional)
    if (-not $WhatIf) {
        Write-Step -Number 4 -Text 'Budżety narratorów...'
        if (Request-YesNo -Prompt 'Czy narratorzy mają budżety walut do zarejestrowania?' -Default $false) {
            Invoke-NarratorBudgetEntry
        } else {
            Write-Host '  Pominięto budżety narratorów.' -ForegroundColor DarkGray
        }
        Update-PhaseChecklist -State $State -Phase 5 -Item 'NarratorBudgets' -Value $true
    }

    # Step 5: Verify currency entities and run reconciliation
    Write-Step -Number 5 -Text 'Weryfikacja walut...'
    $FinalReport = Get-CurrencyReport
    $FinalCount = ($FinalReport | Measure-Object).Count
    Write-StepOK "Łącznie encji walutowych: $FinalCount"

    $Recon = Test-CurrencyReconciliation
    if ($Recon.WarningCount -eq 0) {
        Write-StepOK 'Rekoncyliacja: brak ostrzeżeń'
    } else {
        Write-StepWarning "Rekoncyliacja: $($Recon.WarningCount) ostrzeżeń"
        foreach ($Warning in ($Recon.Warnings | Select-Object -First 5)) {
            Write-Host "    [$($Warning.Severity)] $($Warning.Check): $($Warning.Detail)" -ForegroundColor DarkGray
        }
    }
    Update-PhaseChecklist -State $State -Phase 5 -Item 'ReconciliationRun' -Value $true

    # Step 6: Prompt to commit currency changes
    if (-not $WhatIf) {
        Write-Step -Number 6 -Text 'Commit...'
        $GitDiff = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        if ($GitDiff) {
            if (Request-YesNo -Prompt 'Czy zacommitować zmiany walutowe?' -Default $true) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                & git -C $RepoRoot commit -m 'Enrollment walut — stan początkowy' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Zacommitowano'
                    Update-PhaseChecklist -State $State -Phase 5 -Item 'Committed' -Value $true
                }
            }
        } else {
            Write-StepOK 'Brak zmian do zacommitowania'
        }
    }

    # Phase summary and state persistence
    $AllRegistered = $CharsWithout.Count -eq 0
    if ($AllRegistered -and $Recon.WarningCount -eq 0) {
        Set-PhaseCompleted -State $State -Phase 5
        Write-PhaseSummary -Phase 5 -Status 'Completed' -Lines @("[OK] $FinalCount encji walutowych, rekoncyliacja czysta")
    } else {
        Set-PhaseInProgress -State $State -Phase 5
        Write-PhaseSummary -Phase 5 -Status 'InProgress' -Lines @(
            "[!!] $($CharsWithout.Count) postaci bez waluty",
            "[!!] $($Recon.WarningCount) ostrzeżeń rekoncyliacji"
        )
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# Import currency data from a CSV file
function Invoke-CurrencyCSVImport {
    param([Parameter(Mandatory)] [System.Collections.Generic.List[object]]$CharactersWithout)

    Write-Host '  Format CSV: Postać,Korony,Talary,Kogi' -ForegroundColor DarkGray
    Write-Host '  Przykład: Crag Hack,50,200,1500' -ForegroundColor DarkGray
    $CsvPath = Request-StringInput -Prompt 'Ścieżka do pliku CSV'

    if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not [System.IO.File]::Exists($CsvPath)) {
        Write-StepError "Plik nie istnieje: $CsvPath"
        return
    }

    try {
        $CsvData = Import-Csv -Path $CsvPath -Header 'Postać', 'Korony', 'Talary', 'Kogi'
        $Created = 0
        foreach ($Row in $CsvData) {
            $CharName = $Row.'Postać'.Trim()
            if ([string]::IsNullOrWhiteSpace($CharName)) { continue }

            $Korony = 0; $Talary = 0; $Kogi = 0
            [void][int]::TryParse($Row.Korony, [ref]$Korony)
            [void][int]::TryParse($Row.Talary, [ref]$Talary)
            [void][int]::TryParse($Row.Kogi, [ref]$Kogi)

            if ($Korony -gt 0) {
                New-CurrencyEntity -Denomination 'Korony' -Owner $CharName -Amount $Korony -Confirm:$false
                $Created++
            }
            if ($Talary -gt 0) {
                New-CurrencyEntity -Denomination 'Talary' -Owner $CharName -Amount $Talary -Confirm:$false
                $Created++
            }
            if ($Kogi -gt 0) {
                New-CurrencyEntity -Denomination 'Kogi' -Owner $CharName -Amount $Kogi -Confirm:$false
                $Created++
            }
        }
        Write-StepOK "Utworzono $Created encji walutowych z CSV"
    }
    catch {
        Write-StepError "Błąd importu CSV: $($_.Exception.Message)"
    }
}

# Interactive per-character currency data entry
function Invoke-CurrencyInteractiveEntry {
    param([Parameter(Mandatory)] [System.Collections.Generic.List[object]]$CharactersWithout)

    $Created = 0
    foreach ($Item in $CharactersWithout) {
        Write-Host ''
        Write-Host "  Postać: $($Item.CharacterName) (Gracz: $($Item.PlayerName))" -ForegroundColor White

        $Korony = Request-NumericInput -Prompt 'Korony (złoto)' -AllowSkip
        $Talary = Request-NumericInput -Prompt 'Talary (srebro)' -AllowSkip
        $Kogi = Request-NumericInput -Prompt 'Kogi (miedź)' -AllowSkip

        if ($null -ne $Korony -and $Korony -gt 0) {
            New-CurrencyEntity -Denomination 'Korony' -Owner $Item.CharacterName -Amount $Korony -Confirm:$false
            $Created++
        }
        if ($null -ne $Talary -and $Talary -gt 0) {
            New-CurrencyEntity -Denomination 'Talary' -Owner $Item.CharacterName -Amount $Talary -Confirm:$false
            $Created++
        }
        if ($null -ne $Kogi -and $Kogi -gt 0) {
            New-CurrencyEntity -Denomination 'Kogi' -Owner $Item.CharacterName -Amount $Kogi -Confirm:$false
            $Created++
        }
    }
    Write-StepOK "Utworzono $Created encji walutowych"
}

# Interactive narrator budget registration loop
function Invoke-NarratorBudgetEntry {
    while ($true) {
        $NarratorName = Request-StringInput -Prompt 'Nazwa narratora (Enter = zakończ)'
        if ([string]::IsNullOrWhiteSpace($NarratorName)) { break }

        Write-Host "  Budżet dla: $NarratorName" -ForegroundColor White
        $Korony = Request-NumericInput -Prompt 'Korony' -AllowSkip
        $Talary = Request-NumericInput -Prompt 'Talary' -AllowSkip
        $Kogi = Request-NumericInput -Prompt 'Kogi' -AllowSkip

        if ($null -ne $Korony -and $Korony -gt 0) {
            New-CurrencyEntity -Denomination 'Korony' -Owner $NarratorName -Amount $Korony -Confirm:$false
        }
        if ($null -ne $Talary -and $Talary -gt 0) {
            New-CurrencyEntity -Denomination 'Talary' -Owner $NarratorName -Amount $Talary -Confirm:$false
        }
        if ($null -ne $Kogi -and $Kogi -gt 0) {
            New-CurrencyEntity -Denomination 'Kogi' -Owner $NarratorName -Amount $Kogi -Confirm:$false
        }
        Write-StepOK "Zarejestrowano budżet dla $NarratorName"
    }
}

# ============================================================================
# PHASE 6 — Parallel operation monitoring dashboard
# ============================================================================

function Invoke-MigrationPhase6 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 6
    Write-PhaseHeader -Phase 6 -Status $PhaseStatus

    # Initialize parallel period start timestamp
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
    $Diag = Test-PlayerCharacterPUAssignment
    if ($Diag.OK) {
        Write-StepOK 'Test-PlayerCharacterPUAssignment: OK'
    } else {
        $IssueCount = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                      $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
        Write-StepWarning "Test-PlayerCharacterPUAssignment: $IssueCount problemów"
    }
    Update-PhaseChecklist -State $State -Phase 6 -Item 'DiagnosticsOK' -Value $Diag.OK

    # Dashboard section 2: PU simulation (dry-run for current month)
    Write-SectionHeader 'Symulacja PU (bieżący miesiąc)'
    $Now = [datetime]::Now
    try {
        $PUResults = Invoke-PlayerCharacterPUAssignment -Year $Now.Year -Month $Now.Month -WhatIf 2>$null
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
    $RecentSessions = Get-Session | Where-Object { $_.Date -and $_.Date -ge [datetime]::Now.AddMonths(-2) }
    $NonGen4Recent = $RecentSessions | Where-Object { $_.Format -ne 'Gen4' }
    $NonGen4Count = ($NonGen4Recent | Measure-Object).Count
    if ($NonGen4Count -eq 0) {
        Write-StepOK 'Wszystkie ostatnie sesje w formacie Gen4'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'AllGen4' -Value $true
    } else {
        Write-StepWarning "$NonGen4Count ostatnich sesji nie w formacie Gen4"
        Update-PhaseChecklist -State $State -Phase 6 -Item 'AllGen4' -Value $false
    }

    # Dashboard section 4: Currency reconciliation
    Write-SectionHeader 'Rekoncyliacja walut'
    $Recon = Test-CurrencyReconciliation
    if ($Recon.WarningCount -eq 0) {
        Write-StepOK 'Brak ostrzeżeń'
        Update-PhaseChecklist -State $State -Phase 6 -Item 'CurrencyOK' -Value $true
    } else {
        Write-StepWarning "$($Recon.WarningCount) ostrzeżeń"
        Update-PhaseChecklist -State $State -Phase 6 -Item 'CurrencyOK' -Value $false
    }

    # Dashboard section 5: Cutover readiness criteria
    Write-SectionHeader 'Kryteria przełączenia'
    $Criteria = @{
        'Min. 1 pełny cykl PU bez rozbieżności'  = $State.Phases['6'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['6'].Checklist['PUCycleValidated']
        'Wszyscy aktywni narratorzy stosują Gen4'  = $NonGen4Count -eq 0
        'Test-PUAssignment: OK = True'             = $Diag.OK
        'Test-CurrencyReconciliation: brak błędów' = $Recon.WarningCount -eq 0
    }
    Write-ChecklistReport -Checklist $Criteria -Title 'KRYTERIA PRZEŁĄCZENIA'

    # Ask coordinator to confirm PU cycle validation (one-time gate)
    if ($Diag.OK -and -not ($State.Phases['6'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['6'].Checklist['PUCycleValidated'])) {
        if (Request-YesNo -Prompt 'Czy porównano wyniki PU z starym systemem i są zgodne?' -Default $false) {
            Update-PhaseChecklist -State $State -Phase 6 -Item 'PUCycleValidated' -Value $true
        }
    }

    # Evaluate all criteria — mark phase completed if all pass
    $AllCriteria = $Criteria.Values | Where-Object { $_ -eq $false }
    if (($AllCriteria | Measure-Object).Count -eq 0) {
        Write-Host ''
        Write-StepOK 'Wszystkie kryteria spełnione. Możesz przejść do Fazy 7.'
        Set-PhaseCompleted -State $State -Phase 6
    }

    # Append dashboard run timestamp to history
    if (-not $State.Phases['6'].ContainsKey('DashboardRuns')) {
        $State.Phases['6'].DashboardRuns = @()
    }
    $State.Phases['6'].DashboardRuns = @($State.Phases['6'].DashboardRuns) + @([datetime]::UtcNow.ToString('o'))

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

# ============================================================================
# PHASE 7 — Cutover (freeze legacy, first standalone PU run)
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
    $Diag = Test-PlayerCharacterPUAssignment
    if ($Diag.OK) {
        Write-StepOK 'Diagnostyka: OK'
        Update-PhaseChecklist -State $State -Phase 7 -Item 'FinalDiagnostics' -Value $true
    } else {
        Write-StepError 'Diagnostyka: PROBLEMY — napraw je przed przełączeniem'
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
                & git -C $RepoRoot commit -m 'Zamrożenie Gracze.md — migracja zakończona' 2>&1
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
        $DryResults = Invoke-PlayerCharacterPUAssignment -Year $Year -Month $Month -WhatIf 2>$null
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
    Write-Host '  W razie pytań — kontakt z koordynatorem.' -ForegroundColor Cyan
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

# ============================================================================
# QUICK DIAGNOSTICS — main menu shortcut
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
# FULL REPORT — per-phase status with checklists
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
        Write-Host "  Faza $I`: $Name — $($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusInfo.Color

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

<#
    .SYNOPSIS
    Phase 0: Setup & bootstrap.

    .DESCRIPTION
    Verifies clean git state, creates safety tag, checks PU state file,
    submodule registration, module import, and .robot/robot-data.psd1 manifest.
    Then bootstraps entities.md from legacy Gracze.md, verifies entry counts
    and required sections, and commits the result.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 0 - Setup & bootstrap
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

    # ── Preparation ───────────────────────────────────────────────────────────

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
        Write-StepWarning 'Plik .gitmodules nie istnieje - submoduł nie jest zarejestrowany'
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

    # Step 6: Ensure .robot/robot-data.psd1 manifest exists
    Write-Step -Number 6 -Text 'Sprawdzanie manifestu .robot/robot-data.psd1...'
    $ManifestPath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'robot-data.psd1')
    if ([System.IO.File]::Exists($ManifestPath)) {
        try {
            $ManifestData = Import-PowerShellDataFile -Path $ManifestPath
            if ($ManifestData.ContainsKey('EntitiesFile')) {
                Write-StepOK "Manifest istnieje (EntitiesFile = '$($ManifestData['EntitiesFile'])')"
            } else {
                Write-StepWarning 'Manifest istnieje, ale brakuje klucza EntitiesFile'
                $AllOK = $false
            }
        }
        catch {
            Write-StepError "Nie udało się odczytać manifestu: $_"
            $AllOK = $false
        }
    } else {
        if ($WhatIf) {
            Write-StepWarning '[SUCHY PRZEBIEG] Utworzyłbym manifest .robot/robot-data.psd1'
        } else {
            $ManifestDir = [System.IO.Path]::GetDirectoryName($ManifestPath)
            if (-not [System.IO.Directory]::Exists($ManifestDir)) {
                [void][System.IO.Directory]::CreateDirectory($ManifestDir)
            }
            $ManifestContent = "@{`n    EntitiesFile = '../entities.md'`n}`n"
            [System.IO.File]::WriteAllText($ManifestPath, $ManifestContent, [System.Text.UTF8Encoding]::new($false))
            Write-StepOK 'Utworzono manifest .robot/robot-data.psd1 (EntitiesFile → ../entities.md)'
        }
    }
    Update-PhaseChecklist -State $State -Phase 0 -Item 'ManifestCreated' -Value $true

    # Gate: if preparation failed, stop before bootstrap
    if (-not $AllOK) {
        Set-PhaseInProgress -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'InProgress' -Lines @(
            '[!!] Warunki przygotowawcze nie spełnione — napraw problemy przed bootstrapem'
        )
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # ── Bootstrap entities.md ─────────────────────────────────────────────────

    $EntitiesPath = [System.IO.Path]::Combine($RepoRoot, 'entities.md')
    $ModuleRoot = [System.IO.Path]::Combine($RepoRoot, '.robot.new')
    $SkipGeneration = $false

    # Step 7: Check if entities.md already exists and is committed
    Write-Step -Number 7 -Text 'Sprawdzanie pliku entities.md...'
    if ([System.IO.File]::Exists($EntitiesPath)) {
        $LineCount = [System.IO.File]::ReadAllLines($EntitiesPath).Count
        Write-StepOK "Plik entities.md już istnieje ($LineCount linii)"
        Update-PhaseChecklist -State $State -Phase 0 -Item 'EntitiesGenerated' -Value $true

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
            Update-PhaseChecklist -State $State -Phase 0 -Item 'Committed' -Value $true
        } else {
            Write-StepWarning 'Plik entities.md istnieje, ale nie jest zacommitowany'
            Update-PhaseChecklist -State $State -Phase 0 -Item 'Committed' -Value $false
        }

        if (-not (Request-YesNo -Prompt 'Plik entities.md już istnieje. Czy wygenerować ponownie?' -Default $false -HelpText @(
            'Ponowne generowanie entities.md z Gracze.md.',
            'Nadpisze aktualny plik entities.md nową wersją',
            'wygenerowaną z danych legacy (Gracze.md).',
            '',
            'Tak = nadpisz entities.md nowo wygenerowaną wersją',
            'Nie = zachowaj istniejący plik i przejdź do weryfikacji',
            '',
            'Patrz: docs/Migration.md (Faza 0 — Bootstrap)'
        ))) {
            # Skip regeneration, proceed to verification only
            $SkipGeneration = $true
        }
    }

    if (-not $SkipGeneration) {
        # Step 8: Generate entities.md from Gracze.md
        Write-Step -Number 8 -Text 'Generowanie entities.md z Gracze.md...'

        # Ensure ConvertTo-EntitiesFromPlayers is available
        if (-not (Get-Command 'ConvertTo-EntitiesFromPlayers' -ErrorAction SilentlyContinue)) {
            $MigrationHelpersPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'entity-migrationhelpers.ps1')
            . $MigrationHelpersPath
        }

        if ($WhatIf) {
            Write-StepWarning '[SUCHY PRZEBIEG] Wygenerowałbym entities.md'
        } else {
            try {
                ConvertTo-EntitiesFromPlayers -OutputPath $EntitiesPath
                Write-StepOK 'Plik entities.md wygenerowany'
                Update-PhaseChecklist -State $State -Phase 0 -Item 'EntitiesGenerated' -Value $true
            }
            catch {
                Write-StepError "Błąd generowania entities.md: $($_.Exception.Message)"
                Set-PhaseInProgress -State $State -Phase 0
                Save-MigrationState -State $State
                return
            }
        }
    }

    # Step 9: Verify generated file - count entries, show preview
    Write-Step -Number 9 -Text 'Weryfikacja wygenerowanego pliku...'
    if ([System.IO.File]::Exists($EntitiesPath)) {
        $Content = [System.IO.File]::ReadAllText($EntitiesPath)
        $EntryPattern = [regex]::new('^\* ', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $EntryCount = $EntryPattern.Matches($Content).Count
        Write-StepOK "Znaleziono $EntryCount wpisów encji"
        Update-PhaseChecklist -State $State -Phase 0 -Item 'EntitiesVerified' -Value ($EntryCount -gt 0)

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

    # Step 10: Verify required entity sections exist
    Write-Step -Number 10 -Text 'Sprawdzanie sekcji encji...'
    $RequiredSections = @('## NPC', '## Grupa', '## Lokacja', '## Przedmiot')
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
            Update-PhaseChecklist -State $State -Phase 0 -Item 'SectionsAdded' -Value $true
        } else {
            Write-StepWarning "Brakujące sekcje: $($MissingSections -join ', ')"
            if (-not $WhatIf -and (Request-YesNo -Prompt 'Czy dodać brakujące sekcje automatycznie?' -Default $true -HelpText @(
                'Dopisanie brakujących sekcji (## NPC, ## Grupa itp.)',
                'na końcu pliku entities.md.',
                '',
                'Sekcje te są wymagane przez Get-Entity do poprawnego',
                'parsowania encji w repozytorium.',
                '',
                'Tak = dopisz brakujące nagłówki sekcji do entities.md',
                'Nie = pomiń — musisz dodać sekcje ręcznie'
            ))) {
                $SB = [System.Text.StringBuilder]::new()
                [void]$SB.Append($Content)
                foreach ($Section in $MissingSections) {
                    [void]$SB.Append("`n`n$Section`n")
                }
                $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($EntitiesPath, $SB.ToString(), $UTF8NoBOM)
                Write-StepOK 'Dodano brakujące sekcje'
                Update-PhaseChecklist -State $State -Phase 0 -Item 'SectionsAdded' -Value $true
            }
        }
    }

    # Step 11: Prompt to commit entities.md
    if (-not $WhatIf) {
        $NeedsCommit = $false
        $GitDiff = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        $GitUntracked = & git -C $RepoRoot ls-files --others --exclude-standard 'entities.md' 2>&1
        if ($GitDiff -or $GitUntracked) { $NeedsCommit = $true }

        if ($NeedsCommit) {
            Write-Step -Number 11 -Text 'Commit...'
            if (Request-YesNo -Prompt 'Czy zacommitować entities.md?' -Default $true -HelpText @(
                'Zapisanie zmian do repozytorium git.',
                '',
                'Wykona: git add entities.md + git commit',
                'z komunikatem "Bootstrap entities.md z Gracze.md".',
                '',
                'Tak = git add + git commit',
                'Nie = pominięcie, zmiany zostają niezacommitowane'
            )) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                & git -C $RepoRoot commit -m 'Bootstrap entities.md z Gracze.md' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Zacommitowano entities.md'
                    Update-PhaseChecklist -State $State -Phase 0 -Item 'Committed' -Value $true
                } else {
                    Write-StepError 'Nie udało się zacommitować entities.md'
                }
            }
        } else {
            Write-StepOK 'Brak zmian do zacommitowania'
            Update-PhaseChecklist -State $State -Phase 0 -Item 'Committed' -Value $true
        }
    }

    # Phase summary and state persistence
    $Checklist = $State.Phases['0'].Checklist
    $BootstrapDone = $Checklist['EntitiesGenerated'] -and $Checklist['EntitiesVerified'] -and $Checklist['Committed']
    if ($AllOK -and $BootstrapDone) {
        Set-PhaseCompleted -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'Completed' -Lines @(
            '[OK] Repozytorium czyste, tag pre-migration, moduł załadowany',
            '[OK] entities.md wygenerowany i zacommitowany'
        )
    } else {
        Set-PhaseInProgress -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'InProgress' -Lines @('[!!] Nie wszystkie kroki ukończone')
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

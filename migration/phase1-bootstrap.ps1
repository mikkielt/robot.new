<#
    .SYNOPSIS
    Phase 1: Bootstrap entities.md from Gracze.md.

    .DESCRIPTION
    Generates entities.md from legacy Gracze.md player data, verifies
    entry counts and required sections, and commits the result.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 1 - Bootstrap entities.md from Gracze.md
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
            $MigrationHelpersPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'entity-migrationhelpers.ps1')
            . $MigrationHelpersPath
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

    # Step 3: Verify generated file - count entries, show preview
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

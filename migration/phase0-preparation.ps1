<#
    .SYNOPSIS
    Phase 0: Preparation & backup.

    .DESCRIPTION
    Verifies clean git state, creates safety tag, checks PU state file,
    submodule registration, module import, and .robot/robot-data.psd1 manifest.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 0 - Preparation & backup
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
            $ManifestContent = "@{`n    EntitiesFile = 'entities.md'`n}`n"
            [System.IO.File]::WriteAllText($ManifestPath, $ManifestContent, [System.Text.UTF8Encoding]::new($false))
            Write-StepOK 'Utworzono manifest .robot/robot-data.psd1 (EntitiesFile → entities.md)'
        }
    }
    Update-PhaseChecklist -State $State -Phase 0 -Item 'ManifestCreated' -Value $true

    # Phase summary and state persistence
    if ($AllOK) {
        Set-PhaseCompleted -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'Completed' -Lines @(
            '[OK] Repozytorium czyste',
            '[OK] Tag pre-migration istnieje',
            '[OK] Moduł załadowany',
            '[OK] Manifest .robot/robot-data.psd1 gotowy'
        )
    } else {
        Set-PhaseInProgress -State $State -Phase 0
        Write-PhaseSummary -Phase 0 -Status 'InProgress' -Lines @(
            '[!!] Niektóre warunki nie są spełnione - sprawdź powyższe komunikaty'
        )
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

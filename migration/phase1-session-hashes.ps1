<#
    .SYNOPSIS
    Phase 1: Generate session integrity hashes (baseline snapshot).

    .DESCRIPTION
    Runs Set-SessionHash -Full to compute SHA256 content hashes for all
    headers in repository Markdown files. This captures the pre-mutation
    baseline before any validation, repair, or format-upgrade phases
    modify session content.

    The hash store is created in {ResDir}/session-hashes/ and enables
    Test-SessionIntegrity to detect content tampering later.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 1 - Generate session integrity hashes (baseline snapshot)
# ============================================================================

function Invoke-MigrationPhase1 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 1)) {
        Write-StepWarning 'Faza 0 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 1
    Write-PhaseHeader -Phase 1 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $Config = Get-AdminConfig
    $HashDir = [System.IO.Path]::Combine($Config.ResDir, 'session-hashes')

    # Step 1: Check for existing hash store
    Write-Step -Number 1 -Text 'Sprawdzanie istniejącego magazynu hashy...'

    $HasExisting = [System.IO.Directory]::Exists($HashDir)
    if ($HasExisting) {
        $ExistingFiles = [System.IO.Directory]::GetFiles($HashDir, '*.json', [System.IO.SearchOption]::AllDirectories)
        $ExistingCount = $ExistingFiles.Count
        Write-StepWarning "Magazyn hashy już istnieje ($ExistingCount plików JSON)"

        if (-not (Request-YesNo -Prompt 'Czy przeliczyć wszystkie hashy od nowa?' -Default $false -HelpText @(
            'Przeliczenie hashy SHA256 dla wszystkich plików Markdown.',
            'Magazyn hashy już istnieje — ta operacja go nadpisze.',
            '',
            'Hashy służą do weryfikacji integralności sesji',
            '(wykrywanie nieautoryzowanych zmian treści).',
            '',
            'Tak = usuń istniejące hashy i wygeneruj od nowa',
            'Nie = zachowaj obecne hashy i przejdź do weryfikacji',
            '',
            'Patrz: docs/Session-Integrity.md'
        ))) {
            Update-PhaseChecklist -State $State -Phase 1 -Item 'HashesGenerated' -Value $true
            Update-PhaseChecklist -State $State -Phase 1 -Item 'FileCount' -Value $ExistingCount

            # Skip to integrity check
            $SkipGeneration = $true
        }
    } else {
        Write-StepOK 'Brak istniejącego magazynu — zostanie utworzony'
    }

    # Step 2: Generate hashes for all files
    if (-not $SkipGeneration) {
        Write-Step -Number 2 -Text 'Generowanie hashy SHA256 dla plików Markdown...'

        if ($WhatIf) {
            Write-StepWarning '[SUCHY PRZEBIEG] Wygenerowałbym hashy sesji'
            Update-PhaseChecklist -State $State -Phase 1 -Item 'HashesGenerated' -Value $false
        } else {
            try {
                $HashResult = Set-SessionHash -Full
                $FileCount = $HashResult.FilesProcessed
                $HashCount = $HashResult.HashesComputed

                Write-StepOK "Przetworzono $FileCount plików, obliczono $HashCount hashy"
                Update-PhaseChecklist -State $State -Phase 1 -Item 'HashesGenerated' -Value $true
                Update-PhaseChecklist -State $State -Phase 1 -Item 'FileCount' -Value $FileCount
                Update-PhaseChecklist -State $State -Phase 1 -Item 'HashCount' -Value $HashCount
            }
            catch {
                Write-StepError "Błąd generowania hashy: $($_.Exception.Message)"
                Set-PhaseInProgress -State $State -Phase 1
                Save-MigrationState -State $State
                return
            }
        }
    }

    # Step 3: Run integrity check to verify clean baseline
    Write-Step -Number 3 -Text 'Weryfikacja integralności (baseline)...'

    if ($WhatIf) {
        Write-StepWarning '[SUCHY PRZEBIEG] Sprawdziłbym integralność sesji'
    } else {
        $IntegrityResult = Test-SessionIntegrity -Full

        if ($IntegrityResult.OK) {
            Write-StepOK 'Integralność potwierdzona — brak anomalii'
            Update-PhaseChecklist -State $State -Phase 1 -Item 'IntegrityOK' -Value $true
        } else {
            # Report findings (informational — does not block phase completion)
            $Issues = @()
            if ($IntegrityResult.MalformedHeaders.Count -gt 0) {
                $Issues += "nieprawidłowe nagłówki: $($IntegrityResult.MalformedHeaders.Count)"
            }
            if ($IntegrityResult.FormatAnomalies.Count -gt 0) {
                $Issues += "anomalie formatu: $($IntegrityResult.FormatAnomalies.Count)"
            }
            if ($IntegrityResult.FutureDatedSessions.Count -gt 0) {
                $Issues += "sesje z przyszłą datą: $($IntegrityResult.FutureDatedSessions.Count)"
            }

            $IssueStr = $Issues -join ', '
            Write-StepWarning "Wykryto problemy: $IssueStr"
            Write-Host '    Te problemy zostaną rozwiązane w kolejnych fazach migracji.' -ForegroundColor DarkGray
            Update-PhaseChecklist -State $State -Phase 1 -Item 'IntegrityOK' -Value $false
            Update-PhaseChecklist -State $State -Phase 1 -Item 'IntegrityIssues' -Value $IssueStr
        }
    }

    # Phase summary and state persistence
    $Checklist = $State.Phases['1'].Checklist
    $AllDone = $Checklist['HashesGenerated'] -eq $true

    if ($AllDone) {
        Set-PhaseCompleted -State $State -Phase 1
        $SummaryLines = @("[OK] Wygenerowano hashy sesji (baseline)")
        if ($Checklist['IntegrityOK'] -eq $true) {
            $SummaryLines += '[OK] Integralność potwierdzona'
        } else {
            $SummaryLines += '[!!] Wykryto problemy integralności (informacyjnie)'
        }
        Write-PhaseSummary -Phase 1 -Status 'Completed' -Lines $SummaryLines
    } else {
        Set-PhaseInProgress -State $State -Phase 1
        Write-PhaseSummary -Phase 1 -Status 'InProgress' -Lines @('[!!] Generowanie hashy nie ukończone')
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

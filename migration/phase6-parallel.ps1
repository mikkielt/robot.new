<#
    .SYNOPSIS
    Phase 7: Parallel operation monitoring dashboard.

    .DESCRIPTION
    Runs PU diagnostics, PU simulation, session format check, currency
    reconciliation, and evaluates cutover readiness criteria. Tracks
    dashboard runs and parallel period duration.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 7 - Parallel operation monitoring dashboard
# ============================================================================

function Invoke-MigrationPhase7 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 7
    Write-PhaseHeader -Phase 7 -Status $PhaseStatus

    # Initialize parallel period start timestamp
    if ($PhaseStatus -eq 'NotStarted') {
        Set-PhaseInProgress -State $State -Phase 7
        $State.Phases['7'].ParallelStartedAt = [datetime]::UtcNow.ToString('o')
    }

    # Display parallel period duration
    $StartStr = $State.Phases['7'].ParallelStartedAt
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
    Update-PhaseChecklist -State $State -Phase 7 -Item 'DiagnosticsOK' -Value $Diag.OK

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
    $RecentSessions = Get-Session -ExcludeDirectory $script:MigrationExcludeDirs | Where-Object { $_.Date -and $_.Date -ge [datetime]::Now.AddMonths(-2) }
    $NonGen4Recent = $RecentSessions | Where-Object { $_.Format -ne 'Gen4' }
    $NonGen4Count = ($NonGen4Recent | Measure-Object).Count
    if ($NonGen4Count -eq 0) {
        Write-StepOK 'Wszystkie ostatnie sesje w formacie Gen4'
        Update-PhaseChecklist -State $State -Phase 7 -Item 'AllGen4' -Value $true
    } else {
        Write-StepWarning "$NonGen4Count ostatnich sesji nie w formacie Gen4"
        Update-PhaseChecklist -State $State -Phase 7 -Item 'AllGen4' -Value $false
    }

    # Dashboard section 4: Currency reconciliation
    Write-SectionHeader 'Rekoncyliacja walut'
    $Recon = Test-CurrencyReconciliation
    if ($Recon.WarningCount -eq 0) {
        Write-StepOK 'Brak ostrzeżeń'
        Update-PhaseChecklist -State $State -Phase 7 -Item 'CurrencyOK' -Value $true
    } else {
        Write-StepWarning "$($Recon.WarningCount) ostrzeżeń"
        Update-PhaseChecklist -State $State -Phase 7 -Item 'CurrencyOK' -Value $false
    }

    # Dashboard section 5: Cutover readiness criteria
    Write-SectionHeader 'Kryteria przełączenia'
    $Criteria = @{
        'Min. 1 pełny cykl PU bez rozbieżności'  = $State.Phases['7'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['7'].Checklist['PUCycleValidated']
        'Wszyscy aktywni narratorzy stosują Gen4'  = $NonGen4Count -eq 0
        'Test-PUAssignment: OK = True'             = $Diag.OK
        'Test-CurrencyReconciliation: brak błędów' = $Recon.WarningCount -eq 0
    }
    Write-ChecklistReport -Checklist $Criteria -Title 'KRYTERIA PRZEŁĄCZENIA'

    # Ask coordinator to confirm PU cycle validation (one-time gate)
    if ($Diag.OK -and -not ($State.Phases['7'].Checklist.ContainsKey('PUCycleValidated') -and $State.Phases['7'].Checklist['PUCycleValidated'])) {
        if (Request-YesNo -Prompt 'Czy porównano wyniki PU z starym systemem i są zgodne?' -Default $false) {
            Update-PhaseChecklist -State $State -Phase 7 -Item 'PUCycleValidated' -Value $true
        }
    }

    # Evaluate all criteria - mark phase completed if all pass
    $AllCriteria = $Criteria.Values | Where-Object { $_ -eq $false }
    if (($AllCriteria | Measure-Object).Count -eq 0) {
        Write-Host ''
        Write-StepOK 'Wszystkie kryteria spełnione. Możesz przejść do Fazy 7.'
        Set-PhaseCompleted -State $State -Phase 7
    }

    # Append dashboard run timestamp to history
    if (-not $State.Phases['7'].ContainsKey('DashboardRuns')) {
        $State.Phases['7'].DashboardRuns = @()
    }
    $State.Phases['7'].DashboardRuns = @($State.Phases['7'].DashboardRuns) + @([datetime]::UtcNow.ToString('o'))

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

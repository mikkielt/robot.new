<#
    .SYNOPSIS
    Phase 2: Data parity validation (read-only).

    .DESCRIPTION
    Loads players/characters, spot-checks PU values, verifies aliases and
    webhooks, runs full PU diagnostics. Optionally marks webhook-less
    active players as inactive.

    Dependencies: migration-ui.ps1, migration-state.ps1, migration-shared.ps1,
                  robot module imported.
#>

# ============================================================================
# PHASE 2 - Data parity validation (read-only)
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

    # Step 5: Check players missing Discord webhooks (only Active players)
    Write-Step -Number 5 -Text 'Sprawdzanie webhooków (aktywni gracze)...'

    # Build player status lookup from entity data (use config-resolved path
    # so the manifest-redirected entities.md is read, not the submodule default)
    $PlayerStatusMap = @{}
    $EntitiesConfig = Get-AdminConfig
    foreach ($E in (Get-Entity -Path $EntitiesConfig.EntitiesFile)) {
        if ([string]::Equals($E.Type, 'Gracz', [System.StringComparison]::OrdinalIgnoreCase)) {
            $PlayerStatusMap[$E.Name] = $E.Status
        }
    }

    $NoWebhook = [System.Collections.Generic.List[string]]::new()
    $SkippedInactive = 0
    foreach ($Player in $Players) {
        $PlayerStatus = $PlayerStatusMap[$Player.Name]
        if (-not $PlayerStatus) { $PlayerStatus = 'Aktywny' }

        if (-not [string]::Equals($PlayerStatus, 'Aktywny', [System.StringComparison]::OrdinalIgnoreCase)) {
            $SkippedInactive++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Player.PRFWebhook) -or $Player.PRFWebhook -eq 'BRAK') {
            $NoWebhook.Add($Player.Name)
        }
    }

    if ($NoWebhook.Count -gt 0) {
        Write-StepWarning "Aktywnych graczy bez webhooka: $($NoWebhook.Count)"
        if ($SkippedInactive -gt 0) {
            Write-Host "    (pominięto $SkippedInactive nieaktywnych graczy)" -ForegroundColor DarkGray
        }
        foreach ($Name in ($NoWebhook | Select-Object -First 5)) {
            Write-Host "    - $Name" -ForegroundColor DarkGray
        }
        if ($NoWebhook.Count -gt 5) {
            Write-Host "    ... (i $($NoWebhook.Count - 5) więcej)" -ForegroundColor DarkGray
        }

        # Offer to mark webhook-less active players as inactive
        $WebhooksResolved = $false
        if (-not $WhatIf) {
            $MarkInactive = Request-YesNo -Prompt 'Czy chcesz oznaczyć ich jako nieaktywnych?' -Default $false
            if ($MarkInactive) {
                $MarkedCount = 0
                foreach ($PlayerName in $NoWebhook) {
                    try {
                        Set-Entity -Name $PlayerName -Tags @{ status = 'Nieaktywny' } -Confirm:$false
                        $MarkedCount++
                    }
                    catch {
                        Write-StepError "Nie udało się oznaczyć '$PlayerName': $($_.Exception.Message)"
                    }
                }
                if ($MarkedCount -gt 0) {
                    Write-StepOK "Oznaczono $MarkedCount graczy jako nieaktywnych"
                    $WebhooksResolved = ($MarkedCount -eq $NoWebhook.Count)
                }
            }
        }
    } else {
        $WebhooksResolved = $true
        $OkMsg = 'Wszyscy aktywni gracze mają webhook'
        if ($SkippedInactive -gt 0) {
            $OkMsg += " (pominięto $SkippedInactive nieaktywnych)"
        }
        Write-StepOK $OkMsg
    }
    Update-PhaseChecklist -State $State -Phase 2 -Item 'WebhooksChecked' -Value $true

    # Step 6: Run full PU diagnostics
    Write-Step -Number 6 -Text 'Uruchamianie diagnostyki PU...'
    $Diag = Test-PlayerCharacterPUAssignment -ExcludeDirectory $script:MigrationExcludeDirs
    Show-DiagnosticResults -Diagnostics $Diag
    Update-PhaseChecklist -State $State -Phase 2 -Item 'DiagnosticsRun' -Value $true
    Update-PhaseChecklist -State $State -Phase 2 -Item 'DiagnosticsOK' -Value $Diag.OK

    # Phase summary and state persistence
    $SummaryLines = @(
        "[OK] Graczy: $PlayerCount, Postaci: $CharCount",
        "[OK] PU zweryfikowane (wyrywkowo)",
        "[OK] Aliasy: $AliasCount postaci"
    )
    if ($NoWebhook.Count -gt 0 -and -not $WebhooksResolved) {
        $SummaryLines += "[!!] Aktywnych graczy bez webhooka: $($NoWebhook.Count)"
    } elseif ($NoWebhook.Count -gt 0 -and $WebhooksResolved) {
        $SummaryLines += "[OK] Gracze bez webhooka oznaczeni jako nieaktywni ($($NoWebhook.Count))"
    }
    if ($Diag.OK) {
        $SummaryLines += '[OK] Diagnostyka PU: OK'
        Set-PhaseCompleted -State $State -Phase 2
        Write-PhaseSummary -Phase 2 -Status 'Completed' -Lines $SummaryLines
    } else {
        $IssueCount = $Diag.UnresolvedCharacters.Count + $Diag.MalformedPU.Count +
                      $Diag.DuplicateEntries.Count + $Diag.FailedSessionsWithPU.Count
        $SummaryLines += "[!!] Diagnostyka PU: $IssueCount problemów - przejdź do Fazy 3"
        Set-PhaseInProgress -State $State -Phase 2
        Write-PhaseSummary -Phase 2 -Status 'InProgress' -Lines $SummaryLines
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}

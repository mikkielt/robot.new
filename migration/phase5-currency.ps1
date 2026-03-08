<#
    .SYNOPSIS
    Phase 5: Currency enrollment.

    .DESCRIPTION
    Creates coordinator treasury, inventories active characters without
    currency data, offers CSV or interactive currency registration,
    handles narrator budgets, and runs reconciliation.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ============================================================================
# PHASE 5 - Currency enrollment
# ============================================================================

function Invoke-MigrationPhase5 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 5)) {
        Write-StepWarning 'Faza 4 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

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
        } elseif (Request-YesNo -Prompt 'Czy utworzyć Skarbiec Koordynatorów?' -Default $true -HelpText @(
            'Utworzenie encji typu Grupa o nazwie "Skarbiec Koordynatorów"',
            'w pliku entities.md. Skarbiec pełni rolę centralnego konta',
            'walutowego, z którego koordynatorzy przydzielają środki.',
            '',
            'Po utworzeniu zostaniesz poproszony o podanie początkowych',
            'rezerw (Korony, Talary, Kogi).',
            '',
            'Tak = utwórz skarbiec i wprowadź rezerwy',
            'Nie = pomiń, skarbiec trzeba będzie utworzyć ręcznie'
        )) {
            try {
                New-Entity -Type 'Grupa' -Name 'Skarbiec Koordynatorów' -Confirm:$false
                Write-StepOK 'Utworzono grupę Skarbiec Koordynatorów'

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
        $UseCsv = Request-YesNo -Prompt "Czy wczytać dane z pliku CSV? ($($CharsWithout.Count) postaci bez waluty)" -Default $false -HelpText @(
            'Import danych walutowych z pliku CSV dla postaci',
            'bez zarejestrowanych walut.',
            '',
            'Format CSV: Postać,Korony,Talary,Kogi',
            'Przykład: Crag Hack,50,200,1500',
            '',
            'Tak = wczytaj dane z pliku CSV (batch import)',
            'Nie = przejdź do ręcznego wprowadzania danych'
        )

        if ($UseCsv) {
            Invoke-CurrencyCSVImport -CharactersWithout $CharsWithout
        } else {
            # Fall back to interactive per-character entry
            $DoInteractive = Request-YesNo -Prompt "Czy wprowadzić dane ręcznie dla $($CharsWithout.Count) postaci?" -Default $true -HelpText @(
                'Ręczne wprowadzanie stanów walut dla każdej aktywnej',
                'postaci, która nie ma jeszcze encji walutowych.',
                '',
                'Dla każdej postaci podajesz Korony, Talary i Kogi.',
                'Można pominąć (Enter) nominał, który nie dotyczy postaci.',
                '',
                'Tak = wprowadź dane interaktywnie postać po postaci',
                'Nie = pomiń, uruchom Fazę 5 ponownie po zebraniu danych'
            )
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
        if (Request-YesNo -Prompt 'Czy narratorzy mają budżety walut do zarejestrowania?' -Default $false -HelpText @(
            'Rejestracja budżetów walutowych dla narratorów.',
            'Narratorzy mogą posiadać pule walut przeznaczone',
            'do rozdawania graczom podczas sesji.',
            '',
            'Po wybraniu Tak, podajesz nazwę narratora i kwoty.',
            'Pusta nazwa kończy wprowadzanie.',
            '',
            'Tak = przejdź do rejestracji budżetów narratorów',
            'Nie = pomiń, narratorzy nie mają budżetów do rejestracji'
        )) {
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
            if (Request-YesNo -Prompt 'Czy zacommitować zmiany walutowe?' -Default $true -HelpText @(
                'Zapisanie zmian walutowych do repozytorium git.',
                '',
                'Wykona: git add entities.md + git commit',
                'z komunikatem "Enrollment walut - stan początkowy".',
                '',
                'Tak = git add + git commit',
                'Nie = pominięcie, zmiany zostają niezacommitowane'
            )) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                & git -C $RepoRoot commit -m 'Enrollment walut - stan początkowy' 2>&1
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

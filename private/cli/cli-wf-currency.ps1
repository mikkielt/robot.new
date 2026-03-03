<#
    .SYNOPSIS
    Currency-domain CLI workflows - transfer wizard and reconciliation display.

    .DESCRIPTION
    This file contains workflow functions for currency management, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-CurrencyTransferWorkflow:       full transfer wizard (source -> amount -> destination)
    - Invoke-CurrencyReconciliationDisplay:  formatted currency reconciliation results

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1, cli-display.ps1
#>

# ── Currency Transfer Workflow ───────────────────────────────────────────────

function Invoke-CurrencyTransferWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor   = Get-CLIColor -Role 'Error'
    $InfoColor    = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    # Step 1: Source currency
    [System.Console]::Clear()
    Write-CLILine -Text 'Transfer walutowy' -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-Host ''

    $Source = Show-FuzzySearch -Prompt 'Źródło (waluta do obciążenia)' -Source 'currency' -State $State
    if (-not $Source) { return }

    # Step 2: Amount
    Write-Host ''
    $AmountStep = [PSCustomObject]@{
        Name = 'Amount'; Label = 'Kwota do przelania'; StepType = 'number'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $Amount = Invoke-WizardStep -Step $AmountStep -State $State
    if ($Amount -eq '__back__' -or -not $Amount) { return }

    # Step 3: Destination currency
    [System.Console]::Clear()
    Write-CLILine -Text 'Transfer walutowy' -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-Host "  $('Źródło'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Source.Name)"
    Write-Host "  $('Kwota'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$Amount"
    Write-Host ''

    $Dest = Show-FuzzySearch -Prompt 'Cel (waluta do zasilenia)' -Source 'currency' -State $State
    if (-not $Dest) { return }

    # Preview both operations
    [System.Console]::Clear()
    Write-Host "  $Sep" -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Podgląd transferu:' -Color $AccentColor
    Write-Host ''
    Write-Host "  $('Źródło'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Source.Name) $([char]0x2192) -$Amount"
    Write-Host "  $('Cel'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Dest.Name) $([char]0x2192) +$Amount"
    Write-Host "  $Sep" -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-Host ''

    Write-CLILine -Text 'Wykonać transfer?' -Color $AccentColor
    $Confirm = Show-ArrowMenu -Items @(
        [PSCustomObject]@{ ID = 'yes'; Label = 'Tak, wykonaj'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'no';  Label = 'Anuluj';       Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
    ) -ShowBack

    if ($Confirm -ne 'yes') {
        Write-CLILine -Text 'Anulowano.' -Color (Get-CLIColor -Role 'Disabled')
        return
    }

    try {
        # Execute source debit
        Set-CurrencyEntity -Name $Source.Name -AmountDelta (-$Amount)
        # Execute destination credit
        Set-CurrencyEntity -Name $Dest.Name -AmountDelta $Amount

        Write-Host ''
        Write-CLILine -Text "$([char]0x2713) Transfer zakończony pomyślnie." -Color $SuccessColor

        # Refresh state
        try { Refresh-NavState -State $State } catch {}
    }
    catch {
        Write-CLILine -Text "$([char]0x2717) Błąd transferu: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

# ── Currency Reconciliation Display ──────────────────────────────────────────

function Invoke-CurrencyReconciliationDisplay {
    param([object]$State, [hashtable]$Entry)

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $WarningColor = Get-CLIColor -Role 'Warning'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-Host ''
    Write-CLILine -Text 'Uzgodnienie walut' -Color $AccentColor
    Write-Host ''

    try {
        $Result = Test-CurrencyReconciliation

        Write-CLILine -Text "Encje walutowe: $($Result.EntityCount)" -Color $DisabledColor
        Write-CLILine -Text "Sprawdzono: $($Result.CheckedAt)" -Color $DisabledColor
        Write-Host ''

        if ($Result.WarningCount -eq 0) {
            Write-CLILine -Text "$([char]0x2713) Brak ostrzeżeń - waluty spójne." -Color $SuccessColor
        }
        else {
            Write-CLILine -Text "$([char]0x26A0) Ostrzeżenia: $($Result.WarningCount)" -Color $WarningColor
            Write-Host ''

            foreach ($Warn in $Result.Warnings) {
                $Severity = if ($Warn.Severity) { $Warn.Severity } else { '?' }
                $SevColor = switch ($Severity) {
                    'Error'   { Get-CLIColor -Role 'Error' }
                    'Warning' { $WarningColor }
                    default   { $DisabledColor }
                }
                Write-Host "    [$Severity] " -NoNewline -ForegroundColor $SevColor
                Write-Host "$($Warn.Check)" -ForegroundColor $SevColor
                if ($Warn.Entity)  { Write-CLILine -Text "      Encja: $($Warn.Entity)" -Color $DisabledColor }
                if ($Warn.Detail)  { Write-CLILine -Text "      Szczegóły: $($Warn.Detail)" -Color $DisabledColor }
            }
        }

        # Show supply summary
        if ($Result.Supply -and $Result.Supply.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text 'Podaż walut:' -Color $AccentColor
            foreach ($S in $Result.Supply) {
                Write-CLILine -Text "    $($S.Denomination): $($S.Total)" -Color $DisabledColor
            }
        }
    }
    catch {
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void](Read-ArrowKey)
}

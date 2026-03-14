<#
    .SYNOPSIS
    Economy-domain CLI workflows - snapshot, timeline, and materialization reports.

    .DESCRIPTION
    This file contains workflow functions for economic analysis, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-EconomicSnapshotWorkflow:         point-in-time economic snapshot
    - Invoke-EconomicTimelineWorkflow:         monthly economic trends
    - Invoke-MaterializationReportWorkflow:    physical vs virtual currency analysis

    Dependencies: cli-primitives.ps1, cli-wizard.ps1
#>

# ── Economic Snapshot Workflow ─────────────────────────────────────────────

function Invoke-EconomicSnapshotWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Obraz gospodarki' -Color $AccentColor
    Write-Host ''

    # Optional denomination filter
    $DenomStep = [PSCustomObject]@{
        Name = 'Denomination'; Label = 'Nominał (opcjonalny)'; StepType = 'choice'; Required = $false
        Source = $null; Options = @('Wszystkie', 'Korony Elanckie', 'Talary Hirońskie', 'Kogi Skeltvorskie')
        SubSteps = $null; EntrySource = $null; Condition = $null; Transform = $null; Default = 'Wszystkie'
    }
    $DenomChoice = Invoke-WizardStep -Step $DenomStep -State $State
    if ($DenomChoice -eq '__back__') { return }

    $SnapProg = New-ProgressState -Title 'Migawka ekonomiczna' -TotalSteps 1
    Start-ProgressStep -State $SnapProg -Label 'Obliczanie'

    try {
        $Params = @{ Quiet = $true }
        if ($DenomChoice -and $DenomChoice -ne 'Wszystkie') {
            $Params['Denomination'] = $DenomChoice
        }

        $Snapshot = Get-EconomicSnapshot @Params
        Complete-ProgressStep -State $SnapProg -Detail 'OK'
        Complete-ProgressGroup -State $SnapProg

        Write-Host ''
        Write-CLILine -Text "  Data: $($Snapshot.SnapshotDate.ToString('yyyy-MM-dd'))" -Color $AccentColor
        Write-Host ''

        # Supply breakdown
        Write-CLILine -Text '  Podaż wg nominałów:' -Color $AccentColor
        foreach ($Entry in $Snapshot.SupplyByDenomination.GetEnumerator()) {
            Write-CLILine -Text "    $($Entry.Key): $($Entry.Value.Total) (fiz: $($Entry.Value.Physical), wirt: $($Entry.Value.Virtual))" -Color $DisabledColor
        }
        Write-Host ''

        # Summary stats
        $Breakdown = ConvertFrom-CurrencyBaseUnit -Amount $Snapshot.TotalSupplyKogi
        Write-CLILine -Text "  Podaż ogółem (Kogi): $($Snapshot.TotalSupplyKogi)" -Color $AccentColor
        Write-CLILine -Text "  Fizyczna: $($Snapshot.PhysicalSupplyKogi) Kogi ($([math]::Round($Snapshot.PhysicalRatio * 100, 1))%)" -Color $AccentColor
        Write-CLILine -Text "  Wirtualna: $($Snapshot.VirtualSupplyKogi) Kogi" -Color $AccentColor
        Write-CLILine -Text "  Właściciele z saldem: $($Snapshot.HolderCount)" -Color $AccentColor
        Write-CLILine -Text "  Gini: $($Snapshot.GiniCoefficient)" -Color $AccentColor
        Write-CLILine -Text "  Transakcje: $($Snapshot.TransactionVolume) (wartość: $($Snapshot.TransactionValueKogi) Kogi)" -Color $AccentColor
        Write-Host ''

        # Top holders table
        if ($Snapshot.TopHolders.Count -gt 0) {
            $TableData = $Snapshot.TopHolders | ForEach-Object {
                [PSCustomObject]@{
                    Właściciel = $_.Owner
                    Majątek    = $_.WealthKogi
                    Kategoria  = $_.OwnerCategory
                }
            }
            $TableComponent = New-ResultTableComponent -Data @($TableData) `
                -Columns @('Właściciel', 'Majątek', 'Kategoria') `
                -Headers @('Właściciel', 'Majątek (Kogi)', 'Kategoria') `
                -Widths @(25, 15, 12) `
                -Title 'Najbogatsi'
            [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
        }
    }
    catch {
        Complete-ProgressStep -State $SnapProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $SnapProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

# ── Economic Timeline Workflow ─────────────────────────────────────────────

function Invoke-EconomicTimelineWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Oś czasu gospodarki' -Color $AccentColor
    Write-Host ''

    # Date range
    $MinDateStep = [PSCustomObject]@{
        Name = 'MinDate'; Label = 'Od daty'; StepType = 'date'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $MaxDateStep = [PSCustomObject]@{
        Name = 'MaxDate'; Label = 'Do daty'; StepType = 'date'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MaxDate = Invoke-WizardStep -Step $MaxDateStep -State $State
    if ($MaxDate -eq '__back__') { return }

    $TlProg = New-ProgressState -Title 'Oś czasu ekonomiczna' -TotalSteps 1
    Start-ProgressStep -State $TlProg -Label 'Generowanie'

    try {
        $TlCB = { param($C,$T,$D); Update-ProgressStep -State $TlProg -Detail "$C/$T" }.GetNewClosure()
        $Timeline = Get-EconomicTimeline -MinDate $MinDate -MaxDate $MaxDate -Quiet -ProgressCallback $TlCB
        Complete-ProgressStep -State $TlProg -Detail "$($Timeline.Count) miesięcy"
        Complete-ProgressGroup -State $TlProg

        if (-not $Timeline -or $Timeline.Count -eq 0) {
            Write-CLILine -Text 'Brak danych w wybranym zakresie.' -Color $WarningColor
        } else {
            $TableData = $Timeline | ForEach-Object {
                [PSCustomObject]@{
                    Miesiąc   = $_.Month
                    Ogółem    = $_.TotalSupplyKogi
                    Fizyczna  = $_.PhysicalSupplyKogi
                    Wirtualna = $_.VirtualSupplyKogi
                    Transfery = $_.TransferCount
                }
            }
            $TableComponent = New-ResultTableComponent -Data @($TableData) `
                -Columns @('Miesiąc', 'Ogółem', 'Fizyczna', 'Wirtualna', 'Transfery') `
                -Headers @('Miesiąc', 'Ogółem (Kogi)', 'Fizyczna', 'Wirtualna', 'Transfery') `
                -Widths @(10, 15, 15, 15, 10) `
                -Title 'Oś czasu gospodarki'
            [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
        }
    }
    catch {
        Complete-ProgressStep -State $TlProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $TlProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

# ── Materialization Report Workflow ────────────────────────────────────────

function Invoke-MaterializationReportWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Raport materializacji' -Color $AccentColor
    Write-Host ''

    $MatProg = New-ProgressState -Title 'Raport materializacji' -TotalSteps 1
    Start-ProgressStep -State $MatProg -Label 'Obliczanie'

    try {
        $Report = Get-MaterializationReport -Quiet
        Complete-ProgressStep -State $MatProg -Detail 'OK'
        Complete-ProgressGroup -State $MatProg

        Write-Host ''

        # Summary
        $Summary = $Report.Summary
        Write-CLILine -Text "  Fizyczna łącznie: $($Summary.TotalPhysical) Kogi" -Color $AccentColor
        Write-CLILine -Text "  Wirtualna łącznie: $($Summary.TotalVirtual) Kogi" -Color $AccentColor
        if ($Summary.OrphanedCount -gt 0) {
            Write-CLILine -Text "  Osierocone pozycje: $($Summary.OrphanedCount)" -Color $WarningColor
        }
        Write-Host ''

        # Denomination breakdown
        if ($Report.DenominationBreakdown.Count -gt 0) {
            Write-CLILine -Text '  Podział wg nominałów:' -Color $AccentColor
            foreach ($D in $Report.DenominationBreakdown) {
                Write-CLILine -Text "    $($D.Denomination): $($D.Total) (fiz: $($D.Physical) [$($D.PhysicalPct)%], wirt: $($D.Virtual))" -Color $DisabledColor
            }
            Write-Host ''
        }

        # Player breakdown table
        if ($Report.PlayerBreakdown.Count -gt 0) {
            $PlayerData = $Report.PlayerBreakdown | ForEach-Object {
                [PSCustomObject]@{
                    Gracz     = $_.PlayerName
                    Postacie  = ($_.Characters -join ', ')
                    Majątek   = $_.TotalPhysicalKogi
                }
            }
            $TableComponent = New-ResultTableComponent -Data @($PlayerData) `
                -Columns @('Gracz', 'Postacie', 'Majątek') `
                -Headers @('Gracz', 'Postacie', 'Majątek (Kogi)') `
                -Widths @(18, 30, 15) `
                -Title 'Majątek fizyczny wg graczy'
            [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
        }

        # Orphaned physical
        if ($Report.OrphanedPhysical.Count -gt 0) {
            Write-Host ''
            $OrphanData = $Report.OrphanedPhysical | ForEach-Object {
                [PSCustomObject]@{
                    Encja    = $_.Entity
                    Właściciel = $_.Owner
                    Status   = $_.OwnerStatus
                    Nominał  = $_.Denomination
                    Ilość    = $_.Quantity
                }
            }
            $TableComponent = New-ResultTableComponent -Data @($OrphanData) `
                -Columns @('Encja', 'Właściciel', 'Status', 'Nominał', 'Ilość') `
                -Headers @('Encja', 'Właściciel', 'Status', 'Nominał', 'Ilość') `
                -Widths @(25, 18, 12, 18, 8) `
                -Title 'Osierocona waluta fizyczna'
            [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
        }
    }
    catch {
        Complete-ProgressStep -State $MatProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $MatProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

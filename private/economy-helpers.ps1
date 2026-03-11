<#
    .SYNOPSIS
    Shared economic analysis helpers for snapshot and timeline reporting.

    .DESCRIPTION
    Contains New-EconomicSnapshotData which computes supply breakdown, Gini
    coefficient, top holders, and transaction volume from enriched currency items.
    Dot-sourced by Get-EconomicSnapshot and Get-EconomicTimeline.
#>

function New-EconomicSnapshotData {
    <#
        .SYNOPSIS
        Builds economic snapshot data from enriched currency items and transfer entries.
        Returns a hashtable with supply breakdown, Gini, top holders, and transaction stats.
    #>
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$CurrencyItems,

        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$TransferEntries,

        [int]$Top = 10
    )

    if (-not $CurrencyItems) { $CurrencyItems = @() }
    if (-not $TransferEntries) { $TransferEntries = @() }

    # Supply breakdown by denomination and owner category
    $SupplyByDenomination = @{}
    $OwnerWealth = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $OwnerCategories = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $TotalSupplyKogi = 0
    $PhysicalSupplyKogi = 0
    $VirtualSupplyKogi = 0

    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }

        $DenomName = $Item.Denomination.Name
        $BaseValue = $Item.Quantity * $Item.Denomination.Multiplier
        $Category = if ($Item.OwnerCategory) { $Item.OwnerCategory } else { 'Unknown' }

        # Supply by denomination
        if (-not $SupplyByDenomination.ContainsKey($DenomName)) {
            $SupplyByDenomination[$DenomName] = @{ Total = 0; Physical = 0; Virtual = 0 }
        }
        $SupplyByDenomination[$DenomName].Total += $Item.Quantity
        if ($Category -eq 'Physical') {
            $SupplyByDenomination[$DenomName].Physical += $Item.Quantity
        } elseif ($Category -eq 'Virtual') {
            $SupplyByDenomination[$DenomName].Virtual += $Item.Quantity
        }

        # Total supply in base unit
        $TotalSupplyKogi += $BaseValue
        if ($Category -eq 'Physical') { $PhysicalSupplyKogi += $BaseValue }
        elseif ($Category -eq 'Virtual') { $VirtualSupplyKogi += $BaseValue }

        # Per-owner wealth accumulation
        if ($Item.Owner) {
            if (-not $OwnerWealth.ContainsKey($Item.Owner)) {
                $OwnerWealth[$Item.Owner] = 0
            }
            $OwnerWealth[$Item.Owner] += $BaseValue

            if (-not $OwnerCategories.ContainsKey($Item.Owner)) {
                $OwnerCategories[$Item.Owner] = $Category
            }
        }
    }

    # Physical ratio
    $PhysicalRatio = if ($TotalSupplyKogi -gt 0) { [double]$PhysicalSupplyKogi / $TotalSupplyKogi } else { 0.0 }

    # Holder count (owners with balance > 0)
    $HolderCount = 0
    foreach ($Entry in $OwnerWealth.GetEnumerator()) {
        if ($Entry.Value -gt 0) { $HolderCount++ }
    }

    # Top holders — sort by wealth descending, take top N
    $TopHolders = [System.Collections.Generic.List[object]]::new()
    $OwnerEntries = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string, int]]]::new()
    foreach ($Entry in $OwnerWealth.GetEnumerator()) {
        $OwnerEntries.Add($Entry)
    }
    $OwnerEntries.Sort([System.Comparison[System.Collections.Generic.KeyValuePair[string, int]]]{
        param($A, $B) $B.Value.CompareTo($A.Value)
    })
    $TopCount = [math]::Min($Top, $OwnerEntries.Count)
    for ($J = 0; $J -lt $TopCount; $J++) {
        $Entry = $OwnerEntries[$J]
        $Cat = if ($OwnerCategories.ContainsKey($Entry.Key)) { $OwnerCategories[$Entry.Key] } else { 'Unknown' }
        $TopHolders.Add([PSCustomObject]@{
            Owner         = $Entry.Key
            WealthKogi    = $Entry.Value
            OwnerCategory = $Cat
        })
    }

    # Gini coefficient
    # G = (2 * Σ(i * w[i])) / (n * Σ(w)) - (n+1)/n
    $GiniCoefficient = 0.0
    $PositiveWealth = [System.Collections.Generic.List[int]]::new()
    foreach ($Entry in $OwnerWealth.GetEnumerator()) {
        if ($Entry.Value -gt 0) { $PositiveWealth.Add($Entry.Value) }
    }
    if ($PositiveWealth.Count -gt 1) {
        $PositiveWealth.Sort()
        $N = $PositiveWealth.Count
        [double]$SumW = 0
        [double]$SumIW = 0
        for ($I = 0; $I -lt $N; $I++) {
            $SumW += $PositiveWealth[$I]
            $SumIW += ($I + 1) * $PositiveWealth[$I]
        }
        if ($SumW -gt 0) {
            $GiniCoefficient = (2.0 * $SumIW) / ($N * $SumW) - ($N + 1.0) / $N
        }
    }

    # Transaction volume
    $TransactionVolume = 0
    $TransactionValueKogi = 0
    if ($TransferEntries) {
        $TransactionVolume = $TransferEntries.Count
        foreach ($Entry in $TransferEntries) {
            $Directive = $Entry.Directive
            $Denom = Resolve-CurrencyDenomination -Name $Directive.Denomination
            if ($Denom) {
                $TransactionValueKogi += $Directive.Amount * $Denom.Multiplier
            }
        }
    }

    return @{
        SupplyByDenomination = $SupplyByDenomination
        TotalSupplyKogi      = $TotalSupplyKogi
        PhysicalSupplyKogi   = $PhysicalSupplyKogi
        VirtualSupplyKogi    = $VirtualSupplyKogi
        PhysicalRatio        = [math]::Round($PhysicalRatio, 4)
        HolderCount          = $HolderCount
        TopHolders           = @($TopHolders)
        GiniCoefficient      = [math]::Round($GiniCoefficient, 4)
        TransactionVolume    = $TransactionVolume
        TransactionValueKogi = $TransactionValueKogi
    }
}

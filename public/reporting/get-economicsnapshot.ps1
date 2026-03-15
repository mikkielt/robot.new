<#
    .SYNOPSIS
    Economic snapshot report — supply breakdown, wealth distribution, and Gini coefficient.

    .DESCRIPTION
    Get-EconomicSnapshot produces a point-in-time economic snapshot showing
    physical vs virtual currency supply, top holders, Gini coefficient
    (wealth inequality), and transaction volume.

    Key concepts:
    - Physical currency: owned by Postać entities (actual Margonem items
      in player equipment). These are real in-game objects.
    - Virtual currency: owned by NPC/Grupa/Gracz entities (RP bookkeeping
      balances that don't correspond to in-game items).

    Processing pipeline:
    1. Fetch entities (with optional -ActiveOn temporal filter) and sessions
    2. Build a case-insensitive entity lookup for owner type classification
       (determines Physical vs Virtual categorization)
    3. Extract and filter currency items via Get-CurrencyEntitiesFiltered,
       including inactive and deleted entities for complete supply picture
    4. Apply optional denomination and owner filters
    5. Extract transfer entries from session @Transfer directives for
       transaction volume metrics
    6. Delegate snapshot computation to New-EconomicSnapshotData (in
       economy-helpers.ps1), which calculates supply breakdown, Gini
       coefficient via Robot.EconomicAnalyzer C# type, and top holders

    The Gini coefficient ranges from 0 (perfect equality) to 1 (maximum
    inequality) and measures wealth concentration across all currency
    holders. Computed in C# for performance when Robot.EconomicAnalyzer
    is available, with a PowerShell fallback.

    Dot-sources currency-helpers.ps1, reporting-helpers.ps1, and
    economy-helpers.ps1.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"
. "$script:ModuleRoot/private/reporting-helpers.ps1"
. "$script:ModuleRoot/private/economy-helpers.ps1"

function Get-EconomicSnapshot {
    <#
        .SYNOPSIS
        Generates a point-in-time economic snapshot with supply breakdown and wealth distribution.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Snapshot effective date (temporal filter)")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Scope to a specific owner entity")]
        [string]$Owner,

        [Parameter(HelpMessage = "Scope to a specific denomination")]
        [string]$Denomination,

        [Parameter(HelpMessage = "Number of top holders to include")]
        [int]$Top = 10,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session
    }

    # Multi-name entity lookup: maps every known name (primary + aliases) to its entity
    # for classifying currency owners as Physical (Postać) or Virtual (NPC/Grupa/Gracz)
    $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityLookup.ContainsKey($Name)) {
                $EntityLookup[$Name] = $Entity
            }
        }
    }

    # Include inactive/deleted entities for a complete supply picture (deleted currency
    # still existed and affects historical totals; inactive may return to circulation)
    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive -IncludeDeleted -EntityLookup $EntityLookup

    # Narrow results to user-specified denomination or owner scope
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
        if ($DenomFilter) {
            $Filtered = [System.Collections.Generic.List[object]]::new()
            foreach ($Item in $CurrencyItems) {
                if ($Item.Denomination.Name -eq $DenomFilter.Name) { $Filtered.Add($Item) }
            }
            $CurrencyItems = @($Filtered)
        }
    }
    if ($Owner) {
        $Filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in $CurrencyItems) {
            if ($Item.Owner -and [string]::Equals($Item.Owner, $Owner, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Filtered.Add($Item)
            }
        }
        $CurrencyItems = @($Filtered)
    }

    # Count session @Transfer directives for transaction volume metrics
    $TransferEntries = @()
    if ($Sessions -and $Sessions.Count -gt 0) {
        $TransferEntries = @(Get-SessionDirectiveEntries -Sessions $Sessions -DirectiveName 'Transfers')
    }

    # Delegate aggregation (Gini, top holders, supply split) to economy-helpers
    $Data = New-EconomicSnapshotData -CurrencyItems $CurrencyItems -TransferEntries $TransferEntries -Top $Top

    $SnapshotDate = if ($ActiveOn) { $ActiveOn } else { [datetime]::Now }

    return [PSCustomObject]@{
        SnapshotDate         = $SnapshotDate
        SupplyByDenomination = $Data.SupplyByDenomination
        TotalSupplyKogi      = $Data.TotalSupplyKogi
        PhysicalSupplyKogi   = $Data.PhysicalSupplyKogi
        VirtualSupplyKogi    = $Data.VirtualSupplyKogi
        PhysicalRatio        = $Data.PhysicalRatio
        HolderCount          = $Data.HolderCount
        TopHolders           = $Data.TopHolders
        GiniCoefficient      = $Data.GiniCoefficient
        TransactionVolume    = $Data.TransactionVolume
        TransactionValueKogi = $Data.TransactionValueKogi
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

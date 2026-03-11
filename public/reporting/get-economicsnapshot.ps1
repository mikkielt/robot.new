<#
    .SYNOPSIS
    Economic snapshot report — supply breakdown, wealth distribution, and Gini coefficient.

    .DESCRIPTION
    Produces a point-in-time economic snapshot showing physical vs virtual currency
    supply, top holders, Gini coefficient (wealth inequality), and transaction volume.

    Physical currency = owned by Postać entities (actual Margonem items in player equipment).
    Virtual currency = owned by NPC/Grupa/Gracz entities (RP bookkeeping).

    Dot-sources currency-helpers.ps1, reporting-helpers.ps1, and economy-helpers.ps1.
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

    # Build entity lookup for owner type classification
    $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityLookup.ContainsKey($Name)) {
                $EntityLookup[$Name] = $Entity
            }
        }
    }

    # Get enriched currency items with owner classification
    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive -IncludeDeleted -EntityLookup $EntityLookup

    # Apply filters
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

    # Get transfer entries for transaction volume
    $TransferEntries = @()
    if ($Sessions -and $Sessions.Count -gt 0) {
        $TransferEntries = @(Get-SessionDirectiveEntries -Sessions $Sessions -DirectiveName 'Transfers')
    }

    # Build snapshot data
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

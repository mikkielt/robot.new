<#
    .SYNOPSIS
    Economic timeline report — monthly supply and transaction trends over a date range.

    .DESCRIPTION
    Iterates month boundaries between MinDate and MaxDate, computing economic snapshot
    data for each month using Get-EntityState with temporal filtering. Returns an array
    of monthly data points for trend analysis.

    Dot-sources currency-helpers.ps1, temporal-helpers.ps1, and economy-helpers.ps1.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"
. "$script:ModuleRoot/private/temporal-helpers.ps1"
. "$script:ModuleRoot/private/reporting-helpers.ps1"
. "$script:ModuleRoot/private/economy-helpers.ps1"

function Get-EconomicTimeline {
    <#
        .SYNOPSIS
        Generates monthly economic data points over a date range for trend analysis.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched raw entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(Mandatory, HelpMessage = "Start date for timeline")]
        [datetime]$MinDate,

        [Parameter(Mandatory, HelpMessage = "End date for timeline")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Scope to a specific owner entity")]
        [string]$Entity,

        [Parameter(HelpMessage = "Scope to a specific denomination")]
        [string]$Denomination,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-Entity
    }
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session
    }

    $Timeline = [System.Collections.Generic.List[object]]::new()

    # Iterate month boundaries
    $Current = [datetime]::new($MinDate.Year, $MinDate.Month, 1)
    $EndBoundary = [datetime]::new($MaxDate.Year, $MaxDate.Month, 1).AddMonths(1).AddDays(-1)

    while ($Current -le $EndBoundary) {
        $MonthEnd = $Current.AddMonths(1).AddDays(-1)
        $EffectiveDate = if ($MonthEnd -gt $MaxDate) { $MaxDate } else { $MonthEnd }

        # Get entity state at this point in time (fresh copy per iteration since Get-EntityState mutates)
        $MonthEntities = Get-Entity -ActiveOn $EffectiveDate
        if (-not $MonthEntities) { $MonthEntities = @() }

        $SessionArgs = @{ ActiveOn = $EffectiveDate; Quiet = $true }
        if ($Sessions -and $Sessions.Count -gt 0) { $SessionArgs['Sessions'] = $Sessions }

        $MonthState = @()
        if ($MonthEntities.Count -gt 0) {
            $MonthState = Get-EntityState -Entities $MonthEntities @SessionArgs
        }
        if (-not $MonthState) { $MonthState = @() }

        # Build entity lookup
        $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($E in $MonthState) {
            foreach ($Name in $E.Names) {
                if (-not $EntityLookup.ContainsKey($Name)) {
                    $EntityLookup[$Name] = $E
                }
            }
        }

        # Get enriched currency items
        $CurrencyItems = @()
        if ($MonthState.Count -gt 0) {
            $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $MonthState -IncludeInactive -EntityLookup $EntityLookup
        }
        if (-not $CurrencyItems) { $CurrencyItems = @() }

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
        if ($Entity) {
            $Filtered = [System.Collections.Generic.List[object]]::new()
            foreach ($Item in $CurrencyItems) {
                if ($Item.Owner -and [string]::Equals($Item.Owner, $Entity, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Filtered.Add($Item)
                }
            }
            $CurrencyItems = @($Filtered)
        }

        # Count transfers in this month
        $MonthStart = $Current
        $TransferEntries = @()
        if ($Sessions -and $Sessions.Count -gt 0) {
            $TransferEntries = @(Get-SessionDirectiveEntries -Sessions $Sessions -DirectiveName 'Transfers' -MinDate $MonthStart -MaxDate $EffectiveDate)
        }

        # Build snapshot data for this month
        $Data = New-EconomicSnapshotData -CurrencyItems $CurrencyItems -TransferEntries $TransferEntries

        $Timeline.Add([PSCustomObject]@{
            Month                = $Current.ToString('yyyy-MM')
            TotalSupplyKogi      = $Data.TotalSupplyKogi
            PhysicalSupplyKogi   = $Data.PhysicalSupplyKogi
            VirtualSupplyKogi    = $Data.VirtualSupplyKogi
            SupplyByDenomination = $Data.SupplyByDenomination
            TransferCount        = $Data.TransactionVolume
        })

        $Current = $Current.AddMonths(1)
    }

    return @($Timeline)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

<#
    .SYNOPSIS
    Reports currency holdings across the entity system.

    .DESCRIPTION
    Filters entities to currency items (Przedmiot with @generyczne_nazwy matching
    a known denomination) and produces a structured report. Supports filtering by
    owner, denomination, inclusion of virtual/inactive holdings, temporal queries,
    and base-unit conversion for cross-denomination comparison.

    Dot-sources currency-helpers.ps1 for denomination constants and identification.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"

function Get-CurrencyReport {
    <#
        .SYNOPSIS
        View currency holdings across the system with optional filters.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState or Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Filter by owner entity name")]
        [string]$Owner,

        [Parameter(HelpMessage = "Filter by denomination (e.g. 'Korony Elanckie', 'koron', 'tal')")]
        [string]$Denomination,

        [Parameter(HelpMessage = "Include virtual-only holdings (NPC/org treasuries). Default: all entities.")]
        [switch]$IncludeVirtual,

        [Parameter(HelpMessage = "Include Nieaktywny entities")]
        [switch]$IncludeInactive,

        [Parameter(HelpMessage = "Temporal filter for balance state")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Include full QuantityHistory timeline")]
        [switch]$ShowHistory,

        [Parameter(HelpMessage = "Convert all amounts to Kogi equivalent for comparison")]
        [switch]$AsBaseUnit,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $Entities) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }

    # Resolve denomination filter
    $DenomFilter = $null
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
        if (-not $DenomFilter) {
            Write-RobotWarning "[WARN Get-CurrencyReport] Unknown denomination filter: '$Denomination'"
            return @()
        }
    }

    $Report = [System.Collections.Generic.List[object]]::new()

    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive:$IncludeInactive

    foreach ($Item in $CurrencyItems) {
        # Denomination filter
        if ($DenomFilter -and $Item.Denomination.Name -ne $DenomFilter.Name) { continue }

        # Owner filter
        if ($Owner) {
            if (-not $Item.Owner -or -not [string]::Equals($Item.Owner, $Owner, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }

        # Determine owner type
        $OwnerType = if ($Item.Owner) { 'Owner' } elseif ($Item.Location) { 'Location' } else { 'Unowned' }

        # Compute base unit value if requested
        $BaseUnitValue = $null
        if ($AsBaseUnit) {
            $BaseUnitValue = $Item.Quantity * $Item.Denomination.Multiplier
        }

        # Determine last change date from QuantityHistory
        $LastChangeDate = $null
        if ($Item.Entity.QuantityHistory -and $Item.Entity.QuantityHistory.Count -gt 0) {
            $LastEntry = $Item.Entity.QuantityHistory[-1]
            $LastChangeDate = $LastEntry.ValidFrom
        }

        # Status flags
        $Warnings = [System.Collections.Generic.List[string]]::new()
        if ($Item.Quantity -lt 0) {
            $Warnings.Add('NegativeBalance')
        }
        if ($LastChangeDate) {
            $StaleThreshold = if ($ActiveOn) { $ActiveOn.AddMonths(-3) } else { [datetime]::Now.AddMonths(-3) }
            if ($LastChangeDate -lt $StaleThreshold -and $Item.Owner) {
                $Warnings.Add('StaleBalance')
            }
        }

        $ReportEntry = [PSCustomObject]@{
            EntityName     = $Item.Entity.Name
            Denomination   = $Item.Denomination.Name
            DenomShort     = $Item.Denomination.Short
            Tier           = $Item.Denomination.Tier
            Owner          = $Item.Owner
            Location       = $Item.Location
            OwnerType      = $OwnerType
            Balance        = $Item.Quantity
            BaseUnitValue  = $BaseUnitValue
            Status         = $Item.Status
            LastChangeDate = $LastChangeDate
            Warnings       = $Warnings.ToArray()
        }

        if ($ShowHistory -and $Item.Entity.QuantityHistory) {
            $ReportEntry | Add-Member -NotePropertyName 'History' -NotePropertyValue @($Item.Entity.QuantityHistory)
        }

        $Report.Add($ReportEntry)
    }

    return @($Report)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

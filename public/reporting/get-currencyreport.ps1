<#
    .SYNOPSIS
    Reports currency holdings across the entity system.

    .DESCRIPTION
    Get-CurrencyReport filters entities to currency items (Przedmiot entities
    whose @generyczne_nazwy matches a known denomination) and produces a
    structured report with optional filtering by owner, denomination,
    activity status, and temporal state.

    Processing pipeline:
    1. Fetch entities via Get-EntityState (with optional -ActiveOn temporal filter)
    2. Resolve optional denomination filter via Resolve-CurrencyDenomination
    3. Extract currency items via Get-CurrencyEntitiesFiltered
    4. Apply denomination and owner filters
    5. Classify owner type: 'Owner' (has @nale¿y_do), 'Location' (placed at
       @lokacja only), or 'Unowned' (neither)
    6. Optionally convert to base unit (Kogi) using denomination multiplier
    7. Compute staleness warning: balance unchanged for >3 months on owned items
    8. Attach QuantityHistory timeline when -ShowHistory is set

    Each report entry includes Balance (current quantity), Denomination
    metadata (Name, Short, Tier), owner/location context, and a Warnings
    array with diagnostic flags ('NegativeBalance', 'StaleBalance').

    The StaleBalance threshold is 3 months relative to -ActiveOn (if set)
    or current time, flagging owned items whose last QuantityHistory entry
    predates the threshold.

    Dot-sources currency-helpers.ps1 for denomination constants,
    Resolve-CurrencyDenomination, and Get-CurrencyEntitiesFiltered.
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

    # Map user-supplied denomination string (partial/short form) to canonical denomination
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
        if (-not (Test-CurrencyDenominationMatch -DenominationName $Item.Denomination.Name -DenomFilter $DenomFilter)) { continue }
        if (-not (Test-CurrencyOwnerMatch -EntityOwner $Item.Owner -FilterOwner $Owner)) { continue }

        # Classify ownership: direct owner takes precedence over location-only placement
        $OwnerType = if ($Item.Owner) { 'Owner' } elseif ($Item.Location) { 'Location' } else { 'Unowned' }

        # Convert to Kogi base unit for cross-denomination comparison
        $BaseUnitValue = $null
        if ($AsBaseUnit) {
            $BaseUnitValue = $Item.Quantity * $Item.Denomination.Multiplier
        }

        # Extract most recent change date for staleness detection
        $LastChangeDate = $null
        if ($Item.Entity.QuantityHistory -and $Item.Entity.QuantityHistory.Count -gt 0) {
            $LastEntry = $Item.Entity.QuantityHistory[-1]
            $LastChangeDate = $LastEntry.ValidFrom
        }

        # Diagnostic flags: negative balance (data error) and stale balance (no
        # changes in 3+ months on owned items, may indicate forgotten bookkeeping)
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

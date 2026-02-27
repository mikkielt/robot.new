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

. "$PSScriptRoot/currency-helpers.ps1"

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
        [switch]$AsBaseUnit
    )

    if (-not $Entities) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }

    # Resolve denomination filter
    $DenomFilter = $null
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
        if (-not $DenomFilter) {
            [System.Console]::Error.WriteLine("[WARN Get-CurrencyReport] Unknown denomination filter: '$Denomination'")
            return @()
        }
    }

    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($Entity in $Entities) {
        if (-not (Test-IsCurrencyEntity -Entity $Entity)) { continue }

        # Status filter
        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        if ($Status -eq 'Usunięty') { continue }
        if ($Status -eq 'Nieaktywny' -and -not $IncludeInactive) { continue }

        # Denomination filter
        $EntityDenom = $null
        foreach ($GN in $Entity.GenericNames) {
            $Resolved = Resolve-CurrencyDenomination -Name $GN
            if ($Resolved) { $EntityDenom = $Resolved; break }
        }
        if (-not $EntityDenom) { continue }
        if ($DenomFilter -and $EntityDenom.Name -ne $DenomFilter.Name) { continue }

        # Owner filter
        $EntityOwner = $Entity.Owner
        $EntityLocation = $Entity.Location
        if ($Owner) {
            if (-not $EntityOwner -or -not [string]::Equals($EntityOwner, $Owner, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }

        # Determine owner type
        $OwnerType = if ($EntityOwner) { 'Owner' } elseif ($EntityLocation) { 'Location' } else { 'Unowned' }

        # Current balance
        $CurrentQty = if ($Entity.Quantity) { $Entity.Quantity } else { '0' }
        [int]$QtyInt = 0
        [void][int]::TryParse($CurrentQty, [ref]$QtyInt)

        # Compute base unit value if requested
        $BaseUnitValue = $null
        if ($AsBaseUnit) {
            $BaseUnitValue = $QtyInt * $EntityDenom.Multiplier
        }

        # Determine last change date from QuantityHistory
        $LastChangeDate = $null
        if ($Entity.QuantityHistory -and $Entity.QuantityHistory.Count -gt 0) {
            $LastEntry = $Entity.QuantityHistory[-1]
            $LastChangeDate = $LastEntry.ValidFrom
        }

        # Status flags
        $Warnings = [System.Collections.Generic.List[string]]::new()
        if ($QtyInt -lt 0) {
            $Warnings.Add('NegativeBalance')
        }
        if ($LastChangeDate) {
            $StaleThreshold = if ($ActiveOn) { $ActiveOn.AddMonths(-3) } else { [datetime]::Now.AddMonths(-3) }
            if ($LastChangeDate -lt $StaleThreshold -and $EntityOwner) {
                $Warnings.Add('StaleBalance')
            }
        }

        $ReportEntry = [PSCustomObject]@{
            EntityName     = $Entity.Name
            Denomination   = $EntityDenom.Name
            DenomShort     = $EntityDenom.Short
            Tier           = $EntityDenom.Tier
            Owner          = $EntityOwner
            Location       = $EntityLocation
            OwnerType      = $OwnerType
            Balance        = $QtyInt
            BaseUnitValue  = $BaseUnitValue
            Status         = $Status
            LastChangeDate = $LastChangeDate
            Warnings       = $Warnings.ToArray()
        }

        if ($ShowHistory -and $Entity.QuantityHistory) {
            $ReportEntry | Add-Member -NotePropertyName 'History' -NotePropertyValue @($Entity.QuantityHistory)
        }

        $Report.Add($ReportEntry)
    }

    return @($Report)
}

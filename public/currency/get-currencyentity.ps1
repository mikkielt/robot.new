<#
    .SYNOPSIS
    Queries currency entities with filtering by owner, denomination, and name.

    .DESCRIPTION
    This file contains Get-CurrencyEntity which wraps Get-EntityState output
    with currency identification logic to return currency-enriched objects.

    Processing pipeline:
    1. Iterates all entities from Get-EntityState (or pre-fetched -Entities)
    2. Filters to Przedmiot entities identified as currency via Test-IsCurrencyEntity
    3. Resolves denomination by matching @generyczne_nazwy against known denominations
    4. Applies optional -Owner, -Denomination, -Name filters
    5. Excludes Nieaktywny/Usunięty entities unless -IncludeInactive is set
    6. Parses @ilość into integer balance and enriches output with denomination metadata

    Returns an array of enriched PSCustomObjects with EntityName, Denomination,
    DenomShort, Tier, Owner, Location, Balance, and Status properties.

    Dot-sources currency-helpers.ps1 for Resolve-CurrencyDenomination,
    Test-IsCurrencyEntity, Test-CurrencyDenominationMatch, and
    Test-CurrencyOwnerMatch.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"

function Get-CurrencyEntity {
    <#
        .SYNOPSIS
        Queries currency entities with optional filtering.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by owner entity name")]
        [string]$Owner,

        [Parameter(HelpMessage = "Filter by denomination (e.g. 'Korony', 'tal', 'Kogi Skeltvorskie')")]
        [string]$Denomination,

        [Parameter(HelpMessage = "Filter by entity name")]
        [string]$Name,

        [Parameter(HelpMessage = "Include Nieaktywny and Usunięty entities")]
        [switch]$IncludeInactive,

        [Parameter(HelpMessage = "Temporal filter for balance state")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity or Get-EntityState")]
        [object[]]$Entities
    )

    if (-not $Entities) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }

    # Normalize denomination stem (e.g. "tal" -> Talary) before filtering
    $DenomFilter = $null
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
        if (-not $DenomFilter) {
            throw "Unknown currency denomination: '$Denomination'. Use Korony/Talary/Kogi or a recognized stem."
        }
    }

    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($Entity in $Entities) {
        if (-not (Test-IsCurrencyEntity -Entity $Entity)) { continue }

        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            if (-not [string]::Equals($Entity.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }

        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }  # default: active
        if (-not $IncludeInactive) {
            if ($Status -eq 'Usunięty' -or $Status -eq 'Nieaktywny') { continue }
        }

        # Match @generyczne_nazwy against known denomination registry
        $EntityDenom = $null
        foreach ($GN in $Entity.GenericNames) {
            $Resolved = Resolve-CurrencyDenomination -Name $GN
            if ($Resolved) { $EntityDenom = $Resolved; break }
        }
        if (-not $EntityDenom) { continue }

        if (-not (Test-CurrencyDenominationMatch -DenominationName $EntityDenom.Name -DenomFilter $DenomFilter)) { continue }

        $EntityOwner = $Entity.Owner
        if (-not (Test-CurrencyOwnerMatch -EntityOwner $EntityOwner -FilterOwner $Owner)) { continue }

        # Parse @ilość into integer balance (defaults to 0 if absent or unparseable)
        $CurrentQty = if ($Entity.Quantity) { $Entity.Quantity } else { '0' }
        [int]$Balance = 0
        [void][int]::TryParse($CurrentQty, [ref]$Balance)

        $Results.Add([PSCustomObject]@{
            EntityName   = $Entity.Name
            Denomination = $EntityDenom.Name
            DenomShort   = $EntityDenom.Short
            Tier         = $EntityDenom.Tier
            Owner        = $EntityOwner
            Location     = $Entity.Location
            Balance      = $Balance
            Status       = $Status
        })
    }

    return @($Results)
}

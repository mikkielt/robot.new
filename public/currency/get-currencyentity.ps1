<#
    .SYNOPSIS
    Queries currency entities with filtering by owner, denomination, and name.

    .DESCRIPTION
    This file contains Get-CurrencyEntity which wraps Get-Entity + currency
    identification logic to return currency-enriched objects. Filters to
    Przedmiot entities whose @generyczne_nazwy match a known denomination.

    Excludes Nieaktywny/Usunięty entities unless -IncludeInactive is set.
    Returns enriched objects with balance, denomination metadata, and tier.

    Dot-sources currency-helpers.ps1.
#>

# Dot-source helpers
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

    # Resolve denomination filter
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

        # Name filter
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            if (-not [string]::Equals($Entity.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }

        # Status filter
        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        if (-not $IncludeInactive) {
            if ($Status -eq 'Usunięty' -or $Status -eq 'Nieaktywny') { continue }
        }

        # Resolve entity denomination
        $EntityDenom = $null
        foreach ($GN in $Entity.GenericNames) {
            $Resolved = Resolve-CurrencyDenomination -Name $GN
            if ($Resolved) { $EntityDenom = $Resolved; break }
        }
        if (-not $EntityDenom) { continue }

        # Denomination filter
        if ($DenomFilter -and $EntityDenom.Name -ne $DenomFilter.Name) { continue }

        # Owner filter
        $EntityOwner = $Entity.Owner
        if (-not [string]::IsNullOrWhiteSpace($Owner)) {
            if (-not $EntityOwner -or -not [string]::Equals($EntityOwner, $Owner, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }

        # Parse balance
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

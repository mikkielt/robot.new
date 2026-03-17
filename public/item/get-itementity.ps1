<#
    .SYNOPSIS
    Queries Przedmiot (item) entities with filtering and enrichment.

    .DESCRIPTION
    This file contains Get-ItemEntity which wraps Get-EntityState output
    with item identification and enrichment logic.

    Processing pipeline:
    1. Fetches entities via Get-EntityState (or uses pre-fetched -Entities)
    2. Builds an entity-by-name lookup for owner type resolution
    3. Delegates to Get-ItemEntitiesFiltered (item-helpers.ps1) which:
       - Filters to Przedmiot entities with status/owner/location/name gates
       - Classifies currency vs non-currency via denomination matching
       - Resolves owner type (Physical/Virtual/Unknown)
       - Parses @ilość into integer quantity (defaults to 1)
    4. Returns enriched PSCustomObjects with EntityName, Owner, OwnerType,
       Location, Quantity, Status, IsCurrency, Denomination, LastChangeDate

    By default excludes currency entities (use -IncludeCurrency to include).
    Excludes Usunięty entities by default (use -IncludeDeleted).
    Excludes Nieaktywny entities by default (use -IncludeInactive).

    Dot-sources item-helpers.ps1 for Get-ItemEntitiesFiltered and
    currency-helpers.ps1 for denomination names and Resolve-CurrencyDenomination.
#>

function Get-ItemEntity {
    <#
        .SYNOPSIS
        Queries Przedmiot (item) entities with optional filtering and enrichment.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by @należy_do owner name")]
        [string]$Owner,

        [Parameter(HelpMessage = "Filter by @lokacja location name")]
        [string]$Location,

        [Parameter(HelpMessage = "Filter by entity name (substring, case-insensitive)")]
        [string]$Name,

        [Parameter(HelpMessage = "Include Nieaktywny entities")]
        [switch]$IncludeInactive,

        [Parameter(HelpMessage = "Include Usunięty entities")]
        [switch]$IncludeDeleted,

        [Parameter(HelpMessage = "Include currency entities in results")]
        [switch]$IncludeCurrency,

        [Parameter(HelpMessage = "Filter temporally-scoped data to entries active on this date")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity or Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }

    . "$script:ModuleRoot/private/item-helpers.ps1"
    . "$script:ModuleRoot/private/currency-helpers.ps1"

    # Entity-by-name lookup for owner type resolution
    $EntityByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        if ($Entity.Name -and -not $EntityByName.ContainsKey($Entity.Name)) {
            $EntityByName[$Entity.Name] = $Entity
        }
    }

    $DenomNames = @($script:CurrencyDenominations | ForEach-Object { $_.Name })

    $ExcludeCurrency = -not $IncludeCurrency

    $Items = Get-ItemEntitiesFiltered -Entities $Entities -DenominationNames $DenomNames `
        -OwnerFilter $Owner -LocationFilter $Location -NameFilter $Name `
        -IncludeInactive:$IncludeInactive -IncludeDeleted:$IncludeDeleted `
        -ExcludeCurrency:$ExcludeCurrency -EntityLookup $EntityByName

    $Results = [System.Collections.Generic.List[object]]::new($Items.Count)

    foreach ($Item in $Items) {
        # Compute LastChangeDate from available history lists
        $LastDate = $null
        $Entity = $Item.Entity
        foreach ($History in @($Entity.OwnerHistory, $Entity.LocationHistory, $Entity.StatusHistory, $Entity.QuantityHistory)) {
            if ($History -and $History.Count -gt 0) {
                for ($i = $History.Count - 1; $i -ge 0; $i--) {
                    $VF = $History[$i].ValidFrom
                    if ($VF -and ($null -eq $LastDate -or $VF -gt $LastDate)) {
                        $LastDate = $VF
                    }
                }
            }
        }

        $Results.Add([PSCustomObject]@{
            EntityName     = $Item.EntityName
            Owner          = $Item.Owner
            OwnerType      = $Item.OwnerType
            Location       = $Item.Location
            Quantity       = $Item.Quantity
            Status         = $Item.Status
            IsCurrency     = $Item.IsCurrency
            Denomination   = $Item.Denomination
            LastChangeDate = $LastDate
        })
    }

    return @($Results)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

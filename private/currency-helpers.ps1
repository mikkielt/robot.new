<#
    .SYNOPSIS
    Currency denomination constants, conversion utilities, and identification helpers.

    .DESCRIPTION
    Non-exported helper functions dot-sourced by currency commands (Get-CurrencyReport,
    Test-CurrencyReconciliation) and Get-EntityState (@Transfer expansion).

    Helpers:
    - ConvertTo-CurrencyBaseUnit:      convert any denomination amount to Kogi (base unit)
    - ConvertFrom-CurrencyBaseUnit:    convert Kogi amount to highest-denomination breakdown
    - Resolve-CurrencyDenomination:    resolve colloquial/stem denomination name to canonical
    - Test-CurrencyOwnerMatch:         test whether a currency item's owner matches a filter
    - Test-CurrencyDenominationMatch:  test whether a denomination name matches a filter
    - Test-IsCurrencyEntity:           check if an entity is a currency entity
    - Build-CurrencyEntityLookup:      delegates to Build-ItemLookup, returns ByDenomAndOwner index
    - Find-CurrencyEntity:             delegates to Find-ItemByDenomAndOwner with pre-built lookup
    - Resolve-CurrencyOwnerType:       delegates to Resolve-ItemOwnerType (item-helpers.ps1)
    - Get-CurrencyEntitiesFiltered:    delegates to Get-ItemEntitiesFiltered with currencyOnly flag
    - Get-DenominationNames:           returns canonical denomination name array for item layer

    Module-level data:
    - $script:CurrencyDenominations:   canonical denomination definitions with exchange rates (Korony/Talary/Kogi)
    - $script:DenomLookup:             precomputed hashtable mapping all name variants to denomination objects

    The currency system uses a three-tier denomination model: Korony Elanckie (gold,
    10000 Kogi), Talary Hirońskie (silver, 100 Kogi), Kogi Skeltvorskie (copper, 1 Kogi).
    All cross-denomination arithmetic is done in the Kogi base unit.

    Currency entities are Przedmiot-type entities with @generyczne_nazwy matching a
    denomination name. Owner classification (Physical/Virtual/Unknown) determines
    whether currency is backed by Margonem game items or exists only in the ledger.

    $script:DenomLookup is built once at dot-source time, providing O(1) resolution
    for canonical names, short names, and stem prefixes ("kor" -> Korony Elanckie).

    Lookup, find, owner type, and filter operations delegate to the unified item
    layer (item-helpers.ps1) which handles both currency and non-currency Przedmiot
    entities. Currency-helpers adds denomination resolution, denomination-specific
    enrichment, and the currencyOnly filter flag on top of the generic item layer.
#>

# Canonical denomination definitions
# Multiplier = how many Kogi (base unit) one unit of this denomination is worth
$script:CurrencyDenominations = @(
    [PSCustomObject]@{
        Name       = 'Korony Elanckie'
        Short      = 'Korony'
        Tier       = 'Gold'
        Multiplier = 10000
        Stems      = @('kor')
    }
    [PSCustomObject]@{
        Name       = 'Talary Hirońskie'
        Short      = 'Talary'
        Tier       = 'Silver'
        Multiplier = 100
        Stems      = @('tal')
    }
    [PSCustomObject]@{
        Name       = 'Kogi Skeltvorskie'
        Short      = 'Kogi'
        Tier       = 'Copper'
        Multiplier = 1
        Stems      = @('kog')
    }
)

function ConvertTo-CurrencyBaseUnit {
    param(
        [Parameter(Mandatory)]
        [int]$Amount,

        [Parameter(Mandatory)]
        [string]$Denomination
    )

    $Resolved = Resolve-CurrencyDenomination -Name $Denomination
    if (-not $Resolved) {
        throw "Unknown currency denomination: '$Denomination'"
    }

    return $Amount * $Resolved.Multiplier
}

function ConvertFrom-CurrencyBaseUnit {
    param(
        [Parameter(Mandatory)]
        [int]$Amount
    )

    $Remaining = [math]::Abs($Amount)
    $Sign = if ($Amount -lt 0) { -1 } else { 1 }

    $Korony = [math]::Floor($Remaining / 10000)    # 1 Korona = 10000 Kogi
    $Remaining = $Remaining % 10000

    $Talary = [math]::Floor($Remaining / 100)      # 1 Talar = 100 Kogi
    $Kogi = $Remaining % 100

    return @{
        Korony = $Sign * $Korony
        Talary = $Sign * $Talary
        Kogi   = $Sign * $Kogi
    }
}

# Precomputed denomination lookup table — built once at dot-source time, O(1) exact match
$script:DenomLookup = @{}
foreach ($D in $script:CurrencyDenominations) {
    $script:DenomLookup[$D.Name.ToLowerInvariant()] = $D
    $script:DenomLookup[$D.Short.ToLowerInvariant()] = $D
    foreach ($Stem in $D.Stems) {
        $script:DenomLookup[$Stem] = $D
    }
}

function Resolve-CurrencyDenomination {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $Lower = $Name.Trim().ToLowerInvariant()

    # O(1) exact match on canonical name, short name, or stem
    $Result = $script:DenomLookup[$Lower]
    if ($Result) { return $Result }

    # Stem prefix fallback (for partial names like "koron" matching "kor" stem)
    foreach ($Key in $script:DenomLookup.Keys) {
        if ($Lower.StartsWith($Key)) { return $script:DenomLookup[$Key] }
    }

    return $null
}

function Test-CurrencyOwnerMatch {
    param(
        [string]$EntityOwner,
        [string]$FilterOwner
    )

    if (-not $FilterOwner) { return $true }
    return ($EntityOwner -and
        [string]::Equals($EntityOwner, $FilterOwner, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-CurrencyDenominationMatch {
    param(
        [string]$DenominationName,
        [object]$DenomFilter
    )

    if (-not $DenomFilter) { return $true }
    return [string]::Equals($DenominationName, $DenomFilter.Name, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsCurrencyEntity {
    param(
        [Parameter(Mandatory)]
        [object]$Entity
    )

    if (-not $Entity.GenericNames -or $Entity.GenericNames.Count -eq 0) {
        return $false
    }

    foreach ($GN in $Entity.GenericNames) {
        $Resolved = Resolve-CurrencyDenomination -Name $GN
        if ($Resolved) { return $true }
    }

    return $false
}

function Build-CurrencyEntityLookup {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entities
    )

    # Delegates to unified item layer — returns the ByDenomAndOwner index
    . "$script:ModuleRoot/private/item-helpers.ps1"
    $Lookup = Build-ItemLookup -Entities $Entities -DenominationNames (Get-DenominationNames)
    return $Lookup.ByDenomAndOwner
}

function Find-CurrencyEntity {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entities,

        [Parameter(Mandatory)]
        [string]$Denomination,

        [Parameter(Mandatory)]
        [string]$OwnerName,

        [System.Collections.Generic.Dictionary[string, object]]$CurrencyLookup
    )

    $ResolvedDenom = Resolve-CurrencyDenomination -Name $Denomination
    if (-not $ResolvedDenom) { return $null }

    # If pre-built lookup provided, use it directly (same key format as before)
    if ($CurrencyLookup) {
        $Key = "$($ResolvedDenom.Name)|$OwnerName"
        $Found = $null
        if ($CurrencyLookup.TryGetValue($Key, [ref]$Found)) {
            return $Found
        }
        return $null
    }

    # No pre-built lookup — delegate to item layer
    . "$script:ModuleRoot/private/item-helpers.ps1"
    $Lookup = Build-ItemLookup -Entities $Entities -DenominationNames (Get-DenominationNames)
    return Find-ItemByDenomAndOwner -Lookup $Lookup -Denomination $ResolvedDenom.Name -OwnerName $OwnerName
}

function Resolve-CurrencyOwnerType {
    param(
        [Parameter(Mandatory)]
        [string]$OwnerName,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, object]]$EntityLookup
    )

    # Delegates to unified item layer — identical classification logic
    . "$script:ModuleRoot/private/item-helpers.ps1"
    return Resolve-ItemOwnerType -OwnerName $OwnerName -EntityLookup $EntityLookup
}

function Get-CurrencyEntitiesFiltered {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entities,

        [switch]$IncludeInactive,

        [switch]$IncludeDeleted,

        [System.Collections.Generic.Dictionary[string, object]]$EntityLookup
    )

    # Delegates to unified item layer with currencyOnly filter, then adds
    # denomination object enrichment (the only currency-specific step)
    . "$script:ModuleRoot/private/item-helpers.ps1"
    $DenomNames = Get-DenominationNames

    $Items = Get-ItemEntitiesFiltered -Entities $Entities -DenominationNames $DenomNames `
        -IncludeInactive:$IncludeInactive -IncludeDeleted:$IncludeDeleted `
        -CurrencyOnly -EntityLookup $EntityLookup

    $Result = [System.Collections.Generic.List[object]]::new()
    foreach ($Item in $Items) {
        # Resolve denomination name to full denomination object (with Multiplier, Short, Tier)
        $EntityDenom = if ($Item.Denomination) { Resolve-CurrencyDenomination -Name $Item.Denomination } else { $null }
        if (-not $EntityDenom) { continue }

        $QtyStr = if ($Item.Entity.Quantity) { $Item.Entity.Quantity } else { '0' }
        [int]$QtyInt = 0
        [void][int]::TryParse($QtyStr, [ref]$QtyInt)

        # Preserve original behavior: OwnerCategory is $null when EntityLookup not provided
        $OwnerCategory = if ($EntityLookup) { $Item.OwnerType } else { $null }

        $Result.Add([PSCustomObject]@{
            Entity        = $Item.Entity
            Denomination  = $EntityDenom
            Owner         = $Item.Owner
            Location      = $Item.Location
            Quantity      = $QtyInt
            Status        = $Item.Status
            OwnerCategory = $OwnerCategory
        })
    }

    return @($Result)
}

function Get-DenominationNames {
    return @($script:CurrencyDenominations | ForEach-Object { $_.Name })
}

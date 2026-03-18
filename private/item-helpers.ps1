<#
    .SYNOPSIS
    Unified item layer helpers for ALL Przedmiot entities (including currency).

    .DESCRIPTION
    Non-exported helper functions dot-sourced by get-entitystate.ps1 (@Transfer expansion),
    currency-helpers.ps1 (delegation), and get-itementity.ps1 (item query). This is the
    unified item layer: all Przedmiot entity operations (including currency) route through
    these helpers, replacing the former currency-only lookup in currency-helpers.ps1.

    Build-ItemLookup performs a single O(n) pass over all entities to produce two
    Dictionary[string, object] indexes simultaneously:
    - ByNameAndOwner:  key = "{entityName}|{owner}" — indexes ALL name variants
      (primary Name, aliases from Names collection, generic names) for item @Transfer
    - ByDenomAndOwner: key = "{denominationName}|{owner}" — indexes entities whose
      GenericNames match a known currency denomination for currency @Transfer

    Find helpers perform O(1) dictionary lookups against the pre-built indexes.
    Get-ItemEntitiesFiltered runs a single pass with six filter gates (type, status,
    currency, owner, location, name substring) and enriches matching entities with
    owner type classification, quantity parsing, and currency detection.

    Helpers:
    - Build-ItemLookup:          build dual-index lookup (ByNameAndOwner + ByDenomAndOwner)
                                 for O(1) item/currency entity resolution in a single pass
    - Find-ItemByNameAndOwner:   O(1) lookup by entity name + owner (for item @Transfer)
    - Find-ItemByDenomAndOwner:  O(1) lookup by denomination + owner (for currency @Transfer)
    - Test-IsItemEntity:         returns $true for ALL Przedmiot entities (including currency)
    - Resolve-ItemOwnerType:     classify owner as Physical/Virtual/Unknown by entity type
    - Get-ItemEntitiesFiltered:  single-pass filter + enrichment for Przedmiot entities

    Module-level data: none (stateless helpers)

    When Robot.ItemHelper (lib/ItemHelper.cs) is available, Build-ItemLookup, Find-*,
    and Get-ItemEntitiesFiltered delegate to compiled C# — the C# path eliminates
    per-entity PowerShell interpretation overhead and uses typed parallel arrays
    (index/ownerType/quantity/isCurrency/denomination) for the PS layer to assemble
    PSCustomObjects. Falls back to equivalent PowerShell logic when C# is unavailable.
#>

# C# types: Robot.ItemHelper, Robot.ItemLookupResult, Robot.ItemFilterResult (lib/ItemHelper.cs)
# Compiled centrally in Robot.PowerShell.psm1 at module import time.

function Build-ItemLookup {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entities,

        [Parameter(Mandatory)]
        [string[]]$DenominationNames
    )

    # C# fast path
    if (([System.Management.Automation.PSTypeName]'Robot.ItemHelper').Type) {
        return [Robot.ItemHelper]::BuildLookup($Entities, $DenominationNames)
    }

    # PowerShell fallback: single-pass builds both indexes
    $ByNameAndOwner = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ByDenomAndOwner = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $DenomSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($DN in $DenominationNames) { [void]$DenomSet.Add($DN) }

    $ItemCount = 0
    $CurrencyCount = 0

    foreach ($Entity in $Entities) {
        if ($Entity.Type -ne 'Przedmiot') { continue }
        $ItemCount++

        $Owner = $Entity.Owner
        $EntityName = $Entity.Name

        # ByNameAndOwner index — all names (primary + aliases + generic names)
        # for flexible item transfer resolution
        if ($Owner) {
            if ($Entity.Names -and $Entity.Names.Count -gt 0) {
                foreach ($N in $Entity.Names) {
                    if ($N) {
                        $NameKey = "$N|$Owner"
                        if (-not $ByNameAndOwner.ContainsKey($NameKey)) {
                            $ByNameAndOwner[$NameKey] = $Entity
                        }
                    }
                }
            }
            # Also index by primary Name in case Names list is empty
            if ($EntityName) {
                $PrimaryKey = "$EntityName|$Owner"
                if (-not $ByNameAndOwner.ContainsKey($PrimaryKey)) {
                    $ByNameAndOwner[$PrimaryKey] = $Entity
                }
            }
        }

        # ByDenomAndOwner index (currency items only)
        if ($Entity.GenericNames -and $Entity.GenericNames.Count -gt 0) {
            foreach ($GN in $Entity.GenericNames) {
                if ($DenomSet.Contains($GN)) {
                    $CurrencyCount++
                    if ($Owner) {
                        $DenomKey = "$GN|$Owner"
                        if (-not $ByDenomAndOwner.ContainsKey($DenomKey)) {
                            $ByDenomAndOwner[$DenomKey] = $Entity
                        }
                    }
                    break
                }
            }
        }
    }

    return [PSCustomObject]@{
        ByNameAndOwner  = $ByNameAndOwner
        ByDenomAndOwner = $ByDenomAndOwner
        ItemCount       = $ItemCount
        CurrencyCount   = $CurrencyCount
    }
}

function Find-ItemByNameAndOwner {
    param(
        [Parameter(Mandatory)]
        [object]$Lookup,

        [Parameter(Mandatory)]
        [string]$ItemName,

        [Parameter(Mandatory)]
        [string]$OwnerName
    )

    # C# fast path
    if (([System.Management.Automation.PSTypeName]'Robot.ItemHelper').Type -and $Lookup -is [Robot.ItemLookupResult]) {
        return [Robot.ItemHelper]::FindByNameAndOwner($Lookup, $ItemName, $OwnerName)
    }

    # PowerShell fallback
    $Key = "$ItemName|$OwnerName"
    $Found = $null
    if ($Lookup.ByNameAndOwner.TryGetValue($Key, [ref]$Found)) {
        return $Found
    }
    return $null
}

function Find-ItemByDenomAndOwner {
    param(
        [Parameter(Mandatory)]
        [object]$Lookup,

        [Parameter(Mandatory)]
        [string]$Denomination,

        [Parameter(Mandatory)]
        [string]$OwnerName
    )

    # C# fast path
    if (([System.Management.Automation.PSTypeName]'Robot.ItemHelper').Type -and $Lookup -is [Robot.ItemLookupResult]) {
        return [Robot.ItemHelper]::FindByDenominationAndOwner($Lookup, $Denomination, $OwnerName)
    }

    # PowerShell fallback
    $Key = "$Denomination|$OwnerName"
    $Found = $null
    if ($Lookup.ByDenomAndOwner.TryGetValue($Key, [ref]$Found)) {
        return $Found
    }
    return $null
}

function Test-IsItemEntity {
    param(
        [Parameter(Mandatory)]
        [object]$Entity
    )

    return ($Entity.Type -eq 'Przedmiot')
}

function Resolve-ItemOwnerType {
    param(
        [Parameter(Mandatory)]
        [string]$OwnerName,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, object]]$EntityLookup
    )

    if (-not $EntityLookup.ContainsKey($OwnerName)) {
        return 'Unknown'
    }

    $OwnerEntity = $EntityLookup[$OwnerName]
    $OwnerType = if ($OwnerEntity.Type) { $OwnerEntity.Type } else { $null }

    switch ($OwnerType) {
        'Postać'  { return 'Physical' }
        'NPC'     { return 'Virtual' }
        'Grupa'   { return 'Virtual' }
        'Gracz'   { return 'Virtual' }
        default   { return 'Unknown' }
    }
}

function Get-ItemEntitiesFiltered {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entities,

        [string[]]$DenominationNames,

        [string]$OwnerFilter,
        [string]$LocationFilter,
        [string]$NameFilter,

        [switch]$IncludeInactive,
        [switch]$IncludeDeleted,
        [switch]$CurrencyOnly,
        [switch]$ExcludeCurrency,

        [System.Collections.Generic.Dictionary[string, object]]$EntityLookup
    )

    # C# fast path
    if (([System.Management.Automation.PSTypeName]'Robot.ItemHelper').Type) {
        $Result = [Robot.ItemHelper]::FilterItems($Entities, $DenominationNames,
            $OwnerFilter, $LocationFilter, $NameFilter,
            [bool]$IncludeInactive, [bool]$IncludeDeleted, [bool]$CurrencyOnly,
            [bool]$ExcludeCurrency, $EntityLookup)

        $Output = [System.Collections.Generic.List[object]]::new($Result.Count)
        for ($i = 0; $i -lt $Result.Count; $i++) {
            $Entity = $Entities[$Result.Indices[$i]]
            $Output.Add([PSCustomObject]@{
                Entity       = $Entity
                EntityName   = $Entity.Name
                Owner        = $Entity.Owner
                OwnerType    = $Result.OwnerTypes[$i]
                Location     = $Entity.Location
                Quantity     = $Result.Quantities[$i]
                Status       = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
                IsCurrency   = $Result.IsCurrency[$i]
                Denomination = $Result.Denominations[$i]
            })
        }
        return @($Output)
    }

    # PowerShell fallback: single-pass filter + enrichment
    $DenomSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($DenominationNames) {
        foreach ($DN in $DenominationNames) { [void]$DenomSet.Add($DN) }
    }

    $Output = [System.Collections.Generic.List[object]]::new()

    foreach ($Entity in $Entities) {
        if ($Entity.Type -ne 'Przedmiot') { continue }

        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        if ($Status -eq 'Usunięty' -and -not $IncludeDeleted) { continue }
        if ($Status -eq 'Nieaktywny' -and -not $IncludeInactive) { continue }

        # Currency classification (single GenericNames walk)
        $IsCurrency = $false
        $DenomName = $null
        if ($Entity.GenericNames -and $Entity.GenericNames.Count -gt 0) {
            foreach ($GN in $Entity.GenericNames) {
                if ($DenomSet.Contains($GN)) {
                    $IsCurrency = $true
                    $DenomName = $GN
                    break
                }
            }
        }

        if ($CurrencyOnly -and -not $IsCurrency) { continue }
        if ($ExcludeCurrency -and $IsCurrency) { continue }

        # Owner filter
        if ($OwnerFilter) {
            if (-not $Entity.Owner -or -not [string]::Equals($Entity.Owner, $OwnerFilter, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Location filter
        if ($LocationFilter) {
            if (-not $Entity.Location -or -not [string]::Equals($Entity.Location, $LocationFilter, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Name filter (substring, case-insensitive)
        if ($NameFilter) {
            if (-not $Entity.Name -or $Entity.Name.IndexOf($NameFilter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }

        # Quantity parsing
        $Qty = 1
        if ($Entity.Quantity) {
            [int]$ParsedQty = 0
            if ([int]::TryParse($Entity.Quantity, [ref]$ParsedQty)) {
                $Qty = $ParsedQty
            }
        }

        # Owner type resolution
        $OwnerType = 'Unknown'
        if ($Entity.Owner -and $EntityLookup) {
            $OwnerType = Resolve-ItemOwnerType -OwnerName $Entity.Owner -EntityLookup $EntityLookup
        }

        $Output.Add([PSCustomObject]@{
            Entity       = $Entity
            EntityName   = $Entity.Name
            Owner        = $Entity.Owner
            OwnerType    = $OwnerType
            Location     = $Entity.Location
            Quantity     = $Qty
            Status       = $Status
            IsCurrency   = $IsCurrency
            Denomination = $DenomName
        })
    }

    return @($Output)
}

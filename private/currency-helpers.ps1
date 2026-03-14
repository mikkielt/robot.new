<#
    .SYNOPSIS
    Currency denomination constants, conversion utilities, and identification helpers.

    .DESCRIPTION
    Non-exported helper functions dot-sourced by currency commands (Get-CurrencyReport,
    Test-CurrencyReconciliation) and Get-EntityState (@Transfer expansion).

    Contains:
    - $CurrencyDenominations:          canonical denomination definitions with exchange rates
    - ConvertTo-CurrencyBaseUnit:      convert any denomination amount to Kogi (base unit)
    - ConvertFrom-CurrencyBaseUnit:    convert Kogi amount to highest-denomination breakdown
    - Resolve-CurrencyDenomination:    resolve colloquial/stem denomination name to canonical
    - Test-IsCurrencyEntity:           check if an entity is a currency entity
    - Build-CurrencyEntityLookup:      pre-build denomination+owner -> entity hashtable
    - Find-CurrencyEntity:             find a currency entity by denomination and owner
    - Resolve-CurrencyOwnerType:       classify owner as Physical/Virtual/Unknown by entity type
    - Get-CurrencyEntitiesFiltered:    identify, filter by status, and enrich currency entities
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
    <#
        .SYNOPSIS
        Converts a denomination amount to Kogi (base unit) for comparison.
    #>
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
    <#
        .SYNOPSIS
        Converts a Kogi (base unit) amount to a denomination breakdown.
        Returns hashtable with Korony, Talary, Kogi keys.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Amount
    )

    $Remaining = [math]::Abs($Amount)
    $Sign = if ($Amount -lt 0) { -1 } else { 1 }

    $Korony = [math]::Floor($Remaining / 10000)
    $Remaining = $Remaining % 10000

    $Talary = [math]::Floor($Remaining / 100)
    $Kogi = $Remaining % 100

    return @{
        Korony = $Sign * $Korony
        Talary = $Sign * $Talary
        Kogi   = $Sign * $Kogi
    }
}

function Resolve-CurrencyDenomination {
    <#
        .SYNOPSIS
        Resolves a colloquial or partial denomination name to its canonical definition.
        Uses stem-based matching: kor->Korony, tal->Talary, kog->Kogi.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $Lower = $Name.Trim().ToLowerInvariant()

    # Exact match on canonical name or short name
    foreach ($Denom in $script:CurrencyDenominations) {
        if ($Lower -eq $Denom.Name.ToLowerInvariant() -or $Lower -eq $Denom.Short.ToLowerInvariant()) {
            return $Denom
        }
    }

    # Stem-based match (kor->Korony, tal->Talary, kog->Kogi)
    foreach ($Denom in $script:CurrencyDenominations) {
        foreach ($Stem in $Denom.Stems) {
            if ($Lower.StartsWith($Stem)) {
                return $Denom
            }
        }
    }

    return $null
}

function Test-IsCurrencyEntity {
    <#
        .SYNOPSIS
        Checks if an entity is a currency entity by examining its GenericNames
        for canonical denomination names.
    #>
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

    $Lookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Entity in $Entities) {
        if (-not $Entity.GenericNames -or $Entity.GenericNames.Count -eq 0) { continue }
        if ($Entity.Type -ne 'Przedmiot') { continue }
        if (-not $Entity.Owner) { continue }

        foreach ($GN in $Entity.GenericNames) {
            $Resolved = Resolve-CurrencyDenomination -Name $GN
            if ($Resolved) {
                $Key = "$($Resolved.Name)|$($Entity.Owner)"
                if (-not $Lookup.ContainsKey($Key)) {
                    $Lookup[$Key] = $Entity
                }
            }
        }
    }

    return $Lookup
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

    $CanonicalName = $ResolvedDenom.Name

    if ($CurrencyLookup) {
        $Key = "$CanonicalName|$OwnerName"
        $Found = $null
        if ($CurrencyLookup.TryGetValue($Key, [ref]$Found)) {
            return $Found
        }
        return $null
    }

    foreach ($Entity in $Entities) {
        if (-not $Entity.GenericNames -or $Entity.GenericNames.Count -eq 0) { continue }
        if ($Entity.Type -ne 'Przedmiot') { continue }

        $HasDenom = $false
        foreach ($GN in $Entity.GenericNames) {
            if ([string]::Equals($GN, $CanonicalName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $HasDenom = $true
                break
            }
        }
        if (-not $HasDenom) { continue }

        # Check owner via OwnerHistory (last active) or Owner property
        if ([string]::Equals($Entity.Owner, $OwnerName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $Entity
        }
    }

    return $null
}

function Resolve-CurrencyOwnerType {
    <#
        .SYNOPSIS
        Classifies a currency owner as Physical, Virtual, or Unknown based on the
        owner entity's type. Postać = Physical (actual Margonem items), NPC/Grupa/Gracz = Virtual.
    #>
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

function Get-CurrencyEntitiesFiltered {
    <#
        .SYNOPSIS
        Identifies currency entities from a collection and returns enriched objects
        with resolved denomination, parsed quantity, and extracted properties.
        When EntityLookup is provided, output includes OwnerCategory classification.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entities,

        [switch]$IncludeInactive,

        [switch]$IncludeDeleted,

        [System.Collections.Generic.Dictionary[string, object]]$EntityLookup
    )

    $Result = [System.Collections.Generic.List[object]]::new()

    foreach ($Entity in $Entities) {
        if (-not (Test-IsCurrencyEntity -Entity $Entity)) { continue }

        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        if ($Status -eq 'Usunięty' -and -not $IncludeDeleted) { continue }
        if ($Status -eq 'Nieaktywny' -and -not $IncludeInactive) { continue }

        $EntityDenom = $null
        foreach ($GN in $Entity.GenericNames) {
            $Resolved = Resolve-CurrencyDenomination -Name $GN
            if ($Resolved) { $EntityDenom = $Resolved; break }
        }
        if (-not $EntityDenom) { continue }

        $QtyStr = if ($Entity.Quantity) { $Entity.Quantity } else { '0' }
        [int]$QtyInt = 0
        [void][int]::TryParse($QtyStr, [ref]$QtyInt)

        $OwnerCategory = $null
        if ($EntityLookup -and $Entity.Owner) {
            $OwnerCategory = Resolve-CurrencyOwnerType -OwnerName $Entity.Owner -EntityLookup $EntityLookup
        }

        $Result.Add([PSCustomObject]@{
            Entity        = $Entity
            Denomination  = $EntityDenom
            Owner         = $Entity.Owner
            Location      = $Entity.Location
            Quantity      = $QtyInt
            Status        = $Status
            OwnerCategory = $OwnerCategory
        })
    }

    return @($Result)
}

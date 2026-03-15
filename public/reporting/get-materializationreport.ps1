<#
    .SYNOPSIS
    Materialization report — physical vs virtual currency breakdown by denomination and player.

    .DESCRIPTION
    Get-MaterializationReport analyzes currency ownership to distinguish
    physical currency (Postac-owned, representing actual Margonem items)
    from virtual currency (NPC/Grupa/Gracz-owned, RP bookkeeping).

    Processing pipeline:
    1. Fetch entities and players if not pre-provided
    2. Build multi-name entity lookup for owner type classification
    3. Build entity status lookup for orphan detection
    4. Build character-to-player mapping (Postac -> Gracz) from player
       data for the player breakdown section
    5. Extract currency items via Get-CurrencyEntitiesFiltered with owner
       classification (OwnerCategory: Physical or Virtual)
    6. Compute three report sections:

    Report sections:
    - DenominationBreakdown: per-denomination totals with Physical/Virtual
      split and PhysicalPct (materialization ratio). Deleted entities are
      excluded to reflect current circulating supply.
    - PlayerBreakdown: per-player physical holdings aggregated across all
      their characters, with per-denomination detail and Kogi-equivalent
      total. Only Physical-category items with mapped character owners.
    - OrphanedPhysical: active currency items owned by Nieaktywny or
      Usuniety Postac entities — these represent in-game items that exist
      on inactive characters and may need coordinator intervention.

    Orphan detection is critical for game economy integrity: when a player
    leaves and their Postac becomes Nieaktywny, any physical currency on
    that character is effectively frozen and should be returned.

    Dot-sources currency-helpers.ps1 for denomination constants and
    Get-CurrencyEntitiesFiltered.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"

function Get-MaterializationReport {
    <#
        .SYNOPSIS
        Reports physical vs virtual currency materialization with orphan detection.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched player list from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Temporal filter for balance state")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }
    if (-not $PSBoundParameters.ContainsKey('Players')) {
        $Players = Get-Player -Entities $Entities
    }

    # Multi-name lookup: maps every known name to its entity for Physical/Virtual classification
    $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityLookup.ContainsKey($Name)) {
                $EntityLookup[$Name] = $Entity
            }
        }
    }

    # Status lookup for orphan detection: identifies Nieaktywny/Usuniety owners
    $EntityStatusByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        $EntityStatusByName[$Entity.Name] = $Status
    }

    # Reverse mapping: character name -> player name for the player breakdown section
    $CharacterToPlayer = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Player in $Players) {
        if ($Player.Characters) {
            foreach ($Char in $Player.Characters) {
                $CharName = if ($Char.Name) { $Char.Name } else { $null }
                if ($CharName) {
                    $CharacterToPlayer[$CharName] = $Player.Name
                }
            }
        }
    }

    # Include inactive items: they still represent circulating supply until deleted
    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive -EntityLookup $EntityLookup

    # ── Denomination Breakdown: Physical vs Virtual split per currency type ──
    $DenomBreakdown = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }

        $DName = $Item.Denomination.Name
        if (-not $DenomBreakdown.ContainsKey($DName)) {
            $DenomBreakdown[$DName] = @{ Total = 0; Physical = 0; Virtual = 0 }
        }
        $DenomBreakdown[$DName].Total += $Item.Quantity
        $Category = if ($Item.OwnerCategory) { $Item.OwnerCategory } else { 'Unknown' }
        if ($Category -eq 'Physical') { $DenomBreakdown[$DName].Physical += $Item.Quantity }
        elseif ($Category -eq 'Virtual') { $DenomBreakdown[$DName].Virtual += $Item.Quantity }
    }

    $DenominationBreakdown = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $DenomBreakdown.GetEnumerator()) {
        $PhysPct = if ($Entry.Value.Total -gt 0) { [math]::Round(100.0 * $Entry.Value.Physical / $Entry.Value.Total, 1) } else { 0.0 }
        $DenominationBreakdown.Add([PSCustomObject]@{
            Denomination = $Entry.Key
            Total        = $Entry.Value.Total
            Physical     = $Entry.Value.Physical
            Virtual      = $Entry.Value.Virtual
            PhysicalPct  = $PhysPct
        })
    }

    # ── Player Breakdown: per-player physical holdings across all characters ──
    $PlayerData = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }
        if ($Item.OwnerCategory -ne 'Physical') { continue }
        if (-not $Item.Owner) { continue }

        # Resolve character -> player; skip items not mapped to any player
        $PlayerName = if ($CharacterToPlayer.ContainsKey($Item.Owner)) { $CharacterToPlayer[$Item.Owner] } else { $null }
        if (-not $PlayerName) { continue }

        if (-not $PlayerData.ContainsKey($PlayerName)) {
            $PlayerData[$PlayerName] = @{
                Characters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                TotalPhysicalKogi = 0
                PerDenomination = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        [void]$PlayerData[$PlayerName].Characters.Add($Item.Owner)
        $BaseValue = $Item.Quantity * $Item.Denomination.Multiplier
        $PlayerData[$PlayerName].TotalPhysicalKogi += $BaseValue

        $DName = $Item.Denomination.Name
        if (-not $PlayerData[$PlayerName].PerDenomination.ContainsKey($DName)) {
            $PlayerData[$PlayerName].PerDenomination[$DName] = 0
        }
        $PlayerData[$PlayerName].PerDenomination[$DName] += $Item.Quantity
    }

    $PlayerBreakdown = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $PlayerData.GetEnumerator()) {
        $PlayerBreakdown.Add([PSCustomObject]@{
            PlayerName       = $Entry.Key
            Characters       = @($Entry.Value.Characters)
            TotalPhysicalKogi = $Entry.Value.TotalPhysicalKogi
            PerDenomination  = $Entry.Value.PerDenomination
        })
    }

    # ── Orphaned Physical Currency: active items on inactive/deleted characters ──
    $OrphanedPhysical = [System.Collections.Generic.List[object]]::new()
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -ne 'Aktywny') { continue }
        if ($Item.OwnerCategory -ne 'Physical') { continue }
        if (-not $Item.Owner) { continue }
        if ($Item.Quantity -le 0) { continue }

        # Flag items whose Postac owner is Nieaktywny or Usuniety (needs coordinator action)
        if ($EntityStatusByName.ContainsKey($Item.Owner)) {
            $OwnerStatus = $EntityStatusByName[$Item.Owner]
            if ($OwnerStatus -eq 'Nieaktywny' -or $OwnerStatus -eq 'Usunięty') {
                $OrphanedPhysical.Add([PSCustomObject]@{
                    Entity      = $Item.Entity.Name
                    Owner       = $Item.Owner
                    OwnerStatus = $OwnerStatus
                    Denomination = $Item.Denomination.Name
                    Quantity    = $Item.Quantity
                    BaseValueKogi = $Item.Quantity * $Item.Denomination.Multiplier
                })
            }
        }
    }

    # ── Summary: Kogi-equivalent totals for Physical vs Virtual supply ──
    $TotalPhysical = 0
    $TotalVirtual = 0
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }
        $BaseValue = $Item.Quantity * $Item.Denomination.Multiplier
        if ($Item.OwnerCategory -eq 'Physical') { $TotalPhysical += $BaseValue }
        elseif ($Item.OwnerCategory -eq 'Virtual') { $TotalVirtual += $BaseValue }
    }

    return [PSCustomObject]@{
        DenominationBreakdown = @($DenominationBreakdown)
        PlayerBreakdown       = @($PlayerBreakdown)
        OrphanedPhysical      = @($OrphanedPhysical)
        Summary               = @{
            TotalPhysical  = $TotalPhysical
            TotalVirtual   = $TotalVirtual
            OrphanedCount  = $OrphanedPhysical.Count
        }
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

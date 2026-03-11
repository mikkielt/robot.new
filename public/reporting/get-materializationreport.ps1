<#
    .SYNOPSIS
    Materialization report — physical vs virtual currency breakdown by denomination and player.

    .DESCRIPTION
    Analyzes currency ownership to distinguish physical currency (Postać-owned, representing
    actual Margonem items) from virtual currency (NPC/Grupa/Gracz-owned, RP bookkeeping).
    Detects orphaned physical currency: inactive/deleted Postać entities that still have
    active currency — items that need return to coordinators.

    Dot-sources currency-helpers.ps1 for denomination constants and identification.
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

    # Build entity lookup for owner type classification
    $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityLookup.ContainsKey($Name)) {
                $EntityLookup[$Name] = $Entity
            }
        }
    }

    # Build entity status lookup
    $EntityStatusByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        $EntityStatusByName[$Entity.Name] = $Status
    }

    # Build player-to-character mapping (Postać → Gracz)
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

    # Get enriched currency items with owner classification
    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive -EntityLookup $EntityLookup

    # ── Denomination Breakdown ──
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

    # ── Player Breakdown ──
    $PlayerData = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }
        if ($Item.OwnerCategory -ne 'Physical') { continue }
        if (-not $Item.Owner) { continue }

        # Map character to player
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

    # ── Orphaned Physical Currency ──
    $OrphanedPhysical = [System.Collections.Generic.List[object]]::new()
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -ne 'Aktywny') { continue }
        if ($Item.OwnerCategory -ne 'Physical') { continue }
        if (-not $Item.Owner) { continue }
        if ($Item.Quantity -le 0) { continue }

        # Check if the owning Postać is inactive or deleted
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

    # ── Summary ──
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

<#
    .SYNOPSIS
    Merges entity file data with session-based overrides (Zmiany) and @Transfer
    directives to produce a unified, chronologically resolved entity state.

    .DESCRIPTION
    This file contains Get-EntityState - the second pass in the two-pass entity
    processing architecture:

    Pass 1: Get-Entity (file data only) + Get-Session (basic parse, extracts Zmiany)
    Pass 2: Get-EntityState merges entity file data + session Zmiany chronologically

    Get-EntityState takes pre-fetched entities and sessions as input. For each session
    that contains a - Zmiany: block, it resolves entity names via the full name
    resolution pipeline (exact match, declension stripping, stem alternation,
    Levenshtein fuzzy matching) and applies @tag overrides to the matching entity objects.

    @Transfer directives (e.g. "- @Transfer: 100 koron, Solmyr -> Sandro") are
    expanded into symmetric @ilość deltas on the source and destination currency
    entities, found by matching @generyczne_nazwy (denomination) + @należy_do (owner).

    Override priority: most-recent-dated entry wins regardless of source (entity file
    or session Zmiany). This is achieved by appending session overrides to history lists
    in chronological order and sorting by ValidFrom before recomputing active values.

    Auto-dating: tags in Zmiany blocks without explicit temporal ranges (YYYY-MM:YYYY-MM)
    receive the session date as their implicit ValidFrom (open-ended, no ValidTo).
    Tags with explicit ranges use those ranges instead.

    Entity name resolution: Zmiany entity names are resolved against an entity-only
    lookup first (exact match), then fall back to the full Resolve-Name pipeline.
    When Resolve-Name returns a Player object (due to Player/Gracz dedup in the name
    index), the result is mapped back to the corresponding entity via shared names.
#>

function Get-EntityState {
    <#
        .SYNOPSIS
        Merges entity file data with session Zmiany overrides to produce enriched entity state.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Filter temporally-scoped data to entries active on this date")]
        [datetime]$ActiveOn
    )

    if (-not $Entities) {
        $Entities = if ($ActiveOn) { Get-Entity -ActiveOn $ActiveOn } else { Get-Entity }
    }
    if (-not $Sessions) {
        $Sessions = Get-Session
    }

    # Build entity name lookup from all entity names and aliases (case-insensitive)
    # This enables exact-match entity resolution independent of the Player-priority name index.
    $EntityByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityByName.ContainsKey($Name)) {
                $EntityByName[$Name] = $Entity
            }
        }
    }

    # Build full name resolution infrastructure for fuzzy matching fallback
    $Players = Get-Player -Entities $Entities
    $NameIndexResult = Get-NameIndex -Players $Players -Entities $Entities
    $Cache = @{}

    # Track which entities were modified to recompute their active values
    $ModifiedEntities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Filter to sessions with Zmiany or Transfers and sort chronologically
    $SessionsWithChanges = [System.Collections.Generic.List[object]]::new()
    foreach ($Session in $Sessions) {
        $HasChanges = $Session.Changes -and $Session.Changes.Count -gt 0
        $HasTransfers = $Session.PSObject.Properties['Transfers'] -and $Session.Transfers -and $Session.Transfers.Count -gt 0
        if (($HasChanges -or $HasTransfers) -and $null -ne $Session.Date) {
            $SessionsWithChanges.Add($Session)
        }
    }
    $SessionsWithChanges.Sort([System.Comparison[object]]{ param($a, $b) $a.Date.CompareTo($b.Date) })

    foreach ($Session in $SessionsWithChanges) {
        foreach ($Change in $Session.Changes) {

            # Resolve entity name - exact entity lookup first, then fuzzy fallback
            $TargetEntity = $null

            if ($EntityByName.ContainsKey($Change.EntityName)) {
                $TargetEntity = $EntityByName[$Change.EntityName]
            } else {
                # Fuzzy matching via Resolve-Name (may return Player or entity)
                $Resolved = Resolve-Name -Query $Change.EntityName -Index $NameIndexResult.Index -StemIndex $NameIndexResult.StemIndex -BKTree $NameIndexResult.BKTree -Cache $Cache

                if ($Resolved) {
                    # Direct entity match by resolved name
                    if ($EntityByName.ContainsKey($Resolved.Name)) {
                        $TargetEntity = $EntityByName[$Resolved.Name]
                    } else {
                        # Resolved to a Player - search for matching entity via shared names
                        foreach ($N in $Resolved.Names) {
                            if ($EntityByName.ContainsKey($N)) {
                                $TargetEntity = $EntityByName[$N]
                                break
                            }
                        }
                    }
                }
            }

            if (-not $TargetEntity) {
                [System.Console]::Error.WriteLine("[WARN Get-EntityState] Unresolved entity '$($Change.EntityName)' in session '$($Session.Header)'")
                continue
            }

            [void]$ModifiedEntities.Add($TargetEntity.Name)

            foreach ($TagEntry in $Change.Tags) {
                $Parsed = ConvertFrom-ValidityString -InputText $TagEntry.Value

                # Auto-date: if no temporal range specified, use session date as ValidFrom
                if (-not $Parsed.ValidFrom -and -not $Parsed.ValidTo) {
                    $Parsed = @{
                        Text      = $Parsed.Text
                        ValidFrom = $Session.Date
                        ValidTo   = $null
                    }
                }

                switch ($TagEntry.Tag) {
                    '@lokacja' {
                        $TargetEntity.LocationHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@drzwi' {
                        $TargetEntity.DoorHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@typ' {
                        $TargetEntity.TypeHistory.Add([PSCustomObject]@{
                            Type      = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@należy_do' {
                        $TargetEntity.OwnerHistory.Add([PSCustomObject]@{
                            OwnerName = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@grupa' {
                        $TargetEntity.GroupHistory.Add([PSCustomObject]@{
                            Group     = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@alias' {
                        $TargetEntity.Aliases.Add([PSCustomObject]@{
                            Text      = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                        [void]$TargetEntity.Names.Add($Parsed.Text)
                    }
                    '@zawiera' {
                        $TargetEntity.Contains.Add($Parsed.Text)
                    }
                    '@status' {
                        if (-not $TargetEntity.StatusHistory) {
                            $TargetEntity.StatusHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $TargetEntity.StatusHistory.Add([PSCustomObject]@{
                            Status    = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@ilość' {
                        if (-not $TargetEntity.QuantityHistory) {
                            $TargetEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $QtyText = $Parsed.Text
                        # Arithmetic delta: +N or -N modifies current quantity
                        if ($QtyText -match '^[+-]\d+$') {
                            $Delta = [int]$QtyText
                            $CurrentQty = 0
                            $LastQty = Get-LastActiveValue -History $TargetEntity.QuantityHistory -PropertyName 'Quantity' -ActiveOn $Parsed.ValidFrom
                            if ($LastQty -and $LastQty -match '^\d+$') {
                                $CurrentQty = [int]$LastQty
                            }
                            $QtyText = [string]($CurrentQty + $Delta)
                        }
                        $TargetEntity.QuantityHistory.Add([PSCustomObject]@{
                            Quantity  = $QtyText
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@generyczne_nazwy' {
                        if (-not $TargetEntity.GenericNames) {
                            $TargetEntity.GenericNames = [System.Collections.Generic.List[string]]::new()
                        }
                        foreach ($GN in $Parsed.Text.Split(',')) {
                            $Trimmed = $GN.Trim()
                            if ($Trimmed.Length -gt 0) {
                                $TargetEntity.GenericNames.Add($Trimmed)
                                [void]$TargetEntity.Names.Add($Trimmed)
                            }
                        }
                    }
                    default {
                        # Generic override (e.g. @pu_startowe, @info, @trigger)
                        $PropName = $TagEntry.Tag.Substring(1)  # strip leading '@'
                        if (-not $TargetEntity.Overrides.ContainsKey($PropName)) {
                            $TargetEntity.Overrides[$PropName] = [System.Collections.Generic.List[string]]::new()
                        }
                        $TargetEntity.Overrides[$PropName].Add($Parsed.Text)
                    }
                }
            }
        }

        # Expand @Transfer directives into symmetric @ilość deltas
        if ($Session.PSObject.Properties['Transfers'] -and $Session.Transfers -and $Session.Transfers.Count -gt 0) {
            . "$script:ModuleRoot/private/currency-helpers.ps1"

            foreach ($Transfer in $Session.Transfers) {
                $ResolvedDenom = Resolve-CurrencyDenomination -Name $Transfer.Denomination
                if (-not $ResolvedDenom) {
                    [System.Console]::Error.WriteLine("[WARN Get-EntityState] Unknown denomination '$($Transfer.Denomination)' in @Transfer in session '$($Session.Header)'")
                    continue
                }

                # Find source currency entity
                $SourceEntity = Find-CurrencyEntity -Entities $Entities -Denomination $Transfer.Denomination -OwnerName $Transfer.Source
                if (-not $SourceEntity) {
                    [System.Console]::Error.WriteLine("[WARN Get-EntityState] No currency entity for '$($Transfer.Source)' ($($ResolvedDenom.Name)) in @Transfer in session '$($Session.Header)' - assuming 0 balance")
                }

                # Find destination currency entity
                $DestEntity = Find-CurrencyEntity -Entities $Entities -Denomination $Transfer.Denomination -OwnerName $Transfer.Destination
                if (-not $DestEntity) {
                    [System.Console]::Error.WriteLine("[WARN Get-EntityState] No currency entity for '$($Transfer.Destination)' ($($ResolvedDenom.Name)) in @Transfer in session '$($Session.Header)' - assuming 0 balance")
                }

                # Apply -N to source
                if ($SourceEntity) {
                    if (-not $SourceEntity.QuantityHistory) {
                        $SourceEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                    }
                    $CurrentSrcQty = 0
                    $LastSrcQty = Get-LastActiveValue -History $SourceEntity.QuantityHistory -PropertyName 'Quantity' -ActiveOn $Session.Date
                    if ($LastSrcQty -and $LastSrcQty -match '^\-?\d+$') {
                        $CurrentSrcQty = [int]$LastSrcQty
                    }
                    $SourceEntity.QuantityHistory.Add([PSCustomObject]@{
                        Quantity  = [string]($CurrentSrcQty - $Transfer.Amount)
                        ValidFrom = $Session.Date
                        ValidTo   = $null
                    })
                    [void]$ModifiedEntities.Add($SourceEntity.Name)
                }

                # Apply +N to destination
                if ($DestEntity) {
                    if (-not $DestEntity.QuantityHistory) {
                        $DestEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                    }
                    $CurrentDstQty = 0
                    $LastDstQty = Get-LastActiveValue -History $DestEntity.QuantityHistory -PropertyName 'Quantity' -ActiveOn $Session.Date
                    if ($LastDstQty -and $LastDstQty -match '^\-?\d+$') {
                        $CurrentDstQty = [int]$LastDstQty
                    }
                    $DestEntity.QuantityHistory.Add([PSCustomObject]@{
                        Quantity  = [string]($CurrentDstQty + $Transfer.Amount)
                        ValidFrom = $Session.Date
                        ValidTo   = $null
                    })
                    [void]$ModifiedEntities.Add($DestEntity.Name)
                }
            }
        }
    }

    # Sort history lists by ValidFrom and recompute active values for modified entities.
    # Sorting ensures Get-LastActiveValue (which returns $Active[-1]) picks the most
    # recent dated entry, regardless of whether it came from an entity file or session.
    foreach ($EntityName in $ModifiedEntities) {
        $Entity = if ($EntityByName.ContainsKey($EntityName)) { $EntityByName[$EntityName] } else { $null }
        if (-not $Entity) { continue }

        # Sort helper: $null ValidFrom sorts before dated entries (always-active entries)
        $DateComparer = [System.Comparison[object]]{
            param($a, $b)
            if ($null -eq $a.ValidFrom -and $null -eq $b.ValidFrom) { return 0 }
            if ($null -eq $a.ValidFrom) { return -1 }
            if ($null -eq $b.ValidFrom) { return 1 }
            return $a.ValidFrom.CompareTo($b.ValidFrom)
        }

        if ($Entity.LocationHistory.Count -gt 0) { $Entity.LocationHistory.Sort($DateComparer) }
        if ($Entity.DoorHistory.Count -gt 0)     { $Entity.DoorHistory.Sort($DateComparer) }
        if ($Entity.TypeHistory.Count -gt 0)     { $Entity.TypeHistory.Sort($DateComparer) }
        if ($Entity.OwnerHistory.Count -gt 0)    { $Entity.OwnerHistory.Sort($DateComparer) }
        if ($Entity.GroupHistory.Count -gt 0)    { $Entity.GroupHistory.Sort($DateComparer) }
        if ($Entity.StatusHistory -and $Entity.StatusHistory.Count -gt 0) { $Entity.StatusHistory.Sort($DateComparer) }
        if ($Entity.QuantityHistory -and $Entity.QuantityHistory.Count -gt 0) { $Entity.QuantityHistory.Sort($DateComparer) }

        # Recompute active scalar/array values from merged + sorted histories
        $Entity.Location = Get-LastActiveValue -History $Entity.LocationHistory -PropertyName 'Location'  -ActiveOn $ActiveOn
        $Entity.Doors    = Get-AllActiveValues -History $Entity.DoorHistory     -PropertyName 'Location'  -ActiveOn $ActiveOn
        $Entity.Owner    = Get-LastActiveValue -History $Entity.OwnerHistory    -PropertyName 'OwnerName' -ActiveOn $ActiveOn
        $Entity.Groups   = Get-AllActiveValues -History $Entity.GroupHistory    -PropertyName 'Group'     -ActiveOn $ActiveOn

        $MergedType = Get-LastActiveValue -History $Entity.TypeHistory -PropertyName 'Type' -ActiveOn $ActiveOn
        if ($MergedType) { $Entity.Type = $MergedType }

        if ($Entity.StatusHistory -and $Entity.StatusHistory.Count -gt 0) {
            $MergedStatus = Get-LastActiveValue -History $Entity.StatusHistory -PropertyName 'Status' -ActiveOn $ActiveOn
            if ($MergedStatus) { $Entity.Status = $MergedStatus }
        }

        if ($Entity.QuantityHistory -and $Entity.QuantityHistory.Count -gt 0) {
            $MergedQuantity = Get-LastActiveValue -History $Entity.QuantityHistory -PropertyName 'Quantity' -ActiveOn $ActiveOn
            if ($MergedQuantity) { $Entity.Quantity = $MergedQuantity }
        }
    }

    return $Entities
}

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
    that contains a @Zmiany block, it resolves entity names via the full name
    resolution pipeline (exact match, declension stripping, stem alternation,
    Levenshtein fuzzy matching) and applies @tag overrides to the matching entity objects.

    @Transfer directives (e.g. "- @Transfer: 100 koron, Solmyr -> Sandro" or
    "- @Transfer: Miecz Ognia, Solmyr -> Sandro") are expanded into symmetric
    @ilość deltas on source and destination Przedmiot entities. Resolution uses
    a two-path approach: first tries currency denomination matching
    (Resolve-CurrencyDenomination -> ByDenomAndOwner index), then falls back to
    item name matching (ByNameAndOwner index with optional fuzzy resolution).
    Atomicity: if either side is unresolvable, the entire transfer is skipped
    and recorded in UnresolvedTransfers on the resolvable entity.

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

    Uses item-helpers.ps1 and currency-helpers.ps1 (lazy-loaded on first
    @Transfer) for the unified item lookup layer (Build-ItemLookup). Uses
    Robot.TemporalSorter (lib/TemporalSorter.cs, compiled centrally in
    Robot.PowerShell.psm1) — compiled C# temporal sort comparer invoked O(n log n) times
    per sort across 9 history lists per entity.
#>

# C# types: Robot.TemporalEntry, Robot.Entity, Robot.TemporalSorter
# Compiled centrally in Robot.PowerShell.psm1 at module import time.

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

        [Parameter(HelpMessage = "Pre-fetched player roster from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Pre-built name index from Get-NameIndex (avoids redundant BK-tree rebuild)")]
        [hashtable]$NameIndex,

        [Parameter(HelpMessage = "Filter temporally-scoped data to entries active on this date")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = if ($ActiveOn) { Get-Entity -ActiveOn $ActiveOn } else { Get-Entity }
    }
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session
    }

    # Entity-only lookup bypasses the Player-priority name index for exact-match resolution
    $EntityByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityByName.ContainsKey($Name)) {
                $EntityByName[$Name] = $Entity
            }
        }
    }

    # Full name resolution infrastructure (BK-tree + stem index) for fuzzy matching fallback
    if (-not $PSBoundParameters.ContainsKey('Players')) {
        $Players = Get-Player -Entities $Entities
    }
    $NameIndexResult = if ($PSBoundParameters.ContainsKey('NameIndex') -and $NameIndex) { $NameIndex } else { Get-NameIndex -Players $Players -Entities $Entities }
    $Cache = @{}

    # Only modified entities need expensive history re-sort + scalar recomputation
    $ModifiedEntities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Chronological ordering ensures later session overrides correctly supersede earlier ones
    $SessionsWithChanges = [System.Collections.Generic.List[object]]::new()
    foreach ($Session in $Sessions) {
        $HasChanges = $Session.Changes -and $Session.Changes.Count -gt 0
        $HasTransfers = $Session.PSObject.Properties['Transfers'] -and $Session.Transfers -and $Session.Transfers.Count -gt 0
        if (($HasChanges -or $HasTransfers) -and $null -ne $Session.Date) {
            $SessionsWithChanges.Add($Session)
        }
    }
    $SessionsWithChanges.Sort([System.Comparison[object]]{ param($a, $b) $a.Date.CompareTo($b.Date) })

    $ItemLookup = $null  # lazy-loaded on first @Transfer encounter (unified item+currency lookup)

    $script:ProgressSessIdx = 0
    $script:ProgressSessTotal = $SessionsWithChanges.Count

    foreach ($Session in $SessionsWithChanges) {
        $script:ProgressSessIdx++
        if ($ProgressCallback -and ($script:ProgressSessIdx % 10 -eq 0 -or $script:ProgressSessIdx -eq $script:ProgressSessTotal)) {  # throttled to every 10th session
            & $ProgressCallback $script:ProgressSessIdx $script:ProgressSessTotal $null
        }

        foreach ($Change in $Session.Changes) {

            # Two-stage resolution: exact entity lookup, then Resolve-Name fuzzy fallback
            $TargetEntity = $null

            if ($EntityByName.ContainsKey($Change.EntityName)) {
                $TargetEntity = $EntityByName[$Change.EntityName]
            } else {
                # Resolve-Name may return a Player; map back to entity via shared names
                $Resolved = Resolve-Name -Query $Change.EntityName -Index $NameIndexResult.Index -StemIndex $NameIndexResult.StemIndex -BKTree $NameIndexResult.BKTree -Cache $Cache

                if ($Resolved) {
                    if ($EntityByName.ContainsKey($Resolved.Name)) {
                        $TargetEntity = $EntityByName[$Resolved.Name]
                    } else {
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
                Write-RobotWarning "[WARN Get-EntityState] Unresolved entity '$($Change.EntityName)' in session '$($Session.Header)'"
                continue
            }

            [void]$ModifiedEntities.Add($TargetEntity.Name)

            foreach ($TagEntry in $Change.Tags) {
                $Parsed = ConvertFrom-ValidityString -InputText $TagEntry.Value

                # Implicit dating: Zmiany tags without temporal ranges inherit the session date
                if (-not $Parsed.ValidFrom -and -not $Parsed.ValidTo) {
                    $Parsed = @{
                        Text      = $Parsed.Text
                        ValidFrom = $Session.Date
                        ValidTo   = $null
                        Season    = $Parsed.Season
                    }
                }

                switch ($TagEntry.Tag) {
                    '@lokacja' {
                        $TargetEntity.LocationHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@drzwi' {
                        $TargetEntity.DoorHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@typ' {
                        $TargetEntity.TypeHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@należy_do' {
                        $TargetEntity.OwnerHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@grupa' {
                        $TargetEntity.GroupHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@alias' {
                        $TargetEntity.Aliases.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                        [void]$TargetEntity.Names.Add($Parsed.Text)
                    }
                    '@zawiera' {
                        $TargetEntity.Contains.Add($Parsed.Text)
                    }
                    '@status' {
                        if (-not $TargetEntity.StatusHistory) {
                            $TargetEntity.StatusHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $TargetEntity.StatusHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@ilość' {
                        if (-not $TargetEntity.QuantityHistory) {
                            $TargetEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $QtyText = $Parsed.Text
                        # +N/-N prefix triggers delta arithmetic against current balance
                        if ($QtyText -match '^[+-]\d+$') {
                            $Delta = [int]$QtyText
                            $CurrentQty = 0
                            $LastQty = Get-LastActiveValue -History $TargetEntity.QuantityHistory -PropertyName 'Value' -ActiveOn $Parsed.ValidFrom
                            if ($LastQty -and $LastQty -match '^\d+$') {
                                $CurrentQty = [int]$LastQty
                            }
                            $QtyText = [string]($CurrentQty + $Delta)
                        }
                        $TargetEntity.QuantityHistory.Add([Robot.TemporalEntry]::new($QtyText, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
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
                    '@plik' {
                        if (-not $TargetEntity.FilePathHistory) {
                            $TargetEntity.FilePathHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $TargetEntity.FilePathHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                    }
                    '@nazwa_nerthus' {
                        if (-not $TargetEntity.NerthusNameHistory) {
                            $TargetEntity.NerthusNameHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $TargetEntity.NerthusNameHistory.Add([Robot.TemporalEntry]::new($Parsed.Text, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                        [void]$TargetEntity.Names.Add($Parsed.Text)
                    }
                    '@slug' {
                        [void]$TargetEntity.Names.Add($Parsed.Text)
                    }
                    '@koordynaty' {
                        if (-not $TargetEntity.CoordinateHistory) {
                            $TargetEntity.CoordinateHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $Coord = ConvertFrom-CoordinateString -Text $Parsed.Text
                        if ($Coord) {
                            $TargetEntity.CoordinateHistory.Add([Robot.CoordinateTemporalEntry]::new($Coord.X, $Coord.Y, $Parsed.ValidFrom, $Parsed.ValidTo, $Parsed.Season))
                            $TargetEntity.Coordinates = @{ X = $Coord.X; Y = $Coord.Y }
                        }
                    }
                    default {
                        $PropName = $TagEntry.Tag.Substring(1)  # strip leading '@'
                        if (-not $TargetEntity.Overrides.ContainsKey($PropName)) {
                            $TargetEntity.Overrides[$PropName] = [System.Collections.Generic.List[string]]::new()
                        }
                        $TargetEntity.Overrides[$PropName].Add($Parsed.Text)
                    }
                }
            }
        }

        # @Transfer creates symmetric @ilość changes: -N on source, +N on destination
        # Unified path: try currency denomination first, then item name fallback
        if ($Session.PSObject.Properties['Transfers'] -and $Session.Transfers -and $Session.Transfers.Count -gt 0) {
            if (-not $ItemLookup) {
                . "$script:ModuleRoot/private/item-helpers.ps1"
                . "$script:ModuleRoot/private/currency-helpers.ps1"
                $KnownDenominations = @($script:CurrencyDenominations | ForEach-Object { $_.Name })
                $ItemLookup = Build-ItemLookup -Entities $Entities -DenominationNames $KnownDenominations
            }

            foreach ($Transfer in $Session.Transfers) {
                # Source owner name resolution — same fuzzy pipeline as Zmiany
                $ResolvedSourceName = $Transfer.Source
                if (-not $EntityByName.ContainsKey($ResolvedSourceName)) {
                    $Resolved = Resolve-Name -Query $ResolvedSourceName -Index $NameIndexResult.Index -StemIndex $NameIndexResult.StemIndex -BKTree $NameIndexResult.BKTree -Cache $Cache
                    if ($Resolved) {
                        if ($EntityByName.ContainsKey($Resolved.Name)) {
                            $ResolvedSourceName = $EntityByName[$Resolved.Name].Name
                        } else {
                            foreach ($N in $Resolved.Names) {
                                if ($EntityByName.ContainsKey($N)) {
                                    $ResolvedSourceName = $EntityByName[$N].Name
                                    break
                                }
                            }
                        }
                    }
                }

                # Destination owner name resolution
                $ResolvedDestName = $Transfer.Destination
                if (-not $EntityByName.ContainsKey($ResolvedDestName)) {
                    $Resolved = Resolve-Name -Query $ResolvedDestName -Index $NameIndexResult.Index -StemIndex $NameIndexResult.StemIndex -BKTree $NameIndexResult.BKTree -Cache $Cache
                    if ($Resolved) {
                        if ($EntityByName.ContainsKey($Resolved.Name)) {
                            $ResolvedDestName = $EntityByName[$Resolved.Name].Name
                        } else {
                            foreach ($N in $Resolved.Names) {
                                if ($EntityByName.ContainsKey($N)) {
                                    $ResolvedDestName = $EntityByName[$N].Name
                                    break
                                }
                            }
                        }
                    }
                }

                $SourceEntity = $null
                $DestEntity = $null
                $TransferLabel = $null

                # Path 1: Currency denomination resolution
                $ResolvedDenom = Resolve-CurrencyDenomination -Name $Transfer.Denomination
                if ($ResolvedDenom) {
                    $TransferLabel = $ResolvedDenom.Name
                    $SourceEntity = Find-ItemByDenomAndOwner -Lookup $ItemLookup -Denomination $ResolvedDenom.Name -OwnerName $ResolvedSourceName
                    if (-not $SourceEntity) {
                        Write-RobotWarning "[WARN Get-EntityState] No currency entity for '$($ResolvedSourceName)' ($($ResolvedDenom.Name)) in @Transfer in session '$($Session.Header)'"
                    }
                    $DestEntity = Find-ItemByDenomAndOwner -Lookup $ItemLookup -Denomination $ResolvedDenom.Name -OwnerName $ResolvedDestName
                    if (-not $DestEntity) {
                        Write-RobotWarning "[WARN Get-EntityState] No currency entity for '$($ResolvedDestName)' ($($ResolvedDenom.Name)) in @Transfer in session '$($Session.Header)'"
                    }
                } else {
                    # Path 2: Item name resolution (non-currency Przedmiot)
                    $TransferLabel = $Transfer.Denomination
                    $SourceEntity = Find-ItemByNameAndOwner -Lookup $ItemLookup -ItemName $Transfer.Denomination -OwnerName $ResolvedSourceName
                    if (-not $SourceEntity) {
                        # Try fuzzy name resolution to find the canonical item name
                        $ResolvedItemName = Resolve-Name -Query $Transfer.Denomination -Index $NameIndexResult.Index -StemIndex $NameIndexResult.StemIndex -BKTree $NameIndexResult.BKTree -Cache $Cache
                        if ($ResolvedItemName) {
                            $SourceEntity = Find-ItemByNameAndOwner -Lookup $ItemLookup -ItemName $ResolvedItemName.Name -OwnerName $ResolvedSourceName
                            if ($SourceEntity) {
                                $TransferLabel = $ResolvedItemName.Name
                                $DestEntity = Find-ItemByNameAndOwner -Lookup $ItemLookup -ItemName $ResolvedItemName.Name -OwnerName $ResolvedDestName
                            }
                        }
                    } else {
                        $DestEntity = Find-ItemByNameAndOwner -Lookup $ItemLookup -ItemName $Transfer.Denomination -OwnerName $ResolvedDestName
                    }

                    if (-not $SourceEntity) {
                        Write-RobotWarning "[WARN Get-EntityState] No item entity '$($Transfer.Denomination)' for '$($ResolvedSourceName)' in @Transfer in session '$($Session.Header)'"
                    }
                    if (-not $DestEntity) {
                        Write-RobotWarning "[WARN Get-EntityState] No item entity '$($Transfer.Denomination)' for '$($ResolvedDestName)' in @Transfer in session '$($Session.Header)'"
                    }
                }

                # Atomicity: skip entire transfer if either side is unresolvable
                if (-not $SourceEntity -or -not $DestEntity) {
                    $ErrMsg = "Unresolved @Transfer in session '$($Session.Header)': " +
                              "Source='$ResolvedSourceName' Dest='$ResolvedDestName' ($TransferLabel)"
                    $AffectedEntity = if ($SourceEntity) { $SourceEntity } elseif ($DestEntity) { $DestEntity } else { $null }
                    if ($AffectedEntity) {
                        if (-not $AffectedEntity.UnresolvedTransfers) {
                            $AffectedEntity.UnresolvedTransfers = [System.Collections.Generic.List[string]]::new()
                        }
                        [void]$AffectedEntity.UnresolvedTransfers.Add($ErrMsg)
                    }
                    continue
                }

                # Debit source
                if (-not $SourceEntity.QuantityHistory) {
                    $SourceEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                }
                $CurrentSrcQty = 0
                $LastSrcQty = Get-LastActiveValue -History $SourceEntity.QuantityHistory -PropertyName 'Value' -ActiveOn $Session.Date
                [int]$ParsedSrcQty = 0
                if ($LastSrcQty -and [int]::TryParse($LastSrcQty, [ref]$ParsedSrcQty)) {
                    $CurrentSrcQty = $ParsedSrcQty
                }
                $SourceEntity.QuantityHistory.Add([Robot.TemporalEntry]::new([string]($CurrentSrcQty - $Transfer.Amount), $Session.Date, $null, $null))
                [void]$ModifiedEntities.Add($SourceEntity.Name)

                # Credit destination
                if (-not $DestEntity.QuantityHistory) {
                    $DestEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                }
                $CurrentDstQty = 0
                $LastDstQty = Get-LastActiveValue -History $DestEntity.QuantityHistory -PropertyName 'Value' -ActiveOn $Session.Date
                [int]$ParsedDstQty = 0
                if ($LastDstQty -and [int]::TryParse($LastDstQty, [ref]$ParsedDstQty)) {
                    $CurrentDstQty = $ParsedDstQty
                }
                $DestEntity.QuantityHistory.Add([Robot.TemporalEntry]::new([string]($CurrentDstQty + $Transfer.Amount), $Session.Date, $null, $null))
                [void]$ModifiedEntities.Add($DestEntity.Name)
            }
        }
    }

    # Sorting by ValidFrom ensures Get-LastActiveValue picks the most recent entry
    # regardless of source (entity file vs session). $null ValidFrom sorts first
    # (always-active entries). C# comparer handles the sort via compiled code.
    $DateComparer = if (([System.Management.Automation.PSTypeName]'Robot.TemporalSorter').Type) {
        [Robot.TemporalSorter]::CreateComparer('ValidFrom')
    } else {
        [System.Comparison[object]]{
            param($a, $b)
            if ($null -eq $a.ValidFrom -and $null -eq $b.ValidFrom) { return 0 }
            if ($null -eq $a.ValidFrom) { return -1 }
            if ($null -eq $b.ValidFrom) { return 1 }
            return $a.ValidFrom.CompareTo($b.ValidFrom)
        }
    }

    foreach ($EntityName in $ModifiedEntities) {
        $Entity = if ($EntityByName.ContainsKey($EntityName)) { $EntityByName[$EntityName] } else { $null }
        if (-not $Entity) { continue }

        if ($Entity.LocationHistory.Count -gt 0) { $Entity.LocationHistory.Sort($DateComparer) }
        if ($Entity.DoorHistory.Count -gt 0)     { $Entity.DoorHistory.Sort($DateComparer) }
        if ($Entity.TypeHistory.Count -gt 0)     { $Entity.TypeHistory.Sort($DateComparer) }
        if ($Entity.OwnerHistory.Count -gt 0)    { $Entity.OwnerHistory.Sort($DateComparer) }
        if ($Entity.GroupHistory.Count -gt 0)    { $Entity.GroupHistory.Sort($DateComparer) }
        if ($Entity.StatusHistory -and $Entity.StatusHistory.Count -gt 0) { $Entity.StatusHistory.Sort($DateComparer) }
        if ($Entity.QuantityHistory -and $Entity.QuantityHistory.Count -gt 0) { $Entity.QuantityHistory.Sort($DateComparer) }
        if ($Entity.FilePathHistory -and $Entity.FilePathHistory.Count -gt 0) { $Entity.FilePathHistory.Sort($DateComparer) }
        if ($Entity.NerthusNameHistory -and $Entity.NerthusNameHistory.Count -gt 0) { $Entity.NerthusNameHistory.Sort($DateComparer) }

        # Recompute active scalars from merged + sorted histories
        $Entity.Location = Get-LastActiveValue -History $Entity.LocationHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        $Entity.Doors    = Get-AllActiveValues -History $Entity.DoorHistory     -PropertyName 'Value' -ActiveOn $ActiveOn
        $Entity.Owner    = Get-LastActiveValue -History $Entity.OwnerHistory    -PropertyName 'Value' -ActiveOn $ActiveOn
        $Entity.Groups   = Get-AllActiveValues -History $Entity.GroupHistory    -PropertyName 'Value' -ActiveOn $ActiveOn

        $MergedType = Get-LastActiveValue -History $Entity.TypeHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        if ($MergedType) { $Entity.Type = $MergedType }

        if ($Entity.StatusHistory -and $Entity.StatusHistory.Count -gt 0) {
            $MergedStatus = Get-LastActiveValue -History $Entity.StatusHistory -PropertyName 'Value' -ActiveOn $ActiveOn
            if ($MergedStatus) { $Entity.Status = $MergedStatus }
        }

        if ($Entity.QuantityHistory -and $Entity.QuantityHistory.Count -gt 0) {
            $MergedQuantity = Get-LastActiveValue -History $Entity.QuantityHistory -PropertyName 'Value' -ActiveOn $ActiveOn
            if ($MergedQuantity) { $Entity.Quantity = $MergedQuantity }
        }

        if ($Entity.FilePathHistory -and $Entity.FilePathHistory.Count -gt 0) {
            $MergedFilePath = Get-LastActiveValue -History $Entity.FilePathHistory -PropertyName 'Value' -ActiveOn $ActiveOn
            if ($MergedFilePath) { $Entity.FilePath = $MergedFilePath }
        }

        if ($Entity.NerthusNameHistory -and $Entity.NerthusNameHistory.Count -gt 0) {
            $MergedNerthusName = Get-LastActiveValue -History $Entity.NerthusNameHistory -PropertyName 'Value' -ActiveOn $ActiveOn
            if ($MergedNerthusName) { $Entity.NerthusName = $MergedNerthusName }
        }
    }

    return $Entities

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

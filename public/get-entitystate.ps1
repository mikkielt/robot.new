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

    Preamble: loads Robot.TemporalSorter (lib/TemporalSorter.cs) — compiled C#
    temporal sort comparer that replaces PowerShell scriptblock comparers invoked
    O(n log n) times per sort across 9 history lists per entity.
#>

# Compiled C# comparer eliminates scriptblock overhead on sort-heavy post-merge pass
if (-not ([System.Management.Automation.PSTypeName]'Robot.TemporalSorter').Type) {
    $CsPath = [System.IO.Path]::Combine($script:ModuleRoot, 'lib', 'TemporalSorter.cs')
    if ([System.IO.File]::Exists($CsPath)) {
        $SMAPath = [System.Management.Automation.PSObject].Assembly.Location
        Add-Type -TypeDefinition ([System.IO.File]::ReadAllText($CsPath)) -Language CSharp -ReferencedAssemblies $SMAPath
    }
}

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

    $CurrencyLookup = $null  # lazy-loaded on first @Transfer encounter

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
                        $TargetEntity.LocationHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@drzwi' {
                        $TargetEntity.DoorHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@typ' {
                        $TargetEntity.TypeHistory.Add([PSCustomObject]@{
                            Type      = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@należy_do' {
                        $TargetEntity.OwnerHistory.Add([PSCustomObject]@{
                            OwnerName = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@grupa' {
                        $TargetEntity.GroupHistory.Add([PSCustomObject]@{
                            Group     = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@alias' {
                        $TargetEntity.Aliases.Add([PSCustomObject]@{
                            Text      = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
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
                            Season    = $Parsed.Season
                        })
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
                            Season    = $Parsed.Season
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
                    '@plik' {
                        if (-not $TargetEntity.FilePathHistory) {
                            $TargetEntity.FilePathHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $TargetEntity.FilePathHistory.Add([PSCustomObject]@{
                            FilePath  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@nazwa_nerthus' {
                        if (-not $TargetEntity.NerthusNameHistory) {
                            $TargetEntity.NerthusNameHistory = [System.Collections.Generic.List[object]]::new()
                        }
                        $TargetEntity.NerthusNameHistory.Add([PSCustomObject]@{
                            NerthusName = $Parsed.Text
                            ValidFrom   = $Parsed.ValidFrom
                            ValidTo     = $Parsed.ValidTo
                            Season      = $Parsed.Season
                        })
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
                            $TargetEntity.CoordinateHistory.Add([PSCustomObject]@{
                                X         = $Coord.X
                                Y         = $Coord.Y
                                ValidFrom = $Parsed.ValidFrom
                                ValidTo   = $Parsed.ValidTo
                                Season    = $Parsed.Season
                            })
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
        if ($Session.PSObject.Properties['Transfers'] -and $Session.Transfers -and $Session.Transfers.Count -gt 0) {
            if (-not $CurrencyLookup) {
                . "$script:ModuleRoot/private/currency-helpers.ps1"
                $CurrencyLookup = Build-CurrencyEntityLookup -Entities $Entities
            }

            foreach ($Transfer in $Session.Transfers) {
                $ResolvedDenom = Resolve-CurrencyDenomination -Name $Transfer.Denomination
                if (-not $ResolvedDenom) {
                    Write-RobotWarning "[WARN Get-EntityState] Unknown denomination '$($Transfer.Denomination)' in @Transfer in session '$($Session.Header)'"
                    continue
                }

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

                # Locate currency Przedmiot entities by denomination + owner
                $SourceEntity = Find-CurrencyEntity -Entities $Entities -Denomination $Transfer.Denomination -OwnerName $ResolvedSourceName -CurrencyLookup $CurrencyLookup
                if (-not $SourceEntity) {
                    Write-RobotWarning "[WARN Get-EntityState] No currency entity for '$($ResolvedSourceName)' ($($ResolvedDenom.Name)) in @Transfer in session '$($Session.Header)'"
                }

                $DestEntity = Find-CurrencyEntity -Entities $Entities -Denomination $Transfer.Denomination -OwnerName $ResolvedDestName -CurrencyLookup $CurrencyLookup
                if (-not $DestEntity) {
                    Write-RobotWarning "[WARN Get-EntityState] No currency entity for '$($ResolvedDestName)' ($($ResolvedDenom.Name)) in @Transfer in session '$($Session.Header)'"
                }

                # Atomicity: skip entire transfer if either side is unresolvable
                if (-not $SourceEntity -or -not $DestEntity) {
                    $ErrMsg = "Unresolved @Transfer in session '$($Session.Header)': " +
                              "Source='$ResolvedSourceName' Dest='$ResolvedDestName' ($($ResolvedDenom.Name))"
                    $AffectedEntity = if ($SourceEntity) { $SourceEntity } elseif ($DestEntity) { $DestEntity } else { $null }
                    if ($AffectedEntity) {
                        if (-not $AffectedEntity.PSObject.Properties['UnresolvedTransfers']) {
                            $AffectedEntity | Add-Member -NotePropertyName 'UnresolvedTransfers' -NotePropertyValue ([System.Collections.Generic.List[string]]::new())
                        }
                        [void]$AffectedEntity.UnresolvedTransfers.Add($ErrMsg)
                    }
                    continue
                }

                # Debit source
                if ($SourceEntity) {
                    if (-not $SourceEntity.QuantityHistory) {
                        $SourceEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                    }
                    $CurrentSrcQty = 0
                    $LastSrcQty = Get-LastActiveValue -History $SourceEntity.QuantityHistory -PropertyName 'Quantity' -ActiveOn $Session.Date
                    [int]$ParsedSrcQty = 0
                    if ($LastSrcQty -and [int]::TryParse($LastSrcQty, [ref]$ParsedSrcQty)) {
                        $CurrentSrcQty = $ParsedSrcQty
                    }
                    $SourceEntity.QuantityHistory.Add([PSCustomObject]@{
                        Quantity  = [string]($CurrentSrcQty - $Transfer.Amount)
                        ValidFrom = $Session.Date
                        ValidTo   = $null
                    })
                    [void]$ModifiedEntities.Add($SourceEntity.Name)
                }

                # Credit destination
                if ($DestEntity) {
                    if (-not $DestEntity.QuantityHistory) {
                        $DestEntity.QuantityHistory = [System.Collections.Generic.List[object]]::new()
                    }
                    $CurrentDstQty = 0
                    $LastDstQty = Get-LastActiveValue -History $DestEntity.QuantityHistory -PropertyName 'Quantity' -ActiveOn $Session.Date
                    [int]$ParsedDstQty = 0
                    if ($LastDstQty -and [int]::TryParse($LastDstQty, [ref]$ParsedDstQty)) {
                        $CurrentDstQty = $ParsedDstQty
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

    # Sorting by ValidFrom ensures Get-LastActiveValue picks the most recent entry
    # regardless of source (entity file vs session). $null ValidFrom sorts first
    # (always-active entries). C# comparer eliminates scriptblock invocation overhead.
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

        if ($Entity.FilePathHistory -and $Entity.FilePathHistory.Count -gt 0) {
            $MergedFilePath = Get-LastActiveValue -History $Entity.FilePathHistory -PropertyName 'FilePath' -ActiveOn $ActiveOn
            if ($MergedFilePath) { $Entity.FilePath = $MergedFilePath }
        }

        if ($Entity.NerthusNameHistory -and $Entity.NerthusNameHistory.Count -gt 0) {
            $MergedNerthusName = Get-LastActiveValue -History $Entity.NerthusNameHistory -PropertyName 'NerthusName' -ActiveOn $ActiveOn
            if ($MergedNerthusName) { $Entity.NerthusName = $MergedNerthusName }
        }
    }

    return $Entities

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

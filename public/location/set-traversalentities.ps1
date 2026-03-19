<#
    .SYNOPSIS
    Traversal-driven @drzwi discovery and entity update.

    .DESCRIPTION
    Set-TraversalEntities chains Get-SessionLog, Get-MapTraversalGraph, and
    Get-LocationGraph to discover missing @drzwi connections between Lokacja
    entities. In bootstrap mode (no structural edges) the weight threshold
    auto-lowers so candidates are not lost. Also suggests new Mapa entities
    from unresolved map names.

    Seven-stage pipeline:
    1. Data loading (entities, sessions, logs)
    2. Map traversal graph construction
    3. Location graph with Teleport/Movement classification + bootstrap detection
    4. @drzwi candidate discovery from traversal edges
    5. Mapa entity suggestion from unresolved segments
    6. Batch @drzwi insertion into entity registry files
    7. Result assembly

    Entity file discovery uses Get-AdminConfig().EntitiesFile plus overflow
    *-NNN-ent.md scanning, matching the pattern used by other write commands.
#>

function Set-TraversalEntities {
    <#
        .SYNOPSIS
        Analyze traversal graph and update Lokacja entities with missing @drzwi tags.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Include only sessions on or after this date (delta mode)")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Minimum Teleport edge weight to accept as @drzwi candidate")]
        [int]$MinDoorWeight = 3,

        [Parameter(HelpMessage = "Minimum unresolved name occurrences to suggest new Mapa")]
        [int]$MinMapWeight = 5,

        [Parameter(HelpMessage = "Skip @drzwi discovery")]
        [switch]$SkipDoors,

        [Parameter(HelpMessage = "Skip Mapa entity suggestions")]
        [switch]$SkipMaps,

        [Parameter(HelpMessage = "Only return analysis, don't write")]
        [switch]$ReportOnly,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Helper: build empty result object
    $EmptyResult = {
        return [PSCustomObject]@{
            DoorCandidates   = [PSCustomObject[]]@()
            DoorsApplied     = [PSCustomObject[]]@()
            DoorsSkipped     = [PSCustomObject[]]@()
            MapSuggestions   = [PSCustomObject[]]@()
            TraversalSummary = [PSCustomObject]@{
                TotalSegments          = 0
                ResolvedCount          = 0
                UnresolvedCount        = 0
                MapEdgeCount           = 0
                LocationEdgeCount      = 0
                IsBootstrap            = $false
                EffectiveMinDoorWeight = $MinDoorWeight
            }
            GraphSummary     = $null
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # Stage 1: Data Loading
    # ══════════════════════════════════════════════════════════════════════
    if (-not $Entities) {
        $Entities = Get-Entity -Quiet
    }
    if (-not $Sessions) {
        $SessionParams = @{ Quiet = $true }
        if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
        $Sessions = Get-Session @SessionParams
    }

    if (-not $Sessions -or @($Sessions).Count -eq 0) {
        return (& $EmptyResult)
    }

    $LogData = Get-SessionLog -Session $Sessions -SkipFetch
    if (-not $LogData -or @($LogData).Count -eq 0) {
        return (& $EmptyResult)
    }

    # Build entity lookup by name (case-insensitive)
    $EntityByName = [System.Collections.Generic.Dictionary[string,object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($E in $Entities) {
        if (-not $EntityByName.ContainsKey($E.Name)) {
            $EntityByName[$E.Name] = $E
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # Stage 2: Traversal Graph
    # ══════════════════════════════════════════════════════════════════════
    $MapTraversal = Get-MapTraversalGraph -SessionLog $LogData -Entities $Entities -Quiet

    # ══════════════════════════════════════════════════════════════════════
    # Stage 3: Location Graph with Classification + Bootstrap Detection
    # ══════════════════════════════════════════════════════════════════════
    $Graph = Get-LocationGraph -Entities $Entities -Sessions $Sessions `
        -MapTraversalGraph $MapTraversal -IncludeMovementEdges -Quiet

    $ExistingDoors = @($Graph.Edges.Where({ $_.Type -eq 'Door' }))
    $ContainmentEdges = @($Graph.Edges.Where({ $_.Type -eq 'Containment' }))
    $StructuralEdgeCount = $ExistingDoors.Count + $ContainmentEdges.Count

    # Bootstrap detection: no structural data means Teleport/Movement distinction
    # is meaningless (everything becomes Teleport). In bootstrap mode we use ALL
    # traversal edges and auto-lower MinDoorWeight so candidates aren't lost.
    $IsBootstrap = $StructuralEdgeCount -eq 0
    $EffectiveMinDoorWeight = $MinDoorWeight

    if ($IsBootstrap) {
        if (-not $PSBoundParameters.ContainsKey('MinDoorWeight')) {
            $EffectiveMinDoorWeight = 1
        }
        Write-RobotWarning "[Set-TraversalEntities] Bootstrap: brak danych strukturalnych (ContainmentEdges=0, DoorEdges=0). MinDoorWeight=$EffectiveMinDoorWeight."
    }

    # In bootstrap all traversal edges are Teleport; in mature mode use only Teleport
    $TraversalEdges = if ($IsBootstrap) {
        @($Graph.Edges.Where({ $_.Type -eq 'Teleport' -or $_.Type -eq 'Movement' }))
    } else {
        @($Graph.Edges.Where({ $_.Type -eq 'Teleport' }))
    }

    # ══════════════════════════════════════════════════════════════════════
    # Stage 4: @drzwi Candidate Discovery
    # ══════════════════════════════════════════════════════════════════════
    $Candidates = [System.Collections.Generic.List[object]]::new()

    if (-not $SkipDoors) {
        # Build exclusion sets for existing doors and containment pairs
        $ExistingDoorPairs = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Edge in $ExistingDoors) {
            [void]$ExistingDoorPairs.Add("$($Edge.Source)|$($Edge.Target)")
            [void]$ExistingDoorPairs.Add("$($Edge.Target)|$($Edge.Source)")
        }

        $ContainmentPairs = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Edge in $ContainmentEdges) {
            [void]$ContainmentPairs.Add("$($Edge.Source)|$($Edge.Target)")
            [void]$ContainmentPairs.Add("$($Edge.Target)|$($Edge.Source)")
        }

        # Aggregate traversal edges into candidate pairs (deduplicate A→B and B→A)
        $CandidateMap = [System.Collections.Generic.Dictionary[string,object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Edge in $TraversalEdges) {
            $S = $Edge.Source
            $T = $Edge.Target

            # Skip unresolved (entity must exist)
            if (-not $EntityByName.ContainsKey($S) -or -not $EntityByName.ContainsKey($T)) { continue }
            # Skip existing doors (either direction)
            if ($ExistingDoorPairs.Contains("$S|$T")) { continue }
            # Skip containment (parent/child is not a door)
            if ($ContainmentPairs.Contains("$S|$T")) { continue }
            # Skip self-transitions
            if ([string]::Equals($S, $T, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            # Canonical key: alphabetical order to merge A→B and B→A
            $Key = if ([string]::Compare($S, $T, [System.StringComparison]::OrdinalIgnoreCase) -le 0) {
                "$S|$T"
            } else { "$T|$S" }

            if ($CandidateMap.ContainsKey($Key)) {
                $Existing = $CandidateMap[$Key]
                $Existing.Weight += $Edge.Weight
                if ($Edge.FirstSeen -lt $Existing.FirstSeen) { $Existing.FirstSeen = $Edge.FirstSeen }
                if ($Edge.LastSeen -gt $Existing.LastSeen) { $Existing.LastSeen = $Edge.LastSeen }
                if ($Edge.PossiblyStale) { $Existing.PossiblyStale = $true }
            } else {
                $Parts = $Key.Split('|')
                $CandidateMap[$Key] = @{
                    Source        = $Parts[0]
                    Target        = $Parts[1]
                    Weight        = $Edge.Weight
                    FirstSeen     = $Edge.FirstSeen
                    LastSeen      = $Edge.LastSeen
                    PossiblyStale = $Edge.PossiblyStale
                }
            }
        }

        # Filter by weight threshold and build candidate list
        foreach ($Entry in $CandidateMap.Values) {
            if ($Entry.Weight -ge $EffectiveMinDoorWeight) {
                [void]$Candidates.Add([PSCustomObject]@{
                    Source        = $Entry.Source
                    Target        = $Entry.Target
                    Weight        = $Entry.Weight
                    FirstSeen     = $Entry.FirstSeen
                    LastSeen      = $Entry.LastSeen
                    PossiblyStale = $Entry.PossiblyStale
                })
            }
        }

        # Sort by weight descending
        if ($Candidates.Count -gt 0) {
            $Candidates = [System.Collections.Generic.List[object]]::new(
                [object[]]@([System.Linq.Enumerable]::OrderByDescending(
                    [object[]]$Candidates, [Func[object,int]]{ param($X) $X.Weight })))
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # Stage 5: Mapa Suggestion Discovery
    # ══════════════════════════════════════════════════════════════════════
    $MapSuggestions = [System.Collections.Generic.List[object]]::new()

    if (-not $SkipMaps -and $MapTraversal.Segments -and $MapTraversal.Segments.Count -gt 0) {
        # Group segments by session index for parent inference
        $SessionSegments = [System.Collections.Generic.Dictionary[int,System.Collections.Generic.List[object]]]::new()
        foreach ($Seg in $MapTraversal.Segments) {
            if (-not $SessionSegments.ContainsKey($Seg.SessionIndex)) {
                $SessionSegments[$Seg.SessionIndex] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$SessionSegments[$Seg.SessionIndex].Add($Seg)
        }

        # Group unresolved names by suffix-stripped base name
        $UnresolvedGroups = [System.Collections.Generic.Dictionary[string,object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Seg in $MapTraversal.Segments) {
            if ($Seg.Stage -ne 'Unresolved') { continue }

            $BaseName = try {
                [Robot.MapTraversalBuilder]::StripMapSuffix($Seg.Raw)
            } catch {
                $Seg.Raw
            }

            if (-not $UnresolvedGroups.ContainsKey($BaseName)) {
                $UnresolvedGroups[$BaseName] = @{
                    BaseName = $BaseName
                    Count    = 0
                    Variants = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                    Parents  = [System.Collections.Generic.List[string]]::new()
                }
            }

            $Group = $UnresolvedGroups[$BaseName]
            $Group.Count++
            [void]$Group.Variants.Add($Seg.Raw)

            # Infer parent from nearest resolved segments in same session
            if ($SessionSegments.ContainsKey($Seg.SessionIndex)) {
                $SesSegs = $SessionSegments[$Seg.SessionIndex]
                $SegIdx = -1
                for ($SI = 0; $SI -lt $SesSegs.Count; $SI++) {
                    if ([object]::ReferenceEquals($SesSegs[$SI], $Seg)) {
                        $SegIdx = $SI
                        break
                    }
                }
                if ($SegIdx -ge 0) {
                    # Nearest resolved segment before current → infer parent
                    for ($J = $SegIdx - 1; $J -ge 0; $J--) {
                        if ($SesSegs[$J].Stage -ne 'Unresolved' -and $SesSegs[$J].ParentLocation) {
                            [void]$Group.Parents.Add($SesSegs[$J].ParentLocation)
                            break
                        }
                    }
                    # Nearest resolved segment after current → infer parent
                    for ($J = $SegIdx + 1; $J -lt $SesSegs.Count; $J++) {
                        if ($SesSegs[$J].Stage -ne 'Unresolved' -and $SesSegs[$J].ParentLocation) {
                            [void]$Group.Parents.Add($SesSegs[$J].ParentLocation)
                            break
                        }
                    }
                }
            }
        }

        # Build suggestions from groups meeting threshold
        foreach ($Entry in $UnresolvedGroups.Values) {
            if ($Entry.Count -lt $MinMapWeight) { continue }

            # Most frequent parent location
            $InferredParent = $null
            if ($Entry.Parents.Count -gt 0) {
                $ParentCounts = [System.Collections.Generic.Dictionary[string,int]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($P in $Entry.Parents) {
                    if (-not $ParentCounts.ContainsKey($P)) { $ParentCounts[$P] = 0 }
                    $ParentCounts[$P]++
                }
                $MaxCount = 0
                foreach ($KV in $ParentCounts.GetEnumerator()) {
                    if ($KV.Value -gt $MaxCount) {
                        $MaxCount = $KV.Value
                        $InferredParent = $KV.Key
                    }
                }
            }

            # Most frequent raw form
            $RawName = $null
            $RawCounts = [System.Collections.Generic.Dictionary[string,int]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Seg in $MapTraversal.Segments) {
                if ($Seg.Stage -ne 'Unresolved') { continue }
                $SB = try { [Robot.MapTraversalBuilder]::StripMapSuffix($Seg.Raw) } catch { $Seg.Raw }
                if ([string]::Equals($SB, $Entry.BaseName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if (-not $RawCounts.ContainsKey($Seg.Raw)) { $RawCounts[$Seg.Raw] = 0 }
                    $RawCounts[$Seg.Raw]++
                }
            }
            $MaxRawCount = 0
            foreach ($KV in $RawCounts.GetEnumerator()) {
                if ($KV.Value -gt $MaxRawCount) {
                    $MaxRawCount = $KV.Value
                    $RawName = $KV.Key
                }
            }
            if (-not $RawName) { $RawName = @($Entry.Variants)[0] }

            [void]$MapSuggestions.Add([PSCustomObject]@{
                RawName        = $RawName
                BaseName       = $Entry.BaseName
                InferredParent = $InferredParent
                Count          = $Entry.Count
                Variants       = [string[]]@($Entry.Variants)
            })
        }

        # Sort by count descending
        if ($MapSuggestions.Count -gt 0) {
            $MapSuggestions = [System.Collections.Generic.List[object]]::new(
                [object[]]@([System.Linq.Enumerable]::OrderByDescending(
                    [object[]]$MapSuggestions, [Func[object,int]]{ param($X) $X.Count })))
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # Stage 6: Apply @drzwi
    # ══════════════════════════════════════════════════════════════════════
    $Applied = [System.Collections.Generic.List[object]]::new()
    $Skipped = [System.Collections.Generic.List[object]]::new()

    if (-not $ReportOnly -and -not $SkipDoors -and $Candidates.Count -gt 0) {
        $Config = Get-AdminConfig

        # Discover entity registry files (main + overflow *-NNN-ent.md)
        $MainEntitiesFile = $Config.EntitiesFile
        $EntDir = [System.IO.Path]::GetDirectoryName($MainEntitiesFile)
        $AllEntityFiles = [System.Collections.Generic.List[string]]::new()
        if ([System.IO.File]::Exists($MainEntitiesFile)) {
            [void]$AllEntityFiles.Add($MainEntitiesFile)
        }
        if ([System.IO.Directory]::Exists($EntDir)) {
            foreach ($OF in [System.IO.Directory]::GetFiles($EntDir, '*-*-ent.md', [System.IO.SearchOption]::AllDirectories)) {
                if (-not [string]::Equals($OF, $MainEntitiesFile, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$AllEntityFiles.Add($OF)
                }
            }
        }

        # Build entity name → registry source file map by scanning all entity files
        $EntitySourceMap = [System.Collections.Generic.Dictionary[string,string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($EFile in $AllEntityFiles) {
            $RawLines = [System.IO.File]::ReadAllLines($EFile)
            foreach ($Line in $RawLines) {
                if ($Line.Length -gt 2 -and $Line[0] -eq [char]'*' -and $Line[1] -eq [char]' ') {
                    $BulletName = $Line.Substring(2).Trim()
                    if ($BulletName.Length -gt 0 -and -not $EntitySourceMap.ContainsKey($BulletName)) {
                        $EntitySourceMap[$BulletName] = $EFile
                    }
                }
            }
        }

        # Track which candidate pairs had writes vs skips
        $AppliedPairKeys = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $SkippedPairKeys = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        # Group insertions by file path to minimize file reads/writes
        $FileChanges = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Pair in $Candidates) {
            $PairKey = "$($Pair.Source)|$($Pair.Target)"

            # Each accepted pair produces two directional insertions: A→B and B→A
            foreach ($Dir in @(
                @{ Entity = $Pair.Source; DoorTarget = $Pair.Target; FirstSeen = $Pair.FirstSeen; PairKey = $PairKey }
                @{ Entity = $Pair.Target; DoorTarget = $Pair.Source; FirstSeen = $Pair.FirstSeen; PairKey = $PairKey }
            )) {
                $E = $null
                if (-not $EntityByName.TryGetValue($Dir.Entity, [ref]$E)) { continue }
                $SourceFile = $null
                if (-not $EntitySourceMap.TryGetValue($Dir.Entity, [ref]$SourceFile)) { continue }

                # Check if door already exists (entity-level quick check)
                $AlreadyExists = $false
                if ($null -ne $E.Doors) {
                    foreach ($D in $E.Doors) {
                        if ([string]::Equals($D, $Dir.DoorTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $AlreadyExists = $true
                            break
                        }
                    }
                }

                if ($AlreadyExists) {
                    [void]$SkippedPairKeys.Add($PairKey)
                    continue
                }

                if (-not $FileChanges.ContainsKey($SourceFile)) {
                    $FileChanges[$SourceFile] = [System.Collections.Generic.List[object]]::new()
                }
                [void]$FileChanges[$SourceFile].Add([PSCustomObject]@{
                    EntityName = $Dir.Entity
                    DoorTarget = $Dir.DoorTarget
                    FirstSeen  = $Dir.FirstSeen
                    PairKey    = $Dir.PairKey
                })
            }
        }

        # Apply changes per file
        foreach ($Entry in $FileChanges.GetEnumerator()) {
            $FilePath = $Entry.Key
            $Changes = $Entry.Value

            if (-not [System.IO.File]::Exists($FilePath)) {
                Write-RobotWarning "[WARN Set-TraversalEntities] Plik nie istnieje: $FilePath"
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($FilePath, "Add $($Changes.Count) @drzwi tags")) {
                continue
            }

            $FileData = Read-EntityFile -Path $FilePath
            $Lines = $FileData.Lines
            $NL = $FileData.NL

            $IndexedChanges = [System.Collections.Generic.List[object]]::new()
            foreach ($Change in $Changes) {
                $SectionInfo = Find-EntitySection -Lines $Lines.ToArray() `
                    -EntityType ($EntityByName[$Change.EntityName].Type)
                if ($null -eq $SectionInfo) { continue }

                $BulletInfo = Find-EntityBullet -Lines $Lines.ToArray() `
                    -SectionStart $SectionInfo.StartIdx `
                    -SectionEnd $SectionInfo.EndIdx `
                    -EntityName $Change.EntityName
                if ($null -eq $BulletInfo) { continue }

                # Raw line scan for existing @drzwi tag (belt-and-suspenders)
                $TagExists = $false
                for ($K = $BulletInfo.ChildrenStartIdx; $K -lt $BulletInfo.ChildrenEndIdx; $K++) {
                    $Line = $Lines[$K]
                    if ($Line -match '^\s+-\s+@drzwi:\s*(.+)') {
                        $ExistingTarget = $Matches[1].Trim()
                        # Strip temporal annotation for comparison
                        $ParenIdx = $ExistingTarget.IndexOf('(')
                        if ($ParenIdx -gt 0) { $ExistingTarget = $ExistingTarget.Substring(0, $ParenIdx).Trim() }
                        if ([string]::Equals($ExistingTarget, $Change.DoorTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $TagExists = $true
                            break
                        }
                    }
                }

                if ($TagExists) {
                    [void]$SkippedPairKeys.Add($Change.PairKey)
                    continue
                }

                [void]$IndexedChanges.Add([PSCustomObject]@{
                    InsertIdx  = $BulletInfo.ChildrenEndIdx
                    DoorTarget = $Change.DoorTarget
                    FirstSeen  = $Change.FirstSeen
                    PairKey    = $Change.PairKey
                })
            }

            # Apply from bottom to top (descending insert index) to avoid index shifting
            if ($IndexedChanges.Count -gt 0) {
                $IndexedChanges = @([System.Linq.Enumerable]::OrderByDescending(
                    [object[]]$IndexedChanges, [Func[object,int]]{ param($X) $X.InsertIdx }))

                foreach ($IC in $IndexedChanges) {
                    $Temporal = ''
                    if (-not $IsBootstrap -and $IC.FirstSeen) {
                        $DateStr = $IC.FirstSeen.ToString('yyyy-MM')
                        $Temporal = " ($DateStr`:)"
                    }
                    $TagLine = "    - @drzwi: $($IC.DoorTarget)$Temporal"
                    [void]$Lines.Insert($IC.InsertIdx, $TagLine)
                    [void]$AppliedPairKeys.Add($IC.PairKey)
                }

                Write-EntityFile -Path $FilePath -Lines $Lines -NL $NL
            }
        }

        # Build Applied/Skipped lists from pair-level tracking
        foreach ($Pair in $Candidates) {
            $PairKey = "$($Pair.Source)|$($Pair.Target)"
            if ($AppliedPairKeys.Contains($PairKey)) {
                [void]$Applied.Add($Pair)
            } elseif ($SkippedPairKeys.Contains($PairKey)) {
                [void]$Skipped.Add($Pair)
            }
        }

        # Invalidate graph cache if any writes were made
        if ($AppliedPairKeys.Count -gt 0) {
            Set-SessionGraphStale -Reason 'Set-TraversalEntities' -ResDir $Config.ResDir
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # Stage 7: Return result
    # ══════════════════════════════════════════════════════════════════════
    return [PSCustomObject]@{
        DoorCandidates   = [PSCustomObject[]]@($Candidates)
        DoorsApplied     = [PSCustomObject[]]@($Applied)
        DoorsSkipped     = [PSCustomObject[]]@($Skipped)
        MapSuggestions   = [PSCustomObject[]]@($MapSuggestions)
        TraversalSummary = [PSCustomObject]@{
            TotalSegments         = $MapTraversal.TotalSegments
            ResolvedCount         = $MapTraversal.ResolvedCount
            UnresolvedCount       = $MapTraversal.UnresolvedCount
            MapEdgeCount          = $MapTraversal.MapEdges.Count
            LocationEdgeCount     = $MapTraversal.LocationEdges.Count
            IsBootstrap           = $IsBootstrap
            EffectiveMinDoorWeight = $EffectiveMinDoorWeight
        }
        GraphSummary     = $Graph.Summary
    }

    } finally {
        if ($Quiet) { $script:SuppressWarnings = $PrevSuppress }
    }
}

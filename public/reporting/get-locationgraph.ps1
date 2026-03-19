<#
    .SYNOPSIS
    Builds a unified location graph from entity registry, session metadata, and session logs.

    .DESCRIPTION
    Get-LocationGraph merges seven edge sources into a single node+edge graph:
    - Containment edges from @lokacja parent-child chains (entity registry)
    - Door edges from @drzwi bidirectional connections (entity registry)
    - Route edges from session metadata separators (-> and - patterns)
    - InferredHierarchy edges from slash-path parent detection
    - Movement edges from consecutive log LocationSegments (structurally walkable)
    - Teleport edges from consecutive log LocationSegments (no structural path)
    - MapTraversal edges from Get-MapTraversalGraph projected LocationEdges
      (preferred over raw SessionLog when -MapTraversalGraph is provided)

    Processing pipeline:
    1. Load entities and sessions, build case-insensitive entity lookup
       (maps primary names + aliases for node enrichment in step 9)
    2. Extract Containment edges from @lokacja parent-child chains
    3. Extract Door edges from @drzwi bidirectional connections
    4. Build adjacency sets from structural edges (Containment + Door)
       for walkability classification in step 7
    5. Extract Route and InferredHierarchy edges from Get-NamedLocationReport
    6. Optionally extract Movement/Teleport edges from session log transitions
       via Get-NamedLogLocationReport, classifying each transition as Movement
       (structurally walkable within distance 2) or Teleport (no structural path)
    7. Build node objects from all edge endpoints, enriched with entity metadata
       (CN, NerthusName, Coordinates, IsExterior via computed property, in/out degree)
    8. Detect stale edges where source/target CoordinateHistory changed after
       the edge's FirstSeen date (indicates map geometry may have invalidated
       the connection)

    When -MapTraversalGraph is provided, Movement/Teleport classification uses
    the pre-built LocationEdges from compiled C# MapTraversalBuilder rather than
    re-processing raw session log transitions. The walkability check (distance <= 2
    in the structural adjacency graph) still applies to classify each projected
    edge as Movement or Teleport.

    Inline scriptblocks:
    - $AddEdge: merges duplicate edges by incrementing weight and expanding
      source list; tracks FirstSeen/LastSeen for staleness detection
    - $EnsureAdj: lazily initializes adjacency HashSets in the adjacency dictionary
    - $IsWalkable: checks structural reachability within distance 2
      (direct neighbor or share a common neighbor)

    Edge deduplication uses a "Source|Target|Type" composite key in a
    case-insensitive dictionary. Repeated edges increment weight and
    accumulate data source tags rather than creating duplicates.

    Returns a PSCustomObject with Nodes array, Edges array, and Summary
    containing counts by edge type, resolution stats, and staleness metrics.
#>

function Get-LocationGraph {
    <#
        .SYNOPSIS
        Build a unified location graph merging entity registry, session routes, and log transitions.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched log location report from Get-NamedLogLocationReport")]
        [object[]]$SessionLog,

        [Parameter(HelpMessage = "Pre-built map traversal graph from Get-MapTraversalGraph")]
        [object]$MapTraversalGraph,

        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Include movement/transition edges from session logs")]
        [switch]$IncludeMovementEdges,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # 1. Load entities (all types, not just Lokacja — needed for owner classification)
    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-Entity
    }

    # 2. Load sessions if needed
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $GetSessionArgs = @{}
        if ($MinDate) { $GetSessionArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $GetSessionArgs['MaxDate'] = $MaxDate }
        $Sessions = Get-Session @GetSessionArgs
    }

    # Multi-name entity lookup for enriching nodes with entity metadata in step 9
    $EntityByName = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Ent in $Entities) {
        if (-not $EntityByName.ContainsKey($Ent.Name)) {
            $EntityByName[$Ent.Name] = $Ent
        }
        if ($Ent.PSObject.Properties['Names'] -and $Ent.Names) {
            foreach ($AltName in $Ent.Names) {
                if (-not $EntityByName.ContainsKey($AltName)) {
                    $EntityByName[$AltName] = $Ent
                }
            }
        }
    }

    # Edge accumulator: composite key deduplicates edges across data sources
    $EdgeKey = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Merge-on-insert: increment weight for existing edges, create new otherwise
    $AddEdge = {
        param([string]$Source, [string]$Target, [string]$Type, [string]$DataSource, [datetime]$Date)
        $Key = "$Source|$Target|$Type"
        if ($EdgeKey.ContainsKey($Key)) {
            $Existing = $EdgeKey[$Key]
            $Existing.Weight++
            if (-not $Existing.Sources.Contains($DataSource)) {
                [void]$Existing.Sources.Add($DataSource)
            }
            if ($Date -lt $Existing.FirstSeen) { $Existing.FirstSeen = $Date }
            if ($Date -gt $Existing.LastSeen)  { $Existing.LastSeen = $Date }
        }
        else {
            $EdgeKey[$Key] = [PSCustomObject]@{
                Source        = $Source
                Target        = $Target
                Type          = $Type
                Weight        = 1
                Sources       = [System.Collections.Generic.List[string]]::new([string[]]@($DataSource))
                FirstSeen     = $Date
                LastSeen      = $Date
                PossiblyStale = $false
                StaleReason   = $null
            }
        }
    }

    $Now = [datetime]::UtcNow

    # 3. Containment edges from @lokacja chains
    $LocationEntities = @($Entities).Where({ $_.Type -eq 'Lokacja' })
    foreach ($Loc in $LocationEntities) {
        if ($Loc.PSObject.Properties['Location'] -and $Loc.Location) {
            $ParentName = $Loc.Location
            & $AddEdge $ParentName $Loc.Name 'Containment' 'Entity' $Now
        }
    }

    # 4. Door edges from @drzwi
    foreach ($Loc in $LocationEntities) {
        if ($Loc.PSObject.Properties['Doors'] -and $Loc.Doors -and $Loc.Doors.Count -gt 0) {
            foreach ($DoorTarget in $Loc.Doors) {
                & $AddEdge $Loc.Name $DoorTarget 'Door' 'Entity' $Now
            }
        }
    }

    # 4b. Build adjacency sets from structural edges (Containment + Door) for
    #     walkability classification: two locations are "walkable" if they are
    #     direct neighbors or share a common structural neighbor (distance <= 2)
    $AdjSet = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $EnsureAdj = {
        param([string]$N)
        if (-not $AdjSet.ContainsKey($N)) {
            $AdjSet[$N] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
    }
    foreach ($Edge in $EdgeKey.Values) {
        if ($Edge.Type -ne 'Containment' -and $Edge.Type -ne 'Door') { continue }
        & $EnsureAdj $Edge.Source
        & $EnsureAdj $Edge.Target
        [void]$AdjSet[$Edge.Source].Add($Edge.Target)
        [void]$AdjSet[$Edge.Target].Add($Edge.Source)
    }
    # Two-hop reachability check: direct neighbor or neighbor-of-neighbor
    $IsWalkable = {
        param([string]$A, [string]$B)
        if (-not $AdjSet.ContainsKey($A) -or -not $AdjSet.ContainsKey($B)) { return $false }
        if ($AdjSet[$A].Contains($B)) { return $true }  # distance 1
        # Distance 2: check for shared neighbor between A and B
        $NA = $AdjSet[$A]
        $NB = $AdjSet[$B]
        foreach ($N in $NA) {
            if ($NB.Contains($N)) { return $true }
        }
        return $false
    }

    # 5. Route edges from Get-NamedLocationReport
    $LocReportArgs = @{ Sessions = $Sessions; Entities = $Entities }
    if ($MinDate) { $LocReportArgs['MinDate'] = $MinDate }
    if ($MaxDate) { $LocReportArgs['MaxDate'] = $MaxDate }
    $LocReportArgs['Quiet'] = $true
    $LocReport = Get-NamedLocationReport @LocReportArgs

    if ($LocReport -and $LocReport.RouteEdges) {
        foreach ($RE in $LocReport.RouteEdges) {
            $EdgeDate = if ($RE.SessionDate) {
                try { [datetime]::ParseExact($RE.SessionDate, 'yyyy-MM-dd', $null) } catch { $Now }
            } else { $Now }
            & $AddEdge $RE.Source $RE.Target 'Route' 'SessionMeta' $EdgeDate
        }
    }

    # 6. Inferred hierarchy edges from location report
    if ($LocReport -and $LocReport.Locations) {
        foreach ($LocItem in $LocReport.Locations) {
            if ($LocItem.InferredParents -and $LocItem.InferredParents.Count -gt 0) {
                foreach ($Parent in $LocItem.InferredParents) {
                    & $AddEdge $Parent $LocItem.Name 'InferredHierarchy' 'SessionMeta' $Now
                }
            }
        }
    }

    # 7. Transition edges from session log (optional)
    $MovementEdgeCount = 0
    $TeleportEdgeCount = 0
    if ($IncludeMovementEdges) {
        if ($MapTraversalGraph) {
            # Use projected LocationEdges from the map traversal graph
            foreach ($LocEdge in $MapTraversalGraph.LocationEdges) {
                $EdgeDate = try {
                    [datetime]::ParseExact($LocEdge.FirstSeenDate, 'yyyy-MM-dd', $null)
                } catch { $Now }
                $Walkable = & $IsWalkable $LocEdge.Source $LocEdge.Target
                $Type = if ($Walkable) { 'Movement' } else { 'Teleport' }
                & $AddEdge $LocEdge.Source $LocEdge.Target $Type 'MapTraversal' $EdgeDate
                if ($Walkable) { $MovementEdgeCount++ } else { $TeleportEdgeCount++ }
            }
        }
        elseif ($SessionLog) {
            $LogReport = $SessionLog
        }
        else {
            try {
                $NameIdx = Get-NameIndex -Entities $Entities
                $LogData = Get-SessionLog -Session $Sessions -SkipFetch
                $LogReport = Get-NamedLogLocationReport -SessionLog $LogData -Index $NameIdx -Quiet
            }
            catch {
                Write-RobotWarning "[WARN Get-LocationGraph] Could not fetch session log data: $_"
                $LogReport = $null
            }
        }

        if (-not $MapTraversalGraph -and $LogReport) {
            foreach ($LogSession in $LogReport) {
                if (-not $LogSession.Transitions -or $LogSession.Transitions.Count -eq 0) { continue }
                foreach ($Trans in $LogSession.Transitions) {
                    $EdgeDate = if ($LogSession.SessionDate) { $LogSession.SessionDate } else { $Now }
                    # Structurally reachable transitions are Movement; unreachable are Teleport
                    $Walkable = & $IsWalkable $Trans.Source $Trans.Target
                    if ($Walkable) {
                        & $AddEdge $Trans.Source $Trans.Target 'Movement' 'SessionLog' $EdgeDate
                        $MovementEdgeCount++
                    } else {
                        & $AddEdge $Trans.Source $Trans.Target 'Teleport' 'SessionLog' $EdgeDate
                        $TeleportEdgeCount++
                    }
                }
            }
        }
    }

    # 8. Build node set from all edge endpoints
    $NodeNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Edge in $EdgeKey.Values) {
        [void]$NodeNames.Add($Edge.Source)
        [void]$NodeNames.Add($Edge.Target)
    }

    # 9. Build node objects
    $Nodes = [System.Collections.Generic.List[object]]::new()
    $InDegree  = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $OutDegree = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Edge in $EdgeKey.Values) {
        if (-not $OutDegree.ContainsKey($Edge.Source)) { $OutDegree[$Edge.Source] = 0 }
        $OutDegree[$Edge.Source]++
        if (-not $InDegree.ContainsKey($Edge.Target)) { $InDegree[$Edge.Target] = 0 }
        $InDegree[$Edge.Target]++
    }

    $ResolvedCount = 0
    $UnresolvedCount = 0
    $ExteriorCount = 0
    $InteriorCount = 0

    foreach ($Name in $NodeNames) {
        $MatchedEntity = $null
        if ($EntityByName.ContainsKey($Name)) {
            $MatchedEntity = $EntityByName[$Name]
        }

        $CN = $null
        $NerthusName = $null
        $Coords = $null
        $IsExterior = $false

        if ($MatchedEntity) {
            $ResolvedCount++
            $CN = $MatchedEntity.CN
            if ($MatchedEntity.PSObject.Properties['NerthusName']) {
                $NerthusName = $MatchedEntity.NerthusName
            }
            if ($MatchedEntity.PSObject.Properties['Coordinates'] -and $MatchedEntity.Coordinates) {
                $Coords = $MatchedEntity.Coordinates
            }
            # Use computed IsExterior when available; fall back to coordinates check
            if ($MatchedEntity.PSObject.Properties['IsExterior'] -and $null -ne $MatchedEntity.IsExterior) {
                $IsExterior = ($MatchedEntity.IsExterior -eq $true)
            } elseif ($Coords) {
                $IsExterior = $true
            }
        }
        else {
            $UnresolvedCount++
        }

        if ($IsExterior) { $ExteriorCount++ } else { $InteriorCount++ }

        $NodeIn  = if ($InDegree.ContainsKey($Name))  { $InDegree[$Name] }  else { 0 }
        $NodeOut = if ($OutDegree.ContainsKey($Name)) { $OutDegree[$Name] } else { 0 }

        $Nodes.Add([PSCustomObject]@{
            Name        = $Name
            EntityMatch = $MatchedEntity
            CN          = $CN
            NerthusName = $NerthusName
            Coordinates = $Coords
            IsExterior  = $IsExterior
            InDegree    = $NodeIn
            OutDegree   = $NodeOut
        })
    }

    # 10. Flag edges where source/target coordinates changed after edge creation
    #     (map geometry changes may have invalidated the physical connection)
    foreach ($Edge in $EdgeKey.Values) {
        $SourceEntity = if ($EntityByName.ContainsKey($Edge.Source)) { $EntityByName[$Edge.Source] } else { $null }
        $TargetEntity = if ($EntityByName.ContainsKey($Edge.Target)) { $EntityByName[$Edge.Target] } else { $null }

        # Coordinate history entries after FirstSeen indicate the map moved post-edge
        if ($SourceEntity -and $SourceEntity.PSObject.Properties['CoordinateHistory'] -and $SourceEntity.CoordinateHistory.Count -gt 1) {
            foreach ($CH in $SourceEntity.CoordinateHistory) {
                if ($CH.ValidFrom -and $CH.ValidFrom -gt $Edge.FirstSeen) {
                    $Edge.PossiblyStale = $true
                    $Edge.StaleReason = "Source coordinates changed at $($CH.ValidFrom.ToString('yyyy-MM-dd'))"
                    break
                }
            }
        }
        if (-not $Edge.PossiblyStale -and $TargetEntity -and $TargetEntity.PSObject.Properties['CoordinateHistory'] -and $TargetEntity.CoordinateHistory.Count -gt 1) {
            foreach ($CH in $TargetEntity.CoordinateHistory) {
                if ($CH.ValidFrom -and $CH.ValidFrom -gt $Edge.FirstSeen) {
                    $Edge.PossiblyStale = $true
                    $Edge.StaleReason = "Target coordinates changed at $($CH.ValidFrom.ToString('yyyy-MM-dd'))"
                    break
                }
            }
        }
    }

    # 11. Aggregate edge type counts and staleness metrics for the summary object
    $ContainmentEdges = 0
    $DoorEdges = 0
    $InferredEdges = 0
    $RouteEdgeCount = 0
    $StaleCount = 0
    foreach ($Edge in $EdgeKey.Values) {
        switch ($Edge.Type) {
            'Containment'       { $ContainmentEdges++ }
            'Door'              { $DoorEdges++ }
            'InferredHierarchy' { $InferredEdges++ }
            'Route'             { $RouteEdgeCount++ }
        }
        if ($Edge.PossiblyStale) { $StaleCount++ }
    }

    return [PSCustomObject]@{
        Nodes   = [PSCustomObject[]]$Nodes.ToArray()
        Edges   = [PSCustomObject[]]@($EdgeKey.Values)
        Summary = [PSCustomObject]@{
            NodeCount          = $Nodes.Count
            EdgeCount          = $EdgeKey.Count
            ContainmentEdges   = $ContainmentEdges
            DoorEdges          = $DoorEdges
            RouteEdges         = $RouteEdgeCount
            MovementEdges      = $MovementEdgeCount
            TeleportEdges      = $TeleportEdgeCount
            InferredEdges      = $InferredEdges
            ResolvedNodes      = $ResolvedCount
            UnresolvedNodes    = $UnresolvedCount
            ExteriorNodes      = $ExteriorCount
            InteriorNodes      = $InteriorCount
            PossiblyStaleEdges = $StaleCount
        }
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

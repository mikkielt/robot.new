<#
    .SYNOPSIS
    Builds a map traversal graph from Mapa entities and session log segments.

    .DESCRIPTION
    Resolves raw LocationSegment map names from session logs against Mapa
    entities, builds Mapa-to-Mapa edges from consecutive resolved segments,
    and projects those edges to Lokacja-to-Lokacja edges via @lokacja parent.

    Resolution pipeline (simplified vs Resolve-Name — game map names are not
    Polish-inflected prose):
    1. Exact match against Mapa Name + Aliases
    2. SuffixStrip: iterative 9-pattern stripping, retry exact match
    3. WordDrop: progressive trailing-word removal, retry each candidate
    4. Unresolved

    Dispatches to compiled C# MapTraversalBuilder when available, falls back
    to equivalent PowerShell implementation.

    Mapa entities are identified by having an Overrides dictionary containing
    the 'margonemid' key and a non-null Location (parent Lokacja).
#>

function Get-MapTraversalGraph {
    <#
        .SYNOPSIS
        Build a map traversal graph from Mapa entities and session log segments.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Session log output from Get-SessionLog")]
        [object[]]$SessionLog,

        [Parameter(Mandatory, HelpMessage = "Entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # 1. Build MapEntry list from Mapa entities (identified by @margonemid + @lokacja)
    $MapEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($E in $Entities) {
        if ($E.Overrides -and $E.Overrides.ContainsKey('margonemid') -and $E.Location) {
            $MapEntries.Add(@{
                Name           = $E.Name
                Aliases        = if ($E.Names) { [string[]]@($E.Names) } else { @($E.Name) }
                MargonemId     = $E.Overrides['margonemid']
                ParentLocation = $E.Location
                MapType        = $E.Type
            })
        }
    }

    # 2. Extract raw segment names from SessionLog
    $SessionSegments = [System.Collections.Generic.List[string[]]]::new()
    $SessionDates = [System.Collections.Generic.List[string]]::new()
    foreach ($SL in $SessionLog) {
        $Segments = [System.Collections.Generic.List[string]]::new()
        if ($SL.Logs) {
            foreach ($Log in $SL.Logs) {
                if ($Log.LocationSegments) {
                    foreach ($Seg in $Log.LocationSegments) {
                        $Segments.Add($Seg.Raw)
                    }
                }
            }
        }
        $SessionSegments.Add([string[]]$Segments.ToArray())
        # Handle both datetime and string SessionDate
        $DateStr = if ($SL.SessionDate -is [datetime]) {
            $SL.SessionDate.ToString('yyyy-MM-dd')
        } elseif ($SL.SessionDate) {
            [string]$SL.SessionDate
        } else { '' }
        $SessionDates.Add($DateStr)
    }

    # 3. Dispatch to C# or PowerShell fallback
    if (([System.Management.Automation.PSTypeName]'Robot.MapTraversalBuilder').Type) {
        # Convert to C# MapEntry[]
        $CsEntries = foreach ($ME in $MapEntries) {
            $Entry = [Robot.MapEntry]::new()
            $Entry.Name = $ME.Name
            $Entry.Aliases = [string[]]$ME.Aliases
            $Entry.MargonemId = $ME.MargonemId
            $Entry.ParentLocation = $ME.ParentLocation
            $Entry.MapType = $ME.MapType
            $Entry
        }
        return [Robot.MapTraversalBuilder]::Build(
            [Robot.MapEntry[]]@($CsEntries),
            [string[][]]$SessionSegments.ToArray(),
            [string[]]$SessionDates.ToArray())
    }
    else {
        # PowerShell fallback — same algorithm, slower
        # Dot-source location-helpers.ps1 (non-Verb-Noun file, not auto-loaded by psm1)
        . "$script:ModuleRoot/private/location-helpers.ps1"

        # Build case-insensitive map lookup (Name + Aliases)
        $MapLookup = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($ME in $MapEntries) {
            if ($ME.Name -and -not $MapLookup.ContainsKey($ME.Name)) {
                $MapLookup[$ME.Name] = $ME
            }
            foreach ($Alias in $ME.Aliases) {
                if ($Alias -and -not $MapLookup.ContainsKey($Alias)) {
                    $MapLookup[$Alias] = $ME
                }
            }
        }

        $AllSegments = [System.Collections.Generic.List[object]]::new()
        $UnresolvedSet = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $MapEdgeDict = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $ResolvedCount = 0
        $UnresolvedCount = 0

        for ($SI = 0; $SI -lt $SessionSegments.Count; $SI++) {
            $RawNames = $SessionSegments[$SI]
            $SessionDate = if ($SI -lt $SessionDates.Count) { $SessionDates[$SI] } else { '' }
            $PrevResolved = $null
            $PrevParent = $null

            foreach ($Raw in $RawNames) {
                if ([string]::IsNullOrWhiteSpace($Raw)) { continue }

                $Matched = $null
                $Stage = 'Unresolved'
                $StrippedName = $null

                # Stage 1: Exact
                if ($MapLookup.ContainsKey($Raw)) {
                    $Matched = $MapLookup[$Raw]
                    $Stage = 'Exact'
                }

                # Stage 2: SuffixStrip (iterative 9-pattern via do..while)
                if (-not $Matched) {
                    $Stripped = $Raw
                    do {
                        $Prev = $Stripped
                        $Stripped = $script:LocDifficultyPattern.Replace($Stripped, '')
                        $Stripped = $script:LocFloorPattern.Replace($Stripped, '')
                        $Stripped = $script:LocRoomSuffixPattern.Replace($Stripped, '')
                        $Stripped = $script:LocSalaPattern.Replace($Stripped, '')
                        $Stripped = $script:LocNamedSalaPattern.Replace($Stripped, '')
                        $Stripped = $script:LocDirectionPattern.Replace($Stripped, '')
                        $Stripped = $script:LocPietroPattern.Replace($Stripped, '')
                        $Stripped = $script:LocPiwnicaPattern.Replace($Stripped, '')
                        $Stripped = $script:LocNamedSubareaPattern.Replace($Stripped, '')
                    } while ($Stripped -ne $Prev)

                    if (-not [string]::Equals($Stripped, $Raw, [System.StringComparison]::OrdinalIgnoreCase) -and
                        $Stripped.Length -gt 0 -and $MapLookup.ContainsKey($Stripped)) {
                        $Matched = $MapLookup[$Stripped]
                        $Stage = 'SuffixStrip'
                        $StrippedName = $Stripped
                    }

                    # Stage 3: WordDrop on suffix-stripped result
                    if (-not $Matched) {
                        $DropBase = if (-not [string]::Equals($Stripped, $Raw, [System.StringComparison]::OrdinalIgnoreCase) -and $Stripped.Length -gt 0) {
                            $Stripped
                        } else { $Raw }
                        $Candidates = Get-MapBaseName -Name $DropBase
                        foreach ($Candidate in $Candidates) {
                            if ($MapLookup.ContainsKey($Candidate)) {
                                $Matched = $MapLookup[$Candidate]
                                $Stage = 'WordDrop'
                                $StrippedName = $Candidate
                                break
                            }
                        }
                    }
                }

                # Record segment
                $AllSegments.Add([PSCustomObject]@{
                    Raw            = $Raw
                    Resolved       = if ($Matched) { $Matched.Name } else { $null }
                    Stage          = $Stage
                    StrippedName   = $StrippedName
                    ParentLocation = if ($Matched) { $Matched.ParentLocation } else { $null }
                    SessionIndex   = $SI
                })

                if ($Matched) {
                    $ResolvedCount++
                    $CurResolved = $Matched.Name
                    $CurParent = $Matched.ParentLocation

                    # Build MapEdge from consecutive resolved segments
                    if ($PrevResolved -and
                        -not [string]::Equals($PrevResolved, $CurResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $EdgeKey = "$PrevResolved|$CurResolved"
                        if ($MapEdgeDict.ContainsKey($EdgeKey)) {
                            $Existing = $MapEdgeDict[$EdgeKey]
                            $Existing.Weight++
                            if ($SessionDate -lt $Existing.FirstSeenDate) { $Existing.FirstSeenDate = $SessionDate }
                            if ($SessionDate -gt $Existing.LastSeenDate)  { $Existing.LastSeenDate = $SessionDate }
                        }
                        else {
                            $MapEdgeDict[$EdgeKey] = [PSCustomObject]@{
                                Source        = $PrevResolved
                                Target        = $CurResolved
                                Weight        = 1
                                FirstSeenDate = $SessionDate
                                LastSeenDate  = $SessionDate
                            }
                        }
                    }

                    $PrevResolved = $CurResolved
                    $PrevParent = $CurParent
                }
                else {
                    $UnresolvedCount++
                    [void]$UnresolvedSet.Add($Raw)
                    $PrevResolved = $null
                    $PrevParent = $null
                }
            }
        }

        # Project MapEdges to LocationEdges via ParentLocation
        $LocEdgeDict = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($ME in $MapEdgeDict.Values) {
            $SrcParent = $null; $TgtParent = $null
            if ($MapLookup.ContainsKey($ME.Source)) { $SrcParent = $MapLookup[$ME.Source].ParentLocation }
            if ($MapLookup.ContainsKey($ME.Target)) { $TgtParent = $MapLookup[$ME.Target].ParentLocation }

            if (-not $SrcParent -or -not $TgtParent) { continue }
            if ([string]::Equals($SrcParent, $TgtParent, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $LocKey = "$SrcParent|$TgtParent"
            if ($LocEdgeDict.ContainsKey($LocKey)) {
                $ExistingLoc = $LocEdgeDict[$LocKey]
                $ExistingLoc.Weight += $ME.Weight
                if ($ME.FirstSeenDate -lt $ExistingLoc.FirstSeenDate) { $ExistingLoc.FirstSeenDate = $ME.FirstSeenDate }
                if ($ME.LastSeenDate -gt $ExistingLoc.LastSeenDate)   { $ExistingLoc.LastSeenDate = $ME.LastSeenDate }
            }
            else {
                $LocEdgeDict[$LocKey] = [PSCustomObject]@{
                    Source        = $SrcParent
                    Target        = $TgtParent
                    Weight        = $ME.Weight
                    FirstSeenDate = $ME.FirstSeenDate
                    LastSeenDate  = $ME.LastSeenDate
                }
            }
        }

        return [PSCustomObject]@{
            MapEdges        = @($MapEdgeDict.Values)
            LocationEdges   = @($LocEdgeDict.Values)
            Segments        = @($AllSegments.ToArray())
            UnresolvedNames = [string[]]@($UnresolvedSet)
            TotalSegments   = $AllSegments.Count
            ResolvedCount   = $ResolvedCount
            UnresolvedCount = $UnresolvedCount
        }
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

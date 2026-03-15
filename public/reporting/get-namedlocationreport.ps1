<#
    .SYNOPSIS
    Reports all location names found across recorded sessions.

    .DESCRIPTION
    Get-NamedLocationReport scans all sessions for location references
    and produces a structured report for guiding manual creation of
    Lokacja entities and detecting naming inconsistencies.

    Processing pipeline:
    1. Extract raw location strings from session metadata (@Lokalizacje)
    2. Split route separators (-> and - patterns) into individual locations
       and record route edges between consecutive segments for
       Get-LocationGraph consumption
    3. Parse slash paths (Parent/Child) into atomic segments with parent-child
       hierarchy tracking via ParentOf/ChildOf dictionaries
    4. Normalize and group by case-insensitive key, pick canonical spelling
       (most frequently used raw form wins)
    5. Levenshtein fuzzy matching — two paths:
       - C# fast path: Robot.BKTree.FindFuzzyPairs with ArrayPool zero-alloc
         inner loop for batch pairwise distance computation
       - PowerShell fallback: O(n^2) with length-difference pruning
       Both paths skip slash paths and names shorter than 3 characters.
    6. Optional file/line reference scanning (IncludeReferences): reads
       session files via .NET File.ReadAllLines with per-file caching to
       find exact line numbers for each occurrence
    7. Three-stage entity resolution:
       - Stage 1: Direct index lookup (case-insensitive exact, Lokacja only)
       - Stage 2: Full Resolve-Name with OwnerType='Lokacja' filter
       - Stage 3: Resolve-Name without type filter (catches entities
         registered under wrong type)
    8. Conflict detection: CaseVariant (multiple raw spellings),
       TrailingArtifact (whitespace/asterisk remnants), AmbiguousStandalone
       (bare name also in qualified slash paths), InconsistentHierarchy
       (same child under different parents), NearDuplicate (Levenshtein)

    Returns a PSCustomObject with Locations (sorted by OccurrenceCount
    descending) and RouteEdges (for Get-LocationGraph edge sourcing).

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance.
#>

. "$script:ModuleRoot/private/string-helpers.ps1"

function Get-NamedLocationReport {
    <#
        .SYNOPSIS
        Analyze location names across all sessions and produce a structured report.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity for name resolution")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Only include locations seen at least this many times")]
        [int]$MinOccurrences = 1,

        [Parameter(HelpMessage = "Maximum Levenshtein distance for fuzzy matching")]
        [int]$MaxEditDistance = 2,

        [Parameter(HelpMessage = "Include file/line references (slower: requires file scanning)")]
        [switch]$IncludeReferences,

        [Parameter(HelpMessage = "Treat slash paths as atomic names instead of splitting")]
        [switch]$IncludeRawSlashPaths,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # 1. Load sessions
    if (-not $Sessions) {
        $GetSessionArgs = @{}
        if ($MinDate) { $GetSessionArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $GetSessionArgs['MaxDate'] = $MaxDate }
        $Sessions = Get-Session @GetSessionArgs
    }

    # 2. Extract raw location strings from session @Lokalizacje metadata
    $RawOccurrences = [System.Collections.Generic.List[object]]::new()
    $RouteEdges     = [System.Collections.Generic.List[object]]::new()
    $RouteSplitRegex = [regex]::new('\s*->\s*|\s+- \s*')

    foreach ($Session in $Sessions) {
        if (-not $Session.Locations -or $Session.Locations.Count -eq 0) { continue }

        $DateStr = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { '' }

        foreach ($RawLoc in $Session.Locations) {
            if ([string]::IsNullOrWhiteSpace($RawLoc)) { continue }

            # Split route notation into individual locations for atomic tracking
            $Segments = $RouteSplitRegex.Split($RawLoc)

            # Record directional edges between consecutive route segments
            $CleanedSegments = [System.Collections.Generic.List[string]]::new()
            foreach ($Seg in $Segments) {
                $Cleaned = $Seg.Trim().TrimEnd('*').Trim()
                if ($Cleaned.Length -eq 0 -or $Cleaned -eq 'Brak') { continue }
                $CleanedSegments.Add($Cleaned)
            }
            for ($i = 0; $i -lt $CleanedSegments.Count - 1; $i++) {
                $RouteEdges.Add([PSCustomObject]@{
                    Source      = $CleanedSegments[$i]
                    Target      = $CleanedSegments[$i + 1]
                    SessionDate = $DateStr
                    Header      = $Session.Header
                    FilePath    = $Session.FilePath
                })
            }

            foreach ($Seg in $Segments) {
                $Cleaned = $Seg.Trim().TrimEnd('*').Trim()
                if ($Cleaned.Length -eq 0) { continue }
                if ($Cleaned -eq 'Brak') { continue }

                $RawOccurrences.Add([PSCustomObject]@{
                    Raw         = $Cleaned
                    FilePath    = $Session.FilePath
                    SessionDate = $DateStr
                    Header      = $Session.Header
                })
            }
        }
    }

    if ($RawOccurrences.Count -eq 0) { return [PSCustomObject]@{ Locations = @(); RouteEdges = @() } }

    # Parse slash paths into atomic segments and track parent-child relationships
    # ParentOf: normalized-child -> Set of observed parent names
    # ChildOf:  normalized-parent -> Set of observed child names
    $ParentOf = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $ChildOf = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # After splitting slash paths, each atomic segment becomes a separate occurrence
    $AtomicOccurrences = [System.Collections.Generic.List[object]]::new()

    foreach ($Occ in $RawOccurrences) {
        $Raw = $Occ.Raw

        if ($IncludeRawSlashPaths -or -not $Raw.Contains('/')) {
            $AtomicOccurrences.Add($Occ)
            continue
        }

        # Decompose "Parent/Child/Grandchild" into individual segments with hierarchy edges
        $Parts = $Raw.Split('/')
        for ($i = 0; $i -lt $Parts.Length; $i++) {
            $PartTrimmed = $Parts[$i].Trim()
            if ($PartTrimmed.Length -eq 0) { continue }

            $AtomicOccurrences.Add([PSCustomObject]@{
                Raw         = $PartTrimmed
                FilePath    = $Occ.FilePath
                SessionDate = $Occ.SessionDate
                Header      = $Occ.Header
            })

            # Track hierarchical relationships from slash path structure
            if ($i -gt 0) {
                $ParentName = $Parts[$i - 1].Trim()
                if ($ParentName.Length -eq 0) { continue }

                if (-not $ParentOf.ContainsKey($PartTrimmed)) {
                    $ParentOf[$PartTrimmed] = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                }
                [void]$ParentOf[$PartTrimmed].Add($ParentName)

                if (-not $ChildOf.ContainsKey($ParentName)) {
                    $ChildOf[$ParentName] = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                }
                [void]$ChildOf[$ParentName].Add($PartTrimmed)
            }
        }

        # Keep full slash path as a separate entry for reference tracking and QualifiedPath resolution
        $AtomicOccurrences.Add([PSCustomObject]@{
            Raw         = $Raw
            FilePath    = $Occ.FilePath
            SessionDate = $Occ.SessionDate
            Header      = $Occ.Header
        })
    }

    # 4. Group by normalized (lowercased) name; track raw spelling variants and occurrences
    $Groups = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Occ in $AtomicOccurrences) {
        $Normalized = $Occ.Raw.Trim().TrimEnd('*').Trim().ToLowerInvariant()
        if ($Normalized.Length -eq 0) { continue }

        if (-not $Groups.ContainsKey($Normalized)) {
            $Groups[$Normalized] = [PSCustomObject]@{
                NormalizedName = $Normalized
                RawCounts      = [System.Collections.Generic.Dictionary[string, int]]::new(
                    [System.StringComparer]::Ordinal)
                Occurrences    = [System.Collections.Generic.List[object]]::new()
            }
        }

        $Group = $Groups[$Normalized]
        $RawForm = $Occ.Raw
        if ($Group.RawCounts.ContainsKey($RawForm)) {
            $Group.RawCounts[$RawForm]++
        } else {
            $Group.RawCounts[$RawForm] = 1
        }
        $Group.Occurrences.Add($Occ)
    }

    # Canonical name = most frequently observed raw spelling (preserves intended casing)
    $CanonicalNames = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($KV in $Groups.GetEnumerator()) {
        $BestForm = $null
        $BestCount = 0
        foreach ($RC in $KV.Value.RawCounts.GetEnumerator()) {
            if ($RC.Value -gt $BestCount) {
                $BestCount = $RC.Value
                $BestForm = $RC.Key
            }
        }
        $CanonicalNames[$KV.Key] = $BestForm
    }

    # 5. Fuzzy match: detect near-duplicate location names across the corpus
    $NormalizedKeys = [System.Collections.Generic.List[string]]::new($Groups.Keys)

    # Map standalone names to qualified slash paths that contain them as leaf segments
    # (enables QualifiedPath resolution: "Tavern" -> "Ithan/Tavern")
    $QualifiedPaths = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Key in $NormalizedKeys) {
        if (-not $Key.Contains('/')) { continue }
        $Leaf = $Key.Substring($Key.LastIndexOf('/') + 1).Trim()
        if ($Leaf.Length -eq 0) { continue }
        if (-not $QualifiedPaths.ContainsKey($Leaf)) {
            $QualifiedPaths[$Leaf] = [System.Collections.Generic.List[string]]::new()
        }
        $QualifiedPaths[$Leaf].Add($CanonicalNames[$Key])
    }

    # Build resolution candidates: QualifiedPath matches for standalone names
    $Resolutions = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Key in $NormalizedKeys) {
        $ResList = [System.Collections.Generic.List[object]]::new()

        # High-confidence resolution: standalone name is a leaf of a qualified slash path
        if (-not $Key.Contains('/') -and $QualifiedPaths.ContainsKey($Key)) {
            foreach ($QP in $QualifiedPaths[$Key]) {
                $ResList.Add([PSCustomObject]@{
                    Target     = $QP
                    Reason     = 'QualifiedPath'
                    Confidence = 'High'
                })
            }
        }

        $Resolutions[$Key] = $ResList
    }

    # Filter to simple (non-slash) keys for pairwise comparison
    $SimpleKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($Key in $NormalizedKeys) {
        if (-not $Key.Contains('/')) { $SimpleKeys.Add($Key) }
    }

    # C# fast path: batch pairwise distance via Robot.BKTree.FindFuzzyPairs
    if (([System.Management.Automation.PSTypeName]'Robot.BKTree').Type -and $SimpleKeys.Count -ge 2) {
        $KeyArray = [string[]]$SimpleKeys.ToArray()
        $Pairs = [Robot.BKTree]::FindFuzzyPairs($KeyArray, $MaxEditDistance)
        foreach ($Pair in $Pairs) {
            $KeyA = $KeyArray[$Pair[0]]
            $KeyB = $KeyArray[$Pair[1]]
            $Dist = $Pair[2]

            $Reason = "EditDistance$Dist"
            $Conf = if ($Dist -eq 1) { 'Medium' } else { 'Low' }

            $NameA = $CanonicalNames[$KeyA]
            $NameB = $CanonicalNames[$KeyB]

            if (-not $Resolutions.ContainsKey($KeyA)) {
                $Resolutions[$KeyA] = [System.Collections.Generic.List[object]]::new()
            }
            $Resolutions[$KeyA].Add([PSCustomObject]@{
                Target = $NameB; Reason = $Reason; Confidence = $Conf
            })

            if (-not $Resolutions.ContainsKey($KeyB)) {
                $Resolutions[$KeyB] = [System.Collections.Generic.List[object]]::new()
            }
            $Resolutions[$KeyB].Add([PSCustomObject]@{
                Target = $NameA; Reason = $Reason; Confidence = $Conf
            })
        }
    } else {
        # PowerShell fallback: O(n^2) with length-difference pruning
        $FuzzyPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        for ($i = 0; $i -lt $SimpleKeys.Count; $i++) {
            $KeyA = $SimpleKeys[$i]
            if ($KeyA.Length -lt 3) { continue }
            for ($j = $i + 1; $j -lt $SimpleKeys.Count; $j++) {
                $KeyB = $SimpleKeys[$j]
                if ($KeyB.Length -lt 3) { continue }
                # Quick length-difference pruning
                if ([Math]::Abs($KeyA.Length - $KeyB.Length) -gt $MaxEditDistance) { continue }

                $Dist = Get-LevenshteinDistance -Source $KeyA -Target $KeyB
                if ($Dist -gt 0 -and $Dist -le $MaxEditDistance) {
                    $PairKey = if ($KeyA -lt $KeyB) { "$KeyA|$KeyB" } else { "$KeyB|$KeyA" }
                    if ($FuzzyPairs.Contains($PairKey)) { continue }
                    [void]$FuzzyPairs.Add($PairKey)

                    $Reason = "EditDistance$Dist"
                    $Conf = if ($Dist -eq 1) { 'Medium' } else { 'Low' }

                    $NameA = $CanonicalNames[$KeyA]
                    $NameB = $CanonicalNames[$KeyB]

                    if (-not $Resolutions.ContainsKey($KeyA)) {
                        $Resolutions[$KeyA] = [System.Collections.Generic.List[object]]::new()
                    }
                    $Resolutions[$KeyA].Add([PSCustomObject]@{
                        Target = $NameB; Reason = $Reason; Confidence = $Conf
                    })

                    if (-not $Resolutions.ContainsKey($KeyB)) {
                        $Resolutions[$KeyB] = [System.Collections.Generic.List[object]]::new()
                    }
                    $Resolutions[$KeyB].Add([PSCustomObject]@{
                        Target = $NameA; Reason = $Reason; Confidence = $Conf
                    })
                }
            }
        }
    }

    # 6. Scan session files for exact line references (opt-in, I/O-heavy)
    $RefsByNormalized = @{}
    if ($IncludeReferences) {
        # Per-file line cache: avoids re-reading the same session file for multiple occurrences
        $FileLines = [System.Collections.Generic.Dictionary[string, string[]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $RepoRoot = Get-RepoRoot

        foreach ($KV in $Groups.GetEnumerator()) {
            $Norm = $KV.Key
            $Group = $KV.Value
            $Refs = [System.Collections.Generic.List[object]]::new()

            foreach ($Occ in $Group.Occurrences) {
                $FP = $Occ.FilePath
                if (-not $FP -or $FP.Length -eq 0) { continue }

                if (-not $FileLines.ContainsKey($FP)) {
                    $FullPath = if ([System.IO.Path]::IsPathRooted($FP)) { $FP }
                                else { [System.IO.Path]::Combine($RepoRoot, $FP) }
                    if ([System.IO.File]::Exists($FullPath)) {
                        $FileLines[$FP] = [System.IO.File]::ReadAllLines($FullPath)
                    } else {
                        $FileLines[$FP] = @()
                    }
                }

                $Lines = $FileLines[$FP]
                $SearchText = $Occ.Raw
                $FoundLine = -1
                # Linear scan for the first matching line (sufficient for reference tracking)
                for ($ln = 0; $ln -lt $Lines.Length; $ln++) {
                    if ($Lines[$ln].Contains($SearchText)) {
                        $FoundLine = $ln + 1  # 1-based line number for editor navigation
                        break
                    }
                }

                $Refs.Add([PSCustomObject]@{
                    FilePath    = $FP
                    LineNumber  = $FoundLine
                    SessionDate = $Occ.SessionDate
                    RawText     = $Occ.Raw
                })
            }

            $RefsByNormalized[$Norm] = $Refs
        }
    }

    # 7. Three-stage entity resolution: exact -> fuzzy+Lokacja -> fuzzy+any type
    $EntityMatches = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $NameIdx = $null
    try {
        $IdxArgs = @{}
        if ($Entities) { $IdxArgs['Entities'] = $Entities }
        $NameIdxResult = Get-NameIndex @IdxArgs
        $NameIdx = $NameIdxResult.Index
        $StemIdx = $NameIdxResult.StemIndex
        $BKTree  = $NameIdxResult.BKTree
    } catch {
        Write-RobotWarning "[WARN Get-NamedLocationReport] Could not build name index: $_"
    }

    if ($NameIdx) {
        $ResolveCache = @{}

        foreach ($Key in $NormalizedKeys) {
            $CanonName = $CanonicalNames[$Key]

            # Stage 1: Direct index lookup (case-insensitive exact match, Lokacja only)
            $MatchStage = $null
            $MatchEntry = $null

            if ($NameIdx.ContainsKey($CanonName)) {
                $Entry = $NameIdx[$CanonName]
                if ($Entry.OwnerType -eq 'Lokacja') {
                    $MatchEntry = $Entry
                    $MatchStage = 'Exact'
                }
            }

            # Stage 2: Full resolution pipeline (declension, stem, fuzzy) scoped to Lokacja
            if (-not $MatchEntry) {
                try {
                    $Resolved = Resolve-Name -Query $CanonName -Index $NameIdx `
                        -StemIndex $StemIdx -BKTree $BKTree `
                        -OwnerType 'Lokacja' -Cache $ResolveCache
                    if ($Resolved) {
                        $MatchEntry = [PSCustomObject]@{
                            Owner     = $Resolved
                            OwnerType = 'Lokacja'
                            Ambiguous = $false
                        }
                        $MatchStage = 'Fuzzy'
                    }
                } catch { }
            }

            # Stage 3: Unscoped resolution — catches entities registered under wrong type
            $AnyTypeMatch = $null
            if (-not $MatchEntry) {
                try {
                    $Resolved = Resolve-Name -Query $CanonName -Index $NameIdx `
                        -StemIndex $StemIdx -BKTree $BKTree -Cache $ResolveCache
                    if ($Resolved) {
                        $AnyTypeMatch = $Resolved
                    }
                } catch { }
            }

            if ($MatchEntry) {
                $Owner = if ($MatchEntry.Owner) { $MatchEntry.Owner } else { $null }
                $EntityMatches[$Key] = [PSCustomObject]@{
                    EntityName  = if ($Owner -and $Owner.Name) { $Owner.Name } else { $CanonName }
                    EntityCN    = if ($Owner -and $Owner.CN) { $Owner.CN } else { $null }
                    EntityType  = 'Lokacja'
                    NerthusName = if ($Owner -and $Owner.PSObject.Properties['NerthusName']) { $Owner.NerthusName } else { $null }
                    MatchStage  = $MatchStage
                    IsAmbiguous = if ($MatchEntry.Ambiguous) { $true } else { $false }
                }
            } elseif ($AnyTypeMatch) {
                $EntityMatches[$Key] = [PSCustomObject]@{
                    EntityName  = if ($AnyTypeMatch.Name) { $AnyTypeMatch.Name } else { $CanonName }
                    EntityCN    = if ($AnyTypeMatch.CN) { $AnyTypeMatch.CN } else { $null }
                    EntityType  = if ($AnyTypeMatch.Type) { $AnyTypeMatch.Type } else { 'Unknown' }
                    NerthusName = if ($AnyTypeMatch.PSObject.Properties['NerthusName']) { $AnyTypeMatch.NerthusName } else { $null }
                    MatchStage  = 'Fuzzy'
                    IsAmbiguous = $false
                }
            }
        }
    }

    # 8. Detect naming conflicts and data quality issues
    $ConflictsByNormalized = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Key in $NormalizedKeys) {
        $Conflicts = [System.Collections.Generic.List[object]]::new()
        $Group = $Groups[$Key]

        # CaseVariant: multiple spellings suggest inconsistent data entry
        $DistinctCaseForms = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal)
        foreach ($RC in $Group.RawCounts.Keys) {
            [void]$DistinctCaseForms.Add($RC)
        }
        if ($DistinctCaseForms.Count -gt 1) {
            $Forms = ($DistinctCaseForms | Sort-Object) -join "', '"
            $Conflicts.Add([PSCustomObject]@{
                Type    = 'CaseVariant'
                Details = "Multiple spellings: '$Forms'"
            })
        }

        # TrailingArtifact: whitespace or asterisk remnants from copy-paste errors
        foreach ($Occ in $RawOccurrences) {
            $TestRaw = $Occ.Raw
            if ($TestRaw.ToLowerInvariant().TrimEnd('*').Trim() -eq $Key) {
                if ($TestRaw -ne $TestRaw.Trim() -or $TestRaw.EndsWith('*')) {
                    $Conflicts.Add([PSCustomObject]@{
                        Type    = 'TrailingArtifact'
                        Details = "Raw form has artifacts: '$TestRaw'"
                    })
                    break
                }
            }
        }

        # AmbiguousStandalone: bare name could refer to multiple qualified locations
        if (-not $Key.Contains('/') -and $QualifiedPaths.ContainsKey($Key)) {
            $Paths = ($QualifiedPaths[$Key] | Sort-Object) -join "', '"
            $Conflicts.Add([PSCustomObject]@{
                Type    = 'AmbiguousStandalone'
                Details = "Standalone name also appears in qualified paths: '$Paths'"
            })
        }

        # InconsistentHierarchy: conflicting parent assignments from different slash paths
        if ($ParentOf.ContainsKey($Key) -and $ParentOf[$Key].Count -gt 1) {
            $Parents = ($ParentOf[$Key] | Sort-Object) -join "', '"
            $Conflicts.Add([PSCustomObject]@{
                Type    = 'InconsistentHierarchy'
                Details = "Appears under multiple parents: '$Parents'"
            })
        }

        $ConflictsByNormalized[$Key] = $Conflicts
    }

    # NearDuplicate: add Levenshtein-based conflicts from fuzzy pair detection
    foreach ($Pair in $FuzzyPairs) {
        $SplitIdx = $Pair.IndexOf('|')
        $KeyA = $Pair.Substring(0, $SplitIdx)
        $KeyB = $Pair.Substring($SplitIdx + 1)
        $Dist = Get-LevenshteinDistance -Source $KeyA -Target $KeyB

        $NameA = $CanonicalNames[$KeyA]
        $NameB = $CanonicalNames[$KeyB]

        if (-not $ConflictsByNormalized.ContainsKey($KeyA)) {
            $ConflictsByNormalized[$KeyA] = [System.Collections.Generic.List[object]]::new()
        }
        $ConflictsByNormalized[$KeyA].Add([PSCustomObject]@{
            Type    = 'NearDuplicate'
            Details = "Similar to '$NameB' (edit distance: $Dist)"
        })

        if (-not $ConflictsByNormalized.ContainsKey($KeyB)) {
            $ConflictsByNormalized[$KeyB] = [System.Collections.Generic.List[object]]::new()
        }
        $ConflictsByNormalized[$KeyB].Add([PSCustomObject]@{
            Type    = 'NearDuplicate'
            Details = "Similar to '$NameA' (edit distance: $Dist)"
        })
    }

    # 9. Assemble final report objects with all enrichment data
    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($KV in $Groups.GetEnumerator()) {
        $Norm = $KV.Key
        $Group = $KV.Value
        $TotalCount = $Group.Occurrences.Count

        if ($TotalCount -lt $MinOccurrences) { continue }

        $CanonName = $CanonicalNames[$Norm]

        # Non-canonical raw forms (case-sensitive comparison to preserve variants)
        $Variants = [System.Collections.Generic.List[string]]::new()
        foreach ($RC in $Group.RawCounts.Keys) {
            if ($RC -cne $CanonName) { $Variants.Add($RC) }
        }

        # Resolve inferred parents/children from slash path hierarchy
        $InfParents = if ($ParentOf.ContainsKey($Norm)) {
            @($ParentOf[$Norm] | ForEach-Object { if ($CanonicalNames.ContainsKey($_)) { $CanonicalNames[$_] } else { $_ } })
        } else { @() }

        $InfChildren = if ($ChildOf.ContainsKey($Norm)) {
            @($ChildOf[$Norm] | ForEach-Object { if ($CanonicalNames.ContainsKey($_)) { $CanonicalNames[$_] } else { $_ } })
        } else { @() }

        # Resolution candidates from QualifiedPath and fuzzy matching
        $LRT = if ($Resolutions.ContainsKey($Norm)) { @($Resolutions[$Norm]) } else { @() }

        # File/line references (only populated when -IncludeReferences is set)
        $Refs = if ($IncludeReferences -and $RefsByNormalized.ContainsKey($Norm)) {
            @($RefsByNormalized[$Norm])
        } else { @() }

        # Three-stage entity resolution result (if any)
        $EM = if ($EntityMatches.ContainsKey($Norm)) { $EntityMatches[$Norm] } else { $null }

        # Detected naming conflicts and data quality issues
        $Conf = if ($ConflictsByNormalized.ContainsKey($Norm)) {
            @($ConflictsByNormalized[$Norm])
        } else { @() }

        $Report.Add([PSCustomObject]@{
            Name             = $CanonName
            NormalizedName   = $Norm
            Variants         = @($Variants)
            OccurrenceCount  = $TotalCount
            InferredParents  = $InfParents
            InferredChildren = $InfChildren
            LikelyResolvesTo = $LRT
            References       = $Refs
            EntityMatch      = $EM
            Conflicts        = $Conf
        })
    }

    # Most-referenced locations first for coordinator prioritization
    $Sorted = $Report | Sort-Object -Property OccurrenceCount -Descending
    $Result = @($Sorted)

    # Bundle route edges alongside locations for Get-LocationGraph edge sourcing
    $Result = [PSCustomObject]@{
        Locations  = $Result
        RouteEdges = @($RouteEdges)
    }
    return $Result

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

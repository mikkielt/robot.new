<#
    .SYNOPSIS
    Reports all location names found across recorded sessions.

    .DESCRIPTION
    This file contains Get-NamedLocationReport.

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance.

    Scans all sessions for location references, normalizes and groups them,
    detects hierarchy from slash-separated paths, finds fuzzy near-duplicates,
    resolves against the named entity registry, and flags potential conflicts.
    Designed to guide manual creation of Lokacja entities.
#>

# Dot-source shared helpers
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
        [switch]$IncludeRawSlashPaths
    )

    # 1. Load sessions
    if (-not $Sessions) {
        $GetSessionArgs = @{}
        if ($MinDate) { $GetSessionArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $GetSessionArgs['MaxDate'] = $MaxDate }
        $Sessions = Get-Session @GetSessionArgs
    }

    # 2. Extract raw location data
    # Each occurrence: raw string + session metadata
    $RawOccurrences = [System.Collections.Generic.List[object]]::new()
    $RouteSplitRegex = [regex]::new('\s*->\s*|\s+- \s*')

    foreach ($Session in $Sessions) {
        if (-not $Session.Locations -or $Session.Locations.Count -eq 0) { continue }

        $DateStr = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { '' }

        foreach ($RawLoc in $Session.Locations) {
            if ([string]::IsNullOrWhiteSpace($RawLoc)) { continue }

            # Split route separators (-> and  -  patterns) into individual locations
            $Segments = $RouteSplitRegex.Split($RawLoc)

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

    if ($RawOccurrences.Count -eq 0) { return @() }

    # Parse slash paths & build hierarchy
    # ParentOf: normalized-child -> Set of normalized-parent names
    # ChildOf:  normalized-parent -> Set of normalized-child names
    $ParentOf = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $ChildOf = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Expanded occurrences: after splitting slash paths, each atomic segment is an occurrence
    $AtomicOccurrences = [System.Collections.Generic.List[object]]::new()

    foreach ($Occ in $RawOccurrences) {
        $Raw = $Occ.Raw

        if ($IncludeRawSlashPaths -or -not $Raw.Contains('/')) {
            $AtomicOccurrences.Add($Occ)
            continue
        }

        # Split slash path into segments
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

            # Register parent/child
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

        # Also register the full slash path as a separate entry for reference tracking
        $AtomicOccurrences.Add([PSCustomObject]@{
            Raw         = $Raw
            FilePath    = $Occ.FilePath
            SessionDate = $Occ.SessionDate
            Header      = $Occ.Header
        })
    }

    # 4. Normalize and group
    # Group by normalized name; track raw variants and occurrences
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

    # Pick canonical name: most frequent raw form
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

    # 5. Fuzzy match - cross-location resolution
    $NormalizedKeys = [System.Collections.Generic.List[string]]::new($Groups.Keys)

    # Pre-build: for each normalized name, which qualified slash paths contain it as leaf
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

    # Build LikelyResolvesTo per location
    $Resolutions = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Key in $NormalizedKeys) {
        $ResList = [System.Collections.Generic.List[object]]::new()

        # QualifiedPath: standalone name matches leaf of a slash path
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

    # Levenshtein fuzzy matching (O(n²) over unique keys, skip slash paths for performance)
    $SimpleKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($Key in $NormalizedKeys) {
        if (-not $Key.Contains('/')) { $SimpleKeys.Add($Key) }
    }

    # Track pairs already processed to avoid duplicates
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

    # 6. Scan references (opt-in)
    $RefsByNormalized = @{}
    if ($IncludeReferences) {
        # Build file->lines cache to avoid reading files multiple times
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
                # Search near session header for efficiency
                for ($ln = 0; $ln -lt $Lines.Length; $ln++) {
                    if ($Lines[$ln].Contains($SearchText)) {
                        # Verify it's near a matching session header
                        $FoundLine = $ln + 1
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

    # 7. Resolve entities
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
        [System.Console]::Error.WriteLine("[WARN Get-NamedLocationReport] Could not build name index: $_")
    }

    if ($NameIdx) {
        $ResolveCache = @{}

        foreach ($Key in $NormalizedKeys) {
            $CanonName = $CanonicalNames[$Key]

            # Stage 1: Direct index lookup (case-insensitive exact)
            $MatchStage = $null
            $MatchEntry = $null

            if ($NameIdx.ContainsKey($CanonName)) {
                $Entry = $NameIdx[$CanonName]
                if ($Entry.OwnerType -eq 'Lokacja') {
                    $MatchEntry = $Entry
                    $MatchStage = 'Exact'
                }
            }

            # Stage 2: Full Resolve-Name with Lokacja filter
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

            # Stage 3: Resolve-Name without type filter (catch mis-typed entities)
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
                    MatchStage  = $MatchStage
                    IsAmbiguous = if ($MatchEntry.Ambiguous) { $true } else { $false }
                }
            } elseif ($AnyTypeMatch) {
                $EntityMatches[$Key] = [PSCustomObject]@{
                    EntityName  = if ($AnyTypeMatch.Name) { $AnyTypeMatch.Name } else { $CanonName }
                    EntityCN    = if ($AnyTypeMatch.CN) { $AnyTypeMatch.CN } else { $null }
                    EntityType  = if ($AnyTypeMatch.Type) { $AnyTypeMatch.Type } else { 'Unknown' }
                    MatchStage  = 'Fuzzy'
                    IsAmbiguous = $false
                }
            }
        }
    }

    # 8. Detect conflicts
    $ConflictsByNormalized = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Key in $NormalizedKeys) {
        $Conflicts = [System.Collections.Generic.List[object]]::new()
        $Group = $Groups[$Key]

        # CaseVariant: multiple raw forms with different casing
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

        # TrailingArtifact: check original raw occurrences before cleaning
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

        # AmbiguousStandalone: bare name exists AND qualified Parent/Name exists
        if (-not $Key.Contains('/') -and $QualifiedPaths.ContainsKey($Key)) {
            $Paths = ($QualifiedPaths[$Key] | Sort-Object) -join "', '"
            $Conflicts.Add([PSCustomObject]@{
                Type    = 'AmbiguousStandalone'
                Details = "Standalone name also appears in qualified paths: '$Paths'"
            })
        }

        # InconsistentHierarchy: same child under different parents
        if ($ParentOf.ContainsKey($Key) -and $ParentOf[$Key].Count -gt 1) {
            $Parents = ($ParentOf[$Key] | Sort-Object) -join "', '"
            $Conflicts.Add([PSCustomObject]@{
                Type    = 'InconsistentHierarchy'
                Details = "Appears under multiple parents: '$Parents'"
            })
        }

        $ConflictsByNormalized[$Key] = $Conflicts
    }

    # NearDuplicate: add from fuzzy pairs
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

    # 9. Assemble report
    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($KV in $Groups.GetEnumerator()) {
        $Norm = $KV.Key
        $Group = $KV.Value
        $TotalCount = $Group.Occurrences.Count

        if ($TotalCount -lt $MinOccurrences) { continue }

        $CanonName = $CanonicalNames[$Norm]

        # Variants: all raw forms except the canonical one
        $Variants = [System.Collections.Generic.List[string]]::new()
        foreach ($RC in $Group.RawCounts.Keys) {
            if ($RC -cne $CanonName) { $Variants.Add($RC) }
        }

        # Inferred hierarchy
        $InfParents = if ($ParentOf.ContainsKey($Norm)) {
            @($ParentOf[$Norm] | ForEach-Object { if ($CanonicalNames.ContainsKey($_)) { $CanonicalNames[$_] } else { $_ } })
        } else { @() }

        $InfChildren = if ($ChildOf.ContainsKey($Norm)) {
            @($ChildOf[$Norm] | ForEach-Object { if ($CanonicalNames.ContainsKey($_)) { $CanonicalNames[$_] } else { $_ } })
        } else { @() }

        # LikelyResolvesTo
        $LRT = if ($Resolutions.ContainsKey($Norm)) { @($Resolutions[$Norm]) } else { @() }

        # References
        $Refs = if ($IncludeReferences -and $RefsByNormalized.ContainsKey($Norm)) {
            @($RefsByNormalized[$Norm])
        } else { @() }

        # EntityMatch
        $EM = if ($EntityMatches.ContainsKey($Norm)) { $EntityMatches[$Norm] } else { $null }

        # Conflicts
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

    # Sort by occurrence count descending
    $Sorted = $Report | Sort-Object -Property OccurrenceCount -Descending

    return @($Sorted)
}

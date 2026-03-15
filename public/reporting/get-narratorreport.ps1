<#
    .SYNOPSIS
    Reports all narrator names found across recorded sessions.

    .DESCRIPTION
    Get-NarratorReport scans all sessions for narrator data and produces
    a structured report for guiding manual creation of narrator
    normalization entries and player aliases.

    Processing pipeline:
    1. Extract raw narrator text from session headers (third
       comma-separated segment) along with resolution Confidence,
       resolved Narrators list, and IsCouncil flag
    2. Normalize and group by case-insensitive key, pick canonical
       spelling (most frequently observed raw form wins)
    3. Levenshtein near-duplicate detection (O(n^2) with
       length-difference pruning, skips names shorter than 3 chars)
    4. Cross-reference against existing narrator mappings from
       migration/narrator-normalization.ps1 (Import-NarratorMappings)
       to identify which narrators already have normalization entries
    5. Conflict detection: CaseVariant (multiple raw spellings),
       NearDuplicate (Levenshtein-based similar names)
    6. Optional UnresolvedOnly filter (Confidence='None') to surface
       only narrators that the resolution pipeline could not map to
       any known player

    Each report entry includes: canonical RawText, Variants, OccurrenceCount,
    Confidence level (from Resolve-Narrator), ResolvedPlayers, IsCouncil
    flag, HasMapping status, MappedTo targets, NearDuplicates list,
    Conflicts array, and optional Sessions references.

    The Confidence field reflects how the narrator text was resolved:
    'High' (exact player match), 'Medium' (fuzzy or alias match),
    'None' (unresolved — needs manual normalization entry).

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance.
#>

. "$script:ModuleRoot/private/string-helpers.ps1"

function Get-NarratorReport {
    <#
        .SYNOPSIS
        Analyze narrator names across all sessions and produce a structured report.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Only include narrators seen at least this many times")]
        [int]$MinOccurrences = 1,

        [Parameter(HelpMessage = "Maximum Levenshtein distance for fuzzy matching")]
        [int]$MaxEditDistance = 2,

        [Parameter(HelpMessage = "Include session references per narrator")]
        [switch]$IncludeReferences,

        [Parameter(HelpMessage = "Only return unresolved narrators (Confidence = None)")]
        [switch]$UnresolvedOnly
    )

    # 1. Load sessions
    if (-not $Sessions) {
        $GetSessionArgs = @{}
        if ($MinDate) { $GetSessionArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $GetSessionArgs['MaxDate'] = $MaxDate }
        $Sessions = Get-Session @GetSessionArgs
    }

    # 2. Extract raw narrator data
    $RawOccurrences = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in $Sessions) {
        $Narr = $Session.Narrator
        if ($null -eq $Narr -or $null -eq $Narr.RawText) { continue }

        $RawOccurrences.Add([PSCustomObject]@{
            RawText    = $Narr.RawText
            Confidence = $Narr.Confidence
            Narrators  = $Narr.Narrators
            IsCouncil  = $Narr.IsCouncil
            FilePath   = $Session.FilePath
            Date       = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { '' }
            Header     = $Session.Header
        })
    }

    if ($RawOccurrences.Count -eq 0) { return @() }

    # 3. Group by normalized (lowercased) text; track raw spelling variants
    $Groups = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Occ in $RawOccurrences) {
        $Normalized = $Occ.RawText.Trim().ToLowerInvariant()
        if ($Normalized.Length -eq 0) { continue }

        if (-not $Groups.ContainsKey($Normalized)) {
            $Groups[$Normalized] = [PSCustomObject]@{
                NormalizedText = $Normalized
                RawCounts      = [System.Collections.Generic.Dictionary[string, int]]::new(
                    [System.StringComparer]::Ordinal)
                Occurrences    = [System.Collections.Generic.List[object]]::new()
                Confidence     = $Occ.Confidence
                Narrators      = $Occ.Narrators
                IsCouncil      = $Occ.IsCouncil
            }
        }

        $Group = $Groups[$Normalized]
        $RawForm = $Occ.RawText
        if ($Group.RawCounts.ContainsKey($RawForm)) {
            $Group.RawCounts[$RawForm]++
        } else {
            $Group.RawCounts[$RawForm] = 1
        }
        $Group.Occurrences.Add($Occ)
    }

    # Canonical form = most frequently observed raw spelling (preserves intended casing)
    $CanonicalForms = [System.Collections.Generic.Dictionary[string, string]]::new(
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
        $CanonicalForms[$KV.Key] = $BestForm
    }

    # 4. Pairwise Levenshtein detection: identify narrator names that may be typos
    $NormalizedKeys = [System.Collections.Generic.List[string]]::new($Groups.Keys)
    $FuzzyPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $NearDuplicates = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $NormalizedKeys.Count; $i++) {
        $KeyA = $NormalizedKeys[$i]
        if ($KeyA.Length -lt 3) { continue }
        for ($j = $i + 1; $j -lt $NormalizedKeys.Count; $j++) {
            $KeyB = $NormalizedKeys[$j]
            if ($KeyB.Length -lt 3) { continue }
            if ([Math]::Abs($KeyA.Length - $KeyB.Length) -gt $MaxEditDistance) { continue }

            $Dist = Get-LevenshteinDistance -Source $KeyA -Target $KeyB
            if ($Dist -gt 0 -and $Dist -le $MaxEditDistance) {
                $PairKey = if ($KeyA -lt $KeyB) { "$KeyA|$KeyB" } else { "$KeyB|$KeyA" }
                if ($FuzzyPairs.Contains($PairKey)) { continue }
                [void]$FuzzyPairs.Add($PairKey)

                $NameA = $CanonicalForms[$KeyA]
                $NameB = $CanonicalForms[$KeyB]

                if (-not $NearDuplicates.ContainsKey($KeyA)) {
                    $NearDuplicates[$KeyA] = [System.Collections.Generic.List[object]]::new()
                }
                $NearDuplicates[$KeyA].Add([PSCustomObject]@{ Target = $NameB; EditDistance = $Dist })

                if (-not $NearDuplicates.ContainsKey($KeyB)) {
                    $NearDuplicates[$KeyB] = [System.Collections.Generic.List[object]]::new()
                }
                $NearDuplicates[$KeyB].Add([PSCustomObject]@{ Target = $NameA; EditDistance = $Dist })
            }
        }
    }

    # 5. Load existing narrator normalization mappings for HasMapping check
    . "$script:ModuleRoot/migration/narrator-normalization.ps1"
    $Mappings = Import-NarratorMappings

    # 6. Detect naming conflicts: case variants and near-duplicates
    $ConflictsByNormalized = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Key in $NormalizedKeys) {
        $Conflicts = [System.Collections.Generic.List[object]]::new()
        $Group = $Groups[$Key]

        # CaseVariant: multiple spellings suggest inconsistent data entry
        $DistinctForms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($RC in $Group.RawCounts.Keys) {
            [void]$DistinctForms.Add($RC)
        }
        if ($DistinctForms.Count -gt 1) {
            $Forms = ($DistinctForms | Sort-Object) -join "', '"
            $Conflicts.Add([PSCustomObject]@{
                Type    = 'CaseVariant'
                Details = "Multiple spellings: '$Forms'"
            })
        }

        # NearDuplicate
        if ($NearDuplicates.ContainsKey($Key)) {
            foreach ($ND in $NearDuplicates[$Key]) {
                $Conflicts.Add([PSCustomObject]@{
                    Type    = 'NearDuplicate'
                    Details = "Similar to '$($ND.Target)' (edit distance: $($ND.EditDistance))"
                })
            }
        }

        $ConflictsByNormalized[$Key] = $Conflicts
    }

    # 7. Assemble final report objects with all enrichment data
    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($KV in $Groups.GetEnumerator()) {
        $Norm = $KV.Key
        $Group = $KV.Value
        $TotalCount = $Group.Occurrences.Count

        if ($TotalCount -lt $MinOccurrences) { continue }

        $CanonRaw = $CanonicalForms[$Norm]

        # Non-canonical raw forms (case-sensitive comparison to preserve variants)
        $Variants = [System.Collections.Generic.List[string]]::new()
        foreach ($RC in $Group.RawCounts.Keys) {
            if ($RC -cne $CanonRaw) { $Variants.Add($RC) }
        }

        # Extract player names from Resolve-Narrator results
        $ResolvedPlayers = [System.Collections.Generic.List[string]]::new()
        if ($Group.Narrators -and $Group.Narrators.Count -gt 0) {
            foreach ($N in $Group.Narrators) {
                if ($N.Name) { $ResolvedPlayers.Add($N.Name) }
            }
        }

        # Check if narrator-normalization.ps1 already has an entry for this narrator
        $HasMapping = $Mappings.ContainsKey($CanonRaw)
        $MappedTo = if ($HasMapping) { $Mappings[$CanonRaw] } else { @() }

        # Levenshtein-based similar narrators (potential typos)
        $ND = if ($NearDuplicates.ContainsKey($Norm)) { @($NearDuplicates[$Norm]) } else { @() }

        # All detected naming conflicts for this narrator
        $Conf = if ($ConflictsByNormalized.ContainsKey($Norm)) {
            @($ConflictsByNormalized[$Norm])
        } else { @() }

        # Per-session references (only populated when -IncludeReferences is set)
        $SessionRefs = @()
        if ($IncludeReferences) {
            $SessionRefs = @($Group.Occurrences | ForEach-Object {
                [PSCustomObject]@{
                    FilePath = $_.FilePath
                    Date     = $_.Date
                    Header   = $_.Header
                }
            })
        }

        # Skip resolved narrators when caller only wants unresolved ones
        if ($UnresolvedOnly -and $Group.Confidence -ne 'None') { continue }

        $Report.Add([PSCustomObject]@{
            RawText         = $CanonRaw
            NormalizedText  = $Norm
            Variants        = @($Variants)
            OccurrenceCount = $TotalCount
            Confidence      = $Group.Confidence
            ResolvedPlayers = @($ResolvedPlayers)
            IsCouncil       = $Group.IsCouncil
            HasMapping      = $HasMapping
            MappedTo        = @($MappedTo)
            NearDuplicates  = $ND
            Conflicts       = $Conf
            Sessions        = $SessionRefs
        })
    }

    # Most-referenced narrators first for coordinator prioritization
    $Sorted = $Report | Sort-Object -Property OccurrenceCount -Descending

    return @($Sorted)
}

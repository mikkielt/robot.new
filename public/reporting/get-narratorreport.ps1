<#
    .SYNOPSIS
    Reports all narrator names found across recorded sessions.

    .DESCRIPTION
    Scans all sessions for narrator data and produces a structured report
    for guiding manual creation of narrator normalization entries and
    player aliases.

    Processing pipeline:
    1. Extract raw narrator text from session headers (third comma-separated segment)
    2. Normalize and group by case-insensitive key, pick canonical spelling
    3. Levenshtein near-duplicate detection (O(n^2) with length-difference pruning)
    4. Cross-reference against existing narrator mappings from
       migration/narrator-normalization.ps1 (Import-NarratorMappings)
    5. Conflict detection: CaseVariant, NearDuplicate
    6. Optional UnresolvedOnly filter (Confidence = None)

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance.
#>

# Dot-source shared helpers
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

    # 3. Normalize and group by RawText (case-insensitive)
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

    # Pick canonical raw form: most frequent spelling
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

    # 4. Levenshtein near-duplicate detection (O(n²) over unique normalized keys)
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

    # 5. Check existing narrator mappings
    . "$script:ModuleRoot/migration/narrator-normalization.ps1"
    $Mappings = Import-NarratorMappings

    # 6. Detect conflicts
    $ConflictsByNormalized = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Key in $NormalizedKeys) {
        $Conflicts = [System.Collections.Generic.List[object]]::new()
        $Group = $Groups[$Key]

        # CaseVariant: multiple raw forms
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

    # 7. Assemble report
    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($KV in $Groups.GetEnumerator()) {
        $Norm = $KV.Key
        $Group = $KV.Value
        $TotalCount = $Group.Occurrences.Count

        if ($TotalCount -lt $MinOccurrences) { continue }

        $CanonRaw = $CanonicalForms[$Norm]

        # Variants: all raw forms except the canonical one
        $Variants = [System.Collections.Generic.List[string]]::new()
        foreach ($RC in $Group.RawCounts.Keys) {
            if ($RC -cne $CanonRaw) { $Variants.Add($RC) }
        }

        # Resolved players
        $ResolvedPlayers = [System.Collections.Generic.List[string]]::new()
        if ($Group.Narrators -and $Group.Narrators.Count -gt 0) {
            foreach ($N in $Group.Narrators) {
                if ($N.Name) { $ResolvedPlayers.Add($N.Name) }
            }
        }

        # Mapping check
        $HasMapping = $Mappings.ContainsKey($CanonRaw)
        $MappedTo = if ($HasMapping) { $Mappings[$CanonRaw] } else { @() }

        # NearDuplicates
        $ND = if ($NearDuplicates.ContainsKey($Norm)) { @($NearDuplicates[$Norm]) } else { @() }

        # Conflicts
        $Conf = if ($ConflictsByNormalized.ContainsKey($Norm)) {
            @($ConflictsByNormalized[$Norm])
        } else { @() }

        # Session references
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

        # Apply UnresolvedOnly filter
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

    # Sort by occurrence count descending
    $Sorted = $Report | Sort-Object -Property OccurrenceCount -Descending

    return @($Sorted)
}

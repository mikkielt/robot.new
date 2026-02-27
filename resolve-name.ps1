<#
    .SYNOPSIS
    Generalized name resolution engine — resolves query strings to named objects (players, NPCs,
    organizations, locations) via index lookup, Polish declension stripping, stem-alternation
    reversal, and Levenshtein fuzzy matching.

    .DESCRIPTION
    This file contains the Resolve-Name function and its supporting helpers:

    Helpers:
    - Get-DeclensionStem:            strips Polish noun declension suffixes from a query
    - Get-StemAlternationCandidates:  reverses Polish consonant mutations to produce base-form candidates
    - Get-LevenshteinDistance:        computes edit distance between two strings (two-row matrix)

    Module-level data:
    - $DeclensionSuffixes:  ordered list of Polish noun suffixes (longest-first to prevent partial stripping)
    - $StemAlternations:    consonant mutation mappings (inflected ending -> nominative base)

    Resolve-Name uses a multi-stage pipeline:
      Stage 1  — Exact index lookup (case-insensitive). O(1) via the token index from Get-NameIndex.
      Stage 2  — Declension-stripped match. Strips Polish case suffixes and looks up the stem
                 in the pre-built stem index. Covers forms like "Korma" (genitive of "Korm"),
                 "Anwardem" (instrumental of "Anward").
      Stage 2b — Stem-alternation match. Handles consonant mutations where the suffix replaces
                 the stem ending (e.g. "Vandzie" -> "Vanda", where -da becomes -dzie).
      Stage 3  — Levenshtein fuzzy match. Finds the closest token within a length-scaled edit
                 distance threshold. Uses BK-tree when available (O(log N)), falls back to
                 linear scan.

    The declension suffix list targets Polish noun inflection patterns observed in the repository's
    session notes. The suffix ordering is critical: longest suffixes must be tried first to
    prevent partial stripping (e.g. "-owi" before "-i", "-ami" before "-i").
#>

# Polish noun suffixes ordered longest-first to prevent partial stripping
# (e.g. "-owi" must be tried before "-i", "-ami" before "-i")
$script:DeclensionSuffixes = @(
    "owi",   # dative singular
    "ami",   # instrumental plural
    "ach",   # locative plural
    "iem",   # instrumental singular
    "em",    # instrumental singular
    "om",    # dative plural
    "ą",     # accusative/instr. fem.
    "ę",     # accusative feminine
    "ie",    # locative singular
    "a",     # genitive/acc. masc.
    "u",     # genitive/vocative
    "y"      # genitive feminine
)

# Polish consonant mutations that occur before certain case endings.
# Unlike simple suffixes, these replace the final part of the stem.
# Format: InflectedEnding -> NominativeEnding (what the base name ends with)
$script:StemAlternations = @(
    @{ Inflected = "dzie";  Base = "da"  }   # (dative/locative fem.)
    @{ Inflected = "dzi";   Base = "da"  }   # (variant without final -e)
    @{ Inflected = "ście";  Base = "sta" }   # (locative)
    @{ Inflected = "rze";   Base = "ra"  }   # (locative)
    @{ Inflected = "dze";   Base = "ga"  }   # (locative)
    @{ Inflected = "le";    Base = "ła"  }   # (locative)
    @{ Inflected = "ce";    Base = "ka"  }   # (locative)
    @{ Inflected = "ście";  Base = "ść"  }   # (locative)
    @{ Inflected = "ni";    Base = "ń"   }   # (locative/vocative)
    @{ Inflected = "si";    Base = "ś"   }   # (locative/vocative)
    @{ Inflected = "zi";    Base = "ź"   }   # (locative/vocative)
    @{ Inflected = "ci";    Base = "ć"   }   # (locative/vocative)
)

# Helper: strip declension suffix from a name
# Returns the stem. Returns the original if no suffix matches.
# Minimum stem length of 3 prevents stripping real names down to nothing.
function Get-DeclensionStem {
    param([string]$Text)
    foreach ($Suffix in $script:DeclensionSuffixes) {
        if ($Text.Length -gt ($Suffix.Length + 2) -and $Text.EndsWith($Suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $Text.Substring(0, $Text.Length - $Suffix.Length)
        }
    }
    return $Text
}

# Helper: reverse stem alternation, producing candidate base forms
# For "Vandzie": strip "dzie", append "da" -> "Vanda".
function Get-StemAlternationCandidates {
    param([string]$Text)
    $Candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($Alt in $script:StemAlternations) {
        if ($Text.Length -gt ($Alt.Inflected.Length + 2) -and $Text.EndsWith($Alt.Inflected, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Stem = $Text.Substring(0, $Text.Length - $Alt.Inflected.Length)
            $Candidates.Add($Stem + $Alt.Base)
        }
    }
    return $Candidates
}

# Helper: Levenshtein distance (two-row matrix)
function Get-LevenshteinDistance {
    param([string]$Source, [string]$Target)

    $SourceLower = $Source.ToLowerInvariant()
    $TargetLower = $Target.ToLowerInvariant()

    $SourceLength = $SourceLower.Length
    $TargetLength = $TargetLower.Length

    if ($SourceLength -eq 0) { return $TargetLength }
    if ($TargetLength -eq 0) { return $SourceLength }

    $PreviousRow = [int[]]::new($TargetLength + 1)
    $CurrentRow  = [int[]]::new($TargetLength + 1)

    for ($J = 0; $J -le $TargetLength; $J++) { $PreviousRow[$J] = $J }

    for ($I = 1; $I -le $SourceLength; $I++) {
        $CurrentRow[0] = $I

        for ($J = 1; $J -le $TargetLength; $J++) {
            $Cost = if ($SourceLower[$I - 1] -eq $TargetLower[$J - 1]) { 0 } else { 1 }

            $CurrentRow[$J] = [Math]::Min(
                [Math]::Min($CurrentRow[$J - 1] + 1, $PreviousRow[$J] + 1),
                $PreviousRow[$J - 1] + $Cost
            )
        }

        $TempRow     = $PreviousRow
        $PreviousRow = $CurrentRow
        $CurrentRow  = $TempRow
    }

    return $PreviousRow[$TargetLength]
}

function Resolve-Name {
    <#
        .SYNOPSIS
        Resolves a query string to a named object (player, NPC, organization, or location) using
        index lookup, declension stripping, stem-alternation reversal, and Levenshtein fuzzy matching.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Name string to resolve")]
        [string]$Query,

        [Parameter(HelpMessage = "Pre-fetched player roster from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Token index from Get-NameIndex for name matching")]
        [System.Collections.Generic.Dictionary[string, object]]$Index,

        [Parameter(HelpMessage = "Filter results to a specific entity type")]
        [ValidateSet("Player", "NPC", "Organizacja", "Lokacja")]
        [string]$OwnerType,

        [Parameter(HelpMessage = "Override maximum Levenshtein distance for fuzzy matching")]
        [int]$MaxDistance = -1,

        [Parameter(HelpMessage = "Shared result cache to avoid redundant resolution across calls")]
        [hashtable]$Cache,

        [Parameter(HelpMessage = "Stem index from Get-NameIndex for O(1) declension lookups")]
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,

        [Parameter(HelpMessage = "BK-tree from Get-NameIndex for O(log N) fuzzy matching")]
        [hashtable]$BKTree
    )

    # Build index if not provided — includes both players and entities
    if (-not $Index) {
        if (-not $Players) { $Players = Get-Player }
        if (-not $Entities) { $Entities = Get-Entity }
        $NameIndexResult = Get-NameIndex -Players $Players -Entities $Entities
        $Index     = $NameIndexResult.Index
        $StemIndex = $NameIndexResult.StemIndex
        $BKTree    = $NameIndexResult.BKTree
    }

    # Cache key includes OwnerType filter so "Korm" resolves differently
    # when caller requests only Lokacja vs any type
    $CacheKey = if ($OwnerType) { "$Query|$OwnerType" } else { $Query }
    if ($Cache -and $Cache.ContainsKey($CacheKey)) {
        $Cached = $Cache[$CacheKey]
        # [DBNull]::Value is a sentinel for "we looked this up before and found nothing" —
        # distinguishes a cached miss from a cache miss
        if ($Cached -is [System.DBNull]) { return $null }
        return $Cached
    }

    # Inline filter — kept as a nested function rather than a helper because it captures
    # $OwnerType from the parent scope, avoiding an extra parameter on every call site
    function Test-TypeFilter {
        param([object]$Entry)
        if (-not $OwnerType) { return $true }
        return ($Entry.OwnerType -eq $OwnerType)
    }

    # Stage 1: Exact index lookup (case-insensitive via index comparer)
    if ($Index.ContainsKey($Query)) {
        $Entry = $Index[$Query]
        if (-not $Entry.Ambiguous -and (Test-TypeFilter $Entry)) {
            if ($Cache) { $Cache[$CacheKey] = $Entry.Owner }
            return $Entry.Owner
        }
        # Ambiguous or wrong type — fall through to later stages
    }

    # Stage 2: Declension-stripped match
    $QueryStem = Get-DeclensionStem -Text $Query

    if ($StemIndex -and $StemIndex.ContainsKey($QueryStem)) {
        foreach ($TokenKey in $StemIndex[$QueryStem]) {
            if ($Index.ContainsKey($TokenKey)) {
                $Entry = $Index[$TokenKey]
                if (-not $Entry.Ambiguous -and (Test-TypeFilter $Entry)) {
                    if ($Cache) { $Cache[$CacheKey] = $Entry.Owner }
                    return $Entry.Owner
                }
            }
        }
    }

    # Stage 2b: Stem-alternation match
    $QueryCandidates = Get-StemAlternationCandidates -Text $Query

    foreach ($Candidate in $QueryCandidates) {
        if ($Index.ContainsKey($Candidate)) {
            $Entry = $Index[$Candidate]
            if (-not $Entry.Ambiguous -and (Test-TypeFilter $Entry)) {
                if ($Cache) { $Cache[$CacheKey] = $Entry.Owner }
                return $Entry.Owner
            }
        }
    }

    # Stage 3: Levenshtein fuzzy match
    $BestOwner    = $null
    $BestDistance = [int]::MaxValue

    # Dynamic threshold: short names (<5 chars) allow max 1 edit, longer names allow floor(length / 3)
    $Threshold = if ($MaxDistance -ge 0) {
        $MaxDistance
    } else {
        if ($Query.Length -lt 5) { 1 } else { [Math]::Floor($Query.Length / 3) }
    }

    if ($BKTree) {
        # BK-tree search: O(log N) instead of O(N) linear scan
        $BKResults = Search-BKTree -Tree $BKTree -Query $Query -Threshold $Threshold

        foreach ($BKResult in $BKResults) {
            if ($BKResult.Distance -lt $BestDistance) {
                if ($Index.ContainsKey($BKResult.Key)) {
                    $Entry = $Index[$BKResult.Key]
                    if (-not $Entry.Ambiguous -and (Test-TypeFilter $Entry)) {
                        $BestDistance = $BKResult.Distance
                        $BestOwner   = $Entry.Owner
                    }
                }
            }
        }
    } else {
        # Fallback: linear scan when no BK-tree is available
        $QueryLength = $Query.Length

        foreach ($TokenKey in $Index.Keys) {
            # Length-difference pruning: if lengths differ by more than the threshold,
            # the Levenshtein distance must exceed it too — skip without computing
            $LenDiff = [Math]::Abs($QueryLength - $TokenKey.Length)
            if ($LenDiff -gt $Threshold) { continue }

            $Distance = Get-LevenshteinDistance -Source $Query -Target $TokenKey

            if ($Distance -lt $BestDistance) {
                $Entry = $Index[$TokenKey]
                if (-not $Entry.Ambiguous -and (Test-TypeFilter $Entry)) {
                    $BestDistance = $Distance
                    $BestOwner   = $Entry.Owner
                }
            }

            # Early exit: distance 0-1 is already an excellent match
            if ($BestDistance -le 1) { break }
        }
    }

    if ($BestDistance -le $Threshold) {
        if ($Cache) { $Cache[$CacheKey] = $BestOwner }
        return $BestOwner
    }

    # No match found at any stage — cache the miss too
    if ($Cache) { $Cache[$CacheKey] = [System.DBNull]::Value }
    return $null
}

<#
    .SYNOPSIS
    Generalized name resolution engine - resolves query strings to named objects (players, NPCs,
    groups, locations) via index lookup, Polish declension stripping, stem-alternation
    reversal, and Levenshtein fuzzy matching.

    .DESCRIPTION
    This file contains the Resolve-Name function and its supporting helpers:

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance.

    Helpers:
    - Get-DeclensionStem:            strips Polish noun declension suffixes from a query
    - Get-StemAlternationCandidates:  reverses Polish consonant mutations to produce base-form candidates

    Module-level data:
    - $DeclensionSuffixes:  ordered list of Polish noun suffixes (longest-first to prevent partial stripping)
    - $StemAlternations:    consonant mutation mappings (inflected ending -> nominative base)

    Resolve-Name uses a multi-stage pipeline:
      Stage 1  - Exact index lookup (case-insensitive). O(1) via the token index from Get-NameIndex.
      Stage 2  - Declension-stripped match. Strips Polish case suffixes and looks up the stem
                 in the pre-built stem index. Covers forms like "Thanta" (genitive of "Thant"),
                 "Erdamonem" (instrumental of "Erdamon").
      Stage 2b - Stem-alternation match. Handles consonant mutations where the suffix replaces
                 the stem ending (e.g. "Valesce" -> "Valeska", where -ka becomes -ce).
      Stage 3  - Levenshtein fuzzy match. Finds the closest token within a length-scaled edit
                 distance threshold. Uses BK-tree when available (O(log N)), falls back to
                 linear scan.

    The declension suffix list targets Polish noun inflection patterns observed in the repository's
    session notes. The suffix ordering is critical: longest suffixes must be tried first to
    prevent partial stripping (e.g. "-owi" before "-i", "-ami" before "-i").
#>

. "$script:ModuleRoot/private/string-helpers.ps1"

# C# type: Robot.DeclensionEngine (lib/DeclensionEngine.cs) — compiled centrally in robot.psm1.
# Eliminates PowerShell loop overhead on the hottest resolution path

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

# Prefer the compiled C# engine when available; fall back to the
# PowerShell loop implementations below
$script:CsDeclensionEngine = $null
if (([System.Management.Automation.PSTypeName]'Robot.DeclensionEngine').Type) {
    $AltInflected = [string[]]($script:StemAlternations | ForEach-Object { $_.Inflected })
    $AltBase      = [string[]]($script:StemAlternations | ForEach-Object { $_.Base })
    $script:CsDeclensionEngine = [Robot.DeclensionEngine]::new(
        [string[]]$script:DeclensionSuffixes,
        $AltInflected,
        $AltBase
    )
}

function Get-DeclensionStem {
    param([string]$Text)
    if ($script:CsDeclensionEngine) {
        return $script:CsDeclensionEngine.GetStem($Text)
    }
    foreach ($Suffix in $script:DeclensionSuffixes) {
        # +2 guard: stem must be at least 3 chars to prevent stripping real short names
        if ($Text.Length -gt ($Suffix.Length + 2) -and $Text.EndsWith($Suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $Text.Substring(0, $Text.Length - $Suffix.Length)
        }
    }
    return $Text
}

function Get-StemAlternationCandidates {
    param([string]$Text)
    if ($script:CsDeclensionEngine) {
        return $script:CsDeclensionEngine.GetAlternationCandidates($Text)
    }
    $Candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($Alt in $script:StemAlternations) {
        # Same +2 minimum-stem guard as Get-DeclensionStem
        if ($Text.Length -gt ($Alt.Inflected.Length + 2) -and $Text.EndsWith($Alt.Inflected, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Stem = $Text.Substring(0, $Text.Length - $Alt.Inflected.Length)
            $Candidates.Add($Stem + $Alt.Base)
        }
    }
    return $Candidates
}

function Resolve-Name {
    <#
        .SYNOPSIS
        Resolves a query string to a named object (player, NPC, group, or location) using
        index lookup, declension stripping, stem-alternation reversal, and Levenshtein fuzzy matching.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Name string to resolve")]
        [AllowEmptyString()]
        [string]$Query,

        [Parameter(HelpMessage = "Pre-fetched player roster from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Token index from Get-NameIndex for name matching")]
        [System.Collections.Generic.Dictionary[string, object]]$Index,

        [Parameter(HelpMessage = "Filter results to a specific entity type")]
        [ValidateSet("Player", "NPC", "Grupa", "Lokacja")]
        [string]$OwnerType,

        [Parameter(HelpMessage = "Override maximum Levenshtein distance for fuzzy matching")]
        [int]$MaxDistance = -1,

        [Parameter(HelpMessage = "Shared result cache to avoid redundant resolution across calls")]
        [hashtable]$Cache,

        [Parameter(HelpMessage = "Stem index from Get-NameIndex for O(1) declension lookups")]
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,

        [Parameter(HelpMessage = "BK-tree from Get-NameIndex for O(log N) fuzzy matching (Robot.BKTree or hashtable)")]
        $BKTree,

        [Parameter(HelpMessage = "Skip Stage 3 fuzzy/Levenshtein matching to avoid false positives")]
        [switch]$NoFuzzy
    )

    if ([string]::IsNullOrWhiteSpace($Query)) { return $null }
    if (-not $Index) {
        if (-not $Players) { $Players = Get-Player }
        if (-not $Entities) { $Entities = Get-Entity }
        $NameIndexResult = Get-NameIndex -Players $Players -Entities $Entities
        $Index     = $NameIndexResult.Index
        $StemIndex = $NameIndexResult.StemIndex
        $BKTree    = $NameIndexResult.BKTree
    }

    # OwnerType must be part of the key because the same query can resolve
    # to different objects when scoped to different types
    $CacheKey = if ($OwnerType) { "$Query|$OwnerType" } else { $Query }
    if ($Cache -and $Cache.ContainsKey($CacheKey)) {
        $Cached = $Cache[$CacheKey]
        if ($Cached -is [System.DBNull]) { return $null }  # cached negative result
        return $Cached
    }

    # Stage 1: Exact index lookup (case-insensitive via index comparer)
    if ($Index.ContainsKey($Query)) {
        $Entry = $Index[$Query]
        if (-not $Entry.Ambiguous -and (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType)) {
            if ($Cache) { $Cache[$CacheKey] = $Entry.Owner }
            return $Entry.Owner
        }
        # Ambiguous or wrong type — later stages may disambiguate
    }

    # Stage 2: Declension-stripped match
    $QueryStem = Get-DeclensionStem -Text $Query

    if ($StemIndex -and $StemIndex.ContainsKey($QueryStem)) {
        foreach ($TokenKey in $StemIndex[$QueryStem]) {
            if ($Index.ContainsKey($TokenKey)) {
                $Entry = $Index[$TokenKey]
                if (-not $Entry.Ambiguous -and (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType)) {
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
            if (-not $Entry.Ambiguous -and (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType)) {
                if ($Cache) { $Cache[$CacheKey] = $Entry.Owner }
                return $Entry.Owner
            }
        }
    }

    # Stage 3: Levenshtein fuzzy match (skipped when -NoFuzzy is set)
    if ($NoFuzzy) {
        if ($Cache) { $Cache[$CacheKey] = [System.DBNull]::Value }
        return $null
    }

    $BestOwner    = $null
    $BestDistance = [int]::MaxValue

    # Short names (<5 chars) allow max 1 edit to prevent false positives;
    # longer names scale to floor(length / 3) to accommodate typos
    $Threshold = if ($MaxDistance -ge 0) {
        $MaxDistance
    } else {
        if ($Query.Length -lt 5) { 1 } else { [Math]::Floor($Query.Length / 3) }
    }

    if ($BKTree -is [Robot.BKTree]) {
        $BKResults = $BKTree.Search($Query, $Threshold)

        foreach ($BKResult in $BKResults) {
            if ($BKResult.Value -lt $BestDistance) {
                if ($Index.ContainsKey($BKResult.Key)) {
                    $Entry = $Index[$BKResult.Key]
                    if (-not $Entry.Ambiguous -and (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType)) {
                        $BestDistance = $BKResult.Value
                        $BestOwner   = $Entry.Owner
                    }
                }
            }
        }
    } elseif ($BKTree) {
        # PowerShell hashtable BK-tree fallback when C# type is unavailable
        $BKResults = Search-BKTree -Tree $BKTree -Query $Query -Threshold $Threshold

        foreach ($BKResult in $BKResults) {
            if ($BKResult.Distance -lt $BestDistance) {
                if ($Index.ContainsKey($BKResult.Key)) {
                    $Entry = $Index[$BKResult.Key]
                    if (-not $Entry.Ambiguous -and (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType)) {
                        $BestDistance = $BKResult.Distance
                        $BestOwner   = $Entry.Owner
                    }
                }
            }
        }
    } else {
        # Linear scan fallback when no BK-tree is available
        $QueryLength = $Query.Length

        foreach ($TokenKey in $Index.Keys) {
            # Length-difference pruning: Levenshtein distance >= |len(a) - len(b)|,
            # so tokens outside the threshold are unreachable
            $LenDiff = [Math]::Abs($QueryLength - $TokenKey.Length)
            if ($LenDiff -gt $Threshold) { continue }

            $Distance = Get-LevenshteinDistance -Source $Query -Target $TokenKey -MaxDistance $Threshold

            if ($Distance -lt $BestDistance) {
                $Entry = $Index[$TokenKey]
                if (-not $Entry.Ambiguous -and (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType)) {
                    $BestDistance = $Distance
                    $BestOwner   = $Entry.Owner
                }
            }

            if ($BestDistance -le 1) { break }  # distance 0-1 cannot improve further
        }
    }

    if ($BestDistance -le $Threshold) {
        if ($Cache) { $Cache[$CacheKey] = $BestOwner }
        return $BestOwner
    }

    # Cache the negative result to avoid redundant resolution on repeated queries
    if ($Cache) { $Cache[$CacheKey] = [System.DBNull]::Value }
    return $null
}

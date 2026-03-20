<#
    .SYNOPSIS
    Generalized name resolution engine - resolves query strings to named objects (players, NPCs,
    groups, locations) via index lookup, Polish declension stripping, stem-alternation
    reversal, and Levenshtein fuzzy matching.

    .DESCRIPTION
    This file contains the Resolve-Name function and its supporting helpers:

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance.

    Helpers:
    - Get-DeclensionStem:            strips Polish noun/adjective declension suffixes from a query
    - Get-StemAlternationCandidates:  reverses Polish consonant mutations to produce base-form candidates
    - Get-EntityFilesFingerprint:     builds a LastWriteTimeUtc-based fingerprint across all
      entity source files (entities.md, overflow *-NNN-ent.md, Gracze.md) for cache
      invalidation in the WP-1 name index cache
    - Resolve-AmbiguousEntry:        disambiguates index entries by OwnerType filter; handles
      both non-ambiguous (single owner) and ambiguous (typed Owners array) entries

    Module-level data:
    - $DeclensionSuffixes:    ordered list of Polish noun/adjective suffixes (longest-first to prevent partial stripping)
    - $StemAlternations:      consonant mutation mappings (inflected ending -> nominative base)
    - $CachedNameIndex:       WP-1 module-scoped cache holding the last Get-NameIndex result
      (Index + StemIndex + BKTree) to avoid rebuilding the name index on every Resolve-Name
      call when no entity files have changed
    - $CachedNameIndexKey:    fingerprint string from Get-EntityFilesFingerprint matching
      the cached name index; a mismatch triggers a full rebuild

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

    All stages delegate to Resolve-AmbiguousEntry for OwnerType-based filtering: non-ambiguous
    entries are returned directly if the type matches, ambiguous entries are narrowed to a
    single owner when exactly one matches the requested type (with Lokacja also accepting Mapa).

    When no caller-provided Index is passed, Resolve-Name checks the WP-1 module-scoped
    cache before rebuilding. The cache key is a file-modification fingerprint: if entity
    files haven't changed since the last call, the cached name index is reused directly.
    This avoids the ~4s Get-Entity + Get-NameIndex rebuild that would otherwise run on
    every standalone Resolve-Name invocation (e.g. from session-parsehelpers Intel resolution).

    The declension suffix list targets Polish noun and adjective inflection patterns observed in
    the repository's session notes. The suffix ordering is critical: longest suffixes must be
    tried first to prevent partial stripping (e.g. "-owi" before "-i", "-ami" before "-i").
#>

. "$script:ModuleRoot/private/string-helpers.ps1"

# C# type: Robot.DeclensionEngine (lib/DeclensionEngine.cs) — compiled centrally in Robot.PowerShell.psm1.
# Eliminates PowerShell loop overhead on the hottest resolution path

# Polish noun + adjective suffixes ordered longest-first to prevent partial stripping
# (e.g. "-owi" must be tried before "-i", "-ami" before "-i")
$script:DeclensionSuffixes = @(
    "owi",   # dative singular (noun)
    "ami",   # instrumental plural (noun)
    "ach",   # locative plural (noun)
    "ego",   # genitive masc./neuter (adjective)
    "emu",   # dative masc./neuter (adjective)
    "ymi",   # instrumental plural (adjective)
    "ych",   # genitive/locative plural (adjective)
    "iem",   # instrumental singular (noun)
    "em",    # instrumental singular (noun)
    "om",    # dative plural (noun)
    "ej",    # gen./dat./loc. feminine (adjective)
    "ym",    # instr./loc. masc./neuter (adjective)
    "ą",     # accusative/instr. fem. (noun)
    "ę",     # accusative feminine (noun)
    "ie",    # locative singular (noun)
    "a",     # genitive/acc. masc. (noun)
    "u",     # genitive/vocative (noun)
    "y",     # genitive feminine (noun)
    "i"      # gen./dat./loc. feminine -ia/-ja (noun)
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

function Get-EntityFilesFingerprint {
    # Concatenates LastWriteTimeUtc ticks from all entity source files into a single
    # fingerprint string for WP-1 cache invalidation. Returning null forces a cache miss
    # (no entity files found — fresh repo or test environment).
    $RepoRoot = Get-RepoRoot
    $FP = [System.Text.StringBuilder]::new()

    # Primary entity file (same discovery logic as Get-Entity's file resolution)
    $EntPath = [System.IO.Path]::Combine($RepoRoot, 'entities.md')
    if ([System.IO.File]::Exists($EntPath)) {
        $Info = [System.IO.FileInfo]::new($EntPath)
        [void]$FP.Append($Info.LastWriteTimeUtc.Ticks).Append(':')
    }

    # Overflow entity files (*-NNN-ent.md)
    $OverflowFiles = [System.IO.Directory]::GetFiles($RepoRoot, '*-*-ent.md', [System.IO.SearchOption]::AllDirectories)
    foreach ($OvFile in $OverflowFiles) {
        $Info = [System.IO.FileInfo]::new($OvFile)
        [void]$FP.Append($Info.LastWriteTimeUtc.Ticks).Append(':')
    }

    # Player source file (Gracze.md) — name index includes player names (F1)
    $GraczePath = [System.IO.Path]::Combine($RepoRoot, 'Gracze.md')
    if ([System.IO.File]::Exists($GraczePath)) {
        $Info = [System.IO.FileInfo]::new($GraczePath)
        [void]$FP.Append($Info.LastWriteTimeUtc.Ticks).Append(':')
    }

    if ($FP.Length -eq 0) { return $null }
    return $FP.ToString()
}

function Resolve-AmbiguousEntry {
    param(
        [object]$Entry,
        [string]$OwnerType
    )
    # Non-ambiguous: check type filter directly
    if (-not $Entry.Ambiguous) {
        if (-not $OwnerType -or $Entry.OwnerType -eq $OwnerType) {
            return $Entry.Owner
        }
        return $null
    }
    # Ambiguous: try type-based disambiguation when OwnerType filter is given
    if (-not $OwnerType -or -not $Entry.Owners) { return $null }
    $FilteredOwners = @($Entry.Owners.Where({
        $_.Type -eq $OwnerType -or
        ($OwnerType -eq 'Lokacja' -and $_.Type -in @('Lokacja', 'Mapa'))
    }))
    if ($FilteredOwners.Count -eq 1) { return $FilteredOwners[0].Owner }
    return $null
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
        # WP-1: Reuse cached name index when entity files haven't changed.
        # Without this cache, standalone Resolve-Name calls (no caller-provided Index)
        # would rebuild Get-Entity + Get-NameIndex (~4s) on every invocation.
        $CacheKey = Get-EntityFilesFingerprint
        if ($null -ne $CacheKey -and $script:CachedNameIndexKey -eq $CacheKey -and $null -ne $script:CachedNameIndex) {
            $NameIndexResult = $script:CachedNameIndex
        } else {
            if (-not $Players) { $Players = Get-Player }
            if (-not $Entities) { $Entities = Get-Entity }
            $NameIndexResult = Get-NameIndex -Players $Players -Entities $Entities
            # Persist for subsequent calls within the same module session
            $script:CachedNameIndex    = $NameIndexResult
            $script:CachedNameIndexKey = $CacheKey
        }
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
        $Resolved = Resolve-AmbiguousEntry -Entry $Entry -OwnerType $OwnerType
        if ($Resolved) {
            if ($Cache) { $Cache[$CacheKey] = $Resolved }
            return $Resolved
        }
        # Ambiguous or wrong type — later stages may disambiguate
    }

    # Stage 2: Declension-stripped match
    $QueryStem = Get-DeclensionStem -Text $Query

    if ($StemIndex -and $StemIndex.ContainsKey($QueryStem)) {
        foreach ($TokenKey in $StemIndex[$QueryStem]) {
            if ($Index.ContainsKey($TokenKey)) {
                $Entry = $Index[$TokenKey]
                $Resolved = Resolve-AmbiguousEntry -Entry $Entry -OwnerType $OwnerType
                if ($Resolved) {
                    if ($Cache) { $Cache[$CacheKey] = $Resolved }
                    return $Resolved
                }
            }
        }
    }

    # Stage 2b: Stem-alternation match
    $QueryCandidates = Get-StemAlternationCandidates -Text $Query

    foreach ($Candidate in $QueryCandidates) {
        if ($Index.ContainsKey($Candidate)) {
            $Entry = $Index[$Candidate]
            $Resolved = Resolve-AmbiguousEntry -Entry $Entry -OwnerType $OwnerType
            if ($Resolved) {
                if ($Cache) { $Cache[$CacheKey] = $Resolved }
                return $Resolved
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
                    $Resolved = Resolve-AmbiguousEntry -Entry $Entry -OwnerType $OwnerType
                    if ($Resolved) {
                        $BestDistance = $BKResult.Value
                        $BestOwner   = $Resolved
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
                    $Resolved = Resolve-AmbiguousEntry -Entry $Entry -OwnerType $OwnerType
                    if ($Resolved) {
                        $BestDistance = $BKResult.Distance
                        $BestOwner   = $Resolved
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
                $Resolved = Resolve-AmbiguousEntry -Entry $Entry -OwnerType $OwnerType
                if ($Resolved) {
                    $BestDistance = $Distance
                    $BestOwner   = $Resolved
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

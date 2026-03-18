<#
    .SYNOPSIS
    Resolves narrator names from session headers to player objects, with confidence scoring,
    co-narrator detection, and council session handling.

    .DESCRIPTION
    This file contains the Resolve-Narrator function and its helper:

    Helpers:
    - Resolve-NarratorCandidate: resolves a single name query to a player with confidence level
      (High for exact index match, Medium for declension/fuzzy match)

    Resolve-Narrator processes an array of session section objects, extracts the narrator
    candidate from the last comma-delimited segment of each header, and resolves it against
    the name index. It handles:
    - "Rada" (council sessions with no individual narrator)
    - Co-narrators ("Sandro i Solmyr", "Gelu + Kyrre", "X (autorstwo: Rada)")
    - Typos and variant spellings via Resolve-Name (declension stripping + Levenshtein)

    Results are cached by raw narrator text - many sessions share the same narrator,
    so this avoids redundant resolution work within a single batch call.

    Legacy narrators not present in Gracze.md should be added as Gracz entities in
    entities.md so they can be resolved.
#>

# C# types: Robot.NarratorResult, Robot.Narrator (lib/NarratorResult.cs)
# Compiled centrally in Robot.PowerShell.psm1 at module import time.

function Resolve-NarratorCandidate {
    param(
        [string]$Query,
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,
        $BKTree
    )

    if ($Index.ContainsKey($Query)) {
        $Entry = $Index[$Query]
        if (-not $Entry.Ambiguous -and $Entry.OwnerType -eq 'Player') {
            return [Robot.Narrator]::new($Entry.Owner.Name, $Entry.Owner, 'High')
        }
    }

    # Declension/fuzzy match yields lower confidence because the
    # match is approximate — callers may want to flag it for review
    $Player = Resolve-Name -Query $Query -Index $Index -StemIndex $StemIndex -BKTree $BKTree -OwnerType "Player"
    if ($Player) {
        return [Robot.Narrator]::new($Player.Name, $Player, 'Medium')
    }

    return $null
}

function Resolve-Narrator {
    <#
        .SYNOPSIS
        Resolves narrator names from session headers to player objects.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Array of session objects with Header property")]
        [object[]]$Sessions,

        [Parameter(Mandatory, HelpMessage = "Name index from Get-NameIndex")]
        [System.Collections.Generic.Dictionary[string, object]]$Index,

        [Parameter(HelpMessage = "Stem index from Get-NameIndex for O(1) declension lookups")]
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,

        [Parameter(HelpMessage = "BK-tree from Get-NameIndex for O(log N) fuzzy matching")]
        $BKTree,

        [Parameter(HelpMessage = "Shared narrator cache across calls (avoids re-resolving same narrators across files)")]
        [System.Collections.Generic.Dictionary[string, object]]$NarratorCache
    )

    $Results = [System.Collections.Generic.List[object]]::new()

    # Many sessions share the same narrator, so caching by raw text avoids
    # redundant resolution. Shared cross-file caches amortize across batch calls.
    if (-not $NarratorCache) {
        $NarratorCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    foreach ($Session in $Sessions) {
        $HeaderText = if ($Session.Header -is [string]) { $Session.Header } else { $Session.Header.Text }
        $RawNarrator = $null

        # Header format: "yyyy-MM-dd, Title, Narrator" — the narrator
        # occupies the last segment, but only when at least 2 commas exist
        # (single-comma headers are date+title with no narrator)
        $LastComma = $HeaderText.LastIndexOf(',')
        if ($LastComma -ge 0 -and ($HeaderText.Split(',').Length - 1) -ge 2) {
            $RawNarrator = $HeaderText.Substring($LastComma + 1).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($RawNarrator)) {
            $Results.Add([Robot.NarratorResult]::new(@(), $false, 'None', $null))
            continue
        }

        if ($NarratorCache.ContainsKey($RawNarrator)) {
            $Results.Add($NarratorCache[$RawNarrator])
            continue
        }

        # "Rada" is a reserved keyword for council sessions with no individual narrator
        if ($RawNarrator.Trim().ToLowerInvariant() -eq "rada") {
            $CachedResult = [Robot.NarratorResult]::new(@(), $true, 'High', $RawNarrator)
            $NarratorCache[$RawNarrator] = $CachedResult
            $Results.Add($CachedResult)
            continue
        }

        # Try single-name resolution first; co-narrator splitting is more
        # expensive and only needed when the single match fails
        $SingleMatch = Resolve-NarratorCandidate -Query $RawNarrator -Index $Index -StemIndex $StemIndex -BKTree $BKTree
        if ($SingleMatch) {
            $CachedResult = [Robot.NarratorResult]::new(
                @($SingleMatch),
                $false,
                $SingleMatch.Confidence,
                $RawNarrator
            )
            $NarratorCache[$RawNarrator] = $CachedResult
            $Results.Add($CachedResult)
            continue
        }

        # Co-narrator patterns use Polish conjunctions ("i", "oraz"), plus signs,
        # or parenthetical attribution ("autorstwo: Rada")
        if ($RawNarrator -match ' i | oraz | \+ |\(') {
            $Parts = $RawNarrator -split ' i | oraz | \+ |\(|\)'
            $NarratorList = [System.Collections.Generic.List[object]]::new()
            $HasCouncil = $false

            foreach ($Part in $Parts) {
                $CleanPart = $Part.Trim()
                if ($CleanPart -match '^autorstwo\s*:\s*(.+)$') {
                    $CleanPart = $Matches[1].Trim()
                }
                if ([string]::IsNullOrWhiteSpace($CleanPart)) { continue }

                if ($CleanPart.ToLowerInvariant() -eq "rada") {
                    $HasCouncil = $true
                    continue
                }

                $PartMatch = Resolve-NarratorCandidate -Query $CleanPart -Index $Index -StemIndex $StemIndex -BKTree $BKTree
                if ($PartMatch) {
                    $NarratorList.Add($PartMatch)
                }
            }

            if ($NarratorList.Count -gt 0 -or $HasCouncil) {
                # Confidence floor: overall confidence degrades to the lowest individual
                # confidence to reflect that any approximate match reduces trust
                $OverallConfidence = "High"
                foreach ($N in $NarratorList) {
                    if ($N.Confidence -ne "High") { $OverallConfidence = $N.Confidence }
                }

                $CachedResult = [Robot.NarratorResult]::new(@($NarratorList), $HasCouncil, $OverallConfidence, $RawNarrator)
                $NarratorCache[$RawNarrator] = $CachedResult
                $Results.Add($CachedResult)
                continue
            }
        }

        $UnresolvedResult = [Robot.NarratorResult]::new(@(), $false, 'None', $RawNarrator)
        $NarratorCache[$RawNarrator] = $UnresolvedResult
        $Results.Add($UnresolvedResult)
    }

    return $Results
}

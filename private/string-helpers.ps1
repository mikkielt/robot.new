<#
    .SYNOPSIS
    Shared string comparison utilities for fuzzy name matching.

    .DESCRIPTION
    Non-exported helper functions consumed by Resolve-Name, Get-NameIndex, and
    Get-NamedLocationReport via dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Get-LevenshteinDistance: computes edit distance between two strings

    Get-LevenshteinDistance uses the classic two-row Wagner-Fischer algorithm
    (O(m*n) time, O(min(m,n)) space) with case-insensitive comparison via
    ToLowerInvariant. An optional MaxDistance threshold enables early exit:
    if the minimum possible distance in the current row exceeds MaxDistance,
    the function returns MaxDistance+1 immediately. This avoids computing
    the full matrix for clearly dissimilar strings.

    The two-row technique alternates PreviousRow and CurrentRow arrays via
    a temp-swap, avoiding allocation of the full m*n matrix. Length-delta
    pruning rejects pairs where |len(source) - len(target)| > MaxDistance
    before any row computation.

    This is the PowerShell fallback path; performance-critical callers
    (e.g. CLI fuzzy typeahead) use the compiled C# Robot.BKTree or
    Robot.FuzzyMatcher instead.
#>

function Get-LevenshteinDistance {
    param(
        [string]$Source,
        [string]$Target,
        [int]$MaxDistance = [int]::MaxValue
    )

    $SourceLower = $Source.ToLowerInvariant()
    $TargetLower = $Target.ToLowerInvariant()

    $SourceLength = $SourceLower.Length
    $TargetLength = $TargetLower.Length

    if ($SourceLength -eq 0) { return $TargetLength }
    if ($TargetLength -eq 0) { return $SourceLength }
    if ([Math]::Abs($SourceLength - $TargetLength) -gt $MaxDistance) { return $MaxDistance + 1 } # length-delta pruning

    $PreviousRow = [int[]]::new($TargetLength + 1)
    $CurrentRow  = [int[]]::new($TargetLength + 1)

    for ($J = 0; $J -le $TargetLength; $J++) { $PreviousRow[$J] = $J }

    for ($I = 1; $I -le $SourceLength; $I++) {
        $CurrentRow[0] = $I
        $RowMin = $I

        for ($J = 1; $J -le $TargetLength; $J++) {
            $Cost = if ($SourceLower[$I - 1] -eq $TargetLower[$J - 1]) { 0 } else { 1 }

            $CurrentRow[$J] = [Math]::Min(
                [Math]::Min($CurrentRow[$J - 1] + 1, $PreviousRow[$J] + 1),
                $PreviousRow[$J - 1] + $Cost
            )
            if ($CurrentRow[$J] -lt $RowMin) { $RowMin = $CurrentRow[$J] }
        }

        if ($RowMin -gt $MaxDistance) { return $MaxDistance + 1 } # early exit: no cell can produce a result <= threshold

        $TempRow     = $PreviousRow
        $PreviousRow = $CurrentRow
        $CurrentRow  = $TempRow
    }

    return $PreviousRow[$TargetLength]
}

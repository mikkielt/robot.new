<#
    .SYNOPSIS
    Shared string comparison utilities.

    .DESCRIPTION
    Non-exported helper functions consumed by Resolve-Name, Get-NameIndex, and
    Get-NamedLocationReport via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Get-LevenshteinDistance: computes edit distance between two strings (two-row matrix,
      case-insensitive via ToLowerInvariant)
#>

# Levenshtein distance (two-row matrix, case-insensitive, optional early-exit threshold)
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
    if ([Math]::Abs($SourceLength - $TargetLength) -gt $MaxDistance) { return $MaxDistance + 1 }

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

        # Early exit: if minimum possible distance exceeds threshold, abort
        if ($RowMin -gt $MaxDistance) { return $MaxDistance + 1 }

        $TempRow     = $PreviousRow
        $PreviousRow = $CurrentRow
        $CurrentRow  = $TempRow
    }

    return $PreviousRow[$TargetLength]
}

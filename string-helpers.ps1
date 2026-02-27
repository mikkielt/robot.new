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

# Levenshtein distance (two-row matrix, case-insensitive)
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

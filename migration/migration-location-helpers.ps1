<#
    .SYNOPSIS
    Location name helpers for migration Phase 5.

    .DESCRIPTION
    Provides two functions for inferring parent-child hierarchy from Margonem
    game-map location names during bulk import:

    - Get-MapBaseNameDeterministic: 9-pattern iterative stripping → single base name
    - Get-MapBaseNameCandidates:    progressive word removal → candidate array

    Regex patterns are imported from the canonical source in
    private/location-helpers.ps1 so they stay in sync across migration,
    plugin, and core code.

    Dot-sourced by phase3-location-import.ps1.
#>

# ── Import canonical location regex patterns ────────────────────────────────
. "$PSScriptRoot/../private/location-helpers.ps1"

# ── Get-MapBaseNameDeterministic ────────────────────────────────────────────

function Get-MapBaseNameDeterministic {
    <#
        .SYNOPSIS
        Strips floor/room/direction/difficulty/named subarea suffixes from a map name.

        .DESCRIPTION
        Applies 9 precompiled regex patterns iteratively until stable.
        Returns a single deterministic base name. Used as the primary method
        for inferring parent location from a child location name.

        .PARAMETER Name
        The raw game-map location name.

        .OUTPUTS
        [string] The stripped base name.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $Result = $Name
    do {
        $Prev = $Result
        $Result = $script:LocDifficultyPattern.Replace($Result, '')
        $Result = $script:LocFloorPattern.Replace($Result, '')
        $Result = $script:LocRoomSuffixPattern.Replace($Result, '')
        $Result = $script:LocSalaPattern.Replace($Result, '')
        $Result = $script:LocNamedSalaPattern.Replace($Result, '')
        $Result = $script:LocDirectionPattern.Replace($Result, '')
        $Result = $script:LocPietroPattern.Replace($Result, '')
        $Result = $script:LocPiwnicaPattern.Replace($Result, '')
        $Result = $script:LocNamedSubareaPattern.Replace($Result, '')
    } while ($Result -ne $Prev)

    return $Result
}

# ── Get-MapBaseNameCandidates ───────────────────────────────────────────────

function Get-MapBaseNameCandidates {
    <#
        .SYNOPSIS
        Progressive word removal to produce resolution candidate array.

        .DESCRIPTION
        Pre-strips difficulty parenthetical, then progressively removes trailing
        words (split by whitespace). Returns an array of candidate base names,
        from longest to shortest. Trailing separators are cleaned.
        Returns empty array if the name is a single word.

        Used as fallback when deterministic stripping overshoots
        (stripped too much and the base name no longer exists in the name set).

        .PARAMETER Name
        The raw game-map location name.

        .OUTPUTS
        [string[]] Candidate base names, ordered from longest to shortest.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Pre-strip difficulty parenthetical
    $Clean = $script:LocDifficultyPattern.Replace($Name, '').Trim()
    if ($Clean.Length -eq 0) { return [string[]]@() }

    $Candidates = [System.Collections.Generic.List[string]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # If difficulty was stripped, the cleaned name is the first candidate
    if (-not [string]::Equals($Clean, $Name.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$Seen.Add($Clean)
        $Candidates.Add($Clean)
    }

    $Words = $Clean -split '\s+'
    if ($Words.Count -le 1) { return [string[]]$Candidates.ToArray() }

    # Progressively drop words from the end, keeping at least 1 word
    for ($i = $Words.Count - 1; $i -ge 1; $i--) {
        $Candidate = ($Words[0..($i - 1)] -join ' ').TrimEnd(' ', '-', [char]0x2013, [char]0x2014)
        if ($Candidate.Length -gt 0 -and
            -not [string]::Equals($Candidate, $Name, [System.StringComparison]::OrdinalIgnoreCase) -and
            $Seen.Add($Candidate)) {
            $Candidates.Add($Candidate)
        }
    }

    return [string[]]$Candidates.ToArray()
}

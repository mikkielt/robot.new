<#
    .SYNOPSIS
    Self-contained location name helpers for migration Phase 5.

    .DESCRIPTION
    Provides two functions for inferring parent-child hierarchy from Margonem
    game-map location names during bulk import:

    - Get-MapBaseNameDeterministic: 9-pattern iterative stripping → single base name
    - Get-MapBaseNameCandidates:    progressive word removal → candidate array

    These are copied from the margoworld plugin and core location-helpers.ps1
    respectively, so that migration does not depend on optional plugins.

    Dot-sourced by phase3-location-import.ps1.
#>

# ── Precompiled regex patterns (copied from margoworld-helpers.ps1) ─────────

$script:MLDifficultyPattern = [regex]::new(
    '\s*\(poziom:\s*[^)]+\)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$script:MLFloorPattern = [regex]::new(
    '\s+p\.\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:MLRoomSuffixPattern = [regex]::new(
    '\s+s\.\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:MLSalaPattern = [regex]::new(
    '\s+-\s+sala\s+\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$script:MLNamedSalaPattern = [regex]::new(
    '\s+-\s+Sala\s+.+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:MLDirectionPattern = [regex]::new(
    '\s+-\s+(północ|południe|wschód|zachód|góra|dół)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$script:MLPietroPattern = [regex]::new(
    '\s+-\s+piętro(\s+\d+)?$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$script:MLPiwnicaPattern = [regex]::new(
    '\s+-\s+piwnica(\s+p\.\d+)?$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$script:MLNamedSubareaPattern = [regex]::new(
    '\s+-\s+[a-ząćęłńóśżź].+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Precompiled pattern for candidate generation (difficulty pre-strip)
$script:MLCandidateDifficultyPattern = [regex]::new(
    '\s*\(poziom:\s*[^)]+\)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

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
        $Result = $script:MLDifficultyPattern.Replace($Result, '')
        $Result = $script:MLFloorPattern.Replace($Result, '')
        $Result = $script:MLRoomSuffixPattern.Replace($Result, '')
        $Result = $script:MLSalaPattern.Replace($Result, '')
        $Result = $script:MLNamedSalaPattern.Replace($Result, '')
        $Result = $script:MLDirectionPattern.Replace($Result, '')
        $Result = $script:MLPietroPattern.Replace($Result, '')
        $Result = $script:MLPiwnicaPattern.Replace($Result, '')
        $Result = $script:MLNamedSubareaPattern.Replace($Result, '')
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
    $Clean = $script:MLCandidateDifficultyPattern.Replace($Name, '').Trim()
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

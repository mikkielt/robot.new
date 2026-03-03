<#
    .SYNOPSIS
    Helper functions for game-map location name normalization.

    .DESCRIPTION
    Provides Get-MapBaseName which progressively strips trailing words
    from game-map location names to produce candidate base names for
    entity resolution.

    Maps use naming conventions like:
        "Piekielna Grota p.3 - sala 2"
        "Klasztor Różanitów - wieża płn.-wsch. p.1"
        "Lezysko Baraniego Kanoniera (poziom: trudny)"
        "Erem Czarnego Słońca p.1 - północ"
        "Grota Arbor s.2"

    This file is dot-sourced by Get-NamedLogLocationReport.
#>

# Strip trailing parenthetical like "(poziom: trudny)" before word splitting
$script:RE_Difficulty = [regex]::new(
    '\s*\(poziom:\s*[^)]+\)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Get-MapBaseName {
    <#
        .SYNOPSIS
        Strip game-map suffixes from a location name, producing resolution candidates.

        .DESCRIPTION
        Progressively removes trailing words (split by whitespace) from the input name.
        Returns an array of candidate base names, from longest to shortest.
        Trailing separators (-, –, —) are cleaned from each candidate.
        Returns empty array if the name is a single word (cannot be stripped further).

        .PARAMETER Name
        The raw game-map location name (e.g. "Piekielna Grota p.3 - sala 2").

        .OUTPUTS
        [string[]] Candidate base names, ordered from longest (least stripped) to shortest.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Pre-strip difficulty parenthetical
    $Clean = $script:RE_Difficulty.Replace($Name, '').Trim()
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

<#
    .SYNOPSIS
    Reputation tier parser and formatter for character files.

    .DESCRIPTION
    Non-exported helper functions for parsing and rendering three-tier
    reputation structures (Pozytywna/Neutralna/Negatywna) in character files
    (Postaci/Gracze/*.md).

    Split from charfile-helpers.ps1 — dot-sourced by that file.

    Contains:
    - Read-ReputationTier:         parses a single reputation tier (Positive/Neutral/Negative)
    - Format-ReputationSection:    renders three-tier reputation structure as markdown lines
#>

# Reputation tier bullets: "- Pozytywna:", "- Neutralna:", "- Negatywna:"
$script:ReputationTierPattern = [regex]::new(
    '^\s*-\s+(Pozytywna|Neutralna|Negatywna)\s*:\s*(.*)',
    ([System.Text.RegularExpressions.RegexOptions]::Compiled -bor
     [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
)

# Helper: parse a single reputation tier
# Returns array of @{ Location; Detail } objects
function Read-ReputationTier {
    param(
        [string[]]$Lines,
        [int]$TierLineIdx,
        [string]$InlineContent,
        [int]$NextTierOrEnd
    )

    $Results = [System.Collections.Generic.List[object]]::new()

    # Parse inline comma-separated entries
    if (-not [string]::IsNullOrWhiteSpace($InlineContent)) {
        $Trimmed = $InlineContent.Trim()
        # Skip dash-only values (empty marker)
        if ($Trimmed -ne '-' -and $Trimmed -ne '') {
            $Parts = $Trimmed.Split(',')
            foreach ($Part in $Parts) {
                $PartTrimmed = $Part.Trim()
                if ([string]::IsNullOrWhiteSpace($PartTrimmed) -or $PartTrimmed -eq '-') { continue }

                $DetailMatch = $script:LocationDetailPattern.Match($PartTrimmed)
                if ($DetailMatch.Success -and ($DetailMatch.Groups[2].Success -or $DetailMatch.Groups[3].Success)) {
                    $Detail = if ($DetailMatch.Groups[2].Success) { $DetailMatch.Groups[2].Value.Trim() } else { $DetailMatch.Groups[3].Value.Trim() }
                    $Results.Add([PSCustomObject]@{
                        Location = $DetailMatch.Groups[1].Value.Trim()
                        Detail   = $Detail
                    })
                } else {
                    $Results.Add([PSCustomObject]@{
                        Location = $PartTrimmed
                        Detail   = $null
                    })
                }
            }
        }
    }

    # Parse nested child bullets (indented lines with - prefix)
    for ($i = $TierLineIdx + 1; $i -lt $NextTierOrEnd; $i++) {
        $Line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }

        # Must be indented (at least 4 spaces or tab) and start with -
        $Stripped = $Line.TrimStart()
        if (-not $Stripped.StartsWith('-')) { continue }
        if ($Line.Length -eq $Stripped.Length) { continue }  # not indented

        $EntryText = $Stripped.Substring(1).Trim()
        if ([string]::IsNullOrWhiteSpace($EntryText)) { continue }

        # Remove trailing comma if present
        if ($EntryText.EndsWith(',')) { $EntryText = $EntryText.Substring(0, $EntryText.Length - 1).Trim() }

        $DetailMatch = $script:LocationDetailPattern.Match($EntryText)
        if ($DetailMatch.Success -and ($DetailMatch.Groups[2].Success -or $DetailMatch.Groups[3].Success)) {
            $Detail = if ($DetailMatch.Groups[2].Success) { $DetailMatch.Groups[2].Value.Trim() } else { $DetailMatch.Groups[3].Value.Trim() }
            $Results.Add([PSCustomObject]@{
                Location = $DetailMatch.Groups[1].Value.Trim()
                Detail   = $Detail
            })
        } else {
            # Check for nested sub-bullets (descriptions under a location)
            # e.g. "Nithal:" followed by indented description bullets
            if ($EntryText.EndsWith(':')) {
                $LocName = $EntryText.Substring(0, $EntryText.Length - 1).Trim()
                # Collect sub-bullet text as detail
                $SubDetails = [System.Collections.Generic.List[string]]::new()
                for ($k = $i + 1; $k -lt $NextTierOrEnd; $k++) {
                    $SubLine = $Lines[$k]
                    if ([string]::IsNullOrWhiteSpace($SubLine)) { continue }
                    $SubStripped = $SubLine.TrimStart()
                    if (-not $SubStripped.StartsWith('-')) { break }
                    # Must be more indented than current bullet
                    $CurrentIndent = $Line.Length - $Stripped.Length
                    $SubIndent = $SubLine.Length - $SubStripped.Length
                    if ($SubIndent -le $CurrentIndent) { break }
                    $SubDetails.Add($SubStripped.Substring(1).Trim())
                    $i = $k  # Intentionally advance outer loop past consumed sub-bullets
                }
                $DetailStr = if ($SubDetails.Count -gt 0) { $SubDetails -join '; ' } else { $null }
                $Results.Add([PSCustomObject]@{
                    Location = $LocName
                    Detail   = $DetailStr
                })
            } else {
                $Results.Add([PSCustomObject]@{
                    Location = $EntryText
                    Detail   = $null
                })
            }
        }
    }

    return ,$Results.ToArray()
}

# Renders three-tier reputation structure as markdown content lines
function Format-ReputationSection {
    param(
        [object[]]$Positive = @(),
        [object[]]$Neutral  = @(),
        [object[]]$Negative = @()
    )

    $Result = [System.Collections.Generic.List[string]]::new()

    # Helper: render one tier
    $RenderTier = {
        param([string]$TierName, [object[]]$Entries)

        if (-not $Entries -or $Entries.Count -eq 0) {
            $Result.Add("- ${TierName}: ")
            return
        }

        $HasDetail = $false
        foreach ($E in $Entries) {
            if ($E.Detail) { $HasDetail = $true; break }
        }

        if (-not $HasDetail) {
            # Inline format: - TierName: Loc1, Loc2, Loc3
            $Locs = ($Entries | ForEach-Object { $_.Location }) -join ', '
            $Result.Add("- ${TierName}: $Locs")
        } else {
            # Nested bullet format
            $Result.Add("- ${TierName}:")
            foreach ($E in $Entries) {
                if ($E.Detail) {
                    $Result.Add("    - $($E.Location): $($E.Detail)")
                } else {
                    $Result.Add("    - $($E.Location)")
                }
            }
        }
    }

    & $RenderTier 'Pozytywna' $Positive
    & $RenderTier 'Neutralna' $Neutral
    & $RenderTier 'Negatywna' $Negative

    return $Result.ToArray()
}

<#
    .SYNOPSIS
    Character file parser and writer for Postaci/Gracze/*.md files.

    .DESCRIPTION
    Non-exported helper functions consumed by Get-PlayerCharacter (-IncludeState),
    Set-PlayerCharacter, and New-PlayerCharacter via dot-sourcing. Not auto-loaded
    by robot.psm1 (non-Verb-Noun filename).

    Contains:
    - Find-CharacterSection:       locates **Header:** section boundaries in character file lines
    - Read-CharacterFile:          parses an entire character file into a structured object
    - Read-ReputationTier:         parses a single reputation tier (Positive/Neutral/Negative)
    - Write-CharacterFileSection:  replaces content of a single bold-header section in-place
    - Format-ReputationSection:    renders three-tier reputation structure as markdown lines

    All functions operate on raw line arrays following the same pattern as
    entity-writehelpers.ps1.
#>

# Precompiled regex patterns
# Bold-header sections: **Header:** with optional inline content
$script:CharSectionPattern = [regex]::new(
    '^\*\*([^*]+?):\*\*\s*(.*)',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Reputation tier bullets: "- Pozytywna:", "- Neutralna:", "- Negatywna:"
$script:ReputationTierPattern = [regex]::new(
    '^\s*-\s+(Pozytywna|Neutralna|Negatywna)\s*:\s*(.*)',
    ([System.Text.RegularExpressions.RegexOptions]::Compiled -bor
     [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
)

# Session headers in character files: ### YYYY-MM-DD, ...
$script:SessionHeaderPattern_CF = [regex]::new(
    '^###\s+(\d{4}-\d{2}-\d{2}),\s*(.+?)(?:,\s*(.+))?$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Parenthetical detail: "Location (detail)" or "Location: detail"
$script:LocationDetailPattern = [regex]::new(
    '^(.+?)\s*(?:\(([^)]+)\)|:\s*(.+))$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Section name -> English property name mapping
$script:SectionNameToProperty = @{
    'Karta Postaci'          = 'CharacterSheet'
    'Tematy zastrzeżone'     = 'RestrictedTopics'    # note: ż in source files
    'Tematy zastrzezone'     = 'RestrictedTopics'     # variant without diacritic
    'Stan'                   = 'Condition'
    'Przedmioty specjalne'   = 'SpecialItems'
    'Reputacja'              = 'Reputation'
    'Dodatkowe informacje'   = 'AdditionalNotes'
    'Opisane sesje'          = 'DescribedSessions'
}

# Helper: locate a bold-header section in a character file's line array
# Returns hashtable: HeaderIdx, InlineContent, ContentStart, ContentEnd (exclusive)
# Returns $null if not found.
function Find-CharacterSection {
    param(
        [string[]]$Lines,
        [string]$SectionName
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Match = $script:CharSectionPattern.Match($Lines[$i])
        if (-not $Match.Success) { continue }

        $HeaderName = $Match.Groups[1].Value.Trim()
        if (-not [string]::Equals($HeaderName, $SectionName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $InlineContent = $Match.Groups[2].Value.Trim()
        $ContentStart = $i + 1

        # ContentEnd = next **...:**, or next ### header, or EOF
        $ContentEnd = $Lines.Count
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($script:CharSectionPattern.IsMatch($Lines[$j]) -or $Lines[$j].StartsWith('###')) {
                $ContentEnd = $j
                break
            }
        }

        # Trim trailing blank lines from content range
        while ($ContentEnd -gt $ContentStart -and [string]::IsNullOrWhiteSpace($Lines[$ContentEnd - 1])) {
            $ContentEnd--
        }

        return @{
            HeaderIdx     = $i
            InlineContent = $InlineContent
            ContentStart  = $ContentStart
            ContentEnd    = $ContentEnd
        }
    }

    return $null
}

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
                    $i = $k  # advance outer loop
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

# Main parser: reads an entire character file into a structured object
function Read-CharacterFile {
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $RawContent = [System.IO.File]::ReadAllText($Path, $UTF8NoBOM)
    $NL = if ($RawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
    $LineArray = $RawContent.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    # Locate all sections
    $Sections = @{}
    foreach ($SectionName in @('Karta Postaci', 'Tematy zastrzeżone', 'Stan', 'Przedmioty specjalne', 'Reputacja', 'Dodatkowe informacje', 'Opisane sesje')) {
        $Found = Find-CharacterSection -Lines $LineArray -SectionName $SectionName
        if ($Found) { $Sections[$SectionName] = $Found }
    }

    # --- Karta Postaci (CharacterSheet) ---
    $CharacterSheet = $null
    $Sec = $Sections['Karta Postaci']
    if ($Sec) {
        if (-not [string]::IsNullOrWhiteSpace($Sec.InlineContent)) {
            $CharacterSheet = $Sec.InlineContent
        } elseif ($Sec.ContentStart -lt $Sec.ContentEnd) {
            for ($i = $Sec.ContentStart; $i -lt $Sec.ContentEnd; $i++) {
                if (-not [string]::IsNullOrWhiteSpace($LineArray[$i])) {
                    $CharacterSheet = $LineArray[$i].Trim()
                    break
                }
            }
        }
        # Strip angle brackets if present (e.g. <https://...>)
        if ($CharacterSheet -and $CharacterSheet.StartsWith('<') -and $CharacterSheet.EndsWith('>')) {
            $CharacterSheet = $CharacterSheet.Substring(1, $CharacterSheet.Length - 2)
        }
    }

    # --- Tematy zastrzeżone (RestrictedTopics) ---
    $RestrictedTopics = $null
    $Sec = $Sections['Tematy zastrzeżone']
    if ($Sec) {
        $TopicLines = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Sec.InlineContent)) {
            $TopicLines.Add($Sec.InlineContent)
        }
        for ($i = $Sec.ContentStart; $i -lt $Sec.ContentEnd; $i++) {
            if (-not [string]::IsNullOrWhiteSpace($LineArray[$i])) {
                $TopicLines.Add($LineArray[$i].Trim())
            }
        }
        $Joined = ($TopicLines -join ' ').Trim()
        if ($Joined -ieq 'Brak.' -or $Joined -ieq 'brak') { $Joined = $null }
        $RestrictedTopics = $Joined
    }

    # --- Stan (Condition) ---
    $Condition = $null
    $Sec = $Sections['Stan']
    if ($Sec) {
        $CondLines = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Sec.InlineContent)) {
            $CondLines.Add($Sec.InlineContent)
        }
        for ($i = $Sec.ContentStart; $i -lt $Sec.ContentEnd; $i++) {
            $Line = $LineArray[$i]
            # Strip leading "- " from condition lines (some files use bullet prefix)
            $Stripped = $Line.TrimStart()
            if ($Stripped.StartsWith('- ')) { $Stripped = $Stripped.Substring(2) }
            if (-not [string]::IsNullOrWhiteSpace($Stripped)) {
                $CondLines.Add($Stripped)
            }
        }
        $Joined = ($CondLines -join "`n").Trim()
        if ($Joined -ieq 'Zdrowy.' -or $Joined -ieq 'Zdrowa.') {
            $Condition = $Joined  # keep the value, it's valid state
        } elseif ([string]::IsNullOrWhiteSpace($Joined)) {
            $Condition = $null
        } else {
            $Condition = $Joined
        }
    }

    # --- Przedmioty specjalne (SpecialItems) ---
    $SpecialItems = @()
    $Sec = $Sections['Przedmioty specjalne']
    if ($Sec) {
        $Items = [System.Collections.Generic.List[string]]::new()
        for ($i = $Sec.ContentStart; $i -lt $Sec.ContentEnd; $i++) {
            $Line = $LineArray[$i].TrimStart()
            if ($Line.StartsWith('- ')) {
                $Items.Add($Line.Substring(2).Trim())
            } elseif (-not [string]::IsNullOrWhiteSpace($Line) -and $Line -ine 'Brak.' -and $Line -ine 'Brak') {
                $Items.Add($Line.Trim())
            }
        }
        # Check for "Brak." as the only content line
        if ($Items.Count -eq 1 -and ($Items[0] -ieq 'Brak.' -or $Items[0] -ieq 'Brak')) {
            $Items.Clear()
        }
        $SpecialItems = $Items.ToArray()
    }

    # --- Reputacja (Reputation) ---
    $Reputation = [PSCustomObject]@{
        Positive = @()
        Neutral  = @()
        Negative = @()
    }
    $Sec = $Sections['Reputacja']
    if ($Sec) {
        # Find all tier lines within the Reputacja section
        $TierPositions = [System.Collections.Generic.List[object]]::new()
        for ($i = $Sec.ContentStart; $i -lt $Sec.ContentEnd; $i++) {
            $TierMatch = $script:ReputationTierPattern.Match($LineArray[$i])
            if ($TierMatch.Success) {
                $TierPositions.Add([PSCustomObject]@{
                    TierName = $TierMatch.Groups[1].Value.Trim()
                    LineIdx  = $i
                    Inline   = $TierMatch.Groups[2].Value.Trim()
                })
            }
        }

        for ($t = 0; $t -lt $TierPositions.Count; $t++) {
            $Tier = $TierPositions[$t]
            $NextEnd = if ($t + 1 -lt $TierPositions.Count) { $TierPositions[$t + 1].LineIdx } else { $Sec.ContentEnd }
            $TierEntries = Read-ReputationTier -Lines $LineArray -TierLineIdx $Tier.LineIdx -InlineContent $Tier.Inline -NextTierOrEnd $NextEnd

            switch -Wildcard ($Tier.TierName) {
                'Pozytywna' { $Reputation.Positive = $TierEntries }
                'Neutralna' { $Reputation.Neutral  = $TierEntries }
                'Negatywna' { $Reputation.Negative = $TierEntries }
            }
        }
    }

    # --- Dodatkowe informacje (AdditionalNotes) ---
    $AdditionalNotes = @()
    $Sec = $Sections['Dodatkowe informacje']
    if ($Sec) {
        $Notes = [System.Collections.Generic.List[string]]::new()
        for ($i = $Sec.ContentStart; $i -lt $Sec.ContentEnd; $i++) {
            $Line = $LineArray[$i].TrimStart()
            if ($Line.StartsWith('- ')) {
                $Notes.Add($Line.Substring(2).Trim())
            } elseif (-not [string]::IsNullOrWhiteSpace($Line) -and $Line -ine 'Brak.' -and $Line -ine 'Brak') {
                $Notes.Add($Line.Trim())
            }
        }
        if ($Notes.Count -eq 1 -and ($Notes[0] -ieq 'Brak.' -or $Notes[0] -ieq 'Brak')) {
            $Notes.Clear()
        }
        $AdditionalNotes = $Notes.ToArray()
    }

    # --- Opisane sesje (DescribedSessions, read-only) ---
    $DescribedSessions = @()
    $Sec = $Sections['Opisane sesje']
    if ($Sec) {
        $SessionList = [System.Collections.Generic.List[object]]::new()
        # Scan from ContentStart to end of file (sessions span to EOF)
        for ($i = $Sec.ContentStart; $i -lt $LineArray.Count; $i++) {
            $SessMatch = $script:SessionHeaderPattern_CF.Match($LineArray[$i])
            if (-not $SessMatch.Success) { continue }

            $DateStr = $SessMatch.Groups[1].Value
            $SessDate = $null
            try {
                $SessDate = [datetime]::ParseExact($DateStr, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { }

            $TitleAndNarrator = $SessMatch.Groups[2].Value.Trim()
            $Narrator = if ($SessMatch.Groups[3].Success) { $SessMatch.Groups[3].Value.Trim() } else { $null }
            $Title = if ($Narrator) { $TitleAndNarrator } else {
                # Try to split on last comma for title/narrator
                $LastComma = $TitleAndNarrator.LastIndexOf(',')
                if ($LastComma -gt 0) {
                    $Narrator = $TitleAndNarrator.Substring($LastComma + 1).Trim()
                    $TitleAndNarrator.Substring(0, $LastComma).Trim()
                } else {
                    $TitleAndNarrator
                }
            }

            $SessionList.Add([PSCustomObject]@{
                Date     = $SessDate
                Title    = $Title
                Narrator = $Narrator
            })
        }
        $DescribedSessions = $SessionList.ToArray()
    }

    return [PSCustomObject]@{
        FilePath          = $Path
        Lines             = $LineArray
        NL                = $NL
        CharacterSheet    = $CharacterSheet
        RestrictedTopics  = $RestrictedTopics
        Condition         = $Condition
        SpecialItems      = $SpecialItems
        Reputation        = $Reputation
        AdditionalNotes   = $AdditionalNotes
        DescribedSessions = $DescribedSessions
        Sections          = $Sections
    }
}

# Writer: section-level in-place replacement
# Replaces content of a single bold-header section. Modifies $Lines in-place.
function Write-CharacterFileSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$SectionName,
        [string[]]$NewContent = @(),
        [string]$InlineValue
    )

    $Section = Find-CharacterSection -Lines $Lines.ToArray() -SectionName $SectionName
    if (-not $Section) {
        [System.Console]::Error.WriteLine("[WARN charfile-helpers] Section '$SectionName' not found in character file")
        return
    }

    # Rewrite header line if InlineValue specified
    if ($PSBoundParameters.ContainsKey('InlineValue')) {
        $Lines[$Section.HeaderIdx] = "**${SectionName}:** $InlineValue"
    }

    # Find the actual end for removal (include trailing blank lines up to next section)
    $RemoveEnd = $Section.ContentEnd
    # Also remove blank lines between content and next section
    $RawEnd = $Lines.Count
    for ($j = $Section.HeaderIdx + 1; $j -lt $Lines.Count; $j++) {
        if ($script:CharSectionPattern.IsMatch($Lines[$j]) -or $Lines[$j].StartsWith('###')) {
            $RawEnd = $j
            break
        }
    }
    $RemoveEnd = $RawEnd

    # Remove existing content lines (from ContentStart to RemoveEnd)
    $RemoveCount = $RemoveEnd - $Section.ContentStart
    if ($RemoveCount -gt 0) {
        $Lines.RemoveRange($Section.ContentStart, $RemoveCount)
    }

    # Insert new content + trailing blank line at ContentStart
    $InsertIdx = $Section.ContentStart
    foreach ($Line in $NewContent) {
        $Lines.Insert($InsertIdx, $Line)
        $InsertIdx++
    }
    # Ensure blank line after content (section separator)
    $Lines.Insert($InsertIdx, '')
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

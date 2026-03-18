<#
    .SYNOPSIS
    Character file parser and writer for Postaci/Gracze/*.md files.

    .DESCRIPTION
    Non-exported helper functions consumed by Get-PlayerCharacter (-IncludeState),
    Set-PlayerCharacter, and New-PlayerCharacter via dot-sourcing. Not auto-loaded
    by Robot.PowerShell.psm1 (non-Verb-Noun filename).

    Helpers:
    - Find-CharacterSection:       locates **Header:** section boundaries in character file lines
    - Read-CharacterFile:          parses an entire character file into a structured object
    - Write-CharacterFileSection:  replaces content of a single bold-header section in-place
    - Write-CharacterFile:         writes character file to disk (UTF-8 no BOM) with plugin hooks

    Module-level data:
    - $script:HasOpCtx:               whether operation-context helpers are available
    - $script:CharSectionPattern:     bold-header sections (**Header:** with optional inline content)
    - $script:SessionHeaderPattern_CF: session headers in character files (### YYYY-MM-DD, ...)
    - $script:LocationDetailPattern:  parenthetical or colon-delimited detail after location name
    - $script:SectionNameToProperty:  Polish section name -> English property name mapping

    Reputation helpers (Read-ReputationTier, Format-ReputationSection) are in
    charfile-reputation.ps1, dot-sourced below.

    Character files follow a fixed-section Markdown format with bold headers
    (**Karta Postaci:**, **Stan:**, etc.). The parser locates sections by regex,
    extracts typed data (scalars, bullet lists, reputation tiers), and returns a
    single PSCustomObject. Writers splice line arrays in-place to preserve
    surrounding content and original newline style (CRLF/LF auto-detected).

    All functions operate on raw line arrays following the same pattern as
    entity-writehelpers.ps1. Write-CharacterFile fires BeforeWrite/AfterWrite
    plugin hooks and registers files with the operation context for audit trails.
#>

# Dot-source reputation helpers (Read-ReputationTier, Format-ReputationSection)
. "$PSScriptRoot/charfile-reputation.ps1"

# Check for operation context availability
$script:HasOpCtx = $null -ne (Get-Command 'Add-OperationFile' -ErrorAction SilentlyContinue)

# Precompiled regex patterns
# Bold-header sections: **Header:** with optional inline content
$script:CharSectionPattern = [regex]::new(
    '^\*\*([^*]+?):\*\*\s*(.*)',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
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

# Maps Polish section headers to English property names used in the parsed PSCustomObject
$script:SectionNameToProperty = @{
    'Karta Postaci'          = 'CharacterSheet'
    'Tematy zastrzeżone'     = 'RestrictedTopics'    # canonical form with ż diacritic
    'Tematy zastrzezone'     = 'RestrictedTopics'     # fallback for files missing the diacritic
    'Stan'                   = 'Condition'
    'Przedmioty specjalne'   = 'SpecialItems'
    'Reputacja'              = 'Reputation'
    'Dodatkowe informacje'   = 'AdditionalNotes'
    'Opisane sesje'          = 'DescribedSessions'
}

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

    # Karta Postaci (CharacterSheet)
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

    # Tematy zastrzeżone (RestrictedTopics)
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
        # "Brak"/"Brak." is the Polish placeholder for "none" — normalize to null
        if ($Joined -ieq 'Brak.' -or $Joined -ieq 'brak') { $Joined = $null }
        $RestrictedTopics = $Joined
    }

    # Stan (Condition)
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

    # Przedmioty specjalne (SpecialItems)
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

    # Reputacja (Reputation)
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

    # Dodatkowe informacje (AdditionalNotes)
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

    # Opisane sesje (DescribedSessions) — read-only, never written back
    $DescribedSessions = @()
    $Sec = $Sections['Opisane sesje']
    if ($Sec) {
        $SessionList = [System.Collections.Generic.List[object]]::new()
        # Scan to end of file, not ContentEnd — session entries are the last section and span to EOF
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

function Write-CharacterFileSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$SectionName,
        [string[]]$NewContent = @(),
        [string]$InlineValue
    )

    $Section = Find-CharacterSection -Lines $Lines.ToArray() -SectionName $SectionName
    if (-not $Section) {
        Write-RobotWarning "[WARN charfile-helpers] Section '$SectionName' not found in character file"
        return
    }

    # Rewrite header line if InlineValue specified
    if ($PSBoundParameters.ContainsKey('InlineValue')) {
        $Lines[$Section.HeaderIdx] = "**${SectionName}:** $InlineValue"
    }

    # Extend removal range past trailing blank lines up to the next section header
    $RemoveEnd = $Section.ContentEnd
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

function Write-CharacterFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $HasHooks = Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue

    if ($HasHooks) {
        Invoke-PluginHook -Operation 'Write-CharacterFile' -Phase 'BeforeWrite' -Context @{
            Operation = 'Write-CharacterFile'
            Path      = $Path
            Content   = $Content
        }
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $UTF8NoBOM)

    if ($script:HasOpCtx) { Add-OperationFile -Path $Path }

    if ($HasHooks) {
        Invoke-PluginHook -Operation 'Write-CharacterFile' -Phase 'AfterWrite' -Context @{
            Operation = 'Write-CharacterFile'
            Path      = $Path
        }
    }
}

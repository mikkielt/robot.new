<#
    .SYNOPSIS
    Session section decomposition and format-conversion helpers for Set-Session.

    .DESCRIPTION
    This file contains helpers used by Set-Session to locate, decompose, and
    upgrade session sections within Markdown files. It is dot-sourced by
    set-session.ps1 alongside format-sessionblock.ps1.

    Helpers:
    - Find-SessionInFile:         locates session section boundaries by header text or date
    - Split-SessionSection:       decomposes a section into metadata blocks, preserved blocks, and body
    - ConvertTo-Gen4FromRawBlock: converts existing Gen3 metadata block lines to Gen4 format
    - ConvertFrom-ItalicLocation: converts Gen2 italic location line to Gen4 block
    - ConvertFrom-PlainTextLog:   converts Gen1/2 plain text log lines to Gen4 block
    - Get-FormatFromSplit:        derives format generation from Split-SessionSection MetaBlocks dictionary
#>

# Helper: finds session section boundaries in a file's lines by matching header
# text or date. Returns a list of match objects with HeaderLineIdx, SectionStartIdx,
# SectionEndIdx, HeaderText.
function Find-SessionInFile {
    param(
        [string[]]$Lines,
        [string]$TargetHeader,
        [datetime]$TargetDate
    )

    $DateRegex = $script:SessionDatePattern
    $Results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i]
        if (-not $Line.StartsWith('### ')) { continue }

        $HeaderText = $Line.Substring(4).Trim()
        $IsMatch = $false

        if ($TargetHeader) {
            $IsMatch = [string]::Equals($HeaderText, $TargetHeader, [System.StringComparison]::Ordinal)
        }
        else {
            $DMatch = $DateRegex.Match($HeaderText)
            if ($DMatch.Success) {
                [datetime]$Parsed = [datetime]::MinValue
                if ([datetime]::TryParseExact($DMatch.Groups[1].Value, 'yyyy-MM-dd',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
                    $IsMatch = $Parsed.Date -eq $TargetDate.Date
                }
            }
        }

        if (-not $IsMatch) { continue }

        # Find section end (next ### or EOF)
        $EndIdx = $Lines.Count
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j].StartsWith('### ')) {
                $EndIdx = $j
                break
            }
        }

        $Results.Add(@{
            HeaderLineIdx   = $i
            SectionStartIdx = $i + 1
            SectionEndIdx   = $EndIdx
            HeaderText      = $HeaderText
        })
    }

    return ,$Results
}

# Helper: decomposes a session section (lines between header and next header)
# into metadata blocks, preserved blocks, and body text. Returns hashtable with
# MetaBlocks ([ordered] dict: canonical key -> string[] lines), PreservedBlocks
# (List of Tag+Lines), and BodyLines (string[]).
function Split-SessionSection {
    param([string[]]$Lines)

    $MetaTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($T in @('narrator', 'data', 'pu', 'logi', 'lokalizacje', 'lokacje', 'zmiany', 'intel')) {
        [void]$MetaTags.Add($T)
    }

    $PreservedTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($T in @('objaśnienia', 'efekty', 'komunikaty', 'straty', 'nagrody')) {
        [void]$PreservedTags.Add($T)
    }

    # Normalize raw tag name -> canonical key
    $TagKeyMap = @{
        'narrator'    = 'narrator'
        'data'        = 'data'
        'lokalizacje' = 'locations'
        'lokacje'     = 'locations'
        'logi'        = 'logs'
        'pu'          = 'pu'
        'zmiany'      = 'changes'
        'intel'       = 'intel'
    }

    $MetaBlocks      = [ordered]@{}
    $PreservedBlocks = [System.Collections.Generic.List[object]]::new()
    $BodyLines       = [System.Collections.Generic.List[string]]::new()

    $InCodeBlock       = $false
    $CurrentBlockType  = $null     # 'meta' | 'preserved'
    $CurrentTag        = $null
    $CurrentLines      = $null
    $CodeFence         = [string]::new([char]96, 3)  # three backticks

    foreach ($Line in $Lines) {
        # Code fence toggle
        if ($Line.TrimStart().StartsWith($CodeFence)) {
            $InCodeBlock = -not $InCodeBlock
            # Close any open block
            if ($CurrentBlockType -eq 'meta' -and $CurrentTag) {
                $MetaBlocks[$CurrentTag] = $CurrentLines.ToArray()
            } elseif ($CurrentBlockType -eq 'preserved' -and $CurrentTag) {
                $PreservedBlocks.Add(@{ Tag = $CurrentTag; Lines = $CurrentLines.ToArray() })
            }
            $CurrentBlockType = $null; $CurrentTag = $null; $CurrentLines = $null
            $BodyLines.Add($Line)
            continue
        }
        if ($InCodeBlock) {
            $BodyLines.Add($Line)
            continue
        }

        # Root list item (starts with "- " at column 0)
        if ($Line.StartsWith('- ')) {
            # Close previous block
            if ($CurrentBlockType -eq 'meta' -and $CurrentTag) {
                $MetaBlocks[$CurrentTag] = $CurrentLines.ToArray()
            } elseif ($CurrentBlockType -eq 'preserved' -and $CurrentTag) {
                $PreservedBlocks.Add(@{ Tag = $CurrentTag; Lines = $CurrentLines.ToArray() })
            }
            $CurrentBlockType = $null; $CurrentTag = $null; $CurrentLines = $null

            # Extract and classify tag
            $TagRaw = $Line.Substring(2).Trim()
            $TestText = if ($TagRaw.StartsWith('@')) { $TagRaw.Substring(1) } else { $TagRaw }
            $ColonIdx = $TestText.IndexOf(':')
            $TagName = if ($ColonIdx -ge 0) { $TestText.Substring(0, $ColonIdx).Trim() } else { $TestText }

            if ($MetaTags.Contains($TagName)) {
                $CanonKey = $TagKeyMap[$TagName.ToLowerInvariant()]
                $CurrentBlockType = 'meta'
                $CurrentTag = $CanonKey
                $CurrentLines = [System.Collections.Generic.List[string]]::new()
                $CurrentLines.Add($Line)
            }
            elseif ($PreservedTags.Contains($TagName)) {
                $CurrentBlockType = 'preserved'
                $CurrentTag = $TagName.ToLowerInvariant()
                $CurrentLines = [System.Collections.Generic.List[string]]::new()
                $CurrentLines.Add($Line)
            }
            else {
                $BodyLines.Add($Line)
            }
            continue
        }

        # Indented continuation of current block
        if ($CurrentBlockType -and $Line.Length -gt 0 -and $Line[0] -eq ' ') {
            $CurrentLines.Add($Line)
            continue
        }

        # Gen2 italic location line
        if ($Line.StartsWith('*Lokalizacj')) {
            if ($CurrentBlockType -eq 'meta' -and $CurrentTag) {
                $MetaBlocks[$CurrentTag] = $CurrentLines.ToArray()
            } elseif ($CurrentBlockType -eq 'preserved' -and $CurrentTag) {
                $PreservedBlocks.Add(@{ Tag = $CurrentTag; Lines = $CurrentLines.ToArray() })
            }
            $CurrentBlockType = $null; $CurrentTag = $null; $CurrentLines = $null
            $MetaBlocks['locations-italic'] = @($Line)
            continue
        }

        # Gen1/2 plain text log line
        if ([regex]::IsMatch($Line, '^Logi:\s*https?://')) {
            if ($CurrentBlockType -eq 'meta' -and $CurrentTag) {
                $MetaBlocks[$CurrentTag] = $CurrentLines.ToArray()
            } elseif ($CurrentBlockType -eq 'preserved' -and $CurrentTag) {
                $PreservedBlocks.Add(@{ Tag = $CurrentTag; Lines = $CurrentLines.ToArray() })
            }
            $CurrentBlockType = $null; $CurrentTag = $null; $CurrentLines = $null

            if ($MetaBlocks.Contains('logs-plain')) {
                $Existing = [System.Collections.Generic.List[string]]::new([string[]]$MetaBlocks['logs-plain'])
                $Existing.Add($Line)
                $MetaBlocks['logs-plain'] = $Existing.ToArray()
            } else {
                $MetaBlocks['logs-plain'] = @($Line)
            }
            continue
        }

        # Blank line while in a block -> close block
        if ($CurrentBlockType -and [string]::IsNullOrWhiteSpace($Line)) {
            if ($CurrentBlockType -eq 'meta' -and $CurrentTag) {
                $MetaBlocks[$CurrentTag] = $CurrentLines.ToArray()
            } elseif ($CurrentBlockType -eq 'preserved' -and $CurrentTag) {
                $PreservedBlocks.Add(@{ Tag = $CurrentTag; Lines = $CurrentLines.ToArray() })
            }
            $CurrentBlockType = $null; $CurrentTag = $null; $CurrentLines = $null
        }

        # Regular text or non-metadata line
        $BodyLines.Add($Line)
    }

    # Close final block
    if ($CurrentBlockType -eq 'meta' -and $CurrentTag) {
        $MetaBlocks[$CurrentTag] = $CurrentLines.ToArray()
    } elseif ($CurrentBlockType -eq 'preserved' -and $CurrentTag) {
        $PreservedBlocks.Add(@{ Tag = $CurrentTag; Lines = $CurrentLines.ToArray() })
    }

    return @{
        MetaBlocks      = $MetaBlocks
        PreservedBlocks = $PreservedBlocks
        BodyLines       = $BodyLines.ToArray()
    }
}

# Helper: converts an existing Gen3 metadata block (raw lines) to Gen4 format.
# Renames the root tag and re-indents children to 4-space base.
function ConvertTo-Gen4FromRawBlock {
    param(
        [string]$Tag,
        [string[]]$Lines,
        [string]$NL
    )

    $Gen4Tag = switch ($Tag) {
        'narrator'  { 'Narrator' }
        'data'      { 'Data' }
        'locations' { 'Lokacje' }
        'logs'      { 'Logi' }
        'pu'        { 'PU' }
        'changes'   { 'Zmiany' }
        'intel'     { 'Intel' }
        default     { $Tag }
    }

    $SB = [System.Text.StringBuilder]::new(256)
    [void]$SB.Append("- @${Gen4Tag}:")

    # Check for inline content on root line (e.g., "- Lokalizacje: A, B")
    $RootLine = $Lines[0]
    $ColonIdx = $RootLine.IndexOf(':')
    $InlineContent = ''
    if ($ColonIdx -ge 0 -and $ColonIdx + 1 -lt $RootLine.Length) {
        $InlineContent = $RootLine.Substring($ColonIdx + 1).Trim()
    }

    $ChildLines = if ($Lines.Count -gt 1) { $Lines[1..($Lines.Count - 1)] } else { @() }

    if ($ChildLines.Count -gt 0) {
        # Detect indent base from first meaningful child
        $MinIndent = [int]::MaxValue
        foreach ($CL in $ChildLines) {
            $Stripped = $CL.TrimStart()
            if ($Stripped.Length -eq 0) { continue }
            $Indent = $CL.Length - $Stripped.Length
            if ($Indent -gt 0 -and $Indent -lt $MinIndent) { $MinIndent = $Indent }
        }
        if ($MinIndent -eq [int]::MaxValue) { $MinIndent = 4 }
        $IndentBase = if ($MinIndent -le 3) { $MinIndent } else { 4 }

        foreach ($CL in $ChildLines) {
            $Stripped = $CL.TrimStart()
            if ($Stripped.Length -eq 0) { continue }
            $OldIndent = $CL.Length - $Stripped.Length
            $IndentLevel = [Math]::Max(1, [int][Math]::Round([double]$OldIndent / $IndentBase))
            $NewIndent = $IndentLevel * 4
            [void]$SB.Append($NL)
            [void]$SB.Append((' ' * $NewIndent) + $Stripped)
        }
    }
    elseif ($InlineContent) {
        # Inline comma-separated values -> expand to children
        foreach ($Part in $InlineContent.Split(',')) {
            $Trimmed = $Part.Trim()
            if ($Trimmed.Length -gt 0) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $Trimmed")
            }
        }
    }

    return $SB.ToString()
}

# Helper: converts a Gen2 italic location line (*Lokalizacja: X, Y*) to a Gen4 block.
function ConvertFrom-ItalicLocation {
    param(
        [string]$Line,
        [string]$NL
    )

    $Match = [regex]::Match($Line, '\*Lokalizacj[ae]?:\s*(.+?)\*')
    if (-not $Match.Success) { return $null }

    $Items = [System.Collections.Generic.List[string]]::new()
    foreach ($Part in $Match.Groups[1].Value.Split(',')) {
        $Trimmed = $Part.Trim()
        if ($Trimmed.Length -gt 0) { $Items.Add($Trimmed) }
    }

    if ($Items.Count -eq 0) { return $null }
    return ConvertTo-Gen4MetadataBlock -Tag 'Lokacje' -Items $Items.ToArray() -NL $NL
}

# Helper: converts Gen1/2 plain text log lines (Logi: URL) to a Gen4 block.
function ConvertFrom-PlainTextLog {
    param(
        [string[]]$Lines,
        [string]$NL
    )

    $UrlRegex = [regex]::new('(https?://\S+)')
    $Urls = [System.Collections.Generic.List[string]]::new()
    foreach ($Line in $Lines) {
        $Match = $UrlRegex.Match($Line)
        if ($Match.Success) { $Urls.Add($Match.Groups[1].Value) }
    }

    if ($Urls.Count -eq 0) { return $null }
    return ConvertTo-Gen4MetadataBlock -Tag 'Logi' -Items $Urls.ToArray() -NL $NL
}

# Helper: derives format generation from Split-SessionSection MetaBlocks dictionary.
# Returns 'Gen1', 'Gen2', 'Gen3', or 'Gen4'.
function Get-FormatFromSplit {
    param([System.Collections.Specialized.OrderedDictionary]$MetaBlocks)

    if ($MetaBlocks.Count -eq 0) { return 'Gen1' }

    if ($MetaBlocks.Contains('locations-italic')) { return 'Gen2' }

    $StructuredKeys = @('locations', 'logs', 'pu', 'changes', 'narrator', 'data', 'intel')
    foreach ($Key in $MetaBlocks.Keys) {
        if ($Key -eq 'logs-plain') { continue }
        if ($Key -in $StructuredKeys) {
            $FirstLine = $MetaBlocks[$Key][0]
            if ($FirstLine -match '^- @\w') { return 'Gen4' }
            return 'Gen3'
        }
    }

    if ($MetaBlocks.Contains('logs-plain')) { return 'Gen1' }

    return 'Gen1'
}

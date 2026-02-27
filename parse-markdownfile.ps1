<#
    .SYNOPSIS
    Self-contained Markdown file parser — extracts headers, sections, list items, and links
    from a single .md file into structured objects.

    .DESCRIPTION
    This is a standalone script (not a module function) designed to be loaded and executed
    by Get-Markdown inside RunspacePool workers. RunspacePool threads don't share the module
    scope, so this script must be entirely self-contained — no references to module functions
    or $script: variables.

    Input:  A single file path passed as a positional parameter.
    Output: A PSCustomObject with properties:
        - FilePath:  the input path (for caller correlation)
        - Headers:   list of header objects with Level, Text, ParentHeader, LineNumber
        - Sections:  list of section objects with Header, Content (raw text), Lists
        - Lists:     flat list of all list items across the file
        - Links:     list of link objects (MarkdownLink with Text+Url, or PlainUrl with Url)

    Parsing strategy:
    - Single-pass line-by-line scan, accumulating content into the current section
    - Code blocks (``` fences) are tracked to avoid treating their contents as Markdown
    - Headers are tracked in a stack to maintain parent-child hierarchy
    - List items use indent-based nesting: raw indentation is normalized to multiples of 2
      (Floor(indent/2)*2) to tolerate 1-3 space indents that all mean "one level deep"
    - Links are extracted from every non-code line: Markdown-style [text](url) first,
      then plain URLs from the remainder (after stripping Markdown links to avoid duplicates)
#>

param([string]$FilePath)

# Precompiled link patterns — used on every line outside code blocks
$MdLinkPattern  = [regex]'\[(.+?)\]\((.+?)\)'
$PlainUrlPattern = [regex]'https?:\/\/[^\s\)\]]+'

$Lines = [System.IO.File]::ReadAllLines($FilePath)

# Result collections
$Sections  = [System.Collections.Generic.List[object]]::new()
$Headers   = [System.Collections.Generic.List[object]]::new()
$Links     = [System.Collections.Generic.List[object]]::new()
$ListItems = [System.Collections.Generic.List[object]]::new()

# Parser state
$CurrentSectionContent = [System.Text.StringBuilder]::new()
$CurrentLists          = [System.Collections.Generic.List[object]]::new()
$CurrentHeader         = $null
$HeaderStack           = [System.Collections.Generic.Stack[object]]::new()  # tracks header hierarchy for ParentHeader
$ListStack             = [System.Collections.Generic.Stack[object]]::new()  # tracks list nesting for ParentListItem
$InCodeBlock           = $false
$LineNumber            = 0

foreach ($Line in $Lines) {
    $LineNumber++
    # TrimEnd only — preserve leading whitespace needed for indent detection
    $TrimLine = $Line.TrimEnd()

    # Code block fence toggle — everything between ``` pairs is opaque to the parser
    if ($TrimLine -match '^```') {
        $InCodeBlock = -not $InCodeBlock
        [void]$CurrentSectionContent.Append($Line).Append("`n")
        continue
    }

    if ($InCodeBlock) {
        [void]$CurrentSectionContent.Append($Line).Append("`n")
        continue
    }

    # Link extraction: Markdown-style first, then plain URLs from the leftover text
    foreach ($m in $MdLinkPattern.Matches($TrimLine)) {
        $Links.Add([PSCustomObject]@{
            Type = 'MarkdownLink'
            Text = $m.Groups[1].Value
            Url  = $m.Groups[2].Value
        })
    }
    # Strip already-captured Markdown links before scanning for plain URLs
    # to avoid double-counting URLs that appear inside [text](url)
    $StrippedLine = $MdLinkPattern.Replace($TrimLine, '')
    foreach ($m in $PlainUrlPattern.Matches($StrippedLine)) {
        $Links.Add([PSCustomObject]@{
            Type = 'PlainUrl'
            Url  = $m.Value
        })
    }

    # Header detection: "# Text", "## Text", etc.
    if ($TrimLine -match '^(#+)\s*(.+)$') {
        $Level = $Matches[1].Length
        $Text  = $Matches[2].Trim()

        # Pop headers at same or deeper level to find the correct parent
        while ($HeaderStack.Count -gt 0 -and $HeaderStack.Peek().Level -ge $Level) {
            [void]$HeaderStack.Pop()
        }

        $ParentHeader = if ($HeaderStack.Count -gt 0) { $HeaderStack.Peek() } else { $null }

        $HeaderObj = [PSCustomObject]@{
            Level        = $Level
            Text         = $Text
            ParentHeader = $ParentHeader
            LineNumber   = $LineNumber
        }
        $Headers.Add($HeaderObj)
        $HeaderStack.Push($HeaderObj)

        # Flush the previous section before starting a new one
        if ($CurrentSectionContent.Length -gt 0 -or $CurrentHeader -ne $null) {
            $Sections.Add([PSCustomObject]@{
                Header  = $CurrentHeader
                Content = $CurrentSectionContent.ToString().Trim()
                Lists   = $CurrentLists
            })
        }

        $CurrentSectionContent = [System.Text.StringBuilder]::new()
        $CurrentLists          = [System.Collections.Generic.List[object]]::new()
        $ListStack.Clear()
        $CurrentHeader = $HeaderObj
        continue
    }

    # List item detection: "- text", "* text", "+ text", "1. text"
    $ListMatch = [regex]::Match($TrimLine, '^(\s*)(\d+\.|[-\*\+])\s+(.+)$')
    if ($ListMatch.Success) {
        $RawIndent = $ListMatch.Groups[1].Value.Length
        # Normalize to multiples of 2 — tolerates 1-3 space indents that all mean "one level"
        $Indent    = [Math]::Floor($RawIndent / 2) * 2

        $Marker = $ListMatch.Groups[2].Value
        $Type   = if ($Marker -match '^\d+\.') { 'Numbered' } else { 'Bullet' }
        $Text   = $ListMatch.Groups[3].Value.Trim()

        # Pop items at same or deeper indent to find the correct parent
        while ($ListStack.Count -gt 0 -and $ListStack.Peek().Indent -ge $Indent) {
            [void]$ListStack.Pop()
        }

        $ParentItem = if ($ListStack.Count -gt 0) { $ListStack.Peek() } else { $null }

        $ListItem = [PSCustomObject]@{
            Type           = $Type
            Text           = $Text
            Indent         = $Indent
            ParentListItem = $ParentItem
            SectionHeader  = $CurrentHeader
        }

        $CurrentLists.Add($ListItem)
        $ListItems.Add($ListItem)
        $ListStack.Push($ListItem)
        [void]$CurrentSectionContent.Append($Line).Append("`n")
        continue
    }

    [void]$CurrentSectionContent.Append($Line).Append("`n")
}

# Flush the final section
if ($CurrentSectionContent.Length -gt 0 -or $CurrentHeader -ne $null) {
    $Sections.Add([PSCustomObject]@{
        Header  = $CurrentHeader
        Content = $CurrentSectionContent.ToString().Trim()
        Lists   = $CurrentLists
    })
}

return [PSCustomObject]@{
    FilePath = $FilePath
    Headers  = $Headers
    Sections = $Sections
    Lists    = $ListItems
    Links    = $Links
}

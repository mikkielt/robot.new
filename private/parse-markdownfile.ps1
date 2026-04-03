<#
    .SYNOPSIS
    Self-contained Markdown file parser - extracts headers, sections, list items, and links
    from a single .md file into structured objects.

    .DESCRIPTION
    This is a standalone script (not a module function) designed to be loaded and executed
    by Get-Markdown inside RunspacePool workers. RunspacePool threads don't share the module
    scope, so this script must be entirely self-contained - no references to module functions
    or $script: variables.

    Input:  A single file path passed as a positional parameter.
    Output: A PSCustomObject with properties:
        - FilePath:  the input path (for caller correlation)
        - Headers:   list of header objects with Level, Text, ParentHeader, LineNumber
        - Sections:  list of section objects with Header, Content (raw text), Lists
        - Lists:     flat list of all list items across the file
        - Links:     list of link objects (MarkdownLink with Text+Url, or PlainUrl with Url)

    Two parsing paths:
    1. C# fast path (Robot.MarkdownScanner): compiled centrally by Robot.PowerShell.psm1
       at module import time; AppDomain-wide, so RunspacePool workers share it. Returns ListEntry class objects directly,
       with ParentIndex converted from global to
       section-local and LocalIndex set for O(1) parent→children lookups.
       Headers are still reconstructed as PSCustomObjects (few, needed for
       ParentHeader chain traversal). Links returned as C# structs directly.
    2. PowerShell fallback: used when Robot.MarkdownScanner is not available
       (restricted environments, direct script invocation from tests without
       pre-loading). Uses precompiled regex patterns and stack-based hierarchy
       tracking. Produces compatible output with ParentIndex/LocalIndex integers.

    Parsing strategy (both paths):
    - Single-pass line-by-line scan, accumulating content into the current section
    - Code blocks (``` fences) are tracked to avoid treating their contents as Markdown
    - Headers are tracked in a stack to maintain parent-child hierarchy
    - List items use indent-based nesting: raw indentation is normalized to multiples of 2
      (Floor(indent/2)*2) to tolerate 1-3 space indents that all mean "one level deep"
    - Links are extracted from every non-code line: Markdown-style [text](url) first,
      then plain URLs from the remainder (after stripping Markdown links to avoid duplicates)
#>

param([string]$FilePath)

$Lines = [System.IO.File]::ReadAllLines($FilePath)

# ScanResult → PSCustomObject reconstruction (duplicated from get-markdown.ps1:ConvertFrom-ScanResult).
# This copy MUST stay self-contained for RunspacePool workers (no module scope access).
# Any changes here MUST be mirrored in ConvertFrom-ScanResult.
#
# C# path: compiled scanner with mixed struct/class output, then reconstruct object references.
# Robot.MarkdownScanner compiled centrally in Robot.PowerShell.psm1 — AppDomain-wide, shared by all
# RunspacePool workers. In test mode (direct script invocation without module import)
# the type may not be loaded; PSTypeName check handles both cases.
if (([System.Management.Automation.PSTypeName]'Robot.MarkdownScanner').Type) {
    $CsResult = [Robot.MarkdownScanner]::Parse($Lines)

    # Reconstruct header objects with actual ParentHeader references (not indices).
    # Headers are few (~10-50 per file) so PSCustomObject overhead is negligible,
    # and consumers (get-player.ps1) traverse $Header.ParentHeader chains.
    $HeaderObjs = [System.Collections.Generic.List[object]]::new($CsResult.Headers.Length)
    foreach ($H in $CsResult.Headers) {
        $ParentRef = if ($H.ParentIndex -ge 0) { $HeaderObjs[$H.ParentIndex] } else { $null }
        $HeaderObjs.Add([PSCustomObject]@{
            Level        = $H.Level
            Text         = $H.Text
            ParentHeader = $ParentRef
            LineNumber   = $H.LineNumber
        })
    }

    # Return ListEntry class objects directly.
    # Convert ParentIndex from global (full-file) to section-local (within Section.Lists)
    # and set LocalIndex for O(1) parent→children lookups in consumers.
    $SectionObjs = [System.Collections.Generic.List[object]]::new($CsResult.Sections.Length)
    foreach ($S in $CsResult.Sections) {
        $HeaderRef = if ($S.HeaderIndex -ge 0) { $HeaderObjs[$S.HeaderIndex] } else { $null }
        $Offset = $S.ListStartIndex
        $SectionLists = [System.Collections.Generic.List[object]]::new($S.ListCount)
        for ($J = 0; $J -lt $S.ListCount; $J++) {
            $LI = $CsResult.Lists[$Offset + $J]
            $LI.LocalIndex = $J
            $LI.ParentIndex = if ($LI.ParentIndex -ge 0) { $LI.ParentIndex - $Offset } else { -1 }
            $SectionLists.Add($LI)
        }
        $SectionObjs.Add([PSCustomObject]@{
            Header  = $HeaderRef
            Content = $S.Content
            Lists   = $SectionLists
        })
    }

    # Return LinkEntry structs directly — property access works on C# structs
    # via boxing; no mutations needed so struct semantics are fine.
    return [PSCustomObject]@{
        FilePath = $FilePath
        Headers  = $HeaderObjs
        Sections = $SectionObjs
        Lists    = $CsResult.Lists
        Links    = $CsResult.Links
    }
}

# PowerShell fallback - used when Robot.MarkdownScanner is not available
# (restricted environments, direct script invocation without pre-loading)

# Precompiled patterns - reused on every line, avoids per-line regex compilation
$MdLinkPattern    = [regex]'\[(.+?)\]\((.+?)\)'
$PlainUrlPattern  = [regex]'https?:\/\/[^\s\)\]]+'
$CodeFencePattern = [regex]'^```'
$HeaderPattern    = [regex]'^(#+)\s*(.+)$'
$ListItemPattern  = [regex]'^(\s*)(\d+\.|[-\*\+])\s+(.+)$'
$MarkerNumPattern = [regex]'^\d+\.'

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
$ListStack             = [System.Collections.Generic.Stack[int]]::new()     # tracks list nesting by section-local index
$InCodeBlock           = $false
$LineNumber            = 0

foreach ($Line in $Lines) {
    $LineNumber++
    # TrimEnd only - preserve leading whitespace needed for indent detection
    $TrimLine = $Line.TrimEnd()

    # Code block fence toggle - everything between ``` pairs is opaque to the parser
    if ($CodeFencePattern.IsMatch($TrimLine)) {
        $InCodeBlock = -not $InCodeBlock
        [void]$CurrentSectionContent.Append($Line).Append("`n")
        continue
    }

    if ($InCodeBlock) {
        [void]$CurrentSectionContent.Append($Line).Append("`n")
        continue
    }

    # Link extraction: Markdown-style first, then plain URLs from the leftover text
    foreach ($LinkMatch in $MdLinkPattern.Matches($TrimLine)) {
        $Links.Add([PSCustomObject]@{
            Type = 'MarkdownLink'
            Text = $LinkMatch.Groups[1].Value
            Url  = $LinkMatch.Groups[2].Value
        })
    }
    # Strip already-captured Markdown links before scanning for plain URLs
    # to avoid double-counting URLs that appear inside [text](url)
    $StrippedLine = $MdLinkPattern.Replace($TrimLine, '')
    foreach ($UrlMatch in $PlainUrlPattern.Matches($StrippedLine)) {
        $Links.Add([PSCustomObject]@{
            Type = 'PlainUrl'
            Url  = $UrlMatch.Value
        })
    }

    # Header detection: "# Text", "## Text", etc.
    $HeaderMatch = $HeaderPattern.Match($TrimLine)
    if ($HeaderMatch.Success) {
        $Level = $HeaderMatch.Groups[1].Value.Length
        $Text  = $HeaderMatch.Groups[2].Value.Trim()

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
    $ListMatch = $ListItemPattern.Match($TrimLine)
    if ($ListMatch.Success) {
        $RawIndent = $ListMatch.Groups[1].Value.Length
        # Normalize to multiples of 2 - tolerates 1-3 space indents that all mean "one level"
        $Indent    = [Math]::Floor($RawIndent / 2) * 2

        $Marker = $ListMatch.Groups[2].Value
        $Type   = if ($MarkerNumPattern.IsMatch($Marker)) { 'Numbered' } else { 'Bullet' }
        $Text   = $ListMatch.Groups[3].Value.Trim()

        # Pop items at same or deeper indent to find the correct parent
        while ($ListStack.Count -gt 0 -and $CurrentLists[$ListStack.Peek()].Indent -ge $Indent) {
            [void]$ListStack.Pop()
        }

        $ParentIdx = if ($ListStack.Count -gt 0) { $ListStack.Peek() } else { -1 }
        $LocalIdx = $CurrentLists.Count

        $ListItem = [PSCustomObject]@{
            Type           = $Type
            Text           = $Text
            Indent         = $Indent
            ParentIndex    = $ParentIdx
            LocalIndex     = $LocalIdx
            SectionHeader  = $CurrentHeader
        }

        $CurrentLists.Add($ListItem)
        $ListItems.Add($ListItem)
        $ListStack.Push($LocalIdx)
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

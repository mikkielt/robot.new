<#
    .SYNOPSIS
    Modifies existing session metadata and/or body content in Markdown files.

    .DESCRIPTION
    This file contains Set-Session and its helpers. It dot-sources
    format-sessionblock.ps1 for shared rendering helpers
    (ConvertTo-Gen4MetadataBlock, ConvertTo-SessionMetadata).

    Helpers:
    - Find-SessionInFile:        locates session section boundaries by header text or date
    - Split-SessionSection:      decomposes a section into metadata blocks, preserved blocks, and body
    - ConvertTo-Gen4FromRawBlock: converts existing Gen3 metadata block lines to Gen4 format
    - ConvertFrom-ItalicLocation: converts Gen2 italic location line to Gen4 block
    - ConvertFrom-PlainTextLog:  converts Gen1/2 plain text log lines to Gen4 block

    Set-Session locates a session section in one or more Markdown files and
    replaces metadata blocks (Locations, PU, Logs, Zmiany, Intel) and/or body
    content. Supports -WhatIf via ShouldProcess.

    Session identification: either pipeline input (Session object from Get-Session)
    or explicit -Date + -File parameters.

    Metadata replacement is always full-replace (not merge). Pass @() to clear a block.
    Pass $null (or omit) to leave a block unchanged.

    Format upgrade (-UpgradeFormat) converts Gen2/Gen3 metadata to Gen4 @-prefixed syntax.
    Non-metadata blocks (Objaśnienia, Efekty) are preserved as-is.
#>

# Dot-source shared helpers
. "$PSScriptRoot/format-sessionblock.ps1"

# Helper: finds session section boundaries in a file's lines by matching header
# text or date. Returns a list of match objects with HeaderLineIdx, SectionStartIdx,
# SectionEndIdx, HeaderText.
function Find-SessionInFile {
    param(
        [string[]]$Lines,
        [string]$TargetHeader,
        [datetime]$TargetDate
    )

    $DateRegex = [regex]::new('\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b')
    $Results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i]
        if (-not $Line.StartsWith('### ')) { continue }

        $HeaderText = $Line.Substring(4)
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
# MetaBlocks ([ordered] dict: canonical key → string[] lines), PreservedBlocks
# (List of Tag+Lines), and BodyLines (string[]).
function Split-SessionSection {
    param([string[]]$Lines)

    $MetaTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($T in @('pu', 'logi', 'lokalizacje', 'lokacje', 'zmiany', 'intel')) {
        [void]$MetaTags.Add($T)
    }

    $PreservedTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($T in @('objaśnienia', 'efekty', 'komunikaty', 'straty', 'nagrody')) {
        [void]$PreservedTags.Add($T)
    }

    # Normalize raw tag name → canonical key
    $TagKeyMap = @{
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

        # Blank line while in a block → close block
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
        # Inline comma-separated values → expand to children
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

function Set-Session {
    <#
        .SYNOPSIS
        Modifies existing session metadata and/or body content in Markdown files.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Pipeline')] param(
        [Parameter(ParameterSetName = 'Pipeline', Mandatory, ValueFromPipeline, HelpMessage = "Session object from Get-Session pipeline")]
        [object]$Session,

        [Parameter(ParameterSetName = 'Explicit', Mandatory, HelpMessage = "Session date to locate")]
        [datetime]$Date,

        [Parameter(ParameterSetName = 'Explicit', Mandatory, HelpMessage = "Path to Markdown file containing the session")]
        [ValidateNotNullOrEmpty()]
        [string]$File,

        [Parameter(HelpMessage = "Location names to set (full-replace)")]
        [string[]]$Locations,

        [Parameter(HelpMessage = "PU award entries to set (Character + Value)")]
        [object[]]$PU,

        [Parameter(HelpMessage = "Session log URLs to set")]
        [string[]]$Logs,

        [Parameter(HelpMessage = "Entity state changes (Zmiany entries) to set")]
        [object[]]$Changes,

        [Parameter(HelpMessage = "Intel targeting entries to set")]
        [object[]]$Intel,

        [Parameter(HelpMessage = "Body text content to replace")]
        [string]$Content,

        [Parameter(HelpMessage = "Hashtable of property overrides (alternative to individual parameters)")]
        [hashtable]$Properties,

        [Parameter(HelpMessage = "Convert Gen2/Gen3 metadata to Gen4 @-prefixed syntax")]
        [switch]$UpgradeFormat
    )

    process {
        # Resolve targets

        if ($PSCmdlet.ParameterSetName -eq 'Pipeline') {
            $TargetHeader = $Session.Header
            $TargetFiles = if ($Session.FilePaths) {
                @($Session.FilePaths)
            } else {
                @($Session.FilePath)
            }
        }
        else {
            $Root = Get-RepoRoot
            $FullPath = if ([System.IO.Path]::IsPathRooted($File)) { $File }
                        else { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $File)) }
            if (-not [System.IO.File]::Exists($FullPath)) {
                throw "File not found: $FullPath"
            }
            $TargetHeader = $null
            $TargetFiles = @($FullPath)
        }

        # Merge parameters (individual > Properties > null)

        $EffLocations = if ($PSBoundParameters.ContainsKey('Locations')) { $Locations }
                        elseif ($Properties -and $Properties.ContainsKey('Locations')) { $Properties.Locations }
                        else { $null }

        $EffPU = if ($PSBoundParameters.ContainsKey('PU')) { $PU }
                 elseif ($Properties -and $Properties.ContainsKey('PU')) { $Properties.PU }
                 else { $null }

        $EffLogs = if ($PSBoundParameters.ContainsKey('Logs')) { $Logs }
                   elseif ($Properties -and $Properties.ContainsKey('Logs')) { $Properties.Logs }
                   else { $null }

        $EffChanges = if ($PSBoundParameters.ContainsKey('Changes')) { $Changes }
                      elseif ($Properties -and $Properties.ContainsKey('Changes')) { $Properties.Changes }
                      else { $null }

        $EffIntel = if ($PSBoundParameters.ContainsKey('Intel')) { $Intel }
                    elseif ($Properties -and $Properties.ContainsKey('Intel')) { $Properties.Intel }
                    else { $null }

        $EffContent = if ($PSBoundParameters.ContainsKey('Content')) { $Content }
                      elseif ($Properties -and $Properties.ContainsKey('Content')) { $Properties.Content }
                      else { $null }

        # Check if any changes requested
        $HasChanges = ($null -ne $EffLocations) -or ($null -ne $EffPU) -or ($null -ne $EffLogs) -or
                      ($null -ne $EffChanges) -or ($null -ne $EffIntel) -or ($null -ne $EffContent) -or
                      $UpgradeFormat
        if (-not $HasChanges) {
            Write-Warning 'No changes specified. Use -Locations, -PU, -Logs, -Changes, -Intel, -Content, -Properties, or -UpgradeFormat.'
            return
        }

        $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

        # Metadata config: canonical key, Gen4 tag name, possible original keys in Split output
        $MetaConfig = @(
            @{ Key = 'locations'; Gen4Tag = 'Lokacje'; OrigKeys = @('locations', 'locations-italic'); Effective = $EffLocations }
            @{ Key = 'logs';      Gen4Tag = 'Logi';    OrigKeys = @('logs', 'logs-plain');            Effective = $EffLogs }
            @{ Key = 'pu';        Gen4Tag = 'PU';      OrigKeys = @('pu');                            Effective = $EffPU }
            @{ Key = 'changes';   Gen4Tag = 'Zmiany';  OrigKeys = @('changes');                       Effective = $EffChanges }
            @{ Key = 'intel';     Gen4Tag = 'Intel';    OrigKeys = @('intel');                         Effective = $EffIntel }
        )

        # Process each file

        foreach ($FilePath in $TargetFiles) {
            try {
                if (-not [System.IO.File]::Exists($FilePath)) {
                    Write-Error "File not found: $FilePath"
                    continue
                }

                $FileContent = [System.IO.File]::ReadAllText($FilePath, $UTF8NoBOM)
                $NL = if ($FileContent.Contains("`r`n")) { "`r`n" } else { "`n" }
                $FileLines = $FileContent.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

                # Find session section
                $Found = if ($TargetHeader) {
                    Find-SessionInFile -Lines $FileLines -TargetHeader $TargetHeader
                } else {
                    Find-SessionInFile -Lines $FileLines -TargetDate $Date
                }

                if ($Found.Count -eq 0) {
                    $Desc = if ($TargetHeader) { "header '$TargetHeader'" } else { "date $($Date.ToString('yyyy-MM-dd'))" }
                    throw "Session not found in '${FilePath}': no matching $Desc"
                }
                if ($Found.Count -gt 1 -and -not $TargetHeader) {
                    $Headers = ($Found | ForEach-Object { $_.HeaderText }) -join "', '"
                    throw "Ambiguous: $($Found.Count) sessions on $($Date.ToString('yyyy-MM-dd')) in '${FilePath}': '$Headers'. Use pipeline input to specify exact session."
                }

                $Match = $Found[0]

                # Extract section lines (between header line and next header/EOF)
                $SecStart = $Match.SectionStartIdx
                $SecEnd   = $Match.SectionEndIdx - 1
                $SectionLines = if ($SecStart -le $SecEnd) { $FileLines[$SecStart..$SecEnd] } else { @() }

                # Decompose section
                $Split = Split-SessionSection -Lines $SectionLines

                # Build new section content

                $MetaOutput = [System.Collections.Generic.List[string]]::new(5)

                foreach ($MC in $MetaConfig) {
                    $BlockText = $null

                    if ($null -ne $MC.Effective) {
                        # User provided new values → always Gen4
                        $BlockText = ConvertTo-Gen4MetadataBlock -Tag $MC.Gen4Tag -Items $MC.Effective -NL $NL
                    }
                    elseif ($UpgradeFormat) {
                        # Upgrade existing block to Gen4
                        foreach ($OrigKey in $MC.OrigKeys) {
                            if ($Split.MetaBlocks.Contains($OrigKey)) {
                                if ($OrigKey -eq 'locations-italic') {
                                    $BlockText = ConvertFrom-ItalicLocation -Line $Split.MetaBlocks[$OrigKey][0] -NL $NL
                                }
                                elseif ($OrigKey -eq 'logs-plain') {
                                    $BlockText = ConvertFrom-PlainTextLog -Lines $Split.MetaBlocks[$OrigKey] -NL $NL
                                }
                                else {
                                    $BlockText = ConvertTo-Gen4FromRawBlock -Tag $MC.Key -Lines $Split.MetaBlocks[$OrigKey] -NL $NL
                                }
                                break
                            }
                        }
                    }
                    else {
                        # Preserve original lines
                        foreach ($OrigKey in $MC.OrigKeys) {
                            if ($Split.MetaBlocks.Contains($OrigKey)) {
                                $BlockText = $Split.MetaBlocks[$OrigKey] -join $NL
                                break
                            }
                        }
                    }

                    if ($BlockText) { $MetaOutput.Add($BlockText) }
                }

                # Body lines (trim leading/trailing blanks)
                $Body = if ($null -ne $EffContent) {
                    $EffContent
                } else {
                    $BLines = [System.Collections.Generic.List[string]]::new($Split.BodyLines)
                    while ($BLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($BLines[0])) {
                        $BLines.RemoveAt(0)
                    }
                    while ($BLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($BLines[$BLines.Count - 1])) {
                        $BLines.RemoveAt($BLines.Count - 1)
                    }
                    if ($BLines.Count -gt 0) { $BLines -join $NL } else { '' }
                }

                # Preserved blocks
                $PreservedText = ''
                if ($Split.PreservedBlocks.Count -gt 0) {
                    $PBParts = [System.Collections.Generic.List[string]]::new()
                    foreach ($PB in $Split.PreservedBlocks) {
                        $PBParts.Add($PB.Lines -join $NL)
                    }
                    $PreservedText = $PBParts -join $NL
                }

                # Assemble new section
                $NewSectionSB = [System.Text.StringBuilder]::new(1024)

                $MetaStr = if ($MetaOutput.Count -gt 0) { $MetaOutput -join $NL } else { '' }
                $HasMeta = $MetaStr.Length -gt 0
                $HasBody = $Body.Length -gt 0
                $HasPreserved = $PreservedText.Length -gt 0

                if ($HasMeta) {
                    [void]$NewSectionSB.Append($NL)
                    [void]$NewSectionSB.Append($MetaStr)
                }

                if ($HasBody) {
                    [void]$NewSectionSB.Append($NL)
                    if ($HasMeta) { [void]$NewSectionSB.Append($NL) }
                    [void]$NewSectionSB.Append($Body)
                }

                if ($HasPreserved) {
                    [void]$NewSectionSB.Append($NL)
                    if ($HasMeta -or $HasBody) { [void]$NewSectionSB.Append($NL) }
                    [void]$NewSectionSB.Append($PreservedText)
                }

                [void]$NewSectionSB.Append($NL)

                # Reconstruct file

                $NewLines = [System.Collections.Generic.List[string]]::new($FileLines.Count)

                # Lines before section (including header)
                for ($k = 0; $k -lt $Match.SectionStartIdx; $k++) {
                    $NewLines.Add($FileLines[$k])
                }

                # New section content (appended as raw string, split back to lines)
                $NewSectionStr = $NewSectionSB.ToString()
                $NewSectionLines = $NewSectionStr.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)
                foreach ($NSL in $NewSectionLines) {
                    $NewLines.Add($NSL)
                }

                # Lines after section (from next header onward)
                for ($k = $Match.SectionEndIdx; $k -lt $FileLines.Count; $k++) {
                    $NewLines.Add($FileLines[$k])
                }

                $NewFileContent = $NewLines -join $NL

                # Write with ShouldProcess

                if ($PSCmdlet.ShouldProcess($FilePath, "Set-Session: modify session '$($Match.HeaderText)'")) {
                    [System.IO.File]::WriteAllText($FilePath, $NewFileContent, $UTF8NoBOM)
                }
            }
            catch {
                if ($TargetFiles.Count -gt 1) {
                    Write-Error "Failed to process '${FilePath}': $_"
                }
                else {
                    throw
                }
            }
        }
    }
}

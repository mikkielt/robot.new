<#
    .SYNOPSIS
    Private helper functions for parsing raw session log content into structured objects.

    .DESCRIPTION
    Detects log format (ChatLog vs Prose) and parses content into a cross-referenced
    structure with numbered lines, location segments, and extracted speaker/channel data.

    ChatLog format: timestamped lines with [HH:MM] [Channel] Speaker: text
    Prose format: narrative text with Speaker: text lines, no timestamps

    Helpers:
    - Get-LogFormat: detects ChatLog vs Prose by scanning for timestamp patterns
    - ConvertFrom-ChatLogContent: parses timestamped chat lines, location headers, continuations
    - ConvertFrom-ProseContent: parses narrative lines with Speaker: text pattern
    - ConvertFrom-LogContent: dispatcher that auto-detects format and routes to parser

    Module-level data:
    - $script:TimestampPattern: compiled regex for [HH:MM] prefix
    - $script:ChannelPattern: compiled regex for [Channel] tag
    - $script:SpeakerPattern: compiled regex for Speaker: text
    - $script:SpeakerOnlyPattern: compiled regex for Speaker: (no text)
    - $script:FormatDetectPattern: compiled regex for format detection
#>

# ── Precompiled Regex ─────────────────────────────────────────────────────────

# Matches timestamp prefix: [HH:MM]
$script:TimestampPattern = [regex]::new(
    '^\[(\d{2}:\d{2})\]\s*',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Matches channel tag: [Lokalny], [Prywatny], [Grupowy], etc.
$script:ChannelPattern = [regex]::new(
    '^\[([^\]]+)\]\s*',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Matches speaker prefix: "Name: text" (name is non-greedy, stops at first colon followed by space or end)
$script:SpeakerPattern = [regex]::new(
    '^([^:]+?):\s+(.*)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Matches speaker-only (no text after colon, or colon at end): "Name:" or "Name: "
$script:SpeakerOnlyPattern = [regex]::new(
    '^([^:]+?):\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Used for format detection: does line start with [HH:MM]?
$script:FormatDetectPattern = [regex]::new(
    '^\[\d{2}:\d{2}\]',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)


# ── Functions ─────────────────────────────────────────────────────────────────

function Get-LogFormat {
    <#
        .SYNOPSIS
        Detects whether log content is ChatLog or Prose format.

        .DESCRIPTION
        Scans the first ~30 non-empty lines. If 2+ match the [HH:MM] timestamp
        pattern, returns 'ChatLog'. Otherwise returns 'Prose'.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Raw log content string")]
        [string]$Content
    )

    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)
    $TimestampCount = 0
    $ScannedCount = 0

    foreach ($Line in $Lines) {
        $Trimmed = $Line.Trim()
        if ($Trimmed.Length -eq 0) { continue }

        if ($script:FormatDetectPattern.IsMatch($Trimmed)) {
            $TimestampCount++
            if ($TimestampCount -ge 2) { return 'ChatLog' }
        }

        $ScannedCount++
        if ($ScannedCount -ge 30) { break }
    }

    return 'Prose'
}


function ConvertFrom-ChatLogContent {
    <#
        .SYNOPSIS
        Parses ChatLog-format content into structured lines and location segments.

        .DESCRIPTION
        Processes content line by line, detecting:
        - Location headers: non-empty lines that don't start with [HH:MM]
          and aren't continuation text from a preceding timestamp line
        - Chat lines: [HH:MM] [Channel] Speaker: text (or narration without speaker)
        - Continuation lines: text following a [HH:MM] [Channel] line that had no
          inline content (joined to that chat line)

        Returns PSCustomObject with Format, Lines[], LocationSegments[].
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Raw ChatLog content string")]
        [string]$Content
    )

    $RawLines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $ParsedLines = [System.Collections.Generic.List[PSCustomObject]]::new()
    $LocationSegments = [System.Collections.Generic.List[PSCustomObject]]::new()

    $CurrentSegmentIndex = -1
    $PendingTimestamp = $null      # Holds a timestamp line awaiting continuation text
    $PendingChannel = $null

    foreach ($RawLine in $RawLines) {
        $Trimmed = $RawLine.Trim()

        # Empty lines — finalize any pending timestamp line as narration
        if ($Trimmed.Length -eq 0) {
            if ($null -ne $PendingTimestamp) {
                # Timestamp line with no content and no continuation — empty narration
                $LineObj = [PSCustomObject]@{
                    Index   = $ParsedLines.Count
                    Time    = $PendingTimestamp
                    Channel = $PendingChannel
                    Speaker = $null
                    Text    = ''
                    Segment = $CurrentSegmentIndex
                }
                $ParsedLines.Add($LineObj)
                $PendingTimestamp = $null
                $PendingChannel = $null
            }
            continue
        }

        # Check if this is a timestamped line
        $TsMatch = $script:TimestampPattern.Match($Trimmed)

        if ($TsMatch.Success) {
            # Finalize any pending timestamp line first
            if ($null -ne $PendingTimestamp) {
                $LineObj = [PSCustomObject]@{
                    Index   = $ParsedLines.Count
                    Time    = $PendingTimestamp
                    Channel = $PendingChannel
                    Speaker = $null
                    Text    = ''
                    Segment = $CurrentSegmentIndex
                }
                $ParsedLines.Add($LineObj)
                $PendingTimestamp = $null
                $PendingChannel = $null
            }

            $Time = $TsMatch.Groups[1].Value
            $Rest = $Trimmed.Substring($TsMatch.Length)

            # Extract channel tag
            $Channel = $null
            $ChMatch = $script:ChannelPattern.Match($Rest)
            if ($ChMatch.Success) {
                $Channel = $ChMatch.Groups[1].Value
                $Rest = $Rest.Substring($ChMatch.Length)
            }

            if ($Rest.Length -eq 0) {
                # No content after channel tag — next non-empty line is continuation
                $PendingTimestamp = $Time
                $PendingChannel = $Channel
                continue
            }

            # Parse speaker:text or treat as narration
            $Speaker = $null
            $Text = $Rest

            $SpMatch = $script:SpeakerPattern.Match($Rest)
            if ($SpMatch.Success) {
                $Speaker = $SpMatch.Groups[1].Value
                $Text = $SpMatch.Groups[2].Value
            } else {
                $SpOnlyMatch = $script:SpeakerOnlyPattern.Match($Rest)
                if ($SpOnlyMatch.Success) {
                    $Speaker = $SpOnlyMatch.Groups[1].Value
                    $Text = ''
                }
            }

            $LineObj = [PSCustomObject]@{
                Index   = $ParsedLines.Count
                Time    = $Time
                Channel = $Channel
                Speaker = $Speaker
                Text    = $Text
                Segment = $CurrentSegmentIndex
            }
            $ParsedLines.Add($LineObj)
            continue
        }

        # Non-timestamped, non-empty line
        if ($null -ne $PendingTimestamp) {
            # Continuation of a pending timestamp line
            $Speaker = $null
            $Text = $Trimmed

            $SpMatch = $script:SpeakerPattern.Match($Trimmed)
            if ($SpMatch.Success) {
                $Speaker = $SpMatch.Groups[1].Value
                $Text = $SpMatch.Groups[2].Value
            }

            $LineObj = [PSCustomObject]@{
                Index   = $ParsedLines.Count
                Time    = $PendingTimestamp
                Channel = $PendingChannel
                Speaker = $Speaker
                Text    = $Text
                Segment = $CurrentSegmentIndex
            }
            $ParsedLines.Add($LineObj)
            $PendingTimestamp = $null
            $PendingChannel = $null
            continue
        }

        # Not a continuation — this is a location header
        $CurrentSegmentIndex++
        $LocationSegments.Add([PSCustomObject]@{
            Index     = $CurrentSegmentIndex
            Raw       = $Trimmed
            StartLine = $ParsedLines.Count
            EndLine   = -1   # Updated after parsing completes
        })
    }

    # Finalize any remaining pending timestamp
    if ($null -ne $PendingTimestamp) {
        $LineObj = [PSCustomObject]@{
            Index   = $ParsedLines.Count
            Time    = $PendingTimestamp
            Channel = $PendingChannel
            Speaker = $null
            Text    = ''
            Segment = $CurrentSegmentIndex
        }
        $ParsedLines.Add($LineObj)
    }

    # Compute EndLine for each location segment
    $LineCount = $ParsedLines.Count
    for ($i = 0; $i -lt $LocationSegments.Count; $i++) {
        $Seg = $LocationSegments[$i]
        if ($i -lt $LocationSegments.Count - 1) {
            $Seg.EndLine = $LocationSegments[$i + 1].StartLine - 1
        } else {
            $Seg.EndLine = $LineCount - 1
        }
    }

    return [PSCustomObject]@{
        Format           = 'ChatLog'
        Lines            = [PSCustomObject[]]$ParsedLines.ToArray()
        LocationSegments = [PSCustomObject[]]$LocationSegments.ToArray()
    }
}


function ConvertFrom-ProseContent {
    <#
        .SYNOPSIS
        Parses Prose-format content into structured lines and location segments.

        .DESCRIPTION
        Prose logs have no timestamps. Lines are parsed as either:
        - Location headers: standalone heading-like lines (short, no colon pattern)
        - Dialogue/narration: "Speaker: text" or plain narration text

        Heuristic for location headers: a line that is <=60 chars, does not contain
        a colon followed by text (not a Speaker: pattern), and appears after an
        empty line or at the start of content.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Raw Prose content string")]
        [string]$Content
    )

    $RawLines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $ParsedLines = [System.Collections.Generic.List[PSCustomObject]]::new()
    $LocationSegments = [System.Collections.Generic.List[PSCustomObject]]::new()

    $CurrentSegmentIndex = -1
    $PreviousWasEmpty = $true   # Treat start of content as "after empty line"

    foreach ($RawLine in $RawLines) {
        $Trimmed = $RawLine.Trim()

        if ($Trimmed.Length -eq 0) {
            $PreviousWasEmpty = $true
            continue
        }

        # Heuristic: location header = short line after empty line, no Speaker: pattern
        $IsSpeaker = $script:SpeakerPattern.IsMatch($Trimmed) -or $script:SpeakerOnlyPattern.IsMatch($Trimmed)

        if ($PreviousWasEmpty -and -not $IsSpeaker -and $Trimmed.Length -le 60) {
            # Location header
            $CurrentSegmentIndex++
            $LocationSegments.Add([PSCustomObject]@{
                Index     = $CurrentSegmentIndex
                Raw       = $Trimmed
                StartLine = $ParsedLines.Count
                EndLine   = -1
            })
            $PreviousWasEmpty = $false
            continue
        }

        # Parse as dialogue or narration
        $Speaker = $null
        $Text = $Trimmed

        $SpMatch = $script:SpeakerPattern.Match($Trimmed)
        if ($SpMatch.Success) {
            $Speaker = $SpMatch.Groups[1].Value
            $Text = $SpMatch.Groups[2].Value
        } else {
            $SpOnlyMatch = $script:SpeakerOnlyPattern.Match($Trimmed)
            if ($SpOnlyMatch.Success) {
                $Speaker = $SpOnlyMatch.Groups[1].Value
                $Text = ''
            }
        }

        $LineObj = [PSCustomObject]@{
            Index   = $ParsedLines.Count
            Time    = $null
            Channel = $null
            Speaker = $Speaker
            Text    = $Text
            Segment = $CurrentSegmentIndex
        }
        $ParsedLines.Add($LineObj)
        $PreviousWasEmpty = $false
    }

    # Compute EndLine for each location segment
    $LineCount = $ParsedLines.Count
    for ($i = 0; $i -lt $LocationSegments.Count; $i++) {
        $Seg = $LocationSegments[$i]
        if ($i -lt $LocationSegments.Count - 1) {
            $Seg.EndLine = $LocationSegments[$i + 1].StartLine - 1
        } else {
            $Seg.EndLine = $LineCount - 1
        }
    }

    return [PSCustomObject]@{
        Format           = 'Prose'
        Lines            = [PSCustomObject[]]$ParsedLines.ToArray()
        LocationSegments = [PSCustomObject[]]$LocationSegments.ToArray()
    }
}


function ConvertFrom-LogContent {
    <#
        .SYNOPSIS
        Parses raw log content, auto-detecting the format.

        .DESCRIPTION
        Calls Get-LogFormat to detect ChatLog vs Prose, then dispatches to the
        appropriate converter function. Returns the same cross-referenced structure
        regardless of format.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Raw log content string to parse")]
        [string]$Content
    )

    $Format = Get-LogFormat -Content $Content

    switch ($Format) {
        'ChatLog' { return ConvertFrom-ChatLogContent -Content $Content }
        'Prose'   { return ConvertFrom-ProseContent -Content $Content }
        default   { return ConvertFrom-ProseContent -Content $Content }
    }
}

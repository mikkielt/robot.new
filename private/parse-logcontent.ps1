<#
    .SYNOPSIS
    Private helper functions for parsing raw session log content into structured objects.

    .DESCRIPTION
    Detects log format (ChatLog vs Prose) and parses content into a cross-referenced
    structure with numbered lines, location segments, and extracted speaker/channel data.
    Consumed by get-session.ps1 to populate the session's Logs property with parsed
    content from fetched log URLs.

    ChatLog format: timestamped lines with [HH:MM] [Channel] Speaker: text
    (used by Margonem game client logs). Supports multi-line continuations where
    a timestamp line has no content and the next non-empty line provides it.

    Prose format: narrative text with Speaker: text lines, no timestamps
    (used for hand-written session logs). Location headers are detected via
    heuristic: short line (<=60 chars) after an empty line with no Speaker: pattern.

    Both parsers produce identical output structure:
    - Format: 'ChatLog' or 'Prose'
    - Lines[]: { Index, Time, Channel, Speaker, Text, Segment }
    - LocationSegments[]: { Index, Raw, StartLine, EndLine }

    ConvertFrom-LogContent is the primary entry point. It first attempts
    the compiled C# path (Robot.LogParser) which pre-compiles all regex
    patterns and returns C# objects directly — LogLine structs and
    LocationSegment class instances. Falls back to PowerShell helpers
    when the C# type is unavailable.

    Helpers:
    - Get-LogFormat: detects ChatLog vs Prose by scanning first ~30 non-empty lines
      for [HH:MM] timestamps; 2+ matches = ChatLog, otherwise Prose
    - ConvertFrom-ChatLogContent: parses timestamped chat lines, location headers, continuations
    - ConvertFrom-ProseContent: parses narrative lines with Speaker: text pattern;
      uses heuristic for location headers (<=60 chars, after empty line, no Speaker: match)
    - ConvertFrom-LogContent: dispatcher that auto-detects format and routes to parser
    - New-ResolvedLogObject: builds the cross-referenced Get-SessionLog-shaped object
      (Speakers/Channels/LocationSegments/Mentions) from a parse result + name index;
      shared by Get-SessionLog and the /logs/parse API handler
    - Resolve-MessageMentions: extracts in-message entity mentions via Capitalized
      n-gram tokenization and Resolve-Name -NoFuzzy (Stages 1+2 only)

    Module-level data:
    - $script:TimestampPattern: compiled regex for [HH:MM] prefix
    - $script:ChannelPattern: compiled regex for [Channel] tag
    - $script:SpeakerPattern: compiled regex for Speaker: text
    - $script:SpeakerOnlyPattern: compiled regex for Speaker: (no text)
    - $script:FormatDetectPattern: compiled regex for format detection
    - $script:CapitalizedTokenPattern: compiled regex for Capitalized Unicode words
      (used by Resolve-MessageMentions for mention candidate extraction)
    - $script:SentenceBreakPattern: compiled regex for sentence terminators
      (keeps n-gram windows from spanning unrelated clauses)
#>

# C# type: Robot.LogParser (lib/LogParser.cs) — compiled centrally in Robot.PowerShell.psm1.
# Precompiled regex, LogLine structs, LocationSegment classes.

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

# Capitalized Unicode word (Polish diacritics allowed in the body of the token)
$script:CapitalizedTokenPattern = [regex]::new(
    '\p{Lu}[\p{L}\p{M}]*',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Sentence break — keeps n-gram windows from spanning unrelated clauses
$script:SentenceBreakPattern = [regex]::new(
    '[.!?]+',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)


# ── Functions ─────────────────────────────────────────────────────────────────

function Complete-LocationSegmentBoundaries {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Segments,
        [int]$TotalLineCount
    )
    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $Seg = $Segments[$i]
        if ($i -lt $Segments.Count - 1) {
            $Seg.EndLine = $Segments[$i + 1].StartLine - 1
        } else {
            $Seg.EndLine = $TotalLineCount - 1
        }
    }
}

function Get-LogFormat {
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
            if ($TimestampCount -ge 2) { return 'ChatLog' }  # 2 timestamps suffice to confirm ChatLog format
        }

        $ScannedCount++
        if ($ScannedCount -ge 30) { break }  # 30 lines: enough to detect format without scanning entire file
    }

    return 'Prose'
}


function ConvertFrom-ChatLogContent {
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
    Complete-LocationSegmentBoundaries -Segments $LocationSegments -TotalLineCount $ParsedLines.Count

    return [PSCustomObject]@{
        Format           = 'ChatLog'
        Lines            = [PSCustomObject[]]$ParsedLines.ToArray()
        LocationSegments = [PSCustomObject[]]$LocationSegments.ToArray()
    }
}


function ConvertFrom-ProseContent {
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

        if ($PreviousWasEmpty -and -not $IsSpeaker -and $Trimmed.Length -le 60) {  # 60 chars: longest observed location name in the lore repository
            # Location header
            $CurrentSegmentIndex++
            $LocationSegments.Add([PSCustomObject]@{
                Index     = $CurrentSegmentIndex
                Raw       = $Trimmed
                StartLine = $ParsedLines.Count
                EndLine   = -1   # Updated after parsing completes
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
    Complete-LocationSegmentBoundaries -Segments $LocationSegments -TotalLineCount $ParsedLines.Count

    return [PSCustomObject]@{
        Format           = 'Prose'
        Lines            = [PSCustomObject[]]$ParsedLines.ToArray()
        LocationSegments = [PSCustomObject[]]$LocationSegments.ToArray()
    }
}


function New-ResolvedLogObject {
    <#
        .SYNOPSIS
        Builds the cross-referenced Get-SessionLog-shaped object from a parse result
        and an optional name index.

        .DESCRIPTION
        Given a parsed log (ConvertFrom-LogContent output) and an optional name index,
        aggregates Speakers/Channels, resolves location segment headers and (optionally)
        extracts in-message entity mentions.

        Used by Get-SessionLog (per fetched URL) and the /logs/parse API handler
        (per inline content body). Extracting this from Get-SessionLog keeps the
        URL-based and inline-content code paths in sync.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Source URL or local path string to record on the output object")]
        [string]$Url,

        [Parameter(Mandatory, HelpMessage = "Parse result from ConvertFrom-LogContent")]
        [PSObject]$Parsed,

        [Parameter(HelpMessage = "Name index hashtable from Get-NameIndex (Index/StemIndex/BKTree)")]
        [hashtable]$Index,

        [Parameter(HelpMessage = "Shared resolution cache used across Speakers/LocationSegments/Mentions")]
        [hashtable]$Cache,

        [Parameter(HelpMessage = "Skip in-message mention extraction (Mentions/MentionsByLine fields)")]
        [switch]$SkipMentions
    )

    # Per-speaker and per-channel line indexing
    $SpeakerMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $ChannelMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Line in $Parsed.Lines) {
        if ($null -ne $Line.Speaker -and $Line.Speaker.Length -gt 0) {
            if (-not $SpeakerMap.ContainsKey($Line.Speaker)) {
                $SpeakerMap[$Line.Speaker] = [System.Collections.Generic.List[int]]::new()
            }
            $SpeakerMap[$Line.Speaker].Add($Line.Index)
        }
        if ($null -ne $Line.Channel -and $Line.Channel.Length -gt 0) {
            if (-not $ChannelMap.ContainsKey($Line.Channel)) {
                $ChannelMap[$Line.Channel] = [System.Collections.Generic.List[int]]::new()
            }
            $ChannelMap[$Line.Channel].Add($Line.Index)
        }
    }

    # Speakers — resolve when an index is provided
    $Speakers = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($Entry in $SpeakerMap.GetEnumerator()) {
        $Resolved = $null
        $Stage = $null
        if ($null -ne $Index) {
            $ResolveParams = @{ Query = $Entry.Key }
            if ($Index.ContainsKey('Index'))     { $ResolveParams['Index']     = $Index['Index'] }
            if ($Index.ContainsKey('StemIndex')) { $ResolveParams['StemIndex'] = $Index['StemIndex'] }
            if ($Index.ContainsKey('BKTree'))    { $ResolveParams['BKTree']    = $Index['BKTree'] }
            if ($null -ne $Cache) { $ResolveParams['Cache'] = $Cache }
            $ResolveResult = Resolve-Name @ResolveParams
            if ($null -ne $ResolveResult) {
                $Resolved = $ResolveResult.Name
                $Stage = $ResolveResult.Stage
            }
        }
        $Speakers.Add([PSCustomObject]@{
            Raw       = $Entry.Key
            Resolved  = $Resolved
            Stage     = $Stage
            Lines     = [int[]]$Entry.Value.ToArray()
            LineCount = $Entry.Value.Count
        })
    }

    # Channels — ChatLog only
    $Channels = $null
    if ($Parsed.Format -eq 'ChatLog' -and $ChannelMap.Count -gt 0) {
        $ChannelList = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($Entry in $ChannelMap.GetEnumerator()) {
            $ChannelList.Add([PSCustomObject]@{
                Name      = $Entry.Key
                Lines     = [int[]]$Entry.Value.ToArray()
                LineCount = $Entry.Value.Count
            })
        }
        $Channels = [PSCustomObject[]]$ChannelList.ToArray()
    }

    # Location segment resolution. LocationSegment is a C# class on the compiled
    # path (direct field assignment) and a PSCustomObject on the PS fallback path
    # (requires Add-Member).
    $LocationSegments = $Parsed.LocationSegments
    if ($null -ne $Index -and $null -ne $LocationSegments) {
        $IsCompiledPath = ([System.Management.Automation.PSTypeName]'Robot.LogParser').Type
        for ($i = 0; $i -lt $LocationSegments.Count; $i++) {
            $Seg = $LocationSegments[$i]
            $ResolveParams = @{ Query = $Seg.Raw }
            if ($Index.ContainsKey('Index'))     { $ResolveParams['Index']     = $Index['Index'] }
            if ($Index.ContainsKey('StemIndex')) { $ResolveParams['StemIndex'] = $Index['StemIndex'] }
            if ($Index.ContainsKey('BKTree'))    { $ResolveParams['BKTree']    = $Index['BKTree'] }
            if ($null -ne $Cache) { $ResolveParams['Cache'] = $Cache }
            $ResolveResult = Resolve-Name @ResolveParams
            if ($IsCompiledPath) {
                $Seg.Resolved = if ($null -ne $ResolveResult) { $ResolveResult.Name } else { $null }
                $Seg.Stage    = if ($null -ne $ResolveResult) { $ResolveResult.Stage } else { $null }
            } else {
                if ($null -ne $ResolveResult) {
                    $Seg | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue $ResolveResult.Name -Force
                    $Seg | Add-Member -NotePropertyName 'Stage'    -NotePropertyValue $ResolveResult.Stage -Force
                } else {
                    $Seg | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue $null -Force
                    $Seg | Add-Member -NotePropertyName 'Stage'    -NotePropertyValue $null -Force
                }
            }
        }
    }

    # In-message mention extraction — gated on -Index and -SkipMentions
    $Mentions = $null
    $MentionsByLine = $null
    if ($null -ne $Index -and -not $SkipMentions) {
        $MentionMap   = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $MentionTypes = [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $MentionsByLine = @{}

        foreach ($Line in $Parsed.Lines) {
            if ([string]::IsNullOrWhiteSpace($Line.Text)) { continue }
            $LineMentions = Resolve-MessageMentions -Text $Line.Text -Index $Index -Cache $Cache
            if ($null -eq $LineMentions -or $LineMentions.Count -eq 0) { continue }

            $MentionsByLine[$Line.Index] = $LineMentions
            foreach ($M in $LineMentions) {
                if (-not $MentionMap.ContainsKey($M.Resolved)) {
                    $MentionMap[$M.Resolved]   = [System.Collections.Generic.List[int]]::new()
                    $MentionTypes[$M.Resolved] = $M.Type
                }
                $MentionMap[$M.Resolved].Add($Line.Index)
            }
        }

        $Aggregated = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($Entry in $MentionMap.GetEnumerator()) {
            $Aggregated.Add([PSCustomObject]@{
                Resolved  = $Entry.Key
                Type      = $MentionTypes[$Entry.Key]
                Lines     = [int[]]$Entry.Value.ToArray()
                LineCount = $Entry.Value.Count
            })
        }
        $Mentions = [PSCustomObject[]]$Aggregated.ToArray()
    }

    return [PSCustomObject]@{
        Url              = $Url
        Format           = $Parsed.Format
        Lines            = $Parsed.Lines
        LocationSegments = $LocationSegments
        Speakers         = [PSCustomObject[]]$Speakers.ToArray()
        Channels         = $Channels
        Mentions         = $Mentions
        MentionsByLine   = $MentionsByLine
    }
}


function Resolve-MessageMentions {
    <#
        .SYNOPSIS
        Extracts entity mentions from a free-form message body via Capitalized-token
        n-gram windows resolved against a pre-built name index.

        .DESCRIPTION
        Tokenizes Text by Unicode capitalization, builds 1/2/3-gram contiguous windows
        within sentence boundaries, and resolves each window via Resolve-Name -NoFuzzy
        (Stages 1 + 2 only — exact and declension). Fuzzy matching is intentionally
        disabled inside narrative text because it produces too many false positives.

        Longest-match-wins per token position: a successful 3-gram match consumes its
        three tokens so the 1-gram and 2-gram subsets do not double-count.

        Returns an array of PSCustomObject { Raw, Resolved, Stage, Type, Offset, Length }
        with offsets relative to the input Text.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Message body text to scan for entity mentions")]
        [AllowEmptyString()] [string]$Text,

        [Parameter(Mandatory, HelpMessage = "Name index hashtable from Get-NameIndex (Index/StemIndex/BKTree)")]
        [hashtable]$Index,

        [Parameter(HelpMessage = "Shared resolution cache for cross-call memoization")]
        [hashtable]$Cache,

        [Parameter(HelpMessage = "Maximum n-gram window length (default 3)")]
        [ValidateRange(1, 5)] [int]$MaxNGram = 3
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $Mentions = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Walk sentences with their offsets so we can return character positions
    # relative to the original Text, not the sentence-local position
    $LastEnd = 0
    $Breaks = $script:SentenceBreakPattern.Matches($Text)
    $Sentences = [System.Collections.Generic.List[object]]::new()
    foreach ($Br in $Breaks) {
        $Len = $Br.Index - $LastEnd
        if ($Len -gt 0) {
            $Sentences.Add([PSCustomObject]@{
                Text   = $Text.Substring($LastEnd, $Len)
                Offset = $LastEnd
            })
        }
        $LastEnd = $Br.Index + $Br.Length
    }
    if ($LastEnd -lt $Text.Length) {
        $Sentences.Add([PSCustomObject]@{
            Text   = $Text.Substring($LastEnd, $Text.Length - $LastEnd)
            Offset = $LastEnd
        })
    }

    foreach ($S in $Sentences) {
        $Tokens = @($script:CapitalizedTokenPattern.Matches($S.Text))
        if ($Tokens.Count -eq 0) { continue }

        $I = 0
        while ($I -lt $Tokens.Count) {
            $MatchedLen = 0
            $Matched = $null

            # Longest window first — 3-gram beats 2-gram beats 1-gram
            $MaxAvailable = [Math]::Min($MaxNGram, $Tokens.Count - $I)
            for ($N = $MaxAvailable; $N -ge 1; $N--) {
                $Parts = @()
                for ($K = 0; $K -lt $N; $K++) { $Parts += $Tokens[$I + $K].Value }
                $Window = $Parts -join ' '

                $ResolveParams = @{ Query = $Window; NoFuzzy = $true }
                if ($Index.ContainsKey('Index'))     { $ResolveParams.Index     = $Index['Index'] }
                if ($Index.ContainsKey('StemIndex')) { $ResolveParams.StemIndex = $Index['StemIndex'] }
                if ($Index.ContainsKey('BKTree'))    { $ResolveParams.BKTree    = $Index['BKTree'] }
                if ($null -ne $Cache) { $ResolveParams.Cache = $Cache }

                $R = Resolve-Name @ResolveParams
                if ($null -ne $R) {
                    $Matched = $R
                    $MatchedLen = $N
                    break
                }
            }

            if ($null -ne $Matched) {
                $StartIdx = $Tokens[$I].Index
                $EndIdx   = $Tokens[$I + $MatchedLen - 1].Index + $Tokens[$I + $MatchedLen - 1].Length
                $Mentions.Add([PSCustomObject]@{
                    Raw      = $S.Text.Substring($StartIdx, $EndIdx - $StartIdx)
                    Resolved = $Matched.Name
                    Stage    = if ($Matched.PSObject.Properties['Stage']) { $Matched.Stage } else { $null }
                    Type     = if ($Matched.PSObject.Properties['Type'])  { $Matched.Type }  else { $null }
                    Offset   = $S.Offset + $StartIdx
                    Length   = $EndIdx - $StartIdx
                })
                $I += $MatchedLen
            } else {
                $I++
            }
        }
    }

    return [PSCustomObject[]]$Mentions.ToArray()
}


function ConvertFrom-LogContent {
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Raw log content string to parse")]
        [string]$Content
    )

    # C# path: return C# objects directly — LogLine struct fields and
    # LocationSegment class properties are accessible by name in PowerShell.
    # LocationSegment is a class (not struct) so Get-SessionLog can set
    # .Resolved/.Stage via direct property assignment without boxing issues.
    if (([System.Management.Automation.PSTypeName]'Robot.LogParser').Type) {
        $CsResult = [Robot.LogParser]::Parse($Content)

        return [PSCustomObject]@{
            Format           = $CsResult.Format
            Lines            = $CsResult.Lines
            LocationSegments = $CsResult.LocationSegments
        }
    }

    # PowerShell fallback
    $Format = Get-LogFormat -Content $Content

    switch ($Format) {
        'ChatLog' { return ConvertFrom-ChatLogContent -Content $Content }
        'Prose'   { return ConvertFrom-ProseContent -Content $Content }
        default   { return ConvertFrom-ProseContent -Content $Content }
    }
}

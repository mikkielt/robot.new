<#
    .SYNOPSIS
    Chrome rendering helpers for the Robot CLI TUI engine.

    .DESCRIPTION
    Renders the persistent UI chrome elements that frame the content area:
    top bar (breadcrumb navigation path and health subsystem badges),
    filter bar (inline filter text with match count, or the "/" command
    palette with shortcut hints), and status bar (contextual key hints
    for the active component).

    Also provides match highlighting for the inline filter system.
    Filter highlighting uses two rendering strategies: contiguous matches
    (prefix/contains from stages 1-2) bold the matched character range
    inline, while non-contiguous matches (fuzzy/declension from stage 3)
    prepend an approximate symbol because there are no contiguous
    character positions to highlight.

    Helpers:
    - Split-HighlightSegments:  splits text into highlighted/normal segments for filter matches
    - Render-TopBar:            breadcrumb path + health badges into TopBar region
    - Render-FilterBar:         filter text + count, or command palette into Filter region
    - Render-StatusBar:         key hints for the active component into StatusBar region

    Dependencies:
    - cli-engine.ps1:   Get-Region, Get-CLIColor, $script:ScreenWidth, $script:BackBuffer
    - cli-buffer.ps1:   New-Segment, Set-BufferLine
    - cli-input.ps1:    $script:CommandMode, $script:CommandBuffer, $script:FilterActive,
                        Get-FilterText, Split-FilterQuery, $script:FilterHintPending
#>

# ── Match Highlighting ──────────────────────────────────────────────────────

function Split-HighlightSegments {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [string]$NormalColor,
        [string]$HighlightColor,
        [Parameter(Mandatory)] [hashtable]$MatchInfo
    )

    if ($MatchInfo.Type -eq 'fuzzy') {
        return ,@(
            (New-Segment -Text "$([char]0x2248) " -Color $HighlightColor)
            (New-Segment -Text $Text -Color $NormalColor)
        )
    }

    $Start  = $MatchInfo.Start
    $Length = $MatchInfo.Length

    if ($Start -lt 0 -or $Length -le 0 -or $Start -ge $Text.Length) {
        return ,@((New-Segment -Text $Text -Color $NormalColor))
    }

    $End = [Math]::Min($Start + $Length, $Text.Length)
    $Segments = [System.Collections.Generic.List[object]]::new()

    if ($Start -gt 0) {
        [void]$Segments.Add((New-Segment -Text $Text.Substring(0, $Start) -Color $NormalColor))
    }

    [void]$Segments.Add((New-Segment -Text $Text.Substring($Start, $End - $Start) -Color $HighlightColor -Bold))

    if ($End -lt $Text.Length) {
        [void]$Segments.Add((New-Segment -Text $Text.Substring($End) -Color $NormalColor))
    }

    return ,$Segments.ToArray()
}

# ── Chrome Rendering ─────────────────────────────────────────────────────────

function Render-TopBar {
    param(
        [Parameter(Mandatory)] [object]$State
    )

    $Region = Get-Region -Name 'TopBar'
    if ($null -eq $Region) { return }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    # Reverse stack so root appears first (stack is LIFO, breadcrumb reads left-to-right)
    $Parts = [System.Collections.Generic.List[string]]::new()
    $StackArray = $State.BreadcrumbStack.ToArray()
    [System.Array]::Reverse($StackArray)
    foreach ($Part in $StackArray) {
        [void]$Parts.Add($Part)
    }

    $BreadcrumbText = ' ' + ($Parts -join ' > ')

    # Aggregate subsystem health into compact badges (checkmark or warning count)
    $BadgeStr = ''
    if ($State.PSObject.Properties['HealthCache'] -and $State.HealthCache) {
        $HC = $State.HealthCache
        $BadgeParts = [System.Collections.Generic.List[string]]::new()

        if ($HC.PU) {
            $PUWarnCount = @($HC.PU | Where-Object { $_.Status -ne 'OK' }).Count
            if ($PUWarnCount -eq 0) { [void]$BadgeParts.Add("PU:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("PU:$([char]0x26A0)$PUWarnCount") }
        }

        if ($HC.Currency) {
            $CWarnCount = if ($HC.Currency.WarningCount) { $HC.Currency.WarningCount } else { 0 }
            if ($CWarnCount -eq 0) { [void]$BadgeParts.Add("Waluta:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("Waluta:$([char]0x26A0)$CWarnCount") }
        }

        if ($HC.Integrity) {
            $IWarnCount = @($HC.Integrity | Where-Object { -not $_.IsValid }).Count
            if ($IWarnCount -eq 0) { [void]$BadgeParts.Add("Sesje:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("Sesje:$([char]0x26A0)$IWarnCount") }
        }

        if ($HC.Graph) {
            $GWarnCount = if ($HC.Graph.WarningCount) { $HC.Graph.WarningCount } else { 0 }
            if ($GWarnCount -eq 0) { [void]$BadgeParts.Add("Graf:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("Graf:$([char]0x26A0)$GWarnCount") }
        }

        if ($BadgeParts.Count -gt 0) {
            $BadgeStr = "[$($BadgeParts -join '  ')]"
        }
    }

    # Right-align badges against breadcrumb to use the full top bar width
    $AvailWidth = $script:ScreenWidth - $BreadcrumbText.Length - 2
    $PaddedBadge = if ($BadgeStr -and $AvailWidth -gt $BadgeStr.Length) {
        $BadgeStr.PadLeft($AvailWidth)
    } else { '' }

    $Segments = @(
        (New-Segment -Text $BreadcrumbText -Color $AccentColor -Bold)
        (New-Segment -Text $PaddedBadge -Color $DisabledColor)
    )

    Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments $Segments
}

function Render-FilterBar {
    param(
        [Parameter(Mandatory)] [object]$State,
        [object]$Component
    )

    $Region = Get-Region -Name 'Filter'
    if ($null -eq $Region) { return }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $WarningColor  = Get-CLIColor -Role 'Warning'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    $BorderH = [string][char]0x2500

    # Command palette mode — shows "/" prompt with available shortcut hints
    if ($script:CommandMode) {
        $CmdText = $script:CommandBuffer.ToString()
        $HintText = ' h pomoc ' + [char]0x00B7 + ' s stan ' + [char]0x00B7 +
                    ' r odswiez ' + [char]0x00B7 + ' q wyjdz '
        $Prefix = " $($BorderH * 2) "
        $Prompt = "> /$CmdText"
        $Cursor = '_'
        $FixedLen = $Prefix.Length + $Prompt.Length + $Cursor.Length + $HintText.Length + 2
        $FillLen  = $script:ScreenWidth - $FixedLen
        if ($FillLen -lt 1) { $FillLen = 1 }
        $Segments = @(
            (New-Segment -Text $Prefix -Color $DisabledColor -Dim)
            (New-Segment -Text $Prompt -Color $AccentColor -Bold)
            (New-Segment -Text $Cursor -Color $DisabledColor)
            (New-Segment -Text " $($BorderH * $FillLen) " -Color $DisabledColor -Dim)
            (New-Segment -Text $HintText -Color $DisabledColor)
        )
        Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments $Segments
        return
    }

    # Active filter mode — shows typed query, optional type prefix badge, and match count
    if ($script:FilterActive) {
        $FilterText = Get-FilterText
        $Parsed = Split-FilterQuery -RawInput $FilterText -FilterPrefixes $Component.FilterPrefixes

        $Segments = [System.Collections.Generic.List[object]]::new()
        [void]$Segments.Add((New-Segment -Text " $($BorderH * 2) " -Color $DisabledColor -Dim))
        [void]$Segments.Add((New-Segment -Text '> ' -Color $AccentColor -Bold))

        # Show resolved type filter label (e.g., "NPC", "Lokacja") when user typed "typ:query"
        if ($Parsed.Prefix) {
            $TypeLabel = $Parsed.TypeFilter
            if (-not $TypeLabel) { $TypeLabel = $Parsed.Prefix }
            [void]$Segments.Add((New-Segment -Text "[$TypeLabel] " -Color $AccentColor -Bold))
        }

        [void]$Segments.Add((New-Segment -Text "$($Parsed.Query)_" -Color $AccentColor))

        # Show "N z M" match count so the user knows how many items passed the filter
        if ($Component -and $Component.PSObject -and
            $Component.FilteredCount -is [int] -and $Component.TotalCount -is [int]) {
            $CountText = "    $($Component.FilteredCount) z $($Component.TotalCount)"
            $CountColor = if ($Component.FilteredCount -eq 0) { $WarningColor } else { $DisabledColor }
            [void]$Segments.Add((New-Segment -Text $CountText -Color $CountColor))
        }

        # One-time onboarding hint shown only on the first filter activation per session
        if ($script:FilterHintPending) {
            $script:FilterHintPending = $false
            [void]$Segments.Add((New-Segment -Text '  wpisz typ: aby filtrowac' -Color $DisabledColor))
        }

        Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments @($Segments)
        return
    }

    # Inactive state — show dimmed placeholder to signal that typing starts a filter
    $Filterable = $Component -and $Component.Filterable
    if ($Filterable) {
        $Prefix      = " $($BorderH * 2) "
        $Prompt      = '> '
        $Placeholder = 'wpisz aby filtrowac'
        $SlashHint   = '/ polecenia '
        $FixedLen    = $Prefix.Length + $Prompt.Length + $Placeholder.Length + $SlashHint.Length + 2
        $FillLen     = $script:ScreenWidth - $FixedLen
        if ($FillLen -lt 1) { $FillLen = 1 }
        $Segments = @(
            (New-Segment -Text $Prefix -Color $DisabledColor -Dim)
            (New-Segment -Text $Prompt -Color $DisabledColor -Dim)
            (New-Segment -Text $Placeholder -Color $DisabledColor -Dim)
            (New-Segment -Text " $($BorderH * $FillLen) " -Color $DisabledColor -Dim)
            (New-Segment -Text $SlashHint -Color $DisabledColor -Dim)
        )
        Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments $Segments
    } else {
        Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments @()
    }
}

function Render-StatusBar {
    param(
        [object]$Component
    )

    $Region = Get-Region -Name 'StatusBar'
    if ($null -eq $Region) { return }

    $DisabledColor = Get-CLIColor -Role 'Disabled'

    $Hints = if ($Component -and $Component.StatusHints) {
        $Component.StatusHints
    } else {
        "$([char]0x2191)$([char]0x2193) nawigacja  Enter wybierz  /h pomoc  Esc wstecz"
    }

    $Segments = @(
        (New-Segment -Text " $Hints" -Color $DisabledColor)
    )

    Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments $Segments
}

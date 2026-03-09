<#
    .SYNOPSIS
    Interactive menu components for the Robot CLI - arrow menus and result tables.

    .DESCRIPTION
    DEPRECATED: All functions in this file are deprecated. Use the TUI engine
    (engine/) equivalents instead:
    - Show-ArrowMenu  → New-MenuListComponent + Invoke-EngineLifecycle
    - Show-ResultTable → New-TableComponent + Invoke-EngineLifecycle
    - Show-HelpOverlay → engine overlay system

    Retained for plugin/migration compatibility (migration-ui.ps1,
    cli-wf-margoworld.ps1). Will be removed once all callers are ported.

    These functions depend on the primitives defined in cli-primitives.ps1
    (Get-CLIColor, Write-CLILine, Read-ArrowKey, Clear-MenuArea) and are
    chain-loaded via dot-source from that file. Do not dot-source this file
    directly; loading cli-primitives.ps1 is sufficient.
#>

# ── Show-HelpOverlay ─────────────────────────────────────────────────────────

function Show-HelpOverlay {
    # DEPRECATED: Retained for plugin/migration compatibility. Will be removed in a future version.
    param(
        [string]$Title,
        [string[]]$Content,
        [int]$MenuStartRow,
        [int]$MenuLineCount
    )

    # Box-drawing characters
    $BorderTL = [char]0x250C  # ┌
    $BorderTR = [char]0x2510  # ┐
    $BorderBL = [char]0x2514  # └
    $BorderBR = [char]0x2518  # ┘
    $BorderH  = [char]0x2500  # ─
    $BorderV  = [char]0x2502  # │

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'

    # Calculate box dimensions
    $TermWidth = [System.Console]::WindowWidth
    $MaxContentWidth = 0
    foreach ($Line in $Content) {
        if ($Line.Length -gt $MaxContentWidth) { $MaxContentWidth = $Line.Length }
    }
    $TitleWidth = if ($Title) { $Title.Length + 4 } else { 0 }
    if ($TitleWidth -gt $MaxContentWidth) { $MaxContentWidth = $TitleWidth }

    $BoxInnerWidth = [Math]::Min($MaxContentWidth + 2, $TermWidth - 10)
    $BoxInnerWidth = [Math]::Max($BoxInnerWidth, 20)
    $BoxWidth = $BoxInnerWidth + 4  # 2 border + 2 padding

    # Height: use full terminal height for sizing, shift $Top upward if needed
    $TermHeight = [System.Console]::WindowHeight
    $BoxInnerHeight = [Math]::Min($Content.Count, $TermHeight - 4)
    $BoxInnerHeight = [Math]::Max($BoxInnerHeight, 1)
    $BoxHeight = $BoxInnerHeight + 4  # top + content + footer + bottom

    $NeedsScroll = $Content.Count -gt $BoxInnerHeight

    # Left-align with indent, top-align with menu start (shift up if box overflows terminal)
    $Left = 3
    $Top = $MenuStartRow
    if ($Top + $BoxHeight -gt $TermHeight) {
        $Top = [Math]::Max(0, $TermHeight - $BoxHeight)
    }

    $ScrollOffset = 0

    while ($true) {
        $Row = $Top

        # Top border with title
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($Left, $Row)
        $TitleStr = if ($Title) { " $Title " } else { '' }
        $TopFillLen = $BoxWidth - 2 - $TitleStr.Length
        $TopLeftFill = [Math]::Max(0, [Math]::Floor($TopFillLen / 2))
        $TopRightFill = [Math]::Max(0, $TopFillLen - $TopLeftFill)
        Write-Host "$BorderTL$([string]$BorderH * $TopLeftFill)$TitleStr$([string]$BorderH * $TopRightFill)$BorderTR" -NoNewline -ForegroundColor $AccentColor
        $Row++

        # Content lines
        for ($I = 0; $I -lt $BoxInnerHeight; $I++) {
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($Left, $Row)
            $ContentIdx = $ScrollOffset + $I
            $LineText = if ($ContentIdx -lt $Content.Count) { $Content[$ContentIdx] } else { '' }
            if ($LineText.Length -gt $BoxInnerWidth) {
                $LineText = $LineText.Substring(0, $BoxInnerWidth - 3) + '...'
            }
            $PaddedLine = $LineText.PadRight($BoxInnerWidth)
            Write-Host "$BorderV " -NoNewline -ForegroundColor $AccentColor
            Write-Host $PaddedLine -NoNewline -ForegroundColor $InfoColor
            Write-Host " $BorderV" -NoNewline -ForegroundColor $AccentColor
            $Row++
        }

        # Footer line with scroll indicators and dismiss hint
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($Left, $Row)
        $ScrollHint = ''
        if ($NeedsScroll) {
            $UpArrow = if ($ScrollOffset -gt 0) { [string][char]0x2191 } else { ' ' }
            $DownArrow = if ($ScrollOffset -lt ($Content.Count - $BoxInnerHeight)) { [string][char]0x2193 } else { ' ' }
            $ScrollHint = "$UpArrow$DownArrow  "
        }
        $DismissHint = 'dowolny klawisz = zamknij'
        $FooterContent = "$ScrollHint$DismissHint"
        if ($FooterContent.Length -gt $BoxInnerWidth) {
            $FooterContent = $FooterContent.Substring(0, $BoxInnerWidth)
        }
        $PaddedFooter = $FooterContent.PadRight($BoxInnerWidth)
        Write-Host "$BorderV " -NoNewline -ForegroundColor $AccentColor
        Write-Host $PaddedFooter -NoNewline -ForegroundColor $DisabledColor
        Write-Host " $BorderV" -NoNewline -ForegroundColor $AccentColor
        $Row++

        # Bottom border
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($Left, $Row)
        Write-Host "$BorderBL$([string]$BorderH * ($BoxWidth - 2))$BorderBR" -NoNewline -ForegroundColor $AccentColor

        # Read input
        $Key = Read-ArrowKey

        if ($Key.Key -eq 'UpArrow') {
            if ($ScrollOffset -gt 0) { $ScrollOffset-- }
            continue
        }
        if ($Key.Key -eq 'DownArrow') {
            if ($NeedsScroll -and $ScrollOffset -lt ($Content.Count - $BoxInnerHeight)) { $ScrollOffset++ }
            continue
        }

        # Any other key dismisses the overlay
        break
    }

    # Clean up overlay area so menu redraw starts from clean state
    $OverlayBlank = ' ' * $BoxWidth
    $OverlayEnd = $Top + $BoxInnerHeight + 3  # top border + content + footer + bottom border
    for ($CleanRow = $Top; $CleanRow -le $OverlayEnd; $CleanRow++) {
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($Left, $CleanRow)
        Write-Host $OverlayBlank -NoNewline
    }
}

# ── Show-ArrowMenu ───────────────────────────────────────────────────────────

function Show-ArrowMenu {
    # DEPRECATED: Use New-MenuListComponent + Invoke-EngineLifecycle instead.
    # Retained for plugin/migration compatibility. Will be removed in a future version.
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [string]$Title,
        [switch]$ShowBack,
        [string[]]$HelpContent,
        [string]$HelpTitle = 'Pomoc'
    )

    if ($Items.Count -eq 0) {
        Write-CLILine -Text 'Brak dostępnych opcji.' -Color (Get-CLIColor -Role 'Disabled')
        Write-CLILine -Text ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
        return '__back__'
    }

    # Filter out disabled items for selection, but show them in the list
    $SelectableIndices = [System.Collections.Generic.List[int]]::new()
    for ($I = 0; $I -lt $Items.Count; $I++) {
        if (-not $Items[$I].Disabled) {
            [void]$SelectableIndices.Add($I)
        }
    }

    if ($SelectableIndices.Count -eq 0) {
        Write-CLILine -Text 'Brak dostępnych opcji.' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
        return '__back__'
    }

    $SelectedPos = 0  # Position within selectable indices
    $PrevInfoLines = 0
    $PrevHintRow = -1

    # Calculate max label width for alignment
    $MaxLabelWidth = 0
    foreach ($Item in $Items) {
        $LabelLen = $Item.Label.Length
        if ($Item.RoleTag) { $LabelLen += $Item.RoleTag.Length + 1 }
        if ($LabelLen -gt $MaxLabelWidth) { $MaxLabelWidth = $LabelLen }
    }
    $MaxLabelWidth = [Math]::Min($MaxLabelWidth + 4, [System.Console]::WindowWidth - 20)

    # Pre-extend terminal buffer to prevent scroll during rendering
    $MaxInfoLines = 0
    foreach ($Item in $Items) {
        if ($Item.InfoText) {
            $ICount = if ($Item.InfoText -is [array]) { $Item.InfoText.Count } else { 1 }
            if ($ICount -gt $MaxInfoLines) { $MaxInfoLines = $ICount }
        }
    }
    $TotalMenuHeight = $Items.Count + $(if ($MaxInfoLines -gt 0) { 1 + $MaxInfoLines } else { 0 }) + 2
    for ($Pre = 0; $Pre -lt $TotalMenuHeight; $Pre++) {
        Write-Host ''
    }
    $MenuStartRow = [Math]::Max(0, $Host.UI.RawUI.CursorPosition.Y - $TotalMenuHeight)
    $PrevWindowWidth = [System.Console]::WindowWidth
    $PrevWindowHeight = [System.Console]::WindowHeight

    while ($true) {
        $CurrentIndex = $SelectableIndices[$SelectedPos]

        # Detect terminal resize and re-anchor menu position
        $CurWidth = [System.Console]::WindowWidth
        $CurHeight = [System.Console]::WindowHeight
        if ($CurWidth -ne $PrevWindowWidth -or $CurHeight -ne $PrevWindowHeight) {
            $PrevWindowWidth = $CurWidth
            $PrevWindowHeight = $CurHeight
            # Recalculate label width for new terminal width
            $MaxLabelWidth = 0
            foreach ($Item in $Items) {
                $LabelLen = $Item.Label.Length
                if ($Item.RoleTag) { $LabelLen += $Item.RoleTag.Length + 1 }
                if ($LabelLen -gt $MaxLabelWidth) { $MaxLabelWidth = $LabelLen }
            }
            $MaxLabelWidth = [Math]::Min($MaxLabelWidth + 4, $CurWidth - 20)
            # Re-anchor: estimate menu start from current cursor position
            $TotalMenuLines = $Items.Count + $PrevInfoLines + 3
            $MenuStartRow = [Math]::Max(0, $Host.UI.RawUI.CursorPosition.Y - $TotalMenuLines)
        }

        # Move to menu start position
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow)

        $AccentColor  = Get-CLIColor -Role 'Accent'
        $DisabledColor = Get-CLIColor -Role 'Disabled'
        $RoleTagColor  = Get-CLIColor -Role 'RoleTag'

        $LinesRendered = 0

        for ($I = 0; $I -lt $Items.Count; $I++) {
            $Item = $Items[$I]
            $IsSelected = ($I -eq $CurrentIndex)
            $IsDisabled = [bool]$Item.Disabled

            # Build the line
            $Pointer = if ($IsSelected) { [char]0x25B8 } else { ' ' }  # ▸ or space

            $RoleStr = ''
            if ($Item.RoleTag) {
                $RoleStr = "[$($Item.RoleTag)] "
            }

            $Label = "$RoleStr$($Item.Label)"
            $PaddedLabel = $Label.PadRight($MaxLabelWidth)

            $Desc = if ($Item.Description) { $Item.Description } else { '' }

            # Clear line first
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow + $LinesRendered)
            Write-Host (' ' * ([System.Console]::WindowWidth - 1)) -NoNewline
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow + $LinesRendered)

            if ($IsDisabled) {
                Write-Host "  $Pointer " -NoNewline -ForegroundColor $DisabledColor
                Write-Host $PaddedLabel -NoNewline -ForegroundColor $DisabledColor
                Write-Host $Desc -ForegroundColor $DisabledColor
            }
            elseif ($IsSelected) {
                Write-Host "  $Pointer " -NoNewline -ForegroundColor $AccentColor
                if ($Item.RoleTag) {
                    Write-Host "[$($Item.RoleTag)] " -NoNewline -ForegroundColor $RoleTagColor
                    $InnerLabel = $Item.Label.PadRight($MaxLabelWidth - $RoleStr.Length)
                    Write-Host $InnerLabel -NoNewline -ForegroundColor $AccentColor
                } else {
                    Write-Host $PaddedLabel -NoNewline -ForegroundColor $AccentColor
                }
                Write-Host $Desc -ForegroundColor $AccentColor
            }
            else {
                Write-Host "  $Pointer " -NoNewline
                if ($Item.RoleTag) {
                    Write-Host "[$($Item.RoleTag)] " -NoNewline -ForegroundColor $RoleTagColor
                    $InnerLabel = $Item.Label.PadRight($MaxLabelWidth - $RoleStr.Length)
                    Write-Host $InnerLabel -NoNewline
                } else {
                    Write-Host $PaddedLabel -NoNewline
                }
                Write-Host $Desc
            }
            $LinesRendered++
        }

        # Show InfoText for the currently selected item (below the menu)
        $CurrentInfoLines = 0
        $InfoText = $Items[$CurrentIndex].InfoText
        if ($InfoText) {
            $InfoColor = Get-CLIColor -Role 'Info'
            $InfoLines = if ($InfoText -is [array]) { $InfoText } else { @($InfoText) }
            Write-Host ''
            $LinesRendered++
            foreach ($ILine in $InfoLines) {
                $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow + $LinesRendered)
                Write-Host (' ' * ([System.Console]::WindowWidth - 1)) -NoNewline
                $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow + $LinesRendered)
                Write-CLILine -Text "$([char]0x2139) $ILine" -Color $InfoColor
                $LinesRendered++
                $CurrentInfoLines++
            }
        }

        # Clear any leftover info lines from previous selection
        if ($PrevInfoLines -gt $CurrentInfoLines) {
            $ExtraLines = $PrevInfoLines - $CurrentInfoLines
            if (-not $InfoText) { $ExtraLines++ }  # account for the blank line
            for ($C = 0; $C -lt $ExtraLines + 1; $C++) {
                $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow + $LinesRendered + $C)
                Write-Host (' ' * ([System.Console]::WindowWidth - 1)) -NoNewline
            }
        }
        $PrevInfoLines = $CurrentInfoLines

        # Footer hints — place 1 line below rendered content
        $HintRow = $MenuStartRow + $LinesRendered + 1
        # Clear the separator line and hint row
        for ($G = $MenuStartRow + $LinesRendered; $G -le $HintRow; $G++) {
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $G)
            Write-Host (' ' * ([System.Console]::WindowWidth - 1)) -NoNewline
        }
        # Clear rows from previous taller render (e.g. InfoText removed)
        if ($PrevHintRow -gt $HintRow) {
            for ($G = $HintRow + 1; $G -le $PrevHintRow; $G++) {
                $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $G)
                Write-Host (' ' * ([System.Console]::WindowWidth - 1)) -NoNewline
            }
        }
        $PrevHintRow = $HintRow
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $HintRow)
        $HintParts = [System.Collections.Generic.List[string]]::new()
        [void]$HintParts.Add([char]0x2191 + [char]0x2193 + ' nawigacja')
        [void]$HintParts.Add('Enter wybierz')
        if ($ShowBack) {
            [void]$HintParts.Add('q/Esc wstecz')
        } else {
            [void]$HintParts.Add('q/Esc zakończ')
        }
        if ($HelpContent -and $HelpContent.Count -gt 0) {
            [void]$HintParts.Add('h pomoc')
        }
        Write-Host "  $($HintParts -join '  |  ')" -ForegroundColor (Get-CLIColor -Role 'Disabled')

        # Read input
        $Key = Read-ArrowKey

        switch ($Key.Key) {
            'UpArrow' {
                if ($SelectedPos -gt 0) { $SelectedPos-- }
            }
            'DownArrow' {
                if ($SelectedPos -lt ($SelectableIndices.Count - 1)) { $SelectedPos++ }
            }
            'Enter' {
                $ClearEnd = [Math]::Max($HintRow, $PrevHintRow)
                Clear-MenuArea -StartRow $MenuStartRow -LineCount ($ClearEnd - $MenuStartRow + 1)
                $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $MenuStartRow)
                Write-Host "  $([char]0x25B8) $($Items[$CurrentIndex].Label)" -ForegroundColor $AccentColor
                return $Items[$CurrentIndex].ID
            }
            'Escape' {
                $ClearEnd = [Math]::Max($HintRow, $PrevHintRow)
                Clear-MenuArea -StartRow $MenuStartRow -LineCount ($ClearEnd - $MenuStartRow + 1)
                return '__back__'
            }
            default {
                if ($Key.KeyChar -eq 'h' -or $Key.KeyChar -eq 'H') {
                    if ($HelpContent -and $HelpContent.Count -gt 0) {
                        Show-HelpOverlay -Title $HelpTitle -Content $HelpContent -MenuStartRow $MenuStartRow -MenuLineCount ($HintRow - $MenuStartRow + 1)
                    }
                    continue
                }
                if ($Key.KeyChar -eq 'q' -or $Key.KeyChar -eq 'Q') {
                    $ClearEnd = [Math]::Max($HintRow, $PrevHintRow)
                    Clear-MenuArea -StartRow $MenuStartRow -LineCount ($ClearEnd - $MenuStartRow + 1)
                    return '__back__'
                }
            }
        }
    }
}

# ── Show-ResultTable ─────────────────────────────────────────────────────────

function Show-ResultTable {
    # DEPRECATED: Use New-TableComponent + Invoke-EngineLifecycle instead.
    # Retained for plugin/migration compatibility. Will be removed in a future version.
    param(
        [Parameter(Mandatory)] [object[]]$Data,
        [Parameter(Mandatory)] [string[]]$Columns,
        [Parameter(Mandatory)] [string[]]$Headers,
        [int[]]$Widths,
        [int]$PageSize = 15,
        [string]$Title
    )

    if ($Data.Count -eq 0) {
        Write-CLILine -Text 'Brak danych.' -Color (Get-CLIColor -Role 'Disabled')
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
        return $null
    }

    # Default widths if not provided
    if (-not $Widths -or $Widths.Count -eq 0) {
        $Widths = @()
        foreach ($H in $Headers) {
            $Widths += 20
        }
    }

    # Pre-extend terminal buffer to prevent scroll during rendering
    $TitleLines = if ($Title) { 2 } else { 0 }
    $MaxTableHeight = $TitleLines + 2 + $PageSize + 3
    for ($Pre = 0; $Pre -lt $MaxTableHeight; $Pre++) {
        Write-Host ''
    }
    $TableStartRow = [Math]::Max(0, $Host.UI.RawUI.CursorPosition.Y - $MaxTableHeight)
    $PrevLinesRendered = 0

    # Use absolute row index across all data; derive page from it
    $SelectedAbs = 0

    while ($true) {
        $CurrentPage = [Math]::Floor($SelectedAbs / $PageSize)
        $TotalPages  = [Math]::Ceiling($Data.Count / $PageSize)
        $PageStart   = $CurrentPage * $PageSize
        $PageEnd     = [Math]::Min($PageStart + $PageSize, $Data.Count) - 1
        $PageData    = $Data[$PageStart..$PageEnd]
        $SelectedRow = $SelectedAbs - $PageStart

        $LinesRendered = 0
        $Blank = ' ' * ([System.Console]::WindowWidth - 1)

        if ($Title) {
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
            Write-Host $Blank -NoNewline
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
            Write-CLILine -Text $Title -Color (Get-CLIColor -Role 'Accent')
            $LinesRendered++
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
            Write-Host $Blank -NoNewline
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
            Write-Host ''
            $LinesRendered++
        }

        # Header row
        $HeaderSB = [System.Text.StringBuilder]::new(120)
        [void]$HeaderSB.Append('  ')
        for ($C = 0; $C -lt $Headers.Count; $C++) {
            $W = if ($C -lt $Widths.Count) { $Widths[$C] } else { 20 }
            [void]$HeaderSB.Append($Headers[$C].PadRight($W))
        }
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $Blank -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $HeaderSB.ToString() -ForegroundColor (Get-CLIColor -Role 'Accent')
        $LinesRendered++

        # Separator
        $SepSB = [System.Text.StringBuilder]::new(120)
        [void]$SepSB.Append('  ')
        for ($C = 0; $C -lt $Headers.Count; $C++) {
            $W = if ($C -lt $Widths.Count) { $Widths[$C] } else { 20 }
            [void]$SepSB.Append(([string][char]0x2500 * ($W - 1) + ' '))
        }
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $Blank -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $SepSB.ToString() -ForegroundColor (Get-CLIColor -Role 'Disabled')
        $LinesRendered++

        # Data rows
        for ($R = 0; $R -lt $PageData.Count; $R++) {
            $Row = $PageData[$R]
            $IsSelected = ($R -eq $SelectedRow)
            $RowSB = [System.Text.StringBuilder]::new(120)
            $Pointer = if ($IsSelected) { [char]0x25B8 } else { ' ' }
            [void]$RowSB.Append("$Pointer ")

            for ($C = 0; $C -lt $Columns.Count; $C++) {
                $PropName = $Columns[$C]
                $Val = ''
                if ($Row.PSObject.Properties[$PropName]) {
                    $RawVal = $Row.$PropName
                    if ($null -eq $RawVal) {
                        $Val = ''
                    }
                    elseif ($RawVal -is [System.Collections.IList] -or $RawVal -is [array]) {
                        $Val = [string]$RawVal.Count
                    }
                    else {
                        $Val = [string]$RawVal
                    }
                }
                $W = if ($C -lt $Widths.Count) { $Widths[$C] } else { 20 }
                if ($Val.Length -gt ($W - 1)) {
                    $Val = $Val.Substring(0, $W - 4) + '...'
                }
                [void]$RowSB.Append($Val.PadRight($W))
            }

            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
            Write-Host $Blank -NoNewline
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
            $RowColor = if ($IsSelected) { Get-CLIColor -Role 'Accent' } else { $null }
            if ($RowColor) {
                Write-Host $RowSB.ToString() -ForegroundColor $RowColor
            } else {
                Write-Host $RowSB.ToString()
            }
            $LinesRendered++
        }

        # Footer
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $Blank -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host ''
        $LinesRendered++

        $PageInfo = "  Strona $($CurrentPage + 1)/$TotalPages ($($Data.Count) wyników)  |  Wiersz $($SelectedAbs + 1)/$($Data.Count)"
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $Blank -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $PageInfo -ForegroundColor (Get-CLIColor -Role 'Disabled')
        $LinesRendered++

        $Hints = [System.Collections.Generic.List[string]]::new()
        [void]$Hints.Add([char]0x2191 + [char]0x2193 + ' nawigacja')
        if ($TotalPages -gt 1) { [void]$Hints.Add([char]0x2190 + [char]0x2192 + ' strony') }
        [void]$Hints.Add('Enter szczegóły')
        [void]$Hints.Add('Esc wstecz')
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host $Blank -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $LinesRendered)
        Write-Host "  $($Hints -join '  |  ')" -ForegroundColor (Get-CLIColor -Role 'Disabled')
        $LinesRendered++

        # Clear excess lines from previous render (e.g., last page had fewer rows)
        if ($PrevLinesRendered -gt $LinesRendered) {
            for ($E = $LinesRendered; $E -lt $PrevLinesRendered; $E++) {
                $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $TableStartRow + $E)
                Write-Host $Blank -NoNewline
            }
        }
        $PrevLinesRendered = $LinesRendered

        # Input
        $Key = Read-ArrowKey

        switch ($Key.Key) {
            'UpArrow' {
                if ($SelectedAbs -gt 0) { $SelectedAbs-- }
            }
            'DownArrow' {
                if ($SelectedAbs -lt ($Data.Count - 1)) { $SelectedAbs++ }
            }
            'LeftArrow' {
                if ($CurrentPage -gt 0) {
                    $SelectedAbs = ($CurrentPage - 1) * $PageSize
                }
            }
            'RightArrow' {
                if ($CurrentPage -lt ($TotalPages - 1)) {
                    $SelectedAbs = ($CurrentPage + 1) * $PageSize
                }
            }
            'Enter' {
                return $Data[$SelectedAbs]
            }
            'Escape' {
                return $null
            }
            default {
                if ($Key.KeyChar -eq 'q' -or $Key.KeyChar -eq 'Q') {
                    return $null
                }
            }
        }
    }
}

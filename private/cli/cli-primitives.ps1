<#
    .SYNOPSIS
    Core UI primitives for the Robot CLI - colors, key input, arrow menus,
    result tables, and visual helpers.

    .DESCRIPTION
    This file contains the lowest-level interactive building blocks consumed
    by the entire CLI stack. Dot-sourced on demand (not at module import).

    Helpers:
    - Resolve-CLITheme:   background-adaptive Dark/Light detection
    - Get-CLIColor:       semantic role → ConsoleColor (colorblind-safe)
    - Write-CLILine:      consistent indented Write-Host wrapper
    - Read-ArrowKey:      [Console]::ReadKey wrapper
    - Clear-MenuArea:     overwrite lines without full screen clear
    - Show-Banner:        ASCII "Nerthus" art + version from VERSION file
    - Show-Breadcrumb:    path display (Robot > Sesje > Nowa sesja)
    - Show-InfoBox:       pre-check description box
    - Show-ArrowMenu:     arrow-key selectable list with role tags + InfoText
    - Show-ResultTable:   paginated data display with cursor navigation

    Module-level data:
    - $script:CLIColorScheme: dark/light adaptive color mappings
    - $script:BannerArt:      ASCII art string

    Design:
    - Colors never rely on Red/Green (colorblind-safe). Every semantic meaning
      is reinforced with symbols (checkmark, cross, warning).
    - Per-line SetCursorPosition redraw to avoid flicker (no full Clear).
#>

# ── Color Scheme ─────────────────────────────────────────────────────────────

# Background-adaptive, colorblind-friendly palette.
# Red and Green are NEVER used - the most common colorblindness axis.
$script:CLIColorScheme = @{
    Dark = @{
        Accent   = 'Cyan'
        Success  = 'Cyan'
        Warning  = 'Yellow'
        Error    = 'Magenta'
        Disabled = 'DarkGray'
        Info     = 'Blue'
        RoleTag  = 'DarkCyan'
    }
    Light = @{
        Accent   = 'DarkCyan'
        Success  = 'DarkCyan'
        Warning  = 'DarkYellow'
        Error    = 'DarkMagenta'
        Disabled = 'Gray'
        Info     = 'DarkBlue'
        RoleTag  = 'DarkBlue'
    }
}

$script:BannerArt = @'
    _   __          __  __
   / | / /__  _____/ /_/ /_  __  _______
  /  |/ / _ \/ ___/ __/ __ \/ / / / ___/
 / /|  /  __/ /  / /_/ / / / /_/ (__  )
/_/ |_/\___/_/   \__/_/ /_/\__,_/____/
'@

# ── Theme Detection ──────────────────────────────────────────────────────────

function Resolve-CLITheme {
    try {
        $BG = [System.Console]::BackgroundColor
        switch ($BG) {
            'Black'        { return 'Dark' }
            'DarkBlue'     { return 'Dark' }
            'DarkGray'     { return 'Dark' }
            'DarkCyan'     { return 'Dark' }
            'DarkRed'      { return 'Dark' }
            'DarkMagenta'  { return 'Dark' }
            'DarkGreen'    { return 'Dark' }
            'White'        { return 'Light' }
            'Gray'         { return 'Light' }
            'Yellow'       { return 'Light' }
            default        { return 'Dark' }
        }
    }
    catch {
        return 'Dark'
    }
}

# ── Get-CLIColor ─────────────────────────────────────────────────────────────

function Get-CLIColor {
    param([Parameter(Mandatory)] [string]$Role)
    $Theme = if ($NavState -and $NavState.Theme) { $NavState.Theme } else { 'Dark' }
    $Palette = $script:CLIColorScheme[$Theme]
    if ($Palette.ContainsKey($Role)) {
        return $Palette[$Role]
    }
    return 'White'
}

# ── Write-CLILine ────────────────────────────────────────────────────────────

function Write-CLILine {
    param(
        [string]$Text = '',
        [string]$Color,
        [switch]$NoNewline
    )
    $Params = @{ Object = "  $Text" }
    if ($Color) { $Params['ForegroundColor'] = $Color }
    if ($NoNewline) { $Params['NoNewline'] = $true }
    Write-Host @Params
}

# ── Read-ArrowKey ────────────────────────────────────────────────────────────

function Read-ArrowKey {
    $KeyInfo = [System.Console]::ReadKey($true)
    return $KeyInfo
}

# ── Clear-MenuArea ───────────────────────────────────────────────────────────

# Overwrites N lines starting at the given row with spaces, without clearing the screen
function Clear-MenuArea {
    param(
        [int]$StartRow,
        [int]$LineCount
    )
    $Width = [System.Console]::WindowWidth
    $Blank = ' ' * $Width
    for ($I = 0; $I -lt $LineCount; $I++) {
        [System.Console]::SetCursorPosition(0, $StartRow + $I)
        [System.Console]::Write($Blank)
    }
    [System.Console]::SetCursorPosition(0, $StartRow)
}

# ── Show-Banner ──────────────────────────────────────────────────────────────

function Show-Banner {
    $AccentColor = Get-CLIColor -Role 'Accent'

    # Read version from VERSION file
    $VersionStr = ''
    $VersionPath = [System.IO.Path]::Combine($script:ModuleRoot, 'VERSION')
    if ([System.IO.File]::Exists($VersionPath)) {
        $VersionStr = "v$([System.IO.File]::ReadAllText($VersionPath).Trim())"
    }

    Write-Host ''
    foreach ($Line in $script:BannerArt.Split("`n")) {
        Write-Host $Line -ForegroundColor $AccentColor
    }

    # Version aligned to the right of the banner
    $VersionPadded = $VersionStr.PadLeft(38)
    Write-Host $VersionPadded -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-Host ''
}

# ── Show-Breadcrumb ──────────────────────────────────────────────────────────

function Show-Breadcrumb {
    param([object]$State)

    $Parts = [System.Collections.Generic.List[string]]::new()
    # Stack to list (reverse order since Stack is LIFO)
    $StackArray = $State.BreadcrumbStack.ToArray()
    [System.Array]::Reverse($StackArray)
    foreach ($Part in $StackArray) {
        [void]$Parts.Add($Part)
    }

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    $SB = [System.Text.StringBuilder]::new()
    for ($I = 0; $I -lt $Parts.Count; $I++) {
        if ($I -gt 0) { [void]$SB.Append(' > ') }
        [void]$SB.Append($Parts[$I])
    }

    Write-Host "  $($SB.ToString())" -ForegroundColor $AccentColor
    Write-Host ''
}

# ── Show-InfoBox ─────────────────────────────────────────────────────────────

function Show-InfoBox {
    param([string[]]$Checks)

    $InfoColor = Get-CLIColor -Role 'Info'

    Write-Host ''
    Write-CLILine -Text "Ta operacja sprawdzi:" -Color $InfoColor
    foreach ($Check in $Checks) {
        Write-CLILine -Text "  - $Check" -Color $InfoColor
    }
    Write-Host ''
}

# ── Show-ArrowMenu ───────────────────────────────────────────────────────────

function Show-ArrowMenu {
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [string]$Title,
        [switch]$ShowBack
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

    # Calculate max label width for alignment
    $MaxLabelWidth = 0
    foreach ($Item in $Items) {
        $LabelLen = $Item.Label.Length
        if ($Item.RoleTag) { $LabelLen += $Item.RoleTag.Length + 1 }
        if ($LabelLen -gt $MaxLabelWidth) { $MaxLabelWidth = $LabelLen }
    }
    $MaxLabelWidth = [Math]::Min($MaxLabelWidth + 4, [System.Console]::WindowWidth - 20)

    # Initial render
    $MenuStartRow = [System.Console]::CursorTop

    while ($true) {
        $CurrentIndex = $SelectableIndices[$SelectedPos]

        # Move to menu start position
        [System.Console]::SetCursorPosition(0, $MenuStartRow)

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
            $Width = [System.Console]::WindowWidth
            [System.Console]::Write((' ' * $Width))
            [System.Console]::SetCursorPosition(0, $MenuStartRow + $LinesRendered)

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
                $ClearStr = ' ' * [System.Console]::WindowWidth
                [System.Console]::Write($ClearStr)
                [System.Console]::SetCursorPosition(0, $MenuStartRow + $LinesRendered)
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
                $ClearStr = ' ' * [System.Console]::WindowWidth
                [System.Console]::SetCursorPosition(0, $MenuStartRow + $LinesRendered + $C)
                [System.Console]::Write($ClearStr)
            }
        }
        $PrevInfoLines = $CurrentInfoLines

        # Footer hints
        $HintRow = $MenuStartRow + $Items.Count + $CurrentInfoLines + 2
        [System.Console]::SetCursorPosition(0, $HintRow)
        $HintClear = ' ' * [System.Console]::WindowWidth
        [System.Console]::Write($HintClear)
        [System.Console]::SetCursorPosition(0, $HintRow)
        $HintParts = [System.Collections.Generic.List[string]]::new()
        [void]$HintParts.Add([char]0x2191 + [char]0x2193 + ' nawigacja')
        [void]$HintParts.Add('Enter wybierz')
        if ($ShowBack) { [void]$HintParts.Add('Esc wstecz') }
        [void]$HintParts.Add('q zakończ')
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
                # Clear the hint line and move cursor below menu
                Write-Host ''
                return $Items[$CurrentIndex].ID
            }
            'Escape' {
                Write-Host ''
                return '__back__'
            }
            default {
                # Check for 'q' key
                if ($Key.KeyChar -eq 'q' -or $Key.KeyChar -eq 'Q') {
                    Write-Host ''
                    return '__quit__'
                }
            }
        }
    }
}

# ── Show-ResultTable ─────────────────────────────────────────────────────────

function Show-ResultTable {
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

    # Use absolute row index across all data; derive page from it
    $SelectedAbs = 0

    while ($true) {
        $CurrentPage = [Math]::Floor($SelectedAbs / $PageSize)
        $TotalPages  = [Math]::Ceiling($Data.Count / $PageSize)
        $PageStart   = $CurrentPage * $PageSize
        $PageEnd     = [Math]::Min($PageStart + $PageSize, $Data.Count) - 1
        $PageData    = $Data[$PageStart..$PageEnd]
        $SelectedRow = $SelectedAbs - $PageStart

        [System.Console]::Clear()

        if ($Title) {
            Write-CLILine -Text $Title -Color (Get-CLIColor -Role 'Accent')
            Write-Host ''
        }

        # Header row
        $HeaderSB = [System.Text.StringBuilder]::new(120)
        [void]$HeaderSB.Append('  ')
        for ($C = 0; $C -lt $Headers.Count; $C++) {
            $W = if ($C -lt $Widths.Count) { $Widths[$C] } else { 20 }
            [void]$HeaderSB.Append($Headers[$C].PadRight($W))
        }
        Write-Host $HeaderSB.ToString() -ForegroundColor (Get-CLIColor -Role 'Accent')

        # Separator
        $SepSB = [System.Text.StringBuilder]::new(120)
        [void]$SepSB.Append('  ')
        for ($C = 0; $C -lt $Headers.Count; $C++) {
            $W = if ($C -lt $Widths.Count) { $Widths[$C] } else { 20 }
            [void]$SepSB.Append(([string][char]0x2500 * ($W - 1) + ' '))
        }
        Write-Host $SepSB.ToString() -ForegroundColor (Get-CLIColor -Role 'Disabled')

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
                    # Handle collections: show count or join short values
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

            $RowColor = if ($IsSelected) { Get-CLIColor -Role 'Accent' } else { $null }
            if ($RowColor) {
                Write-Host $RowSB.ToString() -ForegroundColor $RowColor
            } else {
                Write-Host $RowSB.ToString()
            }
        }

        # Footer
        Write-Host ''
        $PageInfo = "  Strona $($CurrentPage + 1)/$TotalPages ($($Data.Count) wyników)  |  Wiersz $($SelectedAbs + 1)/$($Data.Count)"
        Write-Host $PageInfo -ForegroundColor (Get-CLIColor -Role 'Disabled')
        $Hints = [System.Collections.Generic.List[string]]::new()
        [void]$Hints.Add([char]0x2191 + [char]0x2193 + ' nawigacja')
        if ($TotalPages -gt 1) { [void]$Hints.Add([char]0x2190 + [char]0x2192 + ' strony') }
        [void]$Hints.Add('Enter szczegóły')
        [void]$Hints.Add('Esc wstecz')
        Write-Host "  $($Hints -join '  |  ')" -ForegroundColor (Get-CLIColor -Role 'Disabled')

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

<#
    .SYNOPSIS
    Screen and region management for the Robot CLI TUI engine.

    .DESCRIPTION
    Manages a four-region layout with fixed TopBar, dynamic Content region,
    contextual Filter bar, and persistent StatusBar. All rendering is
    region-aware — components only write within their allocated row ranges,
    preventing cross-region bleed when content is taller than the viewport.

    Region boundaries are recalculated on terminal resize via Build-Regions.
    The Content region absorbs all height changes (TopBar, Filter, StatusBar
    are fixed at 1 row each), so the menu/table/wizard visible area scales
    automatically. A minimum terminal size of 60x15 is enforced to guarantee
    that at least a few content rows are visible.

    The 5-tier visual hierarchy (Get-TierStyle) provides consistent emphasis
    across all components without per-component color decisions. ANSI escape
    support is detected at load time via PS version check; PS 5.1 falls back
    to Write-Host color-only rendering with accent promotion for bold.

    Helpers:
    - Initialize-Screen:    check min dimensions, calculate regions, clear, hide cursor
    - Build-Regions:        calculates region boundaries from current terminal dimensions
    - Get-Region:           lookup region object by name
    - Get-RegionHeight:     returns EndRow - StartRow for a named region
    - Resize-Screen:        recalculate all region boundaries on terminal size change
    - Test-MinimumSize:     returns $true if terminal meets minimum 60x15
    - Test-TerminalResized: returns $true if terminal size differs from cached dimensions
    - Restore-Cursor:       re-shows cursor on engine teardown
    - Get-ANSIBold:         returns ANSI bold escape (PS 7+) or empty string
    - Get-ANSIDim:          returns ANSI dim escape (PS 7+) or empty string
    - Get-ANSIReset:        returns ANSI reset escape (PS 7+) or empty string
    - Get-TierStyle:        returns Color/Bold/Dim for a visual hierarchy tier (1-5)
    - New-TierSegment:      creates a segment styled for a given tier

    Module-level data:
    - $script:SupportsANSI:  $true on PS 7+ (enables bold/dim via escape sequences)
    - $script:MinWidth:      60 columns minimum
    - $script:MinHeight:     15 rows minimum
    - $script:Regions:       hashtable of region name -> region object
    - $script:ScreenWidth:   current terminal width (updated on resize)
    - $script:ScreenHeight:  current terminal height (updated on resize)

    Layout:
        Row 0              -> TopBar (breadcrumb + health badges)
        Row 1..(H-3)       -> Content (menus, tables, wizards, cards, overlays)
        Row (H-2)          -> Filter (contextual, hidden when inactive)
        Row (H-1)          -> StatusBar (persistent key hints)
#>

# ── Module-level data ────────────────────────────────────────────────────────

$script:SupportsANSI = $PSVersionTable.PSVersion.Major -ge 7
$script:MinWidth     = 60
$script:MinHeight    = 15
$script:Regions      = @{}
$script:ScreenWidth  = 0
$script:ScreenHeight = 0

# ── ANSI helpers ─────────────────────────────────────────────────────────────

function Get-ANSIBold {
    if ($script:SupportsANSI) { return "`e[1m" }
    return ''
}

function Get-ANSIDim {
    if ($script:SupportsANSI) { return "`e[2m" }
    return ''
}

function Get-ANSIReset {
    if ($script:SupportsANSI) { return "`e[0m" }
    return ''
}

# ── Test-MinimumSize ─────────────────────────────────────────────────────────

function Test-MinimumSize {
    $W = [System.Console]::WindowWidth
    $H = [System.Console]::WindowHeight
    return ($W -ge $script:MinWidth -and $H -ge $script:MinHeight)
}

# ── Build-Regions ────────────────────────────────────────────────────────────

function Build-Regions {
    $W = [System.Console]::WindowWidth
    $H = [System.Console]::WindowHeight

    $script:ScreenWidth  = $W
    $script:ScreenHeight = $H

    $script:Regions = @{
        TopBar = [PSCustomObject]@{
            Name     = 'TopBar'
            StartRow = 0
            EndRow   = 1      # exclusive — 1 row
            Width    = $W
        }
        Content = [PSCustomObject]@{
            Name     = 'Content'
            StartRow = 1
            EndRow   = $H - 2  # exclusive — dynamic height
            Width    = $W
        }
        Filter = [PSCustomObject]@{
            Name     = 'Filter'
            StartRow = $H - 2
            EndRow   = $H - 1  # exclusive — 1 row
            Width    = $W
        }
        StatusBar = [PSCustomObject]@{
            Name     = 'StatusBar'
            StartRow = $H - 1
            EndRow   = $H      # exclusive — 1 row
            Width    = $W
        }
    }
}

# ── Get-Region ───────────────────────────────────────────────────────────────

function Get-Region {
    param([Parameter(Mandatory)] [string]$Name)
    if ($script:Regions.ContainsKey($Name)) {
        return $script:Regions[$Name]
    }
    return $null
}

# ── Get-RegionHeight ─────────────────────────────────────────────────────────

function Get-RegionHeight {
    param([Parameter(Mandatory)] [string]$Name)
    $R = Get-Region -Name $Name
    if ($null -eq $R) { return 0 }
    return ($R.EndRow - $R.StartRow)
}

# ── Initialize-Screen ────────────────────────────────────────────────────────

function Initialize-Screen {
    param([object]$State)

    if (-not (Test-MinimumSize)) {
        [System.Console]::Clear()
        $W = [System.Console]::WindowWidth
        $H = [System.Console]::WindowHeight
        Write-Host ''
        Write-Host "  Terminal za maly: ${W}x${H}" -ForegroundColor (Get-CLIColor -Role 'Warning')
        Write-Host "  Wymagane minimum: $($script:MinWidth)x$($script:MinHeight)" -ForegroundColor (Get-CLIColor -Role 'Disabled')
        Write-Host ''
        Write-Host '  Powieksz okno terminala i sprobuj ponownie.' -ForegroundColor (Get-CLIColor -Role 'Disabled')
        Write-Host ''
        Write-Host '  Nacisnij dowolny klawisz...' -ForegroundColor (Get-CLIColor -Role 'Disabled')
        return $false
    }

    Build-Regions

    # Hide cursor to prevent flicker during ANSI-positioned writes;
    # restored by Restore-Cursor on engine teardown
    try { [System.Console]::CursorVisible = $false } catch {}

    [System.Console]::Clear()

    return $true
}

# ── Resize-Screen ────────────────────────────────────────────────────────────

function Resize-Screen {
    param([object]$State)

    $OldWidth  = $script:ScreenWidth
    $OldHeight = $script:ScreenHeight
    $NewWidth  = [System.Console]::WindowWidth
    $NewHeight = [System.Console]::WindowHeight

    if ($NewWidth -eq $OldWidth -and $NewHeight -eq $OldHeight) {
        return $false
    }

    Build-Regions

    if (-not (Test-MinimumSize)) {
        return $false
    }

    # Full clear on resize — row positions shift when height changes,
    # so diff-based rendering can't recover; one-time cost followed by
    # full re-render via Render-FullBuffer
    [System.Console]::Clear()

    return $true
}

# ── Test-TerminalResized ─────────────────────────────────────────────────────

function Test-TerminalResized {
    $W = [System.Console]::WindowWidth
    $H = [System.Console]::WindowHeight
    return ($W -ne $script:ScreenWidth -or $H -ne $script:ScreenHeight)
}

# ── Restore-Cursor ───────────────────────────────────────────────────────────

function Restore-Cursor {
    try { [System.Console]::CursorVisible = $true } catch {}
}

# ── Tier Style Helpers ──────────────────────────────────────────────────────

# 5-tier visual hierarchy ensures consistent emphasis across all components.
# Higher tiers draw attention; lower tiers recede into the background.
# Tier 1 (Active Focus):  Accent color, Bold — selected item with ▸ pointer
# Tier 2 (Actionable):    Info color (White/DarkBlue) — clickable items
# Tier 3 (Contextual):    Disabled color (DarkGray/Gray) — hints, labels
# Tier 4 (Structural):    Disabled color + Dim — separators ─, box borders
# Tier 5 (Chrome):        Disabled color — persistent status/filter bars
function Get-TierStyle {
    param([Parameter(Mandatory)] [int]$Tier)
    switch ($Tier) {
        1 { return @{ Color = (Get-CLIColor -Role 'Accent');   Bold = $true;  Dim = $false } }
        2 { return @{ Color = (Get-CLIColor -Role 'Info');     Bold = $false; Dim = $false } }
        3 { return @{ Color = (Get-CLIColor -Role 'Disabled'); Bold = $false; Dim = $false } }
        4 { return @{ Color = (Get-CLIColor -Role 'Disabled'); Bold = $false; Dim = $true  } }
        5 { return @{ Color = (Get-CLIColor -Role 'Disabled'); Bold = $false; Dim = $false } }
        default { return @{ Color = $null; Bold = $false; Dim = $false } }
    }
}

function New-TierSegment {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [int]$Tier
    )
    $Style = Get-TierStyle -Tier $Tier
    return (New-Segment -Text $Text -Color $Style.Color -Bold:$Style.Bold -Dim:$Style.Dim)
}

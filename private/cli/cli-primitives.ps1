<#
    .SYNOPSIS
    Core UI primitives for the Robot CLI - colors, key input, and visual helpers.

    .DESCRIPTION
    This file contains the lowest-level interactive building blocks consumed
    by the entire CLI stack. Dot-sourced on demand (not at module import).

    The interactive menu components (Show-ArrowMenu, Show-ResultTable) live in
    cli-menus.ps1, which is chain-loaded via dot-source at the end of this file.

    Active helpers (NOT deprecated):
    - Resolve-CLITheme:   background-adaptive Dark/Light detection
    - Get-CLIColor:       semantic role → ConsoleColor (colorblind-safe)
    - Write-CLILine:      consistent indented Write-Host wrapper

    DEPRECATED helpers (use engine equivalents instead):
    - Read-ArrowKey:      → engine input handling (Start-InputLoop)
    - Clear-MenuArea:     → engine buffer (Write-BufferRegion)
    - Show-Banner:        → engine TopBar chrome
    - Show-Breadcrumb:    → engine TopBar chrome
    - Show-InfoBox:       → engine overlay components

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
        Success  = 'Blue'
        Warning  = 'Yellow'
        Error    = 'Magenta'
        Disabled = 'DarkGray'
        Info     = 'White'
        RoleTag  = 'DarkYellow'
    }
    Light = @{
        Accent   = 'DarkCyan'
        Success  = 'DarkBlue'
        Warning  = 'DarkYellow'
        Error    = 'DarkMagenta'
        Disabled = 'Gray'
        Info     = 'DarkBlue'
        RoleTag  = 'DarkCyan'
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
# DEPRECATED: Use engine input handling (Start-InputLoop) instead.
# Retained for plugin/migration compatibility. Will be removed in a future version.

function Read-ArrowKey {
    $KeyInfo = [System.Console]::ReadKey($true)
    return $KeyInfo
}

# ── Clear-MenuArea ───────────────────────────────────────────────────────────
# DEPRECATED: Use engine buffer (Write-BufferRegion) instead.
# Retained for plugin/migration compatibility. Will be removed in a future version.

# Overwrites N lines starting at the given row with spaces, without clearing the screen
function Clear-MenuArea {
    param(
        [int]$StartRow,
        [int]$LineCount
    )
    $Blank = ' ' * ([System.Console]::WindowWidth - 1)
    for ($I = 0; $I -lt $LineCount; $I++) {
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $StartRow + $I)
        Write-Host $Blank -NoNewline
    }
    $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $StartRow)
}

# ── Show-Banner ──────────────────────────────────────────────────────────────
# DEPRECATED: Banner is now rendered by engine TopBar chrome.
# Retained for plugin/migration compatibility. Will be removed in a future version.

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
# DEPRECATED: Breadcrumb is now rendered by engine TopBar chrome.
# Retained for plugin/migration compatibility. Will be removed in a future version.

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

    # Health badges (right-aligned after breadcrumb)
    $BadgeStr = ''
    if ($State.PSObject.Properties['HealthCache'] -and $State.HealthCache) {
        $HC = $State.HealthCache
        $BadgeParts = [System.Collections.Generic.List[string]]::new()

        # PU badge
        if ($HC.PU) {
            $PUWarnCount = @($HC.PU | Where-Object { $_.Status -ne 'OK' }).Count
            if ($PUWarnCount -eq 0) { [void]$BadgeParts.Add("PU:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("PU:$([char]0x26A0)$PUWarnCount") }
        }

        # Currency badge
        if ($HC.Currency) {
            $CWarnCount = if ($HC.Currency.WarningCount) { $HC.Currency.WarningCount } else { 0 }
            if ($CWarnCount -eq 0) { [void]$BadgeParts.Add("Waluta:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("Waluta:$([char]0x26A0)$CWarnCount") }
        }

        # Integrity badge
        if ($HC.Integrity) {
            $IWarnCount = @($HC.Integrity | Where-Object { -not $_.IsValid }).Count
            if ($IWarnCount -eq 0) { [void]$BadgeParts.Add("Sesje:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("Sesje:$([char]0x26A0)$IWarnCount") }
        }

        # Graph badge
        if ($HC.Graph) {
            $GWarnCount = if ($HC.Graph.WarningCount) { $HC.Graph.WarningCount } else { 0 }
            if ($GWarnCount -eq 0) { [void]$BadgeParts.Add("Graf:$([char]0x2713)") }
            else { [void]$BadgeParts.Add("Graf:$([char]0x26A0)$GWarnCount") }
        }

        if ($BadgeParts.Count -gt 0) {
            $BadgeStr = "    [$($BadgeParts -join '  ')]"
        }
    }

    Write-Host "  $($SB.ToString())$BadgeStr" -ForegroundColor $AccentColor
    Write-Host ''
}

# ── Show-InfoBox ─────────────────────────────────────────────────────────────
# DEPRECATED: Use engine overlay components instead.
# Retained for core/plugin compatibility. Will be removed in a future version.

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

# ── Chain-load interactive menu components ───────────────────────────────────

. "$PSScriptRoot/cli-menus.ps1"

# ── Chain-load TUI engine files in dependency order ─────────────────────────

$EngineDir = "$PSScriptRoot/engine"
if ([System.IO.Directory]::Exists($EngineDir)) {
    . "$EngineDir/cli-engine.ps1"
    . "$EngineDir/cli-buffer.ps1"
    . "$EngineDir/cli-input.ps1"
    . "$EngineDir/cli-chrome.ps1"
    . "$EngineDir/cli-menulist.ps1"
    . "$EngineDir/cli-table.ps1"
    . "$EngineDir/cli-detail.ps1"
    . "$EngineDir/cli-overlays.ps1"
    . "$EngineDir/cli-wizard-step.ps1"
}

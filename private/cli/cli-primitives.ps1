<#
    .SYNOPSIS
    Core UI primitives for the Robot CLI - colors, key input, and visual helpers.

    .DESCRIPTION
    This file contains the lowest-level interactive building blocks consumed
    by the entire CLI stack. Dot-sourced on demand (not at module import).

    The interactive menu components (Show-ArrowMenu, Show-ResultTable) live in
    cli-menus.ps1, which is chain-loaded via dot-source at the end of this file.

    Active helpers (NOT deprecated):
    - Resolve-CLITheme:     background-adaptive Dark/Light detection
    - Get-CLIColor:         semantic role → ConsoleColor (colorblind-safe)
    - Write-CLILine:        consistent indented Write-Host wrapper
    - New-ProgressState:    create Docker-style progress group (title + N steps)
    - Start-ProgressStep:   begin a step (renders [X/N] ⠿ Label...)
    - Update-ProgressStep:  update current step in-place (spinner + detail)
    - Complete-ProgressStep: finish step with ✓/✗ + elapsed time
    - Complete-ProgressGroup: finalize group with total elapsed on title line

    DEPRECATED helpers (use engine equivalents instead):
    - Read-ArrowKey:      → engine input handling (Start-InputLoop)
    - Clear-MenuArea:     → engine buffer (Write-BufferRegion)
    - Show-Banner:        → engine TopBar chrome
    - Show-Breadcrumb:    → engine TopBar chrome
    - Show-InfoBox:       → engine overlay components

    Module-level data:
    - $script:CLIColorScheme: dark/light adaptive color mappings
    - $script:BannerArt:      ASCII art string
    - $script:SpinnerFrames:  braille animation frames (8 chars)
    - $script:SpinnerStatic:  static braille indicator for blocking calls

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

# ── Progress Reporting (Docker-style) ────────────────────────────────────────

# Braille spinner frames for animated progress (cycled by Update-ProgressStep)
$script:SpinnerFrames = @(
    [char]0x280B, # ⠋
    [char]0x2819, # ⠙
    [char]0x2839, # ⠹
    [char]0x2838, # ⠸
    [char]0x283C, # ⠼
    [char]0x2834, # ⠴
    [char]0x2826, # ⠦
    [char]0x2827  # ⠧
)

# Static indicator shown during blocking calls (no callback to animate)
$script:SpinnerStatic = [char]0x283F # ⠿

function New-ProgressState {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [int]$TotalSteps
    )

    $StartRow = [System.Console]::CursorTop
    $GS = [System.Diagnostics.Stopwatch]::new()
    $GS.Start()

    # Render the title line (no counter, no symbol)
    $Clr = Get-CLIColor -Role 'Disabled'
    Write-Host "  $Title" -ForegroundColor $Clr

    return @{
        Title       = $Title
        Steps       = [System.Collections.Generic.List[hashtable]]::new()
        TotalSteps  = $TotalSteps
        CurrentStep = 0
        StartRow    = $StartRow
        GroupStart  = $GS
        StepWatch   = $null
        SpinnerIdx  = 0
        Failed      = $false
    }
}

function Start-ProgressStep {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [string]$Label
    )

    $State.CurrentStep++
    $SW = [System.Diagnostics.Stopwatch]::new()
    $SW.Start()
    $State.StepWatch = $SW
    $State.SpinnerIdx = 0

    $Step = @{
        Label   = $Label
        Status  = 'Running'
        Detail  = ''
        Elapsed = 0.0
    }
    [void]$State.Steps.Add($Step)

    # Render: [X/N] ⠿ Label...
    $Row = $State.StartRow + $State.CurrentStep
    $Width = [System.Console]::WindowWidth
    $Clr = Get-CLIColor -Role 'Disabled'
    $AccClr = Get-CLIColor -Role 'Accent'
    $Counter = "[{0}/{1}]" -f $State.CurrentStep, $State.TotalSteps

    [System.Console]::SetCursorPosition(0, $Row)
    Write-Host "  $Counter " -NoNewline -ForegroundColor $Clr
    Write-Host "$($script:SpinnerStatic) " -NoNewline -ForegroundColor $AccClr
    $Tail = "$Label..."
    $Pad = $Width - 2 - $Counter.Length - 1 - 2 - $Tail.Length
    if ($Pad -lt 0) { $Pad = 0 }
    Write-Host "$Tail$(' ' * $Pad)" -ForegroundColor $Clr
}

function Update-ProgressStep {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [string]$Detail
    )

    if ($State.Steps.Count -eq 0) { return }
    $Step = $State.Steps[$State.Steps.Count - 1]
    if ($Detail) { $Step.Detail = $Detail }

    # Advance spinner
    $State.SpinnerIdx = ($State.SpinnerIdx + 1) % $script:SpinnerFrames.Count
    $Spinner = $script:SpinnerFrames[$State.SpinnerIdx]

    # Re-render current line in-place
    $Row = $State.StartRow + $State.CurrentStep
    $Width = [System.Console]::WindowWidth
    $Clr = Get-CLIColor -Role 'Disabled'
    $AccClr = Get-CLIColor -Role 'Accent'
    $Counter = "[{0}/{1}]" -f $State.CurrentStep, $State.TotalSteps

    $LeftText = "$($Step.Label)..."
    $RightText = if ($Step.Detail) { "  $($Step.Detail)" } else { '' }
    # Prefix: "  [X/N] S " = 2 + counter + 1 + 2 = varies
    $PrefixLen = 2 + $Counter.Length + 1 + 2
    $Pad = $Width - $PrefixLen - $LeftText.Length - $RightText.Length
    if ($Pad -lt 0) { $Pad = 0 }

    [System.Console]::SetCursorPosition(0, $Row)
    Write-Host "  $Counter " -NoNewline -ForegroundColor $Clr
    Write-Host "$Spinner " -NoNewline -ForegroundColor $AccClr
    Write-Host "$LeftText$(' ' * $Pad)$RightText" -NoNewline -ForegroundColor $Clr
    # Clear any leftover chars from previous longer render
    $Written = $PrefixLen + $LeftText.Length + $Pad + $RightText.Length
    $Extra = $Width - $Written
    if ($Extra -gt 0) { [System.Console]::Write(' ' * $Extra) }
}

function Complete-ProgressStep {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [string]$Detail,
        [switch]$Failed
    )

    if ($State.Steps.Count -eq 0) { return }
    $Step = $State.Steps[$State.Steps.Count - 1]

    $State.StepWatch.Stop()
    $Step.Elapsed = $State.StepWatch.Elapsed.TotalSeconds
    $Step.Status = if ($Failed) { 'Error' } else { 'Done' }
    if ($Detail) { $Step.Detail = $Detail }
    if ($Failed) { $State.Failed = $true }

    $Symbol = if ($Failed) { [char]0x2717 } else { [char]0x2713 }
    $SymClr = if ($Failed) { Get-CLIColor -Role 'Error' } else { Get-CLIColor -Role 'Success' }

    $ElapsedStr = '{0:F1}s' -f $Step.Elapsed

    $Row = $State.StartRow + $State.CurrentStep
    $Width = [System.Console]::WindowWidth
    $Clr = Get-CLIColor -Role 'Disabled'
    $Counter = "[{0}/{1}]" -f $State.CurrentStep, $State.TotalSteps

    $LabelText = $Step.Label
    $RightText = ''
    if ($Step.Detail) { $RightText += "  $($Step.Detail)" }
    $RightText += "   $ElapsedStr"
    $PrefixLen = 2 + $Counter.Length + 1 + 2
    $Pad = $Width - $PrefixLen - $LabelText.Length - $RightText.Length
    if ($Pad -lt 0) { $Pad = 0 }

    [System.Console]::SetCursorPosition(0, $Row)
    Write-Host "  $Counter " -NoNewline -ForegroundColor $Clr
    Write-Host "$Symbol " -NoNewline -ForegroundColor $SymClr
    Write-Host "$LabelText$(' ' * $Pad)$RightText" -NoNewline -ForegroundColor $Clr
    # Clear remainder
    $Written = $PrefixLen + $LabelText.Length + $Pad + $RightText.Length
    $Extra = $Width - $Written
    if ($Extra -gt 0) { [System.Console]::Write(' ' * $Extra) }
    Write-Host ''
}

function Complete-ProgressGroup {
    param(
        [Parameter(Mandatory)] [hashtable]$State
    )

    $State.GroupStart.Stop()
    $TotalElapsed = '{0:F1}s' -f $State.GroupStart.Elapsed.TotalSeconds

    # Update the title line with total elapsed (right-aligned)
    $Row = $State.StartRow
    $Width = [System.Console]::WindowWidth
    $Clr = Get-CLIColor -Role 'Disabled'

    $LeftPart = "  $($State.Title)"
    $Pad = $Width - $LeftPart.Length - $TotalElapsed.Length - 3
    if ($Pad -lt 0) { $Pad = 0 }

    [System.Console]::SetCursorPosition(0, $Row)
    Write-Host "$LeftPart$(' ' * $Pad)   $TotalElapsed" -ForegroundColor $Clr

    # Move cursor below the last step + blank line
    $FinalRow = $State.StartRow + $State.TotalSteps + 1
    [System.Console]::SetCursorPosition(0, $FinalRow)
    Write-Host ''
}

# ── Initialize-WorkflowScreen ────────────────────────────────────────────────
# Common workflow screen setup: clear, title, separator, empty line.
# Returns hashtable of all standard CLI colors for caller use.

function Initialize-WorkflowScreen {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [switch]$NoSeparator
    )

    $Colors = @{
        Accent   = Get-CLIColor -Role 'Accent'
        Disabled = Get-CLIColor -Role 'Disabled'
        Info     = Get-CLIColor -Role 'Info'
        Warning  = Get-CLIColor -Role 'Warning'
        Success  = Get-CLIColor -Role 'Success'
        Error    = Get-CLIColor -Role 'Error'
    }

    [System.Console]::Clear()
    Write-CLILine -Text $Title -Color $Colors.Accent
    if (-not $NoSeparator) {
        $Sep = [string][char]0x2500 * 50
        Write-Host "  $Sep" -ForegroundColor $Colors.Disabled
    }
    Write-Host ''

    return $Colors
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

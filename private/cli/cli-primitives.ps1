<#
    .SYNOPSIS
    Core UI primitives for the Robot CLI - colors, key input, progress
    reporting, and visual helpers.

    .DESCRIPTION
    This file contains the lowest-level interactive building blocks consumed
    by the entire CLI stack. Dot-sourced on demand (not at module import).

    The TUI engine files (engine/*.ps1) are chain-loaded in dependency
    order from this file.

    Active helpers (NOT deprecated):
    - Resolve-CLITheme:       background-adaptive Dark/Light detection via
                              Console.BackgroundColor → theme string
    - Get-CLIColor:           semantic role → ConsoleColor lookup through
                              $script:CLIColorScheme (colorblind-safe palette)
    - Write-CLILine:          consistent 2-space-indented Write-Host wrapper
    - Initialize-WorkflowScreen: common workflow screen setup (clear, title,
                              separator). Returns color hashtable for caller use.
    - New-ProgressState:      create Docker-style progress group (title + N steps)
    - Start-ProgressStep:     begin a step (renders [X/N] ⠿ Label...)
    - Update-ProgressStep:    update current step in-place (animated spinner + detail)
    - Complete-ProgressStep:  finish step with ✓/✗ + elapsed time
    - Complete-ProgressGroup: finalize group with total elapsed on title line

    - Show-InfoBox:       simple pre-checks info display for workflow screens

    Module-level data:
    - $script:CLIColorScheme: dark/light adaptive color mappings (7 semantic
      roles: Accent, Success, Warning, Error, Disabled, Info, RoleTag)
    - $script:BannerArt:      ASCII art string for CLI launch screen
    - $script:SpinnerFrames:  8 braille characters cycled by Update-ProgressStep
    - $script:SpinnerStatic:  static braille indicator (⠿) for blocking calls

    Design:
    - Colors never rely on Red/Green (colorblind-safe). Every semantic meaning
      is reinforced with symbols (checkmark, cross, warning triangle).
    - Per-line SetCursorPosition redraw to avoid flicker (no full Clear).
    - Progress functions use Stopwatch for sub-second elapsed timing and
      in-place line updates via SetCursorPosition.

    Dependencies: none (this is the root of the CLI dependency chain)
#>

# ── Color Scheme ─────────────────────────────────────────────────────────────

# Background-adaptive, colorblind-friendly palette.
# Red and Green are NEVER used — the most common colorblindness axis (protanopia/deuteranopia).
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

    # Title line anchors the group — individual steps render below it
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

    # Render step line with static spinner indicator
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

    # Cycle through braille spinner frames for animation
    $State.SpinnerIdx = ($State.SpinnerIdx + 1) % $script:SpinnerFrames.Count
    $Spinner = $script:SpinnerFrames[$State.SpinnerIdx]

    # In-place re-render of the current step line
    $Row = $State.StartRow + $State.CurrentStep
    $Width = [System.Console]::WindowWidth
    $Clr = Get-CLIColor -Role 'Disabled'
    $AccClr = Get-CLIColor -Role 'Accent'
    $Counter = "[{0}/{1}]" -f $State.CurrentStep, $State.TotalSteps

    $LeftText = "$($Step.Label)..."
    $RightText = if ($Step.Detail) { "  $($Step.Detail)" } else { '' }
    # Prefix length: "  [X/N] S " varies with step/total digit count
    $PrefixLen = 2 + $Counter.Length + 1 + 2
    $Pad = $Width - $PrefixLen - $LeftText.Length - $RightText.Length
    if ($Pad -lt 0) { $Pad = 0 }

    [System.Console]::SetCursorPosition(0, $Row)
    Write-Host "  $Counter " -NoNewline -ForegroundColor $Clr
    Write-Host "$Spinner " -NoNewline -ForegroundColor $AccClr
    Write-Host "$LeftText$(' ' * $Pad)$RightText" -NoNewline -ForegroundColor $Clr
    # Erase any trailing chars from previous longer render
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

    $Symbol = if ($Failed) { [char]0x2717 } else { [char]0x2713 }  # ✗ or ✓
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
    # Erase remainder of the line
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

    # Overwrite title line with right-aligned total elapsed time
    $Row = $State.StartRow
    $Width = [System.Console]::WindowWidth
    $Clr = Get-CLIColor -Role 'Disabled'

    $LeftPart = "  $($State.Title)"
    $Pad = $Width - $LeftPart.Length - $TotalElapsed.Length - 3
    if ($Pad -lt 0) { $Pad = 0 }

    [System.Console]::SetCursorPosition(0, $Row)
    Write-Host "$LeftPart$(' ' * $Pad)   $TotalElapsed" -ForegroundColor $Clr

    # Position cursor below the completed group for subsequent output
    $FinalRow = $State.StartRow + $State.TotalSteps + 1
    [System.Console]::SetCursorPosition(0, $FinalRow)
    Write-Host ''
}

# ── Initialize-WorkflowScreen ────────────────────────────────────────────────

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

# ── Show-InfoBox ─────────────────────────────────────────────────────────────
# Displays a simple pre-checks info list for workflow screens (Write-Host context).

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

# ── Chain-load TUI engine files in dependency order ─────────────────────────────

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

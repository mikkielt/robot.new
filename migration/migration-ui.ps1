<#
    .SYNOPSIS
    Polish-language UI helper functions for the migration script.

    .DESCRIPTION
    Console output helpers consumed by migrate.ps1 and migration-phases.ps1
    via dot-sourcing. Provides color-coded, Polish-language output for the
    interactive migration process.

    When the CLI engine (cli-engine.ps1) is available (i.e. loaded by
    Invoke-RobotCLI), output functions use Get-CLIColor for background-adaptive
    colorblind-friendly colors, and interactive prompts use arrow-key navigation.

    When running standalone (migrate.ps1 executed directly), functions fall back
    to hardcoded colors and Read-Host prompts - no dependency on the CLI engine.

    Helpers:
    - Initialize-MigrationLog: opens fresh log file with timestamp header
    - Write-MigrationLog:      appends structured entry to migration-log.txt
    - Write-PhaseHeader:       renders phase banner with status badge
    - Write-Step:              renders step-in-progress line
    - Write-StepOK:            renders success step result
    - Write-StepWarning:       renders warning step result
    - Write-StepError:         renders error step result
    - Write-ChecklistReport:   renders checklist with checkboxes
    - Write-ActionRequired:    renders action-required block
    - Write-CommandHint:       renders copy-paste command suggestion
    - Write-PhaseSummary:      renders end-of-phase summary box
    - Write-SectionHeader:     renders sub-section header
    - Write-TableRow:          renders a formatted table row
    - Request-UserChoice:      menu selection (arrow-key or fallback Read-Host)
    - Request-YesNo:           Tak/Nie prompt (arrow-key or fallback Read-Host)
    - Request-Confirmation:    press any key / Enter to continue
    - Request-StringInput:     text input (character-by-character or fallback Read-Host)
    - Request-NumericInput:    numeric input with validation
    - Show-ProgressSummary:    full migration status overview (arrow-menu or fallback)
#>

# ── CLI engine detection ────────────────────────────────────────────────────
# If Get-CLIColor is already defined (loaded by Invoke-RobotCLI), use it.
# Otherwise fall back to hardcoded colors.

$script:CLIEngineAvailable = [bool](Get-Command 'Get-CLIColor' -ErrorAction SilentlyContinue)

# ── Migration Log ─────────────────────────────────────────────────────────
# Structured text log written to .robot.local/res/migration-log.txt.
# Overwritten on each run (always fresh). Polish language, verbose output.

$script:MigrationLogPath = $null
$script:MigrationLogLines = $null

# Opens a fresh log file. Called once at the start of each migration run.
function Initialize-MigrationLog {
    try {
        $RepoRoot = Get-RepoRoot
    } catch {
        return
    }
    $ResDir = $script:MigrationResDir
    if (-not [System.IO.Directory]::Exists($ResDir)) {
        [void][System.IO.Directory]::CreateDirectory($ResDir)
    }
    $script:MigrationLogPath = [System.IO.Path]::Combine($ResDir, 'migration-log.txt')
    $script:MigrationLogLines = [System.Collections.Generic.List[string]]::new(256)

    $Timestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')

    $script:MigrationLogLines.Add(([string]::new([char]0x2550, 60)))
    $script:MigrationLogLines.Add("  LOG MIGRACJI — wygenerowano $Timestamp")
    $script:MigrationLogLines.Add("  UWAGA: Ten plik jest nadpisywany przy kazdym uruchomieniu.")
    $script:MigrationLogLines.Add("         Zawiera wyniki OSTATNIEGO przebiegu migracji.")
    $script:MigrationLogLines.Add(([string]::new([char]0x2550, 60)))
    $script:MigrationLogLines.Add('')

    Flush-MigrationLog
}

# Appends a structured entry to the migration log.
# Level: INFO, WARN, ERROR, ACTION
# Details: array of indented explanation lines (4-space indent applied automatically)
function Write-MigrationLog {
    param(
        [ValidateSet('INFO','WARN','ERROR','ACTION')]
        [string]$Level = 'INFO',
        [string]$Phase,
        [Parameter(Mandatory)] [string]$Summary,
        [string[]]$Details
    )

    if (-not $script:MigrationLogLines) { return }

    # Guard: predecessor checks call Write-StepWarning before Write-PhaseHeader sets context
    $PhaseLabel = if ([string]::IsNullOrWhiteSpace($Phase)) { '(pre-phase)' } else { $Phase }

    $Timestamp = [datetime]::Now.ToString('HH:mm:ss')
    $script:MigrationLogLines.Add("[$Level] $Timestamp | $PhaseLabel")
    $script:MigrationLogLines.Add("    $Summary")

    if ($Details) {
        foreach ($Line in $Details) {
            $script:MigrationLogLines.Add("        $Line")
        }
    }
    $script:MigrationLogLines.Add('')
}

# Writes accumulated lines to disk (overwrites the entire file each time).
# Called explicitly at the end of each phase rather than after every log entry.
function Flush-MigrationLog {
    if (-not $script:MigrationLogPath -or -not $script:MigrationLogLines) { return }
    try {
        [System.IO.File]::WriteAllLines(
            $script:MigrationLogPath,
            $script:MigrationLogLines,
            [System.Text.UTF8Encoding]::new($false)
        )
    } catch {
        # Non-fatal: log is best-effort
    }
}

function Resolve-MigrationColor {
    param([Parameter(Mandatory)] [string]$Role)

    if ($script:CLIEngineAvailable) {
        return (Get-CLIColor -Role $Role)
    }

    # Fallback palette (standalone mode)
    switch ($Role) {
        'Accent'   { return 'Cyan' }
        'Success'  { return 'Green' }
        'Warning'  { return 'Yellow' }
        'Error'    { return 'Red' }
        'Disabled' { return 'DarkGray' }
        'Info'     { return 'Blue' }
        default    { return 'White' }
    }
}

# Phase name lookup — derives from $script:PhaseRegistry (set by migration-phases.ps1).
# Falls back to "Faza N" if registry is not yet loaded.
function Get-PhaseName {
    param([Parameter(Mandatory)] [int]$Phase)
    if ($script:PhaseRegistry) {
        $Entry = $script:PhaseRegistry | Where-Object { $_.ID -eq $Phase } | Select-Object -First 1
        if ($Entry) { return $Entry.Name }
    }
    return "Faza $Phase"
}

# Status display strings (Polish) - uses semantic roles, not hardcoded colors
$script:StatusDisplay = @{
    'Completed'  = @{ Symbol = [char]0x2713; Text = 'Ukończono';       Role = 'Success'  }
    'InProgress' = @{ Symbol = [char]0x25CF; Text = 'W toku';          Role = 'Warning'  }
    'NotStarted' = @{ Symbol = [char]0x25CB; Text = 'Nie rozpoczęto';  Role = 'Disabled' }
}

# ── Output helpers ──────────────────────────────────────────────────────────

# Current phase/step context for log attribution
$script:LogPhaseContext = ''
$script:LogStepContext  = ''

# Renders "=== FAZA N: Name ===" banner with status badge
function Write-PhaseHeader {
    param(
        [Parameter(Mandatory)] [int]$Phase,
        [string]$Status = 'NotStarted',
        [string]$Detail
    )

    $Name = Get-PhaseName -Phase $Phase
    $StatusInfo = $script:StatusDisplay[$Status]
    $AccentColor = Resolve-MigrationColor -Role 'Accent'

    $script:LogPhaseContext = "Faza $Phase"
    $script:LogStepContext = ''

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor $AccentColor
    Write-Host "  FAZA $Phase`: $Name" -ForegroundColor $AccentColor -NoNewline
    if ($StatusInfo) {
        $StatusColor = Resolve-MigrationColor -Role $StatusInfo.Role
        Write-Host "  $($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusColor -NoNewline
    }
    if ($Detail) {
        Write-Host " ($Detail)" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled') -NoNewline
    }
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor $AccentColor

    $StatusText = if ($StatusInfo) { $StatusInfo.Text } else { '' }
    Write-MigrationLog -Level 'INFO' -Phase "Faza $Phase" -Summary "$Name — $StatusText"
}

# Renders step-in-progress line
function Write-Step {
    param(
        [Parameter(Mandatory)] [string]$Number,
        [Parameter(Mandatory)] [string]$Text
    )
    $script:LogStepContext = "Krok $Number"
    Write-Host ''
    Write-Host "  Krok $Number`: $Text" -ForegroundColor (Resolve-MigrationColor -Role 'Accent')
    Write-MigrationLog -Level 'INFO' -Phase "$script:LogPhaseContext, Krok $Number" -Summary $Text
}

# Renders success step result
function Write-StepOK {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host "  $([char]0x2713) $Text" -ForegroundColor (Resolve-MigrationColor -Role 'Success')
    $Ctx = if ($script:LogStepContext) { "$script:LogPhaseContext, $script:LogStepContext" } else { $script:LogPhaseContext }
    Write-MigrationLog -Level 'INFO' -Phase $Ctx -Summary "OK: $Text"
}

# Renders warning step result
function Write-StepWarning {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [string[]]$LogDetails
    )
    Write-Host "  $([char]0x26A0) $Text" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
    $Ctx = if ($script:LogStepContext) { "$script:LogPhaseContext, $script:LogStepContext" } else { $script:LogPhaseContext }
    Write-MigrationLog -Level 'WARN' -Phase $Ctx -Summary $Text -Details $LogDetails
}

# Renders error step result
function Write-StepError {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [string[]]$LogDetails
    )
    Write-Host "  $([char]0x2717) $Text" -ForegroundColor (Resolve-MigrationColor -Role 'Error')
    $Ctx = if ($script:LogStepContext) { "$script:LogPhaseContext, $script:LogStepContext" } else { $script:LogPhaseContext }
    Write-MigrationLog -Level 'ERROR' -Phase $Ctx -Summary $Text -Details $LogDetails
}

# Renders a sub-section header
function Write-SectionHeader {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host ''
    Write-Host "  --- $Text ---"
}

# Renders checklist with checkboxes for a phase
function Write-ChecklistReport {
    param(
        [Parameter(Mandatory)] [hashtable]$Checklist,
        [string]$Title = 'Checklist'
    )

    Write-Host ''
    Write-Host "  $Title`:"
    foreach ($Key in ($Checklist.Keys | Sort-Object)) {
        $Value = $Checklist[$Key]
        if ($Value -eq $true) {
            Write-Host "    $([char]0x2713) $Key" -ForegroundColor (Resolve-MigrationColor -Role 'Success')
        } else {
            Write-Host "    [ ] $Key" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
        }
    }
}

# Renders action-required block
function Write-ActionRequired {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [string[]]$LogDetails
    )
    Write-Host ''
    Write-Host "  WYMAGANE DZIAŁANIE:" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
    Write-Host "  $Text" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
    $Ctx = if ($script:LogStepContext) { "$script:LogPhaseContext, $script:LogStepContext" } else { $script:LogPhaseContext }
    Write-MigrationLog -Level 'ACTION' -Phase $Ctx -Summary "WYMAGANE: $Text" -Details $LogDetails
}

# Renders copy-paste command suggestion in DarkGray
function Write-CommandHint {
    param([Parameter(Mandatory)] [string]$Command)
    Write-Host "    $Command" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
}

# Renders end-of-phase summary box
function Write-PhaseSummary {
    param(
        [Parameter(Mandatory)] [int]$Phase,
        [Parameter(Mandatory)] [string]$Status,
        [string[]]$Lines = @()
    )

    $Name = Get-PhaseName -Phase $Phase
    $StatusInfo = $script:StatusDisplay[$Status]

    Write-Host ''
    Write-Host ('+' + ('-' * 58) + '+')
    Write-Host ("| FAZA $Phase`: $Name".PadRight(59) + '|')
    Write-Host ('+' + ('-' * 58) + '+')

    foreach ($Line in $Lines) {
        $Color = $null
        if ($Line.StartsWith("$([char]0x2713)") -or $Line.StartsWith('[OK]')) {
            $Color = Resolve-MigrationColor -Role 'Success'
        }
        elseif ($Line.StartsWith("$([char]0x26A0)") -or $Line.StartsWith('[!!]')) {
            $Color = Resolve-MigrationColor -Role 'Warning'
        }
        elseif ($Line.StartsWith("$([char]0x2717)") -or $Line.StartsWith('[XX]')) {
            $Color = Resolve-MigrationColor -Role 'Error'
        }

        if ($Color) {
            Write-Host ("| $Line".PadRight(59) + '|') -ForegroundColor $Color
        } else {
            Write-Host ("| $Line".PadRight(59) + '|')
        }
    }

    $StatusColor = Resolve-MigrationColor -Role $StatusInfo.Role
    $StatusLine = "STATUS: $($StatusInfo.Text)"
    Write-Host ('+' + ('-' * 58) + '+')
    Write-Host ("| $StatusLine".PadRight(59) + '|') -ForegroundColor $StatusColor
    Write-Host ('+' + ('-' * 58) + '+')

    # Log phase summary
    $LogLevel = if ($Status -eq 'Completed') { 'INFO' } elseif ($Status -eq 'InProgress') { 'WARN' } else { 'INFO' }
    Write-MigrationLog -Level $LogLevel -Phase "Faza $Phase" -Summary "PODSUMOWANIE: $($StatusInfo.Text)" -Details $Lines

    # Flush log to disk at phase boundary (batch write instead of per-entry)
    Flush-MigrationLog
}

# Renders a formatted table row with padding
function Write-TableRow {
    param(
        [string[]]$Columns,
        [int[]]$Widths,
        [string]$Color
    )

    $SB = [System.Text.StringBuilder]::new(120)
    for ($I = 0; $I -lt $Columns.Count; $I++) {
        $Width = if ($I -lt $Widths.Count) { $Widths[$I] } else { 20 }
        [void]$SB.Append($Columns[$I].PadRight($Width))
    }

    if ($Color) {
        Write-Host "  $($SB.ToString())" -ForegroundColor $Color
    } else {
        Write-Host "  $($SB.ToString())"
    }
}

# ── Interactive prompts ─────────────────────────────────────────────────────
# When CLI engine is available: engine menus via New-MenuListComponent + Invoke-EngineLifecycle
# When standalone: Read-Host fallback

# Menu selection with validation
function Request-UserChoice {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string[]]$ValidChoices,
        [hashtable]$Labels,
        [string[]]$HelpText
    )

    if ($script:CLIEngineAvailable) {
        # Build engine menu items from valid choices
        $Items = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($Choice in $ValidChoices) {
            $Label = if ($Labels -and $Labels.ContainsKey($Choice)) { $Labels[$Choice] } else { $Choice }
            [void]$Items.Add([PSCustomObject]@{
                ID          = $Choice
                Label       = $Label
                Description = ''
                RoleTag     = $null
                InfoText    = $null
                Disabled    = $false
            })
        }

        Write-CLILine -Text "  $Prompt" -Color (Get-CLIColor -Role 'Accent')
        $MinState = [PSCustomObject]@{ BreadcrumbStack = [System.Collections.Generic.Stack[string]]::new() }
        $MenuComp = New-MenuListComponent -Items $Items -ShowBack -HelpContent $HelpText
        $Selected = Invoke-EngineLifecycle -Component $MenuComp -State $MinState
        if ($Selected -eq '__back__' -or $Selected -eq '__quit__') {
            return 'Q'
        }
        return $Selected
    }

    # Fallback: Read-Host
    while ($true) {
        Write-Host ''
        # Display available options with labels before prompting
        if ($Labels) {
            foreach ($C in $ValidChoices) {
                $Label = if ($Labels.ContainsKey($C)) { $Labels[$C] } else { $C }
                Write-Host "    [$C] $Label" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
            }
        }
        Write-Host "  $Prompt ($($ValidChoices -join '/')) " -NoNewline
        $UserInput = Read-Host
        $Trimmed = $UserInput.Trim().ToUpperInvariant()

        if ($ValidChoices -contains $Trimmed) {
            return $Trimmed
        }

        Write-Host "  Nieprawidłowy wybór. Dostępne opcje: $($ValidChoices -join ', ')" -ForegroundColor (Resolve-MigrationColor -Role 'Error')
    }
}

# Tak/Nie prompt
function Request-YesNo {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [bool]$Default = $true,
        [string[]]$HelpText
    )

    if ($script:CLIEngineAvailable) {
        $Items = @(
            [PSCustomObject]@{ ID = 'tak'; Label = 'Tak'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
            [PSCustomObject]@{ ID = 'nie'; Label = 'Nie'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        Write-Host ''
        Write-Host "  $Prompt" -ForegroundColor (Resolve-MigrationColor -Role 'Accent')
        $MinState = [PSCustomObject]@{ BreadcrumbStack = [System.Collections.Generic.Stack[string]]::new() }
        $MenuComp = New-MenuListComponent -Items $Items -ShowBack -HelpContent $HelpText
        $Selected = Invoke-EngineLifecycle -Component $MenuComp -State $MinState
        if ($Selected -eq '__back__' -or $Selected -eq '__quit__') {
            return $null
        }
        return ($Selected -eq 'tak')
    }

    # Fallback: Read-Host
    $Hint = if ($Default) { '(Tak/nie)' } else { '(tak/Nie)' }
    Write-Host ''
    Write-Host "  $Prompt $Hint " -NoNewline
    $UserInput = Read-Host

    if ([string]::IsNullOrWhiteSpace($UserInput)) {
        return $Default
    }

    $Lower = $UserInput.Trim().ToLowerInvariant()
    if ($Lower -eq 'tak' -or $Lower -eq 't' -or $Lower -eq 'yes' -or $Lower -eq 'y') {
        return $true
    }
    return $false
}

# Press any key / Enter to continue
function Request-Confirmation {
    param([string]$Text = 'Naciśnij dowolny klawisz aby kontynuować...')

    Write-Host ''
    Write-Host "  $Text" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')

    if ($script:CLIEngineAvailable) {
        [void][System.Console]::ReadKey($true)
    } else {
        [void](Read-Host)
    }
}

# Prompt for a string value
function Request-StringInput {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default
    )

    $Hint = if ($Default) { " [$Default]" } else { '' }

    # Always use Read-Host for string input (character-by-character input is
    # only used in fuzzy search and wizard steps, not migration prompts)
    Write-Host "  $Prompt$Hint`: " -NoNewline
    $UserInput = Read-Host

    if ([string]::IsNullOrWhiteSpace($UserInput)) {
        if ($Default) { return $Default }
        return ''
    }
    return $UserInput.Trim()
}

# Prompt for a numeric value (nullable)
function Request-NumericInput {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [switch]$AllowSkip
    )

    $Hint = if ($AllowSkip) { ' [Enter = pomiń]' } else { '' }
    Write-Host "    $Prompt$Hint`: " -NoNewline
    $UserInput = Read-Host

    if ([string]::IsNullOrWhiteSpace($UserInput)) {
        if ($AllowSkip) { return $null }
        return 0
    }

    $Value = 0
    if ([int]::TryParse($UserInput.Trim(), [ref]$Value)) {
        return $Value
    }

    Write-Host "    Nieprawidłowa wartość: '$UserInput' - oczekiwana liczba całkowita" -ForegroundColor (Resolve-MigrationColor -Role 'Error')
    return $null
}

# Full migration status overview (main menu header)
function Show-ProgressSummary {
    param([Parameter(Mandatory)] [hashtable]$State)

    $DateStr = [datetime]::Now.ToString('yyyy-MM-dd')
    $AccentColor = Resolve-MigrationColor -Role 'Accent'

    if ($script:CLIEngineAvailable -and $script:PhaseRegistry) {
        # Arrow-key menu mode: build items from registry and show as selectable list
        # (Dispatch handled by migrate.ps1 using the returned selection)
        Write-Host ''
        Write-Host ('=' * 60) -ForegroundColor $AccentColor
        Write-Host '  MIGRACJA .robot  →  .robot.powershell' -ForegroundColor $AccentColor
        Write-Host "  Stan na: $DateStr" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
        Write-Host ('=' * 60) -ForegroundColor $AccentColor
        Write-Host ''

        # Progress indicator
        $CompletedCount = ($script:PhaseRegistry | Where-Object {
            (Get-PhaseStatus -State $State -Phase $_.ID) -eq 'Completed'
        } | Measure-Object).Count
        $TotalCount = $script:PhaseRegistry.Count
        Write-Host "  Postęp: $CompletedCount/$TotalCount faz ukończonych" -ForegroundColor $AccentColor
        Write-Host ''

        $Items = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($Phase in $script:PhaseRegistry) {
            $PhaseStatus = Get-PhaseStatus -State $State -Phase $Phase.ID
            $StatusInfo = $script:StatusDisplay[$PhaseStatus]
            $StatusSymbol = if ($StatusInfo) { "$($StatusInfo.Symbol) " } else { '' }
            $StatusText = if ($StatusInfo) { $StatusInfo.Text } else { '' }
            $EstStr = if ($Phase.EstimatedMinutes) { " (~$($Phase.EstimatedMinutes) min)" } else { '' }

            [void]$Items.Add([PSCustomObject]@{
                ID          = "phase-$($Phase.ID)"
                Label       = "${StatusSymbol}Faza $($Phase.ID): $($Phase.Name)"
                Description = "$StatusText$EstStr"
                RoleTag     = 'K'
                InfoText    = $null
                Disabled    = $false
            })
        }

        # Extra menu items
        [void]$Items.Add([PSCustomObject]@{
            ID = 'diagnostics'; Label = 'Szybka diagnostyka'; Description = ''
            RoleTag = $null; InfoText = $null; Disabled = $false
        })
        [void]$Items.Add([PSCustomObject]@{
            ID = 'report'; Label = 'Pełny raport'; Description = ''
            RoleTag = $null; InfoText = $null; Disabled = $false
        })

        $MigrationHelp = @(
            'Wybierz fazę migracji do uruchomienia.'
            'Fazy są wykonywane sekwencyjnie (0-8).'
            'Każda faza jest idempotentna — można ją uruchomić wielokrotnie.'
            ''
            'Szybka diagnostyka — przegląd stanu migracji'
            'Pełny raport — szczegółowe zestawienie postępu'
        )

        $MenuComp = New-MenuListComponent -Items $Items -ShowBack -HelpContent $MigrationHelp -HelpTitle 'Migracja - Pomoc'
        $Selected = Invoke-EngineLifecycle -Component $MenuComp -State $State
        return $Selected
    }

    # Fallback: classic numbered list
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor $AccentColor
    Write-Host '  MIGRACJA .robot  →  .robot.powershell' -ForegroundColor $AccentColor
    Write-Host "  Stan na: $DateStr" -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
    Write-Host ('=' * 60) -ForegroundColor $AccentColor
    Write-Host ''

    # Progress indicator (fallback)
    $CompletedCount = 0
    $TotalCount = if ($script:PhaseRegistry) { $script:PhaseRegistry.Count } else { 9 }
    for ($I = 0; $I -le 8; $I++) {
        if ((Get-PhaseStatus -State $State -Phase $I) -eq 'Completed') { $CompletedCount++ }
    }
    Write-Host "  Postęp: $CompletedCount/$TotalCount faz ukończonych" -ForegroundColor $AccentColor
    Write-Host ''

    for ($I = 0; $I -le 8; $I++) {
        $PhaseStatus = Get-PhaseStatus -State $State -Phase $I
        $StatusInfo = $script:StatusDisplay[$PhaseStatus]
        $Name = Get-PhaseName -Phase $I
        $StatusColor = Resolve-MigrationColor -Role $StatusInfo.Role

        $EstStr = ''
        if ($script:PhaseRegistry) {
            $RegEntry = $script:PhaseRegistry | Where-Object { $_.ID -eq $I } | Select-Object -First 1
            if ($RegEntry -and $RegEntry.EstimatedMinutes) { $EstStr = " (~$($RegEntry.EstimatedMinutes) min)" }
        }

        $PhaseLabel = "  [$I] $Name$EstStr"
        $PaddedLabel = $PhaseLabel.PadRight(55)

        Write-Host $PaddedLabel -NoNewline
        Write-Host "$($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusColor
    }

    Write-Host ''
    Write-Host '  [D] Szybka diagnostyka' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
    Write-Host '  [R] Pełny raport' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
    Write-Host '  [Q] Zakończ' -ForegroundColor (Resolve-MigrationColor -Role 'Disabled')
}

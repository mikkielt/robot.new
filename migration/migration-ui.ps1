<#
    .SYNOPSIS
    Polish-language UI helper functions for the migration script.

    .DESCRIPTION
    Console output helpers consumed by migrate.ps1 and migration-phases.ps1
    via dot-sourcing. Provides color-coded, Polish-language output for the
    interactive migration process.

    Helpers:
    - Write-PhaseHeader:     renders phase banner with status badge
    - Write-Step:            renders step-in-progress line
    - Write-StepOK:          renders success step result
    - Write-StepWarning:     renders warning step result
    - Write-StepError:       renders error step result
    - Write-ChecklistReport: renders checklist with checkboxes
    - Write-ActionRequired:  renders action-required block
    - Write-CommandHint:     renders copy-paste command suggestion
    - Write-PhaseSummary:    renders end-of-phase summary box
    - Write-SectionHeader:   renders sub-section header
    - Write-TableRow:        renders a formatted table row
    - Request-UserChoice:    numeric menu selection with validation
    - Request-YesNo:         Tak/Nie prompt with default
    - Request-Confirmation:  press Enter to continue
    - Show-ProgressSummary:  full migration status overview
#>

# Phase name lookup (Polish)
$script:PhaseNames = @{
    0 = 'Przygotowanie i backup'
    1 = 'Bootstrap entities.md'
    2 = 'Walidacja parzystości danych'
    3 = 'Diagnostyka i naprawa danych'
    4 = 'Upgrade formatu sesji'
    5 = 'Enrollment walut'
    6 = 'Okres równoległy'
    7 = 'Przełączenie (cutover)'
}

# Status display strings (Polish)
$script:StatusDisplay = @{
    'Completed'  = @{ Symbol = [char]0x2713; Text = 'Ukończono';       Color = 'Green'  }
    'InProgress' = @{ Symbol = [char]0x25CF; Text = 'W toku';          Color = 'Yellow' }
    'NotStarted' = @{ Symbol = [char]0x25CB; Text = 'Nie rozpoczęto';  Color = 'DarkGray' }
}

# Renders "=== FAZA N: Name ===" banner with status badge
function Write-PhaseHeader {
    param(
        [Parameter(Mandatory)] [int]$Phase,
        [string]$Status = 'NotStarted',
        [string]$Detail
    )

    $Name = $script:PhaseNames[$Phase]
    $StatusInfo = $script:StatusDisplay[$Status]

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  FAZA $Phase`: $Name" -ForegroundColor Cyan -NoNewline
    if ($StatusInfo) {
        Write-Host "  $($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusInfo.Color -NoNewline
    }
    if ($Detail) {
        Write-Host " ($Detail)" -ForegroundColor DarkGray -NoNewline
    }
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

# Renders step-in-progress line
function Write-Step {
    param(
        [Parameter(Mandatory)] [int]$Number,
        [Parameter(Mandatory)] [string]$Text
    )
    Write-Host ''
    Write-Host "  Krok $Number`: $Text" -ForegroundColor Cyan
}

# Renders success step result
function Write-StepOK {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

# Renders warning step result
function Write-StepWarning {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host "  [!!] $Text" -ForegroundColor Yellow
}

# Renders error step result
function Write-StepError {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host "  [XX] $Text" -ForegroundColor Red
}

# Renders a sub-section header
function Write-SectionHeader {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host ''
    Write-Host "  --- $Text ---" -ForegroundColor White
}

# Renders checklist with checkboxes for a phase
function Write-ChecklistReport {
    param(
        [Parameter(Mandatory)] [hashtable]$Checklist,
        [string]$Title = 'Checklist'
    )

    Write-Host ''
    Write-Host "  $Title`:" -ForegroundColor White
    foreach ($Key in ($Checklist.Keys | Sort-Object)) {
        $Value = $Checklist[$Key]
        if ($Value -eq $true) {
            Write-Host "    [$([char]0x2713)] $Key" -ForegroundColor Green
        } else {
            Write-Host "    [ ] $Key" -ForegroundColor DarkGray
        }
    }
}

# Renders action-required block
function Write-ActionRequired {
    param([Parameter(Mandatory)] [string]$Text)
    Write-Host ''
    Write-Host "  WYMAGANE DZIAŁANIE:" -ForegroundColor Yellow
    Write-Host "  $Text" -ForegroundColor Yellow
}

# Renders copy-paste command suggestion in DarkGray
function Write-CommandHint {
    param([Parameter(Mandatory)] [string]$Command)
    Write-Host "    $Command" -ForegroundColor DarkGray
}

# Renders end-of-phase summary box
function Write-PhaseSummary {
    param(
        [Parameter(Mandatory)] [int]$Phase,
        [Parameter(Mandatory)] [string]$Status,
        [string[]]$Lines = @()
    )

    $Name = $script:PhaseNames[$Phase]
    $StatusInfo = $script:StatusDisplay[$Status]

    Write-Host ''
    Write-Host ('+' + ('-' * 58) + '+') -ForegroundColor White
    Write-Host ("| FAZA $Phase`: $Name".PadRight(59) + '|') -ForegroundColor White
    Write-Host ('+' + ('-' * 58) + '+') -ForegroundColor White

    foreach ($Line in $Lines) {
        $Color = 'White'
        if ($Line.StartsWith('[OK]'))   { $Color = 'Green' }
        if ($Line.StartsWith('[!!]'))   { $Color = 'Yellow' }
        if ($Line.StartsWith('[XX]'))   { $Color = 'Red' }
        Write-Host ("| $Line".PadRight(59) + '|') -ForegroundColor $Color
    }

    $StatusLine = "STATUS: $($StatusInfo.Text)"
    Write-Host ('+' + ('-' * 58) + '+') -ForegroundColor White
    Write-Host ("| $StatusLine".PadRight(59) + '|') -ForegroundColor $StatusInfo.Color
    Write-Host ('+' + ('-' * 58) + '+') -ForegroundColor White
}

# Renders a formatted table row with padding
function Write-TableRow {
    param(
        [string[]]$Columns,
        [int[]]$Widths,
        [string]$Color = 'White'
    )

    $SB = [System.Text.StringBuilder]::new(120)
    for ($I = 0; $I -lt $Columns.Count; $I++) {
        $Width = if ($I -lt $Widths.Count) { $Widths[$I] } else { 20 }
        [void]$SB.Append($Columns[$I].PadRight($Width))
    }
    Write-Host "  $($SB.ToString())" -ForegroundColor $Color
}

# Numeric menu selection with validation
function Request-UserChoice {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string[]]$ValidChoices
    )

    while ($true) {
        Write-Host ''
        Write-Host "  $Prompt" -ForegroundColor White -NoNewline
        Write-Host ' ' -NoNewline
        $Input = Read-Host
        $Trimmed = $Input.Trim().ToUpperInvariant()

        if ($ValidChoices -contains $Trimmed) {
            return $Trimmed
        }

        Write-Host "  Nieprawidłowy wybór. Dostępne opcje: $($ValidChoices -join ', ')" -ForegroundColor Red
    }
}

# Tak/Nie prompt with default
function Request-YesNo {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [bool]$Default = $true
    )

    $Hint = if ($Default) { '(Tak/nie)' } else { '(tak/Nie)' }
    Write-Host ''
    Write-Host "  $Prompt $Hint " -ForegroundColor White -NoNewline
    $Input = Read-Host

    if ([string]::IsNullOrWhiteSpace($Input)) {
        return $Default
    }

    $Lower = $Input.Trim().ToLowerInvariant()
    if ($Lower -eq 'tak' -or $Lower -eq 't' -or $Lower -eq 'yes' -or $Lower -eq 'y') {
        return $true
    }
    return $false
}

# Press Enter to continue
function Request-Confirmation {
    param([string]$Text = 'Naciśnij Enter aby kontynuować...')
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

# Prompt for a string value
function Request-StringInput {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default
    )

    $Hint = if ($Default) { " [$Default]" } else { '' }
    Write-Host "  $Prompt$Hint`: " -ForegroundColor White -NoNewline
    $Input = Read-Host

    if ([string]::IsNullOrWhiteSpace($Input)) {
        if ($Default) { return $Default }
        return ''
    }
    return $Input.Trim()
}

# Prompt for a numeric value (nullable)
function Request-NumericInput {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [switch]$AllowSkip
    )

    $Hint = if ($AllowSkip) { ' [Enter = pomiń]' } else { '' }
    Write-Host "    $Prompt$Hint`: " -ForegroundColor White -NoNewline
    $Input = Read-Host

    if ([string]::IsNullOrWhiteSpace($Input)) {
        if ($AllowSkip) { return $null }
        return 0
    }

    $Value = 0
    if ([int]::TryParse($Input.Trim(), [ref]$Value)) {
        return $Value
    }

    Write-Host "    Nieprawidłowa wartość: '$Input' — oczekiwana liczba całkowita" -ForegroundColor Red
    return $null
}

# Full migration status overview (main menu header)
function Show-ProgressSummary {
    param([Parameter(Mandatory)] [hashtable]$State)

    $DateStr = [datetime]::Now.ToString('yyyy-MM-dd')

    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host '  MIGRACJA .robot  →  .robot.new' -ForegroundColor Cyan
    Write-Host "  Stan na: $DateStr" -ForegroundColor DarkGray
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host ''

    for ($I = 0; $I -le 7; $I++) {
        $PhaseStatus = Get-PhaseStatus -State $State -Phase $I
        $StatusInfo = $script:StatusDisplay[$PhaseStatus]
        $Name = $script:PhaseNames[$I]

        $PhaseLabel = "  [$I] $Name"
        $PaddedLabel = $PhaseLabel.PadRight(45)

        Write-Host $PaddedLabel -NoNewline -ForegroundColor White
        Write-Host "$($StatusInfo.Symbol) $($StatusInfo.Text)" -ForegroundColor $StatusInfo.Color
    }

    Write-Host ''
    Write-Host '  [D] Szybka diagnostyka' -ForegroundColor DarkGray
    Write-Host '  [R] Pełny raport' -ForegroundColor DarkGray
    Write-Host '  [Q] Zakończ' -ForegroundColor DarkGray
}

<#
    .SYNOPSIS
    Reporting-domain CLI workflows - Intel preview, name search, and migration reports.

    .DESCRIPTION
    This file contains workflow functions for reporting and diagnostics, consumed
    by the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-IntelPreviewWorkflow:  Intel targeting matrix (read-only)
    - Invoke-NameSearchWorkflow:    standalone name search via fuzzy picker
    - Invoke-MigrationQuickCheck:   migration quick diagnostics
    - Invoke-MigrationFullReport:   migration full report

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1, cli-wf-entity.ps1
#>

# ── Intel Preview Workflow ───────────────────────────────────────────────────

function Invoke-IntelPreviewWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-CLILine -Text 'Podgląd Intel' -Color $AccentColor
    Write-Host ''

    # Date range
    $MinDateStep = [PSCustomObject]@{
        Name = 'MinDate'; Label = 'Od daty'; StepType = 'date'; Required = $false
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__' -or $MinDate -eq '__quit__') { return }

    Write-Host '  Pobieranie sesji z Intel...' -ForegroundColor $DisabledColor

    $SessionParams = @{ IncludeContent = $true }
    if ($MinDate) { $SessionParams['MinDate'] = $MinDate }

    try {
        $Sessions = Get-Session @SessionParams

        $IntelEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($Session in $Sessions) {
            if (-not $Session.Intel -or $Session.Intel.Count -eq 0) { continue }

            foreach ($Intel in $Session.Intel) {
                $Target = if ($Intel.RawTarget) { $Intel.RawTarget } elseif ($Intel.Target) { $Intel.Target } else { '?' }
                $Message = if ($Intel.Message) { $Intel.Message } else { '' }

                [void]$IntelEntries.Add([PSCustomObject]@{
                    SessionDate  = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { '?' }
                    SessionTitle = if ($Session.Title) { $Session.Title } else { $Session.Header }
                    Target       = $Target
                    Message      = $Message
                })
            }
        }

        if ($IntelEntries.Count -eq 0) {
            Write-CLILine -Text 'Brak wpisów Intel w wybranym zakresie.' -Color $DisabledColor
        } else {
            [void](Show-ResultTable -Data $IntelEntries `
                -Columns @('SessionDate', 'Target', 'Message') `
                -Headers @('Data', 'Cel', 'Wiadomość') `
                -Widths @(12, 20, 40) `
                -Title 'Intel - podgląd routingu')
        }
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

# ── Name Search Workflow ─────────────────────────────────────────────────────

function Invoke-NameSearchWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Wyszukiwanie nazwy' -Color $AccentColor
    Write-Host ''

    $Result = Show-FuzzySearch -Prompt 'Szukaj' -Source 'entities' -State $State
    if (-not $Result) { return }

    Show-EntityCard -Entity $Result.Owner -State $State
}

# ── Migration Diagnostics ────────────────────────────────────────────────────

function Invoke-MigrationQuickCheck {
    param([object]$State, [hashtable]$Entry)

    # Try to load migration shared helpers
    $SharedPath = [System.IO.Path]::Combine($script:ModuleRoot, 'migration', 'migration-shared.ps1')
    if ([System.IO.File]::Exists($SharedPath)) {
        . $SharedPath
        if (Get-Command 'Invoke-QuickDiagnostics' -ErrorAction SilentlyContinue) {
            Invoke-QuickDiagnostics
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void](Read-ArrowKey)
            return
        }
    }

    Write-CLILine -Text 'Diagnostyka migracji nie jest dostępna.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

function Invoke-MigrationFullReport {
    param([object]$State, [hashtable]$Entry)

    $SharedPath = [System.IO.Path]::Combine($script:ModuleRoot, 'migration', 'migration-shared.ps1')
    if ([System.IO.File]::Exists($SharedPath)) {
        . $SharedPath
        if (Get-Command 'Invoke-FullReport' -ErrorAction SilentlyContinue) {
            Invoke-FullReport
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void](Read-ArrowKey)
            return
        }
    }

    Write-CLILine -Text 'Raport migracji nie jest dostępny.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

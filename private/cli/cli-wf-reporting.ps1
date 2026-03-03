<#
    .SYNOPSIS
    Reporting-domain CLI workflows - Intel preview, name search, log fetch,
    log location report, and migration reports.

    .DESCRIPTION
    This file contains workflow functions for reporting and diagnostics, consumed
    by the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-IntelPreviewWorkflow:        Intel targeting matrix (read-only)
    - Invoke-NameSearchWorkflow:          standalone name search via fuzzy picker
    - Invoke-FetchLogsWorkflow:           mass log fetch with CDN-safe throttling
    - Invoke-LogLocationReportWorkflow:   log location resolution analysis
    - Invoke-MigrationQuickCheck:         migration quick diagnostics
    - Invoke-MigrationFullReport:         migration full report

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
    if ($MinDate -eq '__back__') { return }

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

# ── Fetch Logs Workflow ──────────────────────────────────────────────────────

function Invoke-FetchLogsWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Pobierz logi sesji' -Color $AccentColor
    Write-Host ''

    # Date range steps
    $MinDateStep = [PSCustomObject]@{
        Name = 'MinDate'; Label = 'Od daty (opcjonalne)'; StepType = 'date'; Required = $false
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $MaxDateStep = [PSCustomObject]@{
        Name = 'MaxDate'; Label = 'Do daty (opcjonalne)'; StepType = 'date'; Required = $false
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MaxDate = Invoke-WizardStep -Step $MaxDateStep -State $State
    if ($MaxDate -eq '__back__') { return }

    Write-Host '  Pobieranie sesji...' -ForegroundColor $DisabledColor

    # Get sessions
    $SessionParams = @{}
    if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
    if ($MaxDate) { $SessionParams['MaxDate'] = $MaxDate }

    try {
        $Sessions = Get-Session @SessionParams
        $WithLogs = [System.Collections.Generic.List[object]]::new()
        foreach ($S in $Sessions) {
            if ($null -ne $S.Logs -and $S.Logs.Count -gt 0) { $WithLogs.Add($S) }
        }

        if ($WithLogs.Count -eq 0) {
            Write-CLILine -Text 'Brak sesji z logami w wybranym zakresie.' -Color $DisabledColor
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void](Read-ArrowKey)
            return
        }

        $TotalUrls = 0
        foreach ($S in $WithLogs) { $TotalUrls += $S.Logs.Count }
        Write-CLILine -Text "Znaleziono $($WithLogs.Count) sesji z $TotalUrls URL logów." -Color $AccentColor
        Write-Host ''

        # Confirmation
        Write-CLILine -Text 'CDN może ograniczać liczbę żądań. Pobieranie odbywa się z opóźnieniem 500ms.' -Color $WarningColor
        Write-Host ''

        $ConfirmItems = @(
            [PSCustomObject]@{ ID = 'yes'; Label = 'Tak, pobierz'; Description = '' }
            [PSCustomObject]@{ ID = 'no'; Label = 'Anuluj'; Description = '' }
        )
        $Confirm = Show-ArrowMenu -Items $ConfirmItems -ShowBack
        if ($Confirm -ne 'yes') { return }

        Write-Host ''
        Write-Host '  Rozpoczynam pobieranie...' -ForegroundColor $DisabledColor

        $Result = $WithLogs | Invoke-SessionLogFetch
        Write-Host ''
        Write-CLILine -Text "Pobrano: $($Result.Fetched)" -Color $AccentColor
        Write-CLILine -Text "Z cache: $($Result.Cached)" -Color $DisabledColor
        Write-CLILine -Text "Pominięto (failed): $($Result.Skipped)" -Color $DisabledColor
        if ($Result.Failed -gt 0) {
            Write-CLILine -Text "Błędy: $($Result.Failed)" -Color $WarningColor
            foreach ($Url in $Result.FailedUrls) {
                Write-CLILine -Text "  $Url" -Color $WarningColor
            }
        }
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void](Read-ArrowKey)
}

# ── Log Location Report Workflow ────────────────────────────────────────────

function Invoke-LogLocationReportWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Raport lokacji z logów' -Color $AccentColor
    Write-Host ''

    # Date range
    $MinDateStep = [PSCustomObject]@{
        Name = 'MinDate'; Label = 'Od daty (opcjonalne)'; StepType = 'date'; Required = $false
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    Write-Host '  Przetwarzanie logów (tylko z cache)...' -ForegroundColor $DisabledColor

    try {
        $SessionParams = @{}
        if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
        $Sessions = Get-Session @SessionParams

        $LogResults = $Sessions | Get-SessionLog -Index $State.NameIndex -SkipFetch
        $LogResultArray = @($LogResults)

        if ($LogResultArray.Count -eq 0) {
            Write-CLILine -Text 'Brak sparsowanych logów. Najpierw użyj "Pobierz logi sesji".' -Color $WarningColor
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void](Read-ArrowKey)
            return
        }

        # Get sessions that had logs for cross-referencing
        $SessionsWithLogs = [System.Collections.Generic.List[object]]::new()
        foreach ($S in $Sessions) {
            if ($null -ne $S.Logs -and $S.Logs.Count -gt 0) { $SessionsWithLogs.Add($S) }
        }

        $Report = Get-NamedLogLocationReport `
            -SessionLog $LogResultArray `
            -Session $SessionsWithLogs `
            -Index $State.NameIndex

        # Build flat table rows
        $TableData = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ReportEntry in $Report) {
            foreach ($Loc in $ReportEntry.Locations) {
                $ResolvedText = if ($Loc.Resolved) { $Loc.Resolved } else { '-' }
                $StageText = if ($Loc.Stage) { $Loc.Stage } else { '-' }
                $InMeta = if ($Loc.InSessionMeta) { 'Tak' } else { 'Nie' }
                $SessionText = if ($ReportEntry.SessionTitle) { $ReportEntry.SessionTitle } else { '?' }

                [void]$TableData.Add([PSCustomObject]@{
                    Session    = $SessionText
                    Location   = $Loc.Raw
                    Resolved   = $ResolvedText
                    Stage      = $StageText
                    InMeta     = $InMeta
                    NearMatches = $Loc.NearMatches
                })
            }
        }

        if ($TableData.Count -eq 0) {
            Write-CLILine -Text 'Brak lokacji w logach.' -Color $DisabledColor
        } else {
            # Summary
            $TotalResolved = 0; $TotalAll = 0; $TotalInMeta = 0
            foreach ($R in $Report) {
                $TotalResolved += $R.Summary.Resolved
                $TotalAll      += $R.Summary.Total
                $TotalInMeta   += $R.Summary.InMeta
            }
            Write-CLILine -Text "$TotalResolved/$TotalAll rozpoznanych, $TotalInMeta w metadanych sesji" -Color $AccentColor
            Write-Host ''

            while ($true) {
                $Selected = Show-ResultTable -Data $TableData `
                    -Columns @('Session', 'Location', 'Resolved', 'Stage', 'InMeta') `
                    -Headers @('Sesja', 'Lokacja', 'Rozpoznano', 'Etap', 'W meta') `
                    -Widths @(20, 20, 20, 10, 6) `
                    -Title 'Lokacje z logów'

                if (-not $Selected) { break }

                # Show detail card with near-matches if any
                if ($Selected.NearMatches -and $Selected.NearMatches.Count -gt 0) {
                    $NearParts = [System.Collections.Generic.List[string]]::new()
                    foreach ($NM in $Selected.NearMatches) { $NearParts.Add("$($NM.Name) (odl. $($NM.Distance))") }
                    $NearText = [string]::Join(', ', $NearParts)
                    $Selected | Add-Member -NotePropertyName 'Podobne' -NotePropertyValue $NearText -Force
                }
                Show-DetailCard -Row $Selected -Title 'Szczegóły lokacji'
            }
        }
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void](Read-ArrowKey)
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

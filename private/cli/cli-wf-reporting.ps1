<#
    .SYNOPSIS
    Reporting-domain CLI workflows - Intel preview, name search, log fetch,
    log location report, location graph, session graph, dormancy, delta,
    and migration reports.

    .DESCRIPTION
    This file contains workflow functions for reporting and diagnostics, consumed
    by the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Helpers:
    - Invoke-IntelPreviewWorkflow:           Intel targeting matrix (session/target/message table)
    - Invoke-NameSearchWorkflow:             standalone name search via fuzzy picker + entity card
    - Invoke-FetchLogsWorkflow:              mass log fetch with 500ms CDN-safe throttling
    - Invoke-LogLocationReportWorkflow:      log location resolution analysis with near-match details
    - Invoke-LocationGraphWorkflow:          location connection graph with optional map traversal
                                              and @drzwi entity update via Set-TraversalEntities
    - Invoke-SessionGraphWorkflow:           session participation graph with 4 query modes
    - Invoke-CompareParticipationWorkflow:   cross-entity session overlap matrix (min 2 entities)
    - Invoke-SessionLeaderboardWorkflow:     session participation ranking with tier breakdown
    - Invoke-DormancyReportWorkflow:         dormant entity detection with configurable threshold
    - Invoke-EntityDeltaWorkflow:            entity property diff between two dates
    - Invoke-MigrationQuickCheck:            migration quick diagnostics (loads migration-shared.ps1)
    - Invoke-MigrationFullReport:            migration full report (loads migration-shared.ps1)

    Intel preview: collects @Intel entries from sessions with optional date
    filter, flattens them into a session/target/message table for review.

    Log fetch: enumerates sessions with @Logi URLs, confirms the download
    count, then delegates to Invoke-SessionLogFetch which throttles at 500ms
    per request to avoid CDN rate limiting.

    Log location report: runs Get-SessionLog over fetched logs, then
    Get-NamedLogLocationReport to resolve location names. Unresolved
    locations show NearMatches (BK-tree candidates) in the detail card.

    Session graph workflow: supports 4 modes mapped from Polish labels:
    Sessions (entity's sessions), CoParticipants (entities sharing sessions),
    EntityTimeline (participants in a single session), Summary (global stats).
    Warns when the Tier-2 (text-based) index is stale.

    Migration workflows: attempt to load migration-shared.ps1 at runtime;
    if unavailable, they show a "not available" message.

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1, cli-wf-entity.ps1
#>

# ── Intel Preview Workflow ───────────────────────────────────────────────────

function Invoke-IntelPreviewWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-CLILine -Text 'Podgląd Intel' -Color $AccentColor
    Write-Host ''

    # Optional date floor to limit session scanning
    $MinDateStep = New-WizardDateStep -Name 'MinDate' -Label 'Od daty'
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $IntelProg = New-ProgressState -Title 'Przegląd Intel' -TotalSteps 1
    Start-ProgressStep -State $IntelProg -Label 'Sesje'

    $SessionParams = @{ IncludeContent = $true }
    if ($MinDate) { $SessionParams['MinDate'] = $MinDate }

    try {
        $SessCB = { param($C,$T,$D); Update-ProgressStep -State $IntelProg -Detail "$C/$T" }.GetNewClosure()
        $SessionParams['ProgressCallback'] = $SessCB
        $Sessions = Get-Session @SessionParams
        Complete-ProgressStep -State $IntelProg -Detail "$($Sessions.Count)"
        Complete-ProgressGroup -State $IntelProg

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
            $TableComponent = New-ResultTableComponent -Data $IntelEntries `
                -Columns @('SessionDate', 'Target', 'Message') `
                -Headers @('Data', 'Cel', 'Wiadomość') `
                -Widths @(12, 20, 40) `
                -Title 'Intel - podgląd routingu'
            [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
        }
    }
    catch {
        Complete-ProgressStep -State $IntelProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $IntelProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

# ── Name Search Workflow ─────────────────────────────────────────────────────

function Invoke-NameSearchWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Wyszukiwanie nazwy' -Color $AccentColor
    Write-Host ''

    $Result = Invoke-EngineFuzzySearch -Prompt 'Szukaj' -Source 'entities' -State $State
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

    # Optional date range to scope the log fetch
    $MinDateStep = New-WizardDateStep -Name 'MinDate' -Label 'Od daty (opcjonalne)'
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $MaxDateStep = New-WizardDateStep -Name 'MaxDate' -Label 'Do daty (opcjonalne)'
    $MaxDate = Invoke-WizardStep -Step $MaxDateStep -State $State
    if ($MaxDate -eq '__back__') { return }

    $LogProg = New-ProgressState -Title 'Pobieranie logów' -TotalSteps 2
    Start-ProgressStep -State $LogProg -Label 'Sesje'

    # Fetch sessions in the date range as input for log enumeration
    $SessionParams = @{}
    if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
    if ($MaxDate) { $SessionParams['MaxDate'] = $MaxDate }

    try {
        $SessCB = { param($C,$T,$D); Update-ProgressStep -State $LogProg -Detail "$C/$T" }.GetNewClosure()
        $SessionParams['ProgressCallback'] = $SessCB
        $Sessions = Get-Session @SessionParams
        Complete-ProgressStep -State $LogProg -Detail "$($Sessions.Count)"
        $WithLogs = [System.Collections.Generic.List[object]]::new()
        foreach ($S in $Sessions) {
            if ($null -ne $S.Logs -and $S.Logs.Count -gt 0) { $WithLogs.Add($S) }
        }

        if ($WithLogs.Count -eq 0) {
            Write-CLILine -Text 'Brak sesji z logami w wybranym zakresie.' -Color $DisabledColor
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void][System.Console]::ReadKey($true)
            return
        }

        $TotalUrls = 0
        foreach ($S in $WithLogs) { $TotalUrls += $S.Logs.Count }
        Write-CLILine -Text "Znaleziono $($WithLogs.Count) sesji z $TotalUrls URL logów." -Color $AccentColor
        Write-Host ''

        # Warn about CDN throttling before starting the fetch
        Write-CLILine -Text 'CDN może ograniczać liczbę żądań. Pobieranie odbywa się z opóźnieniem 500ms.' -Color $WarningColor
        Write-Host ''

        $ConfirmComponent = New-WizardStepComponent -Label 'Rozpocząć pobieranie?' `
            -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
        $Confirm = Invoke-EngineLifecycle -Component $ConfirmComponent -State $State
        if ($Confirm -eq '__quit__') { return '__quit__' }
        if ($Confirm -ne $true) { return }

        Write-Host ''
        Start-ProgressStep -State $LogProg -Label 'Pobieranie URL'
        $Result = $WithLogs | Invoke-SessionLogFetch
        Complete-ProgressStep -State $LogProg -Detail "$($Result.Fetched) pobrano"
        Complete-ProgressGroup -State $LogProg
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
        Complete-ProgressStep -State $LogProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $LogProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

# ── Log Location Report Workflow ────────────────────────────────────────────

function Invoke-LogLocationReportWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Raport lokacji z logów' -Color $AccentColor
    Write-Host ''

    # Optional date floor for session scope
    $MinDateStep = New-WizardDateStep -Name 'MinDate' -Label 'Od daty (opcjonalne)'
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $LocProg = New-ProgressState -Title 'Raport lokacji z logów' -TotalSteps 2
    Start-ProgressStep -State $LocProg -Label 'Sesje'

    try {
        $SessionParams = @{}
        if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
        $SessCB = { param($C,$T,$D); Update-ProgressStep -State $LocProg -Detail "$C/$T" }.GetNewClosure()
        $SessionParams['ProgressCallback'] = $SessCB
        $Sessions = Get-Session @SessionParams
        Complete-ProgressStep -State $LocProg -Detail "$($Sessions.Count)"

        Start-ProgressStep -State $LocProg -Label 'Analiza logów'
        $LogResults = $Sessions | Get-SessionLog -Index $State.NameIndex -SkipFetch
        $LogResultArray = @($LogResults)
        Complete-ProgressStep -State $LocProg -Detail "$($LogResultArray.Count) logów"
        Complete-ProgressGroup -State $LocProg

        if ($LogResultArray.Count -eq 0) {
            Write-CLILine -Text 'Brak sparsowanych logów. Najpierw użyj "Pobierz logi sesji".' -Color $WarningColor
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void][System.Console]::ReadKey($true)
            return
        }

        # Cross-reference sessions with logs to build the report input
        $SessionsWithLogs = [System.Collections.Generic.List[object]]::new()
        foreach ($S in $Sessions) {
            if ($null -ne $S.Logs -and $S.Logs.Count -gt 0) { $SessionsWithLogs.Add($S) }
        }

        $Report = Get-NamedLogLocationReport `
            -SessionLog $LogResultArray `
            -Session $SessionsWithLogs `
            -Index $State.NameIndex

        # Flatten per-session location entries into a single table
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
            # Resolution stats across all report entries
            $TotalResolved = 0; $TotalAll = 0; $TotalInMeta = 0
            foreach ($R in $Report) {
                $TotalResolved += $R.Summary.Resolved
                $TotalAll      += $R.Summary.Total
                $TotalInMeta   += $R.Summary.InMeta
            }
            Write-CLILine -Text "$TotalResolved/$TotalAll rozpoznanych, $TotalInMeta w metadanych sesji" -Color $AccentColor
            Write-Host ''

            while ($true) {
                $TableComponent = New-ResultTableComponent -Data $TableData `
                    -Columns @('Session', 'Location', 'Resolved', 'Stage', 'InMeta') `
                    -Headers @('Sesja', 'Lokacja', 'Rozpoznano', 'Etap', 'W meta') `
                    -Widths @(20, 20, 20, 10, 6) `
                    -Title 'Lokacje z logów'
                $Selected = Invoke-EngineLifecycle -Component $TableComponent -State $State

                if (-not $Selected -or $Selected -eq '__back__' -or $Selected -eq '__quit__') { break }

                # Append BK-tree near-matches to the detail card when available
                if ($Selected.NearMatches -and $Selected.NearMatches.Count -gt 0) {
                    $NearParts = [System.Collections.Generic.List[string]]::new()
                    foreach ($NM in $Selected.NearMatches) { $NearParts.Add("$($NM.Name) (odl. $($NM.Distance))") }
                    $NearText = [string]::Join(', ', $NearParts)
                    $Selected | Add-Member -NotePropertyName 'Podobne' -NotePropertyValue $NearText -Force
                }
                Invoke-EngineDetailCard -Data $Selected -Title 'Szczegóły lokacji' -State $State
            }
        }
    }
    catch {
        Complete-ProgressStep -State $LocProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $LocProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

# ── Migration Diagnostics ────────────────────────────────────────────────────

function Invoke-MigrationQuickCheck {
    param([object]$State, [hashtable]$Entry)

    # Attempt runtime load of migration helpers (may not be present in all deployments)
    $SharedPath = [System.IO.Path]::Combine($script:ModuleRoot, 'migration', 'migration-shared.ps1')
    if ([System.IO.File]::Exists($SharedPath)) {
        . $SharedPath
        if (Get-Command 'Invoke-QuickDiagnostics' -ErrorAction SilentlyContinue) {
            Invoke-QuickDiagnostics
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void][System.Console]::ReadKey($true)
            return
        }
    }

    Write-CLILine -Text 'Diagnostyka migracji nie jest dostępna.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
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
            [void][System.Console]::ReadKey($true)
            return
        }
    }

    Write-CLILine -Text 'Raport migracji nie jest dostępny.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

# ── Location Graph Workflow ──────────────────────────────────────────────────

function Invoke-LocationGraphWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Graf lokacji' -Color $AccentColor
    Write-Host ''

    # Optional date floor to limit edge data
    $MinDateStep = New-WizardDateStep -Name 'MinDate' -Label 'Od daty (opcjonalne)'
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    # Movement edges add log-derived traversal data (heavier computation)
    $IncludeMovement = $false
    $MoveStep = New-WizardChoiceStep -Name 'IncludeMovement' -Label 'Dołączyć krawędzie ruchu z logów?' -Options @('Nie', 'Tak') -Default 'Nie'
    $MoveChoice = Invoke-WizardStep -Step $MoveStep -State $State
    if ($MoveChoice -eq '__back__') { return }
    if ($MoveChoice -eq 'Tak') { $IncludeMovement = $true }

    $UpdateEntities = 'Nie'
    if ($IncludeMovement) {
        $UpdateStep = New-WizardChoiceStep -Name 'UpdateEntities' `
            -Label 'Aktualizować encje (@drzwi) na podstawie analizy?' `
            -Options @('Nie', 'Tylko raport', 'Zastosuj') -Default 'Nie'
        $UpdateChoice = Invoke-WizardStep -Step $UpdateStep -State $State
        if ($UpdateChoice -eq '__back__') { return }
        $UpdateEntities = $UpdateChoice
    }

    $TotalSteps = if ($IncludeMovement -and $UpdateEntities -ne 'Nie') { 3 } elseif ($IncludeMovement) { 2 } else { 1 }
    $GrProg = New-ProgressState -Title 'Graf lokacji' -TotalSteps $TotalSteps

    try {
        $GraphParams = @{ Quiet = $true }
        if ($MinDate) { $GraphParams['MinDate'] = $MinDate }
        if ($IncludeMovement) { $GraphParams['IncludeMovementEdges'] = $true }

        # Build map traversal graph before location graph when movement edges requested
        $MapTraversal = $null
        if ($IncludeMovement) {
            Start-ProgressStep -State $GrProg -Label 'Graf map'
            try {
                $Entities = Get-Entity
                $Sessions = Get-Session
                $LogData = Get-SessionLog -Session $Sessions -SkipFetch
                $MapTraversal = Get-MapTraversalGraph -SessionLog $LogData -Entities $Entities -Quiet
                $GraphParams['Entities'] = $Entities
                $GraphParams['Sessions'] = $Sessions
                $GraphParams['MapTraversalGraph'] = $MapTraversal
                $MapDetail = "map: $($MapTraversal.ResolvedCount)/$($MapTraversal.TotalSegments)"
                Complete-ProgressStep -State $GrProg -Detail $MapDetail
            }
            catch {
                Complete-ProgressStep -State $GrProg -Detail 'pominięto' -Failed
                Write-RobotWarning "[WARN Invoke-LocationGraphWorkflow] Map traversal: $_"
            }
        }

        Start-ProgressStep -State $GrProg -Label 'Budowanie'
        $Graph = Get-LocationGraph @GraphParams
        Complete-ProgressStep -State $GrProg -Detail "$($Graph.Summary.NodeCount) węzłów"

        $UpdateResult = $null
        if ($UpdateEntities -ne 'Nie' -and $MapTraversal) {
            Start-ProgressStep -State $GrProg -Label 'Aktualizacja encji'
            $UpdateParams = @{
                Entities = $Entities
                Sessions = $Sessions
                Quiet    = $true
            }
            if ($UpdateEntities -eq 'Tylko raport') { $UpdateParams['ReportOnly'] = $true }
            $UpdateResult = Set-TraversalEntities @UpdateParams
            Complete-ProgressStep -State $GrProg -Detail "$($UpdateResult.DoorsApplied.Count) @drzwi"
        }

        Complete-ProgressGroup -State $GrProg

        if (-not $Graph -or $Graph.Summary.NodeCount -eq 0) {
            Write-CLILine -Text 'Brak danych do wyświetlenia.' -Color $WarningColor
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void][System.Console]::ReadKey($true)
            return
        }

        # Map traversal summary (when available)
        if ($MapTraversal) {
            Write-Host ''
            Write-CLILine -Text "  Mapy: rozwiązane $($MapTraversal.ResolvedCount)/$($MapTraversal.TotalSegments), krawędzie map: $($MapTraversal.MapEdges.Count), nierozwiązane: $($MapTraversal.UnresolvedCount)" -Color $AccentColor
        }

        # Node/edge stats with resolution and type breakdowns
        $S = $Graph.Summary
        Write-Host ''
        Write-CLILine -Text "  Węzły:  $($S.NodeCount) (rozwiązane: $($S.ResolvedNodes), nierozwiązane: $($S.UnresolvedNodes))" -Color $AccentColor
        Write-CLILine -Text "  Krawędzie: $($S.EdgeCount) (zawieranie: $($S.ContainmentEdges), drzwi: $($S.DoorEdges), trasy: $($S.RouteEdges), ruch: $($S.MovementEdges), wnioskowane: $($S.InferredEdges))" -Color $AccentColor
        Write-CLILine -Text "  Exterior: $($S.ExteriorNodes)  Interior: $($S.InteriorNodes)" -Color $AccentColor
        if ($S.PossiblyStaleEdges -gt 0) {
            Write-CLILine -Text "  Potencjalnie nieaktualne krawędzie: $($S.PossiblyStaleEdges)" -Color $WarningColor
        }

        if ($UpdateResult) {
            Write-Host ''
            Write-CLILine -Text "  @drzwi: kandydaci $($UpdateResult.DoorCandidates.Count), zastosowano $($UpdateResult.DoorsApplied.Count), pominięto $($UpdateResult.DoorsSkipped.Count)" -Color $AccentColor
            if ($UpdateResult.MapSuggestions.Count -gt 0) {
                Write-CLILine -Text "  Sugestie map: $($UpdateResult.MapSuggestions.Count) nierozwiązanych nazw" -Color $WarningColor
            }
        }
        Write-Host ''

        # Nodes sorted by total degree (most-connected first)
        $NodeData = [System.Linq.Enumerable]::OrderByDescending(
            [object[]]@($Graph.Nodes), [Func[object,int]]{ param($X) $X.InDegree + $X.OutDegree })
        $TableData = @([System.Linq.Enumerable]::ToArray($NodeData)).ForEach({
            [PSCustomObject]@{
                Name       = $_.Name
                Degree     = "$($_.InDegree)/$($_.OutDegree)"
                Coords     = if ($_.Coordinates) { "$($_.Coordinates.X), $($_.Coordinates.Y)" } else { '-' }
                Entity     = if ($_.EntityMatch) { $_.EntityMatch.Name } else { '-' }
            }
        })

        $TableComponent = New-ResultTableComponent -Data @($TableData) `
            -Columns @('Name', 'Degree', 'Coords', 'Entity') `
            -Headers @('Lokacja', 'In/Out', 'Koordynaty', 'Encja') `
            -Widths @(25, 8, 12, 20) `
            -Title 'Graf lokacji - węzły'
        $SelectedRow = Invoke-EngineLifecycle -Component $TableComponent -State $State

        if ($SelectedRow -and $SelectedRow -ne '__back__' -and $SelectedRow -ne '__quit__') {
            Invoke-EngineDetailCard -Data $SelectedRow -Title 'Szczegóły węzła' -State $State
        }
    }
    catch {
        Complete-ProgressStep -State $GrProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $GrProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
    }

    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

function Invoke-CompareParticipationWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Porównanie uczestnictwa' -Color $AccentColor
    Write-Host ''

    # Collect at least 2 entity names for pairwise overlap analysis
    $EntityNames = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $Label = if ($EntityNames.Count -lt 2) { "Encja $($EntityNames.Count + 1) (wymagana)" } else { "Encja $($EntityNames.Count + 1) (Enter = koniec)" }
        $NameStep = [PSCustomObject]@{
            Name = 'EntityName'; Label = $Label; StepType = 'text'
            Required = ($EntityNames.Count -lt 2)
            Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
            Condition = $null; Transform = $null; Default = $null
        }
        $Name = Invoke-WizardStep -Step $NameStep -State $State
        if ($Name -eq '__back__') { return }
        if (-not $Name -or $Name.Trim().Length -eq 0) { break }
        [void]$EntityNames.Add($Name.Trim())
    }

    if ($EntityNames.Count -lt 2) {
        Write-CLILine -Text 'Wymagane minimum 2 encje.' -Color $WarningColor
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    $CmpProg = New-ProgressState -Title 'Porównanie uczestnictwa' -TotalSteps 1
    Start-ProgressStep -State $CmpProg -Label 'Analiza'

    try {
        $Result = Compare-SessionParticipation -EntityNames @($EntityNames) -Quiet
        Complete-ProgressStep -State $CmpProg -Detail "$($Result.CommonSessions.Count) wspólnych"
        Complete-ProgressGroup -State $CmpProg

        Write-Host ''
        Write-CLILine -Text "  Wspólne sesje: $($Result.CommonSessions.Count)" -Color $AccentColor

        foreach ($Name in $EntityNames) {
            $ExCount = $Result.ExclusiveSessions[$Name].Count
            Write-CLILine -Text "  Unikalne dla $Name`: $ExCount" -Color $AccentColor
        }

        Write-Host ''
        Write-CLILine -Text '  Macierz pokrycia:' -Color $AccentColor
        foreach ($Row in $Result.OverlapMatrix) {
            Write-CLILine -Text "    $($Row.EntityA) ↔ $($Row.EntityB): $($Row.SharedCount) wspólnych ($($Row.OverlapPct)%)" -Color $DisabledColor
        }

        if ($Result.CommonSessions.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text '  Wspólne sesje:' -Color $AccentColor
            foreach ($H in $Result.CommonSessions) {
                Write-CLILine -Text "    $H" -Color $DisabledColor
            }
        }
    }
    catch {
        Complete-ProgressStep -State $CmpProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $CmpProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

function Invoke-SessionLeaderboardWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Ranking uczestnictwa' -Color $AccentColor
    Write-Host ''

    # Optional entity type filter narrows ranking to a single entity category
    $TypeStep = New-WizardChoiceStep -Name 'EntityType' -Label 'Typ encji (opcjonalny)' `
        -Options @('Wszystkie', 'Postać', 'NPC', 'Lokacja', 'Grupa') -Default 'Wszystkie'
    $TypeChoice = Invoke-WizardStep -Step $TypeStep -State $State
    if ($TypeChoice -eq '__back__') { return }

    $TopStep = New-WizardTextStep -Name 'Top' -Label 'Ile pozycji? (domyślnie 20)' -Default '20'
    $TopValue = Invoke-WizardStep -Step $TopStep -State $State
    if ($TopValue -eq '__back__') { return }
    $TopN = if ($TopValue -and $TopValue -match '^\d+$') { [int]$TopValue } else { 20 }

    $LbProg = New-ProgressState -Title 'Ranking uczestnictwa' -TotalSteps 1
    Start-ProgressStep -State $LbProg -Label 'Budowanie'

    try {
        $Params = @{ Top = $TopN; Quiet = $true }
        if ($TypeChoice -and $TypeChoice -ne 'Wszystkie') {
            $Params['EntityType'] = $TypeChoice
        }

        $Result = Get-SessionGraphLeaderboard @Params
        Complete-ProgressStep -State $LbProg -Detail "$($Result.Count) pozycji"
        Complete-ProgressGroup -State $LbProg

        if (-not $Result -or $Result.Count -eq 0) {
            Write-CLILine -Text 'Brak danych.' -Color $WarningColor
        } else {
            $TableData = @($Result).ForEach({
                [PSCustomObject]@{
                    Poz    = $_.Rank
                    Nazwa  = $_.Name
                    Typ    = if ($_.Type) { $_.Type } else { '-' }
                    Sesji  = $_.SessionCount
                    T0     = $_.Tier0
                    T1     = $_.Tier1
                    T2     = $_.Tier2
                }
            })
            $TableComponent = New-ResultTableComponent -Data @($TableData) `
                -Columns @('Poz', 'Nazwa', 'Typ', 'Sesji', 'T0', 'T1', 'T2') `
                -Headers @('#', 'Nazwa', 'Typ', 'Sesji', 'T0', 'T1', 'T2') `
                -Widths @(4, 25, 10, 6, 4, 4, 4) `
                -Title 'Ranking uczestnictwa'
            $SelectedRow = Invoke-EngineLifecycle -Component $TableComponent -State $State
            if ($SelectedRow -and $SelectedRow -ne '__back__' -and $SelectedRow -ne '__quit__') {
                Invoke-EngineDetailCard -Data $SelectedRow -Title 'Szczegóły' -State $State
            }
        }
    }
    catch {
        Complete-ProgressStep -State $LbProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $LbProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

function Invoke-SessionGraphWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $WarningColor  = Get-CLIColor -Role 'Warning'

    Write-CLILine -Text 'Graf sesji' -Color $AccentColor
    Write-Host ''

    # Check Tier-2 staleness: entity changes since the last Set-SessionGraph -Full
    # mean text-based matches may be outdated (new aliases, renamed entities).
    try {
        if (-not (Get-Command 'Read-SessionGraphMeta' -ErrorAction SilentlyContinue)) {
            . "$script:ModuleRoot/private/session-graphhelpers.ps1"
        }
        if (-not (Get-Command 'Get-AdminConfig' -ErrorAction SilentlyContinue)) {
            . "$script:ModuleRoot/private/admin-config.ps1"
        }
        $WfConfig = Get-AdminConfig
        $WfGraphDir = [System.IO.Path]::Combine($WfConfig.ResDir, 'session-graph')
        $WfMetaPath = [System.IO.Path]::Combine($WfGraphDir, '_meta.json')
        if ([System.IO.File]::Exists($WfMetaPath)) {
            $WfMeta = Read-SessionGraphMeta -MetaPath $WfMetaPath
            if ($WfMeta['Tier2Stale']) {
                Write-Host ''
                Write-CLILine -Text '  ⚠ Wyniki mogą być nieaktualne — indeks wymaga odświeżenia' -Color $WarningColor
                Write-CLILine -Text '    (zmieniono encje od ostatniej pełnej aktualizacji)' -Color $DisabledColor
                Write-CLILine -Text '    Uruchom: Set-SessionGraph -Full' -Color $DisabledColor
                Write-Host ''
            }
        }
    } catch {
        # Ignore meta read failures in CLI
    }

    # Query mode selection (Polish labels mapped to Get-SessionGraph -Mode values)
    $ModeStep = New-WizardChoiceStep -Name 'Mode' -Label 'Tryb zapytania' -Required `
        -Options @('Sesje encji', 'Współuczestnicy', 'Uczestnicy sesji', 'Podsumowanie') -Default 'Sesje encji'
    $ModeChoice = Invoke-WizardStep -Step $ModeStep -State $State
    if ($ModeChoice -eq '__back__') { return }

    # Polish UI labels -> internal Mode enum values
    $ModeMap = @{
        'Sesje encji'        = 'Sessions'
        'Współuczestnicy'    = 'CoParticipants'
        'Uczestnicy sesji'   = 'EntityTimeline'
        'Podsumowanie'       = 'Summary'
    }
    $Mode = $ModeMap[$ModeChoice]

    # Entity name is required for entity-centric queries (Sessions, CoParticipants)
    $EntityName = $null
    if ($Mode -in @('Sessions', 'CoParticipants')) {
        $NameStep = New-WizardTextStep -Name 'EntityName' -Label 'Nazwa encji' -Required
        $EntityName = Invoke-WizardStep -Step $NameStep -State $State
        if ($EntityName -eq '__back__') { return }
    }

    # Session header identifies which session to show participants for
    $SessionHeader = $null
    if ($Mode -eq 'EntityTimeline') {
        $HeaderStep = New-WizardTextStep -Name 'SessionHeader' -Label 'Nagłówek sesji (### YYYY-MM-DD, Tytuł, Narrator)' -Required
        $SessionHeader = Invoke-WizardStep -Step $HeaderStep -State $State
        if ($SessionHeader -eq '__back__') { return }
    }

    $SgProg = New-ProgressState -Title 'Graf sesji' -TotalSteps 1
    Start-ProgressStep -State $SgProg -Label 'Zapytanie'

    try {
        $QueryParams = @{ Mode = $Mode; Quiet = $true }
        if ($EntityName)    { $QueryParams['EntityName'] = $EntityName }
        if ($SessionHeader) { $QueryParams['SessionHeader'] = $SessionHeader }

        $Result = Get-SessionGraph @QueryParams
        Complete-ProgressStep -State $SgProg -Detail 'OK'
        Complete-ProgressGroup -State $SgProg

        if ($Mode -eq 'Summary') {
            Write-Host ''
            Write-CLILine -Text "  Sesji ogółem:        $($Result.TotalSessions)" -Color $AccentColor
            Write-CLILine -Text "  Uczestników ogółem:  $($Result.TotalParticipants)" -Color $AccentColor
            Write-CLILine -Text "  Tier 0 (plik):       $($Result.Tier0Count)" -Color $AccentColor
            Write-CLILine -Text "  Tier 1 (metadane):   $($Result.Tier1Count)" -Color $AccentColor
            Write-CLILine -Text "  Tier 2 (tekst):      $($Result.Tier2Count)" -Color $AccentColor
            Write-Host ''
        }
        elseif (-not $Result -or $Result.Count -eq 0) {
            Write-CLILine -Text 'Brak wyników.' -Color $WarningColor
            Write-Host ''
        }
        elseif ($Mode -eq 'Sessions') {
            $TableData = @($Result).ForEach({
                [PSCustomObject]@{
                    Sesja  = $_.Header
                    Data   = $_.Date
                    Format = $_.Format
                    Tier   = $_.EntityTier
                    Waga   = if ($null -ne $_.EntityWeight) { $_.EntityWeight } else { '-' }
                }
            })
            $TableComponent = New-ResultTableComponent -Data @($TableData) `
                -Columns @('Data', 'Sesja', 'Format', 'Tier', 'Waga') `
                -Headers @('Data', 'Sesja', 'Format', 'Tier', 'Waga') `
                -Widths @(12, 35, 6, 5, 6) `
                -Title "Sesje: $EntityName"
            $SelectedRow = Invoke-EngineLifecycle -Component $TableComponent -State $State
            if ($SelectedRow -and $SelectedRow -ne '__back__' -and $SelectedRow -ne '__quit__') {
                Invoke-EngineDetailCard -Data $SelectedRow -Title 'Szczegóły sesji' -State $State
            }
        }
        elseif ($Mode -eq 'CoParticipants') {
            $TableData = @($Result).ForEach({
                [PSCustomObject]@{
                    Nazwa          = $_.Name
                    Typ            = if ($_.Type) { $_.Type } else { '-' }
                    WspólneSesje   = $_.SharedSessions
                }
            })
            $TableComponent = New-ResultTableComponent -Data @($TableData) `
                -Columns @('Nazwa', 'Typ', 'WspólneSesje') `
                -Headers @('Nazwa', 'Typ', 'Wspólne sesje') `
                -Widths @(25, 12, 14) `
                -Title "Współuczestnicy: $EntityName"
            $SelectedRow = Invoke-EngineLifecycle -Component $TableComponent -State $State
            if ($SelectedRow -and $SelectedRow -ne '__back__' -and $SelectedRow -ne '__quit__') {
                Invoke-EngineDetailCard -Data $SelectedRow -Title 'Szczegóły' -State $State
            }
        }
        elseif ($Mode -eq 'EntityTimeline') {
            $TableData = @($Result).ForEach({
                [PSCustomObject]@{
                    Nazwa  = $_.Name
                    Typ    = if ($_.Type) { $_.Type } else { '-' }
                    Tier   = $_.Tier
                    Źródło = if ($_.Source) { $_.Source } else { '-' }
                    Waga   = if ($null -ne $_.Weight) { $_.Weight } else { '-' }
                }
            })
            $TableComponent = New-ResultTableComponent -Data @($TableData) `
                -Columns @('Nazwa', 'Typ', 'Tier', 'Źródło', 'Waga') `
                -Headers @('Nazwa', 'Typ', 'Tier', 'Źródło', 'Waga') `
                -Widths @(25, 12, 5, 10, 6) `
                -Title "Uczestnicy sesji"
            $SelectedRow = Invoke-EngineLifecycle -Component $TableComponent -State $State
            if ($SelectedRow -and $SelectedRow -ne '__back__' -and $SelectedRow -ne '__quit__') {
                Invoke-EngineDetailCard -Data $SelectedRow -Title 'Szczegóły' -State $State
            }
        }
    }
    catch {
        Complete-ProgressStep -State $SgProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $SgProg
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
    }

    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}

# ── Dormancy Report Workflow ───────────────────────────────────────────────

function Invoke-DormancyReportWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-CLILine -Text 'Raport uśpionych encji' -Color $AccentColor
    Write-Host ''

    # Step 1: Threshold months
    $ThresholdStep = New-WizardTextStep -Name 'Threshold' -Label 'Próg nieaktywności (miesiące, domyślnie 6)'
    $ThresholdInput = Invoke-WizardStep -Step $ThresholdStep -State $State
    if ($ThresholdInput -eq '__back__') { return }

    $ThresholdMonths = 6
    if ($ThresholdInput -and $ThresholdInput -match '^\d+$') {
        $ThresholdMonths = [int]$ThresholdInput
    }

    # Step 2: Optional type filter
    $TypeComponent = New-WizardStepComponent -Label 'Filtr po typie (opcjonalny)' `
        -StepNumber 0 -TotalSteps 0 -StepType 'selection' `
        -Options @('Wszystkie', 'NPC', 'Grupa', 'Lokacja', 'Przedmiot', 'Postać')
    $TypeChoice = Invoke-EngineLifecycle -Component $TypeComponent -State $State
    if ($TypeChoice -eq '__quit__') { return '__quit__' }
    if ($TypeChoice -eq '__back__') { return }

    $Params = @{ ThresholdMonths = $ThresholdMonths; Quiet = $true }
    if ($TypeChoice -and $TypeChoice -ne 'Wszystkie') {
        $Params['Type'] = $TypeChoice
    }

    try {
        $Report = Get-DormancyReport @Params

        if (-not $Report -or $Report.Count -eq 0) {
            Write-Host ''
            Write-CLILine -Text 'Brak uśpionych encji przy progu ' -Color $DisabledColor -NoNewline
            Write-Host "$ThresholdMonths miesięcy."
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void][System.Console]::ReadKey($true)
            return
        }

        $TableComponent = New-ResultTableComponent -Data $Report `
            -Columns @('Name', 'Type', 'DaysDormant', 'LastActivity', 'LastSource') `
            -Headers @('Nazwa', 'Typ', 'Dni', 'Ostatnia aktywność', 'Źródło') `
            -Widths @(25, 12, 8, 15, 18) `
            -Title "Uśpione encje (próg: $ThresholdMonths mies.)"
        [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
    }
}

# ── Entity Delta Workflow ──────────────────────────────────────────────────

function Invoke-EntityDeltaWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-CLILine -Text 'Porównanie stanu encji' -Color $AccentColor
    Write-Host ''

    # Step 1: Pick entity via fuzzy search
    $Entity = Invoke-EngineFuzzySearch -Prompt 'Wybierz encję' -Source 'entities' -State $State
    if (-not $Entity) { return }

    # Step 2: FromDate
    $FromStep = New-WizardDateStep -Name 'FromDate' -Label 'Data „od"' -Required
    $FromDate = Invoke-WizardStep -Step $FromStep -State $State
    if (-not $FromDate -or $FromDate -eq '__back__') { return }

    # Step 3: ToDate
    $ToStep = New-WizardDateStep -Name 'ToDate' -Label 'Data „do"' -Required
    $ToDate = Invoke-WizardStep -Step $ToStep -State $State
    if (-not $ToDate -or $ToDate -eq '__back__') { return }

    try {
        $Delta = Get-EntityDelta -Name $Entity.Name -FromDate $FromDate -ToDate $ToDate -Quiet

        if (-not $Delta -or $Delta.Count -eq 0) {
            Write-Host ''
            Write-CLILine -Text "Brak zmian dla '$($Entity.Name)' w zadanym zakresie." -Color $DisabledColor
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
            [void][System.Console]::ReadKey($true)
            return
        }

        # Format Before/After for display (arrays → comma-joined)
        $DisplayData = [System.Collections.Generic.List[object]]::new($Delta.Count)
        foreach ($D in $Delta) {
            $BeforeStr = if ($D.Before -is [System.Collections.IList]) { $D.Before -join ', ' } elseif ($D.Before) { [string]$D.Before } else { '(brak)' }
            $AfterStr = if ($D.After -is [System.Collections.IList]) { $D.After -join ', ' } elseif ($D.After) { [string]$D.After } else { '(brak)' }
            $DisplayData.Add([PSCustomObject]@{
                Property = $D.Property
                Before   = $BeforeStr
                After    = $AfterStr
            })
        }

        $TableComponent = New-ResultTableComponent -Data @($DisplayData) `
            -Columns @('Property', 'Before', 'After') `
            -Headers @('Właściwość', 'Przed', 'Po') `
            -Widths @(18, 25, 25) `
            -Title "$($Entity.Name): $($FromDate.ToString('yyyy-MM-dd')) → $($ToDate.ToString('yyyy-MM-dd'))"
        [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
    }
}

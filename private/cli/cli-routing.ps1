<#
    .SYNOPSIS
    Menu routing layer for the Robot CLI - registry lookup, action dispatch,
    query execution, and engine-driven main/sub menu loops.

    .DESCRIPTION
    This file connects the menu registry (cli-registry.ps1) with the TUI engine
    (engine/) and wizard system (cli-wizard.ps1). Dot-sourced on demand.

    The routing layer owns the full dispatch lifecycle: looking up a registry
    entry by ID, choosing the correct execution path (Wizard auto-gen, Query
    table, or custom Workflow function), and managing breadcrumb navigation.
    Query-mode entries go through a multi-stage pipeline: optional filter
    wizard steps, core function call, ColumnResolver transforms, identity-hash
    mapping for O(1) detail lookups, then the engine table-detail loop.

    Invoke-EngineRender and Invoke-EngineCommand are the standard callbacks
    shared by all engine-driven views (menus, tables, detail cards). They
    compose the 4-region layout (TopBar, Content, FilterBar, StatusBar) and
    handle /h help overlay, /s search, and /r health dashboard commands.

    Refresh-NavState and Refresh-HealthChecks reload mutable state (entities,
    players, name index, health checks) with progress indicators, keeping
    the TUI responsive during long-running reloads. $script:SuppressWarnings
    is toggled during dispatch to prevent Write-RobotWarning stderr output
    from corrupting the TUI's cursor-positioned rendering.

    Helpers:
    - Get-MenuCategories:          returns ordered list of top-level menu names
    - Get-MenuItems:               returns items for a given category
    - Get-RegistryEntry:           finds registry entry by ID
    - Merge-PluginMenuItems:       merges plugin-declared menu items, categories, and help into CLI state
    - Invoke-MenuAction:           dispatches a menu item by ID (Wizard/Query/Workflow)
    - Invoke-QueryAction:          executes Query-mode: filter → run → table → detail card loop
    - Invoke-EngineRender:         standard engine render callback (TopBar + Content + Filter + StatusBar)
    - Invoke-EngineCommand:        standard command handler for /h, /s, /r palette commands
    - Invoke-EngineFuzzySearch:    engine-driven fuzzy picker using MenuListComponent with Resolve-Name fallback
    - Invoke-EngineDetailCard:     engine-driven detail card for a single data row
    - Show-SubMenu:                engine-driven items within a category (with Migracja phase injection)
    - Show-MainMenu:               engine-driven top-level category loop with refresh option
    - Refresh-NavState:            reloads entities, players, name index, and entity type index
    - Refresh-HealthChecks:        runs PU, currency, session integrity, and graph health checks
    - Get-MigrationMenuItems:      stub (overridden by cli-wizard-migration.ps1)
    - Invoke-MigrationPhaseAction: stub (overridden by cli-wizard-migration.ps1)
#>

# ── Menu Helper Functions ────────────────────────────────────────────────────

function Get-MenuCategories {
    return $script:MenuOrder
}

function Get-MenuItems {
    param([Parameter(Mandatory)] [string]$Category)

    $Items = [System.Collections.Generic.List[PSCustomObject]]::new()

    $CategoryEntries = $null
    if ($script:MenuRegistryByCategory -and $script:MenuRegistryByCategory.TryGetValue($Category, [ref]$CategoryEntries)) {
        foreach ($Entry in $CategoryEntries) {
            [void]$Items.Add([PSCustomObject]@{
                ID          = $Entry.ID
                Label       = $Entry.Label
                Description = if ($Entry.Description) { $Entry.Description } else { '' }
                RoleTag     = if ($Entry.Role) { $Entry.Role } else { $null }
                InfoText    = if ($Entry.InfoText) { $Entry.InfoText } else { $null }
                Disabled    = $false
            })
        }
    }

    return $Items
}

function Get-RegistryEntry {
    param([Parameter(Mandatory)] [string]$ID)
    $Entry = $null
    if ($script:MenuRegistryByID -and $script:MenuRegistryByID.TryGetValue($ID, [ref]$Entry)) {
        return $Entry
    }
    return $null
}

# ── Plugin Menu Merge ────────────────────────────────────────────────────────

function Merge-PluginMenuItems {
    # Plugins populate $script:PluginMenuCategories, $script:PluginMenuItems,
    # and $script:PluginHelpContent during robot.psm1 import. Each section
    # handles its own empty check because a plugin may provide any subset.

    # Categories must merge first so new menu items can reference them
    if ($script:PluginMenuCategories -and $script:PluginMenuCategories.Count -gt 0) {
        foreach ($Cat in $script:PluginMenuCategories) {
            if ($Cat -notin $script:MenuOrder) {
                $script:MenuOrder += $Cat
            }
        }
    }

    # Validate and merge menu items with collision detection
    if ($script:PluginMenuItems -and $script:PluginMenuItems.Count -gt 0) {

    # Build existing ID set to detect duplicate plugin IDs in O(1)
    $ExistingIDs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $script:MenuRegistry) {
        [void]$ExistingIDs.Add($Entry.ID)
    }

    foreach ($Item in $script:PluginMenuItems) {
        $PluginName = $Item['_PluginName']

        # Skip items missing mandatory schema fields
        if (-not $Item.ID -or -not $Item.Label -or -not $Item.Menu) {
            [System.Console]::Error.WriteLine(
                "[WARN Merge-PluginMenuItems] Plugin '$PluginName': menu item missing ID, Label, or Menu - skipped")
            continue
        }

        # Reject duplicate IDs to prevent silent overwrites
        if ($ExistingIDs.Contains($Item.ID)) {
            [System.Console]::Error.WriteLine(
                "[WARN Merge-PluginMenuItems] Plugin '$PluginName': menu ID '$($Item.ID)' already exists - skipped")
            continue
        }

        # Reject items referencing undefined categories
        if ($Item.Menu -notin $script:MenuOrder) {
            [System.Console]::Error.WriteLine(
                "[WARN Merge-PluginMenuItems] Plugin '$PluginName': menu category '$($Item.Menu)' not in MenuOrder - skipped")
            continue
        }

        # Each mode has required fields; missing ones prevent runtime errors
        $Mode = if ($Item.Mode) { $Item.Mode } else { 'Wizard' }
        $Valid = $true
        switch ($Mode) {
            'Wizard' {
                if (-not $Item.Function) {
                    [System.Console]::Error.WriteLine(
                        "[WARN Merge-PluginMenuItems] Plugin '$PluginName': Wizard item '$($Item.ID)' missing Function - skipped")
                    $Valid = $false
                }
            }
            'Workflow' {
                if (-not $Item.WorkflowFunction) {
                    [System.Console]::Error.WriteLine(
                        "[WARN Merge-PluginMenuItems] Plugin '$PluginName': Workflow item '$($Item.ID)' missing WorkflowFunction - skipped")
                    $Valid = $false
                }
            }
            'Query' {
                if (-not $Item.Columns -or -not $Item.Headers) {
                    [System.Console]::Error.WriteLine(
                        "[WARN Merge-PluginMenuItems] Plugin '$PluginName': Query item '$($Item.ID)' missing Columns or Headers - skipped")
                    $Valid = $false
                }
                elseif ($Item.Columns.Count -ne $Item.Headers.Count) {
                    [System.Console]::Error.WriteLine(
                        "[WARN Merge-PluginMenuItems] Plugin '$PluginName': Query item '$($Item.ID)' Columns/Headers count mismatch - skipped")
                    $Valid = $false
                }
            }
        }
        if (-not $Valid) { continue }

        $script:MenuRegistry += $Item
        [void]$ExistingIDs.Add($Item.ID)
        # Keep ByID/ByCategory indexes in sync with the flat array
        $script:MenuRegistryByID[$Item.ID] = $Item
        if (-not $script:MenuRegistryByCategory.ContainsKey($Item.Menu)) {
            $script:MenuRegistryByCategory[$Item.Menu] = [System.Collections.Generic.List[hashtable]]::new()
        }
        [void]$script:MenuRegistryByCategory[$Item.Menu].Add($Item)
    }

    } # end if PluginMenuItems

    # Merge help content (appends to existing categories, creates new ones)
    if ($script:PluginHelpContent -and $script:PluginHelpContent.Count -gt 0) {
        foreach ($HelpKey in $script:PluginHelpContent.Keys) {
            foreach ($HelpEntry in $script:PluginHelpContent[$HelpKey]) {
                if ($script:HelpContent.ContainsKey($HelpKey)) {
                    # Extend existing help topic with plugin-provided lines
                    if ($HelpEntry.Body) {
                        $script:HelpContent[$HelpKey].Body += @('')
                        $script:HelpContent[$HelpKey].Body += $HelpEntry.Body
                    }
                }
                else {
                    # New help topic: requires both Title and Body
                    if ($HelpEntry.Title -and $HelpEntry.Body) {
                        $script:HelpContent[$HelpKey] = @{
                            Title = $HelpEntry.Title
                            Body  = [string[]]$HelpEntry.Body
                        }
                    }
                    else {
                        [System.Console]::Error.WriteLine(
                            "[WARN Merge-PluginMenuItems] Plugin '$($HelpEntry._PluginName)': help for '$HelpKey' missing Title or Body")
                    }
                }
            }
        }
    }
}

# ── Action Dispatch ──────────────────────────────────────────────────────────

function Invoke-MenuAction {
    param(
        [Parameter(Mandatory)] [string]$ItemID,
        [Parameter(Mandatory)] [object]$State
    )

    $Entry = Get-RegistryEntry -ID $ItemID
    if (-not $Entry) {
        Write-CLILine -Text "Nieznana akcja: $ItemID" -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
        return
    }

    # Suppress module-level Write-RobotWarning calls during CLI dispatch
    # because stderr output corrupts the TUI's cursor-positioned rendering.
    $script:SuppressWarnings = $true
    try {

    $Mode = if ($Entry.Mode) { $Entry.Mode } else { 'Wizard' }

    switch ($Mode) {
        'Wizard' {
            if (-not $Entry.Function) {
                Write-CLILine -Text 'Nie zaimplementowano.' -Color (Get-CLIColor -Role 'Disabled')
                Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
                [void][System.Console]::ReadKey($true)
                return
            }
            $WizResult = Invoke-Wizard -RegistryEntry $Entry -State $State
            if ($WizResult -eq '__quit__') { return '__quit__' }
        }

        'Query' {
            $QueryResult = Invoke-QueryAction -Entry $Entry -State $State
            if ($QueryResult -eq '__quit__') { return '__quit__' }
        }

        'Workflow' {
            $WorkflowFn = $Entry.WorkflowFunction
            if (-not $WorkflowFn -or -not (Get-Command $WorkflowFn -ErrorAction SilentlyContinue)) {
                Write-CLILine -Text 'Nie zaimplementowano.' -Color (Get-CLIColor -Role 'Disabled')
                Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
                [void][System.Console]::ReadKey($true)
                return
            }

            # Show pre-checks if defined
            if ($Entry.PreChecks) {
                Show-InfoBox -Checks $Entry.PreChecks
            }

            $WfResult = & $WorkflowFn -State $State -Entry $Entry
            if ($WfResult -eq '__quit__') { return '__quit__' }
        }
    }

    } finally { $script:SuppressWarnings = $false }
}

# ── Query Action ─────────────────────────────────────────────────────────────

function Invoke-QueryAction {
    param(
        [Parameter(Mandatory)] [hashtable]$Entry,
        [Parameter(Mandatory)] [object]$State
    )

    $FunctionName = $Entry.Function
    if (-not $FunctionName -or -not (Get-Command $FunctionName -ErrorAction SilentlyContinue)) {
        Write-CLILine -Text "Funkcja '$FunctionName' nie jest dostępna." -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
        return
    }

    # Collect optional filter parameters via wizard steps before running the query
    $FilterParams = @{}

    if ($Entry.FilterOverrides) {
        foreach ($FilterKey in $Entry.FilterOverrides.Keys) {
            $FilterDef = $Entry.FilterOverrides[$FilterKey]
            $FilterStep = [PSCustomObject]@{
                Name     = $FilterKey
                Label    = if ($FilterDef.Label) { $FilterDef.Label } else { $FilterKey }
                StepType = if ($FilterDef.Type) { $FilterDef.Type } else { 'text' }
                Required = if ($null -ne $FilterDef.Required) { $FilterDef.Required } else { $false }
                Source   = if ($FilterDef.Source) { $FilterDef.Source } else { $null }
                Options  = if ($FilterDef.Options) { $FilterDef.Options } else { $null }
                SubSteps = $null
                EntrySource = $null
                Condition = $null
                Transform = $null
                Default   = $null
            }

            $Result = Invoke-WizardStep -Step $FilterStep -State $State
            if ($Result -eq '__back__') { return }
            if ($null -ne $Result -and $Result -ne '') {
                $FilterParams[$FilterKey] = $Result
            }
        }
    }

    # Default MinDate to 3 months ago to keep query results manageable.
    # Without a date floor, some queries (e.g. Get-Session) would process
    # the entire campaign history on every invocation.
    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if ($Cmd -and $Cmd.Parameters.ContainsKey('MinDate') -and -not $FilterParams.ContainsKey('MinDate')) {
        $FilterParams['MinDate'] = (Get-Date).AddMonths(-3)
    }

    # Execute the core query function with collected parameters
    Write-Host "  Pobieranie danych..." -ForegroundColor (Get-CLIColor -Role 'Disabled')

    try {
        $QueryResult = & $FunctionName @FilterParams

        if (-not $QueryResult -or $QueryResult.Count -eq 0) {
            Write-CLILine -Text 'Brak wyników.' -Color (Get-CLIColor -Role 'Disabled')
            Write-Host ''
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void][System.Console]::ReadKey($true)
            return
        }

        $Columns = if ($Entry.Columns) { $Entry.Columns } else { @('Name') }
        $Headers = if ($Entry.Headers) { $Entry.Headers } else { $Columns }
        $Widths  = if ($Entry.Widths) { $Entry.Widths } else { $null }

        # DataTransform extracts the relevant sub-array from complex return objects
        if ($Entry.DataTransform) {
            $QueryResult = & $Entry.DataTransform $QueryResult
            if (-not $QueryResult -or $QueryResult.Count -eq 0) {
                Write-CLILine -Text 'Brak wyników.' -Color (Get-CLIColor -Role 'Disabled')
                Write-Host ''
                Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
                [void][System.Console]::ReadKey($true)
                return
            }
        }

        # Preserve pre-transform data so detail cards show all fields, not just table columns
        $OriginalData = $QueryResult

        # ColumnResolvers produce computed display values (e.g. formatted dates, joined lists)
        if ($Entry.ColumnResolvers -and $Entry.ColumnResolvers.Count -gt 0) {
            # Partition columns once to avoid per-row dictionary lookups
            $ResolvedCols = [System.Collections.Generic.List[object]]::new()
            $PassthroughCols = [System.Collections.Generic.List[string]]::new()
            foreach ($ColName in $Columns) {
                if ($Entry.ColumnResolvers.ContainsKey($ColName)) {
                    [void]$ResolvedCols.Add(@{ Name = $ColName; Resolver = $Entry.ColumnResolvers[$ColName] })
                } else {
                    [void]$PassthroughCols.Add($ColName)
                }
            }

            $TransformedData = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($Row in $QueryResult) {
                $Props = [ordered]@{}
                foreach ($RC in $ResolvedCols) {
                    $Props[$RC.Name] = & $RC.Resolver $Row
                }
                foreach ($PC in $PassthroughCols) {
                    $Props[$PC] = if ($Row.PSObject.Properties[$PC]) { $Row.$PC } else { '' }
                }
                [void]$TransformedData.Add([PSCustomObject]$Props)
            }
            $QueryResult = $TransformedData.ToArray()
        }

        # Map reference identity hash → array index for O(1) detail card lookups.
        # The table component returns the transformed row object; this map lets us
        # find the corresponding original (pre-transform) row by reference identity
        # without linear scan on every Enter press.
        $IdMap = [System.Collections.Generic.Dictionary[int,int]]::new($QueryResult.Count)
        for ($I = 0; $I -lt $QueryResult.Count; $I++) {
            $IdMap[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($QueryResult[$I])] = $I
        }

        # Engine-driven table/detail card loop: Enter on a row opens its detail card
        [void]$State.BreadcrumbStack.Push($Entry.Label)
        $QuitRequested = $false

        while ($true) {
            $TableComponent = New-ResultTableComponent -Data $QueryResult `
                -Columns $Columns -Headers $Headers -Widths $Widths `
                -Title $Entry.Label `
                -ColumnPriority $(if ($Entry.ColumnPriority) { $Entry.ColumnPriority } else { $null }) `
                -FilterPrefixes $(if ($Entry.FilterPrefixes) { $Entry.FilterPrefixes } else { $null })

            # Attach entry-level help so /h shows context-specific documentation
            if ($Entry.HelpFull) {
                $TableComponent.HelpContent = $Entry.HelpFull
                $TableComponent.HelpTitle = $Entry.Label
            }

            $ScreenOK = Initialize-Screen -State $State
            if (-not $ScreenOK) {
                [void][System.Console]::ReadKey($true)
                break
            }

            Initialize-Buffers
            $RenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
            $CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }

            & $RenderCB $State $TableComponent
            Render-FullBuffer

            try {
                $SelectedRow = Start-InputLoop -State $State -Component $TableComponent `
                    -RenderCallback $RenderCB -CommandHandler $CmdHandler
            } finally {
                Restore-Cursor
            }

            if ($SelectedRow -eq '__quit__') { $QuitRequested = $true; break }
            if ($SelectedRow -eq '__back__') { break }
            if (-not $SelectedRow) { break }

            # Reverse-map transformed row to original data via identity hash (O(1))
            $RowIdx = -1
            $SelHash = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($SelectedRow)
            if ($IdMap.ContainsKey($SelHash)) { $RowIdx = $IdMap[$SelHash] }
            $OriginalRow = if ($RowIdx -ge 0 -and $RowIdx -lt $OriginalData.Count) { $OriginalData[$RowIdx] } else { $SelectedRow }

            # Custom detail functions override the generic key-value card (e.g. entity/player cards)
            if ($Entry.DetailFunction -and (Get-Command $Entry.DetailFunction -ErrorAction SilentlyContinue)) {
                [void]$State.BreadcrumbStack.Push('Szczegóły')
                try {
                    & $Entry.DetailFunction -Row $OriginalRow -State $State
                } finally {
                    [void]$State.BreadcrumbStack.Pop()
                }
            }
            else {
                Invoke-EngineDetailCard -Data $OriginalRow -Title $Entry.Label -State $State
            }
        }

        [void]$State.BreadcrumbStack.Pop()
        if ($QuitRequested) { return '__quit__' }
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
    }
}

# ── Engine Helpers ──────────────────────────────────────────────────────────

# Composes the 4-region engine layout in a single pass for diff-based rendering
function Invoke-EngineRender {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [object]$Component
    )
    Render-TopBar -State $State
    & $Component.Render $State $Component
    Render-FilterBar -State $State -Component $Component
    Render-StatusBar -Component $Component
}

# Handles /h (help), /s (search), /r (health dashboard) palette commands.
# Each spawns a nested engine view on top of the current component.
function Invoke-EngineCommand {
    param(
        [Parameter(Mandatory)] [object]$CmdAction,
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [object]$Component,
        [scriptblock]$RenderCallback
    )

    # Overlay callback skips TopBar because overlays render on top of existing chrome
    $OverlayCB = {
        param($S, $C)
        & $C.Render $S $C
        Render-FilterBar -State $S -Component $C
        Render-StatusBar -Component $C
    }

    switch ($CmdAction.Type) {
        'Help' {
            $HelpBody = $Component.HelpContent
            if ($HelpBody -and $HelpBody.Count -gt 0) {
                $HelpTitle = if ($Component.HelpTitle) { $Component.HelpTitle } else { 'Pomoc' }
                $Overlay = New-HelpOverlayComponent -Title $HelpTitle -Content $HelpBody
                & $OverlayCB $State $Overlay
                Render-BufferDiff
                $OverlayResult = Start-InputLoop -State $State -Component $Overlay -RenderCallback $OverlayCB
                if ($OverlayResult -eq '__quit__') { return '__quit__' }
            }
        }

        'HelpSearch' {
            # Full-text search across all registry help entries
            $Results = Search-HelpTopics -Query $CmdAction.Value -Registry $script:MenuRegistry
            if ($Results -and $Results.Count -gt 0) {
                $Lines = [System.Collections.Generic.List[string]]::new()
                foreach ($R in $Results) {
                    [void]$Lines.Add("$([char]0x25B8) $($R.Label)")
                    foreach ($CLine in $R.Context) {
                        [void]$Lines.Add("  $CLine")
                    }
                    [void]$Lines.Add('')
                }
                $Overlay = New-HelpOverlayComponent -Title "Wyniki: $($CmdAction.Value)" -Content @($Lines)
            } else {
                $Overlay = New-HelpOverlayComponent -Title 'Szukaj' -Content @('Brak wynikow dla zapytania.')
            }
            & $OverlayCB $State $Overlay
            Render-BufferDiff
            $OverlayResult = Start-InputLoop -State $State -Component $Overlay -RenderCallback $OverlayCB
            if ($OverlayResult -eq '__quit__') { return '__quit__' }
        }

        'HealthDashboard' {
            $Dashboard = New-HealthDashboardComponent -State $State
            $DashRenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
            & $DashRenderCB $State $Dashboard
            Render-BufferDiff
            $DashResult = Start-InputLoop -State $State -Component $Dashboard -RenderCallback $DashRenderCB
            if ($DashResult -eq '__quit__') { return '__quit__' }
        }

        'Refresh' {
            Refresh-NavState -State $State
        }
    }
}

# ── Engine Fuzzy Search ────────────────────────────────────────────────────

# Fuzzy picker: builds a MenuListComponent from source candidates, with
# a FuzzyCallback that falls back to Resolve-Name (declension + BK-tree)
# for matches the engine's prefix/contains filter missed.
function Invoke-EngineFuzzySearch {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [object]$State
    )

    $AllCandidates = Get-FuzzySearchCandidates -Source $Source -State $State
    if ($AllCandidates.Count -eq 0) { return $null }

    # Map sequential string IDs to candidate objects for post-selection reverse lookup
    $CandidateMap = @{}

    # Wrap candidates as MenuListComponent items (ID, Label, Description)
    $MenuItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    for ($I = 0; $I -lt $AllCandidates.Count; $I++) {
        $C = $AllCandidates[$I]
        $ItemID = [string]$I
        $CandidateMap[$ItemID] = $C
        [void]$MenuItems.Add([PSCustomObject]@{
            ID          = $ItemID
            Label       = $C.DisplayText
            Description = $C.Type
            RoleTag     = $null
            InfoText    = $null
            Disabled    = $false
        })
    }

    # FuzzyCallback: for items the engine's prefix/contains filter missed,
    # try Resolve-Name (declension stripping + BK-tree edit distance).
    $FuzzyCB = {
        param([string]$Query, [object[]]$Remaining)

        if ($Query.Length -lt 3) { return @() }
        if (-not $State.NameIndex) { return @() }

        $Resolved = Resolve-Name -Query $Query `
            -Index $State.NameIndex.Index `
            -StemIndex $State.NameIndex.StemIndex `
            -BKTree $State.NameIndex.BKTree `
            -Cache $State.ResolveCache

        if (-not $Resolved) { return @() }

        $ResolvedName = if ($Resolved.Name) { $Resolved.Name } else { [string]$Resolved }

        $FuzzyMatches = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in $Remaining) {
            if ($Item.Label.IndexOf($ResolvedName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$FuzzyMatches.Add($Item)
            }
        }
        return @($FuzzyMatches)
    }.GetNewClosure()

    $Component = New-MenuListComponent -Items $MenuItems -ShowBack -FuzzyCallback $FuzzyCB `
        -HelpContent @("Wpisz aby filtrować  |  Enter wybierz  |  Esc anuluj")

    $ScreenOK = Initialize-Screen -State $State
    if (-not $ScreenOK) {
        [void][System.Console]::ReadKey($true)
        return $null
    }

    Initialize-Buffers

    # Standard 4-region render (prompt is shown via TopBar breadcrumb)
    $RenderCB = {
        param($S, $C)
        Render-TopBar -State $S
        & $C.Render $S $C
        Render-FilterBar -State $S -Component $C
        Render-StatusBar -Component $C
    }
    $CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }

    & $RenderCB $State $Component
    Render-FullBuffer

    try {
        $SelectedID = Start-InputLoop -State $State -Component $Component `
            -RenderCallback $RenderCB -CommandHandler $CmdHandler
    } finally {
        Restore-Cursor
    }

    if ($SelectedID -eq '__back__' -or $SelectedID -eq '__quit__' -or -not $SelectedID) {
        return $null
    }

    # Reverse-map selected menu ID back to the original candidate object
    if ($CandidateMap.ContainsKey($SelectedID)) {
        return $CandidateMap[$SelectedID]
    }

    return $null
}

# ── Engine Detail Card ─────────────────────────────────────────────────────

# Shows a read-only key-value card for a data row, managed by the engine lifecycle.
function Invoke-EngineDetailCard {
    param(
        [Parameter(Mandatory)] [object]$Data,
        [string]$Title,
        [Parameter(Mandatory)] [object]$State
    )

    $BreadcrumbLabel = if ($Title) { $Title } else { 'Szczegóły' }
    [void]$State.BreadcrumbStack.Push($BreadcrumbLabel)

    $Component = New-DetailCardComponent -Data $Data -Title $Title

    $ScreenOK = Initialize-Screen -State $State
    if (-not $ScreenOK) {
        [void][System.Console]::ReadKey($true)
        [void]$State.BreadcrumbStack.Pop()
        return
    }

    Initialize-Buffers
    $RenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
    $CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }

    & $RenderCB $State $Component
    Render-FullBuffer

    try {
        $null = Start-InputLoop -State $State -Component $Component `
            -RenderCallback $RenderCB -CommandHandler $CmdHandler
    } finally {
        Restore-Cursor
        [void]$State.BreadcrumbStack.Pop()
    }
}

# ── Main Menu & SubMenu (engine-driven) ────────────────────────────────────

function Show-SubMenu {
    param(
        [Parameter(Mandatory)] [string]$Category,
        [Parameter(Mandatory)] [object]$State
    )

    [void]$State.BreadcrumbStack.Push($Category)

    while ($true) {
        $Items = Get-MenuItems -Category $Category

        # Migracja category injects dynamic phase items before static registry entries
        if ($Category -eq 'Migracja') {
            $MigrationItems = Get-MigrationMenuItems -State $State
            if ($MigrationItems -and $MigrationItems.Count -gt 0) {
                $AllItems = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($MI in $MigrationItems) { [void]$AllItems.Add($MI) }
                foreach ($SI in $Items) { [void]$AllItems.Add($SI) }
                $Items = $AllItems
            }
        }

        $HelpEntry = $script:HelpContent[$Category]
        $HelpBody = if ($HelpEntry) { $HelpEntry.Body } else { $null }
        $HelpTitle = if ($HelpEntry) { $HelpEntry.Title } else { $null }

        $Component = New-MenuListComponent -Items $Items -ShowBack `
            -HelpContent $HelpBody -HelpTitle $HelpTitle

        $ScreenOK = Initialize-Screen -State $State
        if (-not $ScreenOK) {
            [void][System.Console]::ReadKey($true)
            [void]$State.BreadcrumbStack.Pop()
            return
        }

        Initialize-Buffers
        $RenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
        $CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }

        & $RenderCB $State $Component
        Render-FullBuffer

        try {
            $Selected = Start-InputLoop -State $State -Component $Component `
                -RenderCallback $RenderCB -CommandHandler $CmdHandler
        } finally {
            Restore-Cursor
        }

        if ($Selected -eq '__back__') {
            [void]$State.BreadcrumbStack.Pop()
            return
        }

        if ($Selected -eq '__quit__') {
            [void]$State.BreadcrumbStack.Pop()
            return '__quit__'
        }

        # Migration phase IDs use a prefix convention to distinguish from registry IDs
        if ($Selected -is [string] -and $Selected.StartsWith('migration-phase-')) {
            Invoke-MigrationPhaseAction -PhaseID $Selected -State $State
            continue
        }

        $ActionResult = Invoke-MenuAction -ItemID $Selected -State $State
        if ($ActionResult -eq '__quit__') {
            [void]$State.BreadcrumbStack.Pop()
            return '__quit__'
        }
    }
}

function Show-MainMenu {
    param([Parameter(Mandatory)] [object]$State)

    while ($true) {
        # Build category list with sub-item counts for the main menu display
        $CategoryItems = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($Cat in $script:MenuOrder) {
            $CatList = $null
            $SubCount = if ($script:MenuRegistryByCategory -and $script:MenuRegistryByCategory.TryGetValue($Cat, [ref]$CatList)) { $CatList.Count } else { 0 }
            [void]$CategoryItems.Add([PSCustomObject]@{
                ID          = $Cat
                Label       = $Cat
                Description = "$SubCount opcji"
                RoleTag     = $null
                InfoText    = $null
                Disabled    = $false
            })
        }

        # Append synthetic refresh item (not in registry, handled by ID convention)
        [void]$CategoryItems.Add([PSCustomObject]@{
            ID          = '__refresh__'
            Label       = [string][char]0x21BB + ' Odswiez dane'
            Description = 'Przeladuj encje, graczy i indeks nazw'
            RoleTag     = $null
            InfoText    = $null
            Disabled    = $false
        })

        $RootHelp = $script:HelpContent['root']
        $HelpBody = if ($RootHelp) { $RootHelp.Body } else { $null }
        $HelpTitle = if ($RootHelp) { $RootHelp.Title } else { $null }

        $Component = New-MenuListComponent -Items $CategoryItems `
            -HelpContent $HelpBody -HelpTitle $HelpTitle

        $ScreenOK = Initialize-Screen -State $State
        if (-not $ScreenOK) {
            [void][System.Console]::ReadKey($true)
            return
        }

        Initialize-Buffers
        $RenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
        $CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }

        & $RenderCB $State $Component
        Render-FullBuffer

        try {
            $Selected = Start-InputLoop -State $State -Component $Component `
                -RenderCallback $RenderCB -CommandHandler $CmdHandler
        } finally {
            Restore-Cursor
        }

        if ($Selected -eq '__back__' -or $Selected -eq '__quit__') {
            Write-Host ''
            Write-CLILine -Text 'Do zobaczenia!' -Color (Get-CLIColor -Role 'Accent')
            Write-Host ''
            return
        }

        if ($Selected -eq '__refresh__') {
            Refresh-NavState -State $State
            continue
        }

        # Navigate into submenu; propagate __quit__ to exit the entire CLI
        $SubResult = Show-SubMenu -Category $Selected -State $State
        if ($SubResult -eq '__quit__') {
            Write-Host ''
            Write-CLILine -Text 'Do zobaczenia!' -Color (Get-CLIColor -Role 'Accent')
            Write-Host ''
            return
        }
    }
}

# ── Migration Menu Items (stub - overridden by cli-wizard-migration.ps1) ────

function Get-MigrationMenuItems {
    param([object]$State)
    # Stub: replaced at runtime by cli-wizard-migration.ps1 when the migration module is loaded
    return @()
}

# ── Refresh-NavState ─────────────────────────────────────────────────────────

function Refresh-NavState {
    param([Parameter(Mandatory)] [object]$State)

    $Progress = New-ProgressState -Title 'Odświeżanie danych' -TotalSteps 4

    Start-ProgressStep -State $Progress -Label 'Encje'
    $State.Entities = Get-Entity -Quiet
    Complete-ProgressStep -State $Progress -Detail "$($State.Entities.Count)"

    Start-ProgressStep -State $Progress -Label 'Gracze'
    $State.Players  = Get-Player
    Complete-ProgressStep -State $Progress -Detail "$($State.Players.Count)"

    Start-ProgressStep -State $Progress -Label 'Indeks nazw'
    $State.NameIndex = Get-NameIndex -Players $State.Players -Entities $State.Entities
    Complete-ProgressStep -State $Progress -Detail "$($State.NameIndex.Count) wpisów"

    $State.ResolveCache = @{}

    # Rebuild type-keyed index for O(1) entity filtering by type in CLI workflows
    Start-ProgressStep -State $Progress -Label 'Indeks typów'
    $TypeIdx = @{}
    foreach ($E in $State.Entities) {
        if (-not $TypeIdx.ContainsKey($E.Type)) {
            $TypeIdx[$E.Type] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$TypeIdx[$E.Type].Add($E)
    }
    $State.EntityTypeIndex = $TypeIdx
    Complete-ProgressStep -State $Progress -Detail "$($TypeIdx.Count) typów"

    Complete-ProgressGroup -State $Progress
}

function Refresh-HealthChecks {
    param([Parameter(Mandatory)] [object]$State)

    $HC = $State.HealthCache
    $HC.CheckedAt = Get-Date
    $HC.Errors = @()
    $HC.Skipped = $false

    $Progress = New-ProgressState -Title 'Sprawdzanie stanu systemu' -TotalSteps 6

    # Suppress non-terminating errors during health checks — internal calls
    # emit warnings/errors that would corrupt the TUI cursor positioning.
    $PrevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    Start-ProgressStep -State $Progress -Label 'Sesje'
    $SessCB = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
    $SharedSessions = Get-Session -Quiet -Entities $State.Entities -Players $State.Players -NameIndex $State.NameIndex -ProgressCallback $SessCB
    Complete-ProgressStep -State $Progress -Detail "$($SharedSessions.Count)"

    Start-ProgressStep -State $Progress -Label 'Stan encji'
    $EntCB = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
    $SharedEntityState = Get-EntityState -Quiet `
        -Entities $State.Entities -Sessions $SharedSessions `
        -Players $State.Players -NameIndex $State.NameIndex `
        -ProgressCallback $EntCB
    Complete-ProgressStep -State $Progress

    Start-ProgressStep -State $Progress -Label 'Walidacja PU'
    $PUCB = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
    try { $HC.PU = Test-PlayerCharacterPUAssignment -Quiet -AllSessions $SharedSessions -ProgressCallback $PUCB
          Complete-ProgressStep -State $Progress -Detail 'OK' }
    catch { $HC.Errors += "PU: $($_.Exception.Message)"
            Complete-ProgressStep -State $Progress -Detail 'BŁĄD' -Failed }

    Start-ProgressStep -State $Progress -Label 'Walidacja walut'
    $CurCB = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
    try { $HC.Currency = Test-CurrencyReconciliation -Quiet -Entities $SharedEntityState -Sessions $SharedSessions -ProgressCallback $CurCB
          Complete-ProgressStep -State $Progress -Detail 'OK' }
    catch { $HC.Errors += "Waluta: $($_.Exception.Message)"
            Complete-ProgressStep -State $Progress -Detail 'BŁĄD' -Failed }

    Start-ProgressStep -State $Progress -Label 'Integralność sesji'
    $IntCB = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
    try { $HC.Integrity = Test-SessionIntegrity -Quiet -Since (Get-Date).AddMonths(-2) -ProgressCallback $IntCB
          Complete-ProgressStep -State $Progress -Detail 'OK' }
    catch { $HC.Errors += "Sesje: $($_.Exception.Message)"
            Complete-ProgressStep -State $Progress -Detail 'BŁĄD' -Failed }

    Start-ProgressStep -State $Progress -Label 'Graf sesji'
    $GrCB = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
    try { $HC.Graph = Test-SessionGraphIntegrity -Quiet -Sessions $SharedSessions -NameIndex $State.NameIndex -ProgressCallback $GrCB
          Complete-ProgressStep -State $Progress -Detail 'OK' }
    catch { $HC.Errors += "Graf: $($_.Exception.Message)"
            Complete-ProgressStep -State $Progress -Detail 'BŁĄD' -Failed }

    $ErrorActionPreference = $PrevEAP

    Complete-ProgressGroup -State $Progress
}

function Invoke-MigrationPhaseAction {
    param([string]$PhaseID, [object]$State)
    [System.Console]::Clear()
    Write-CLILine -Text 'Migracja nie jest załadowana.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

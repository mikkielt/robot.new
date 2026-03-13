<#
    .SYNOPSIS
    Menu routing layer for the Robot CLI - registry lookup, action dispatch,
    query execution, and engine-driven main/sub menu loops.

    .DESCRIPTION
    This file connects the menu registry (cli-registry.ps1) with the TUI engine
    (engine/) and wizard system (cli-wizard.ps1). Dot-sourced on demand.

    Helpers:
    - Get-MenuCategories:          returns ordered list of top-level menu names
    - Get-MenuItems:               returns items for a given category
    - Get-RegistryEntry:           finds registry entry by ID
    - Merge-PluginMenuItems:       merges plugin-declared menu items, categories, and help into CLI state
    - Invoke-MenuAction:           dispatches a menu item by ID (Wizard/Query/Workflow)
    - Invoke-QueryAction:          executes Query-mode: filter → run → table → detail
    - Invoke-EngineRender:         standard engine render callback (TopBar + Content + Filter + StatusBar)
    - Invoke-EngineCommand:        standard command handler for /h, /s, /r palette commands
    - Invoke-EngineFuzzySearch:    engine-driven fuzzy picker using MenuListComponent
    - Invoke-EngineDetailCard:     engine-driven detail card for a single data row
    - Show-SubMenu:                engine-driven items within a category
    - Show-MainMenu:               engine-driven top-level category loop
    - Refresh-NavState:            reloads entities, players, and name index (moved from cli-display.ps1)
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

    foreach ($Entry in $script:MenuRegistry) {
        if ($Entry.Menu -ne $Category) { continue }

        [void]$Items.Add([PSCustomObject]@{
            ID          = $Entry.ID
            Label       = $Entry.Label
            Description = if ($Entry.Description) { $Entry.Description } else { '' }
            RoleTag     = if ($Entry.Role) { $Entry.Role } else { $null }
            InfoText    = if ($Entry.InfoText) { $Entry.InfoText } else { $null }
            Disabled    = $false
        })
    }

    return $Items
}

function Get-RegistryEntry {
    param([Parameter(Mandatory)] [string]$ID)
    foreach ($Entry in $script:MenuRegistry) {
        if ($Entry.ID -eq $ID) { return $Entry }
    }
    return $null
}

# ── Plugin Menu Merge ────────────────────────────────────────────────────────

function Merge-PluginMenuItems {
    # Read module-scoped plugin data set during robot.psm1 import.
    # Each section handles its own empty check - a plugin may provide only
    # help content, only menu items, or only categories.

    # Merge categories first (so menu items can reference them)
    if ($script:PluginMenuCategories -and $script:PluginMenuCategories.Count -gt 0) {
        foreach ($Cat in $script:PluginMenuCategories) {
            if ($Cat -notin $script:MenuOrder) {
                $script:MenuOrder += $Cat
            }
        }
    }

    # Merge menu items
    if ($script:PluginMenuItems -and $script:PluginMenuItems.Count -gt 0) {

    # Build existing ID set for collision detection
    $ExistingIDs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $script:MenuRegistry) {
        [void]$ExistingIDs.Add($Entry.ID)
    }

    foreach ($Item in $script:PluginMenuItems) {
        $PluginName = $Item['_PluginName']

        # Validate required fields
        if (-not $Item.ID -or -not $Item.Label -or -not $Item.Menu) {
            [System.Console]::Error.WriteLine(
                "[WARN Merge-PluginMenuItems] Plugin '$PluginName': menu item missing ID, Label, or Menu - skipped")
            continue
        }

        # ID collision
        if ($ExistingIDs.Contains($Item.ID)) {
            [System.Console]::Error.WriteLine(
                "[WARN Merge-PluginMenuItems] Plugin '$PluginName': menu ID '$($Item.ID)' already exists - skipped")
            continue
        }

        # Category validation
        if ($Item.Menu -notin $script:MenuOrder) {
            [System.Console]::Error.WriteLine(
                "[WARN Merge-PluginMenuItems] Plugin '$PluginName': menu category '$($Item.Menu)' not in MenuOrder - skipped")
            continue
        }

        # Mode-specific validation
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
    }

    } # end if PluginMenuItems

    # Merge help content
    if ($script:PluginHelpContent -and $script:PluginHelpContent.Count -gt 0) {
        foreach ($HelpKey in $script:PluginHelpContent.Keys) {
            foreach ($HelpEntry in $script:PluginHelpContent[$HelpKey]) {
                if ($script:HelpContent.ContainsKey($HelpKey)) {
                    # Append body lines to existing category help
                    if ($HelpEntry.Body) {
                        $script:HelpContent[$HelpKey].Body += @('')
                        $script:HelpContent[$HelpKey].Body += $HelpEntry.Body
                    }
                }
                else {
                    # New category: add full help entry
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

    # Suppress warnings during CLI dispatch to prevent stderr output from
    # corrupting the interactive menu display (overlay/redraw issue).
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

    # Collect filter parameters if defined
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

    # Apply smart defaults for date-based queries
    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if ($Cmd -and $Cmd.Parameters.ContainsKey('MinDate') -and -not $FilterParams.ContainsKey('MinDate')) {
        # Default: last 3 months
        $FilterParams['MinDate'] = (Get-Date).AddMonths(-3)
    }

    # Execute query
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

        # Apply DataTransform if defined (extracts sub-array from complex objects)
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

        # Keep original data for detail card (before column transformation)
        $OriginalData = $QueryResult

        # Apply ColumnResolvers for computed columns
        if ($Entry.ColumnResolvers -and $Entry.ColumnResolvers.Count -gt 0) {
            $TransformedData = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($Row in $QueryResult) {
                $Props = [ordered]@{}
                foreach ($ColName in $Columns) {
                    if ($Entry.ColumnResolvers.ContainsKey($ColName)) {
                        $Props[$ColName] = & $Entry.ColumnResolvers[$ColName] $Row
                    }
                    elseif ($Row.PSObject.Properties[$ColName]) {
                        $Props[$ColName] = $Row.$ColName
                    }
                    else {
                        $Props[$ColName] = ''
                    }
                }
                [void]$TransformedData.Add([PSCustomObject]$Props)
            }
            $QueryResult = $TransformedData.ToArray()
        }

        # Engine-driven table → detail card loop
        [void]$State.BreadcrumbStack.Push($Entry.Label)
        $QuitRequested = $false

        while ($true) {
            $TableComponent = New-ResultTableComponent -Data $QueryResult `
                -Columns $Columns -Headers $Headers -Widths $Widths `
                -Title $Entry.Label `
                -ColumnPriority $(if ($Entry.ColumnPriority) { $Entry.ColumnPriority } else { $null }) `
                -FilterPrefixes $(if ($Entry.FilterPrefixes) { $Entry.FilterPrefixes } else { $null })

            # Wire entry-level help for /h overlay
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

            # Map selected row back to original data for detail card
            $RowIdx = -1
            $TableData = $TableComponent.Data
            for ($I = 0; $I -lt $TableData.Count; $I++) {
                if ([object]::ReferenceEquals($TableData[$I], $SelectedRow)) {
                    $RowIdx = $I; break
                }
            }
            # If filter was active, search AllData for the absolute index
            if ($RowIdx -lt 0) {
                for ($I = 0; $I -lt $QueryResult.Count; $I++) {
                    if ([object]::ReferenceEquals($QueryResult[$I], $SelectedRow)) {
                        $RowIdx = $I; break
                    }
                }
            }
            $OriginalRow = if ($RowIdx -ge 0 -and $RowIdx -lt $OriginalData.Count) { $OriginalData[$RowIdx] } else { $SelectedRow }

            # Use custom detail function if defined, otherwise engine detail card
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

# Standard render callback: fills all 4 regions of the engine layout
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

# Standard command handler for /h, /s, /r palette commands.
# Shows help overlays and health dashboard as nested engine views.
function Invoke-EngineCommand {
    param(
        [Parameter(Mandatory)] [object]$CmdAction,
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [object]$Component,
        [scriptblock]$RenderCallback
    )

    # Shared overlay render callback (skips TopBar — overlays render on top of existing content)
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
            # Search help topics across registry
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

# Engine-driven fuzzy picker that reuses MenuListComponent with FuzzyCallback.
# Returns a candidate object (with Name, Type, DisplayText, Owner) or $null.
function Invoke-EngineFuzzySearch {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [object]$State
    )

    $AllCandidates = Get-FuzzySearchCandidates -Source $Source -State $State
    if ($AllCandidates.Count -eq 0) { return $null }

    # Build a lookup from sequential ID to candidate
    $CandidateMap = @{}

    # Convert candidates to MenuListComponent items
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

    # FuzzyCallback: runs Resolve-Name on remaining items for stage 3
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

    # Custom render adds prompt in title area
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

    # Map ID back to candidate
    if ($CandidateMap.ContainsKey($SelectedID)) {
        return $CandidateMap[$SelectedID]
    }

    return $null
}

# ── Engine Detail Card ─────────────────────────────────────────────────────

# Displays a detail card for a single data row using the engine lifecycle.
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

        # For Migracja, prepend dynamic phase entries
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

        # Handle migration phase items
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
        # Build top-level category items
        $CategoryItems = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($Cat in $script:MenuOrder) {
            $SubCount = ($script:MenuRegistry | Where-Object { $_.Menu -eq $Cat }).Count
            [void]$CategoryItems.Add([PSCustomObject]@{
                ID          = $Cat
                Label       = $Cat
                Description = "$SubCount opcji"
                RoleTag     = $null
                InfoText    = $null
                Disabled    = $false
            })
        }

        # Add refresh option
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

        # Navigate to submenu (bubble up __quit__ if returned)
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
    # This function is replaced by cli-wizard-migration.ps1 if available
    return @()
}

# ── Refresh-NavState ─────────────────────────────────────────────────────────

function Refresh-NavState {
    param([Parameter(Mandatory)] [object]$State)

    Write-Host "  Odświeżanie danych..." -ForegroundColor (Get-CLIColor -Role 'Disabled')
    $State.Entities = Get-Entity -Quiet
    $State.Players  = Get-Player
    $State.NameIndex = Get-NameIndex -Players $State.Players -Entities $State.Entities
    $State.ResolveCache = @{}
}

function Refresh-HealthChecks {
    param([Parameter(Mandatory)] [object]$State)

    $HC = $State.HealthCache
    $HC.CheckedAt = Get-Date
    $HC.Errors = @()
    $HC.Skipped = $false

    # Suppress non-terminating errors during health checks — internal calls
    # would otherwise corrupt the CLI display.
    $PrevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    $SharedSessions    = Get-Session -Quiet -Entities $State.Entities -Players $State.Players
    $SharedEntityState = Get-EntityState -Quiet

    try { $HC.PU        = Test-PlayerCharacterPUAssignment -Quiet -AllSessions $SharedSessions }
    catch { $HC.Errors += "PU: $($_.Exception.Message)" }
    try { $HC.Currency  = Test-CurrencyReconciliation -Quiet -Entities $SharedEntityState -Sessions $SharedSessions }
    catch { $HC.Errors += "Waluta: $($_.Exception.Message)" }
    try { $HC.Integrity = Test-SessionIntegrity -Quiet -Since (Get-Date).AddMonths(-2) }
    catch { $HC.Errors += "Sesje: $($_.Exception.Message)" }
    try { $HC.Graph     = Test-SessionGraphIntegrity -Quiet -Sessions $SharedSessions -NameIndex $State.NameIndex }
    catch { $HC.Errors += "Graf: $($_.Exception.Message)" }

    $ErrorActionPreference = $PrevEAP
}

function Invoke-MigrationPhaseAction {
    param([string]$PhaseID, [object]$State)
    [System.Console]::Clear()
    Write-CLILine -Text 'Migracja nie jest załadowana.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

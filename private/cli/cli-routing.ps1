<#
    .SYNOPSIS
    Menu routing layer for the Robot CLI - registry lookup, action dispatch,
    query execution, and main/sub menu loops.

    .DESCRIPTION
    This file connects the menu registry (cli-registry.ps1) with the UI engine
    (cli-primitives.ps1) and wizard system (cli-wizard.ps1). Dot-sourced on demand.

    Helpers:
    - Get-MenuCategories:          returns ordered list of top-level menu names
    - Get-MenuItems:               returns items for a given category
    - Get-RegistryEntry:           finds registry entry by ID
    - Merge-PluginMenuItems:       merges plugin-declared menu items, categories, and help into CLI state
    - Invoke-MenuAction:           dispatches a menu item by ID (Wizard/Query/Workflow)
    - Invoke-QueryAction:          executes Query-mode: filter → run → table → detail
    - Show-SubMenu:                items within a category
    - Show-MainMenu:               top-level category loop
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
        [void](Read-ArrowKey)
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
                [void](Read-ArrowKey)
                return
            }
            [void](Invoke-Wizard -RegistryEntry $Entry -State $State)
        }

        'Query' {
            Invoke-QueryAction -Entry $Entry -State $State
        }

        'Workflow' {
            $WorkflowFn = $Entry.WorkflowFunction
            if (-not $WorkflowFn -or -not (Get-Command $WorkflowFn -ErrorAction SilentlyContinue)) {
                Write-CLILine -Text 'Nie zaimplementowano.' -Color (Get-CLIColor -Role 'Disabled')
                Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
                [void](Read-ArrowKey)
                return
            }

            # Show pre-checks if defined
            if ($Entry.PreChecks) {
                Show-InfoBox -Checks $Entry.PreChecks
            }

            & $WorkflowFn -State $State -Entry $Entry
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
        [void](Read-ArrowKey)
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
            [void](Read-ArrowKey)
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
                [void](Read-ArrowKey)
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

        # Loop: table → detail card → back to table
        while ($true) {
            $SelectedRow = Show-ResultTable -Data $QueryResult -Columns $Columns -Headers $Headers -Widths $Widths -Title $Entry.Label

            if (-not $SelectedRow) { break }

            # Find the index of the selected row in transformed data to map back to original
            $RowIdx = [Array]::IndexOf($QueryResult, $SelectedRow)
            $OriginalRow = if ($RowIdx -ge 0 -and $RowIdx -lt $OriginalData.Count) { $OriginalData[$RowIdx] } else { $SelectedRow }

            # Use custom detail function if defined, otherwise generic card
            if ($Entry.DetailFunction -and (Get-Command $Entry.DetailFunction -ErrorAction SilentlyContinue)) {
                & $Entry.DetailFunction -Row $OriginalRow -State $State
            }
            else {
                Show-DetailCard -Row $OriginalRow -Title $Entry.Label
            }
        }
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
    }
}

# ── Main Menu & SubMenu ─────────────────────────────────────────────────────

function Show-SubMenu {
    param(
        [Parameter(Mandatory)] [string]$Category,
        [Parameter(Mandatory)] [object]$State
    )

    [void]$State.BreadcrumbStack.Push($Category)

    while ($true) {
        [System.Console]::Clear()
        Show-Breadcrumb -State $State

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
        $Selected = Show-ArrowMenu -Items $Items -Title $Category -ShowBack -HelpContent $HelpBody -HelpTitle $HelpTitle

        if ($Selected -eq '__back__') {
            [void]$State.BreadcrumbStack.Pop()
            return
        }

        # Handle migration phase items
        if ($Selected.StartsWith('migration-phase-')) {
            Invoke-MigrationPhaseAction -PhaseID $Selected -State $State
            continue
        }

        Invoke-MenuAction -ItemID $Selected -State $State
    }
}

function Show-MainMenu {
    param([Parameter(Mandatory)] [object]$State)

    while ($true) {
        [System.Console]::Clear()
        Show-Banner
        Show-Breadcrumb -State $State

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

        # Add refresh and quit
        [void]$CategoryItems.Add([PSCustomObject]@{
            ID          = '__refresh__'
            Label       = 'Odśwież dane'
            Description = 'Przeładuj encje, graczy i indeks nazw'
            RoleTag     = $null
            InfoText    = $null
            Disabled    = $false
        })

        $RootHelp = $script:HelpContent['root']
        $Selected = Show-ArrowMenu -Items $CategoryItems -HelpContent $RootHelp.Body -HelpTitle $RootHelp.Title

        if ($Selected -eq '__back__') {
            Write-Host ''
            Write-CLILine -Text 'Do zobaczenia!' -Color (Get-CLIColor -Role 'Accent')
            Write-Host ''
            return
        }

        if ($Selected -eq '__refresh__') {
            Refresh-NavState -State $State
            continue
        }

        # Navigate to submenu
        Show-SubMenu -Category $Selected -State $State
    }
}

# ── Migration Menu Items (stub - overridden by cli-wizard-migration.ps1) ────

function Get-MigrationMenuItems {
    param([object]$State)
    # This function is replaced by cli-wizard-migration.ps1 if available
    return @()
}

function Invoke-MigrationPhaseAction {
    param([string]$PhaseID, [object]$State)
    Write-CLILine -Text 'Migracja nie jest załadowana.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

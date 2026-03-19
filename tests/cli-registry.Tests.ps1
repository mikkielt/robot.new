<#
    .SYNOPSIS
    Pester tests for cli-registry.ps1 and cli-routing.ps1.

    .DESCRIPTION
    Tests for menu registry validation, helper functions, migration phase
    registry consistency, and migration UI backward compatibility.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source CLI layers in dependency order
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-primitives.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-fuzzy.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-display-entity.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-help.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-wizard.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-registry.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-routing.ps1')

    # Create a minimal NavState for color resolution
    $script:NavState = [PSCustomObject]@{
        Theme = 'Dark'
    }
}

# ── Menu Registry Validation ───────────────────────────────────────────────

Describe 'Menu Registry' {
    It 'has entries in the registry' {
        $script:MenuRegistry.Count | Should -BeGreaterThan 0
    }

    It 'all entries have a unique ID' {
        $IDs = $script:MenuRegistry | ForEach-Object { $_.ID }
        $UniqueIDs = $IDs | Select-Object -Unique
        $UniqueIDs.Count | Should -Be $IDs.Count
    }

    It 'all entries have a non-empty Label' {
        foreach ($Entry in $script:MenuRegistry) {
            $Entry.Label | Should -Not -BeNullOrEmpty -Because "entry '$($Entry.ID)' needs a Label"
        }
    }

    It 'all entries belong to a valid menu category' {
        $ValidCategories = $script:MenuOrder
        foreach ($Entry in $script:MenuRegistry) {
            $Entry.Menu | Should -BeIn $ValidCategories -Because "entry '$($Entry.ID)' must belong to a valid category"
        }
    }

    It 'Wizard-mode entries have a Function name' {
        foreach ($Entry in $script:MenuRegistry) {
            $Mode = if ($Entry.Mode) { $Entry.Mode } else { 'Wizard' }
            if ($Mode -eq 'Wizard') {
                $Entry.Function | Should -Not -BeNullOrEmpty -Because "Wizard entry '$($Entry.ID)' requires a Function"
            }
        }
    }

    It 'Workflow-mode entries have a WorkflowFunction name' {
        foreach ($Entry in $script:MenuRegistry) {
            if ($Entry.Mode -eq 'Workflow') {
                $Entry.WorkflowFunction | Should -Not -BeNullOrEmpty -Because "Workflow entry '$($Entry.ID)' requires a WorkflowFunction"
            }
        }
    }

    It 'Query-mode entries have Columns and Headers' {
        foreach ($Entry in $script:MenuRegistry) {
            if ($Entry.Mode -eq 'Query') {
                $Entry.Columns | Should -Not -BeNullOrEmpty -Because "Query entry '$($Entry.ID)' requires Columns"
                $Entry.Headers | Should -Not -BeNullOrEmpty -Because "Query entry '$($Entry.ID)' requires Headers"
                $Entry.Columns.Count | Should -Be $Entry.Headers.Count -Because "Columns and Headers count must match for '$($Entry.ID)'"
            }
        }
    }

    It 'Query-mode entries with Widths have matching count to Columns' {
        foreach ($Entry in $script:MenuRegistry) {
            if ($Entry.Mode -eq 'Query' -and $Entry.Widths) {
                $Entry.Widths.Count | Should -Be $Entry.Columns.Count -Because "Widths and Columns count must match for '$($Entry.ID)'"
            }
        }
    }

    It 'Role tags are valid values (N, K, or N/K)' {
        foreach ($Entry in $script:MenuRegistry) {
            if ($Entry.Role) {
                $Entry.Role | Should -BeIn @('N', 'K', 'N/K') -Because "entry '$($Entry.ID)' has invalid role '$($Entry.Role)'"
            }
        }
    }

    It 'every menu category has at least one entry' {
        foreach ($Cat in $script:MenuOrder) {
            if ($Cat -eq 'Migracja') { continue }  # Migracja has dynamic entries
            $Count = ($script:MenuRegistry | Where-Object { $_.Menu -eq $Cat }).Count
            $Count | Should -BeGreaterThan 0 -Because "category '$Cat' should have at least one entry"
        }
    }
}

# ── Menu Helper Functions ───────────────────────────────────────────────────

Describe 'Get-MenuCategories' {
    It 'returns all 8 categories in order' {
        $Cats = Get-MenuCategories
        $Cats.Count | Should -Be 8
        $Cats[0] | Should -Be 'Sesje'
        $Cats[-1] | Should -Be 'Migracja'
    }
}

Describe 'Get-MenuItems' {
    It 'returns items for Sesje category' {
        $Items = Get-MenuItems -Category 'Sesje'
        $Items.Count | Should -BeGreaterThan 0
        foreach ($Item in $Items) {
            $Item.ID | Should -Not -BeNullOrEmpty
            $Item.Label | Should -Not -BeNullOrEmpty
        }
    }

    It 'returns empty list for unknown category' {
        $Items = Get-MenuItems -Category 'NonExistentCategory'
        $Items.Count | Should -Be 0
    }

    It 'items have correct PSCustomObject structure' {
        $Items = Get-MenuItems -Category 'Encje'
        foreach ($Item in $Items) {
            $Item.PSObject.Properties.Name | Should -Contain 'ID'
            $Item.PSObject.Properties.Name | Should -Contain 'Label'
            $Item.PSObject.Properties.Name | Should -Contain 'Description'
            $Item.PSObject.Properties.Name | Should -Contain 'RoleTag'
            $Item.PSObject.Properties.Name | Should -Contain 'InfoText'
            $Item.PSObject.Properties.Name | Should -Contain 'Disabled'
        }
    }
}

Describe 'Get-RegistryEntry' {
    It 'finds entry by ID' {
        $Entry = Get-RegistryEntry -ID 'new-session'
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.Label | Should -Be 'Nowa sesja'
    }

    It 'returns null for unknown ID' {
        $Entry = Get-RegistryEntry -ID 'nonexistent-id-xyz'
        $Entry | Should -BeNullOrEmpty
    }
}

# ── Merge-PluginMenuItems ──────────────────────────────────────────────────

Describe 'Merge-PluginMenuItems' {
    BeforeEach {
        # Snapshot registry/order/help state before each test
        $script:OrigMenuRegistry = $script:MenuRegistry.Clone()
        $script:OrigMenuOrder    = $script:MenuOrder.Clone()
        $script:OrigHelpContent  = @{}
        foreach ($K in $script:HelpContent.Keys) {
            $script:OrigHelpContent[$K] = @{
                Title = $script:HelpContent[$K].Title
                Body  = [string[]]$script:HelpContent[$K].Body.Clone()
            }
        }

        # Clear plugin state
        $script:PluginMenuItems      = [System.Collections.Generic.List[hashtable]]::new()
        $script:PluginMenuCategories = [System.Collections.Generic.List[string]]::new()
        $script:PluginHelpContent    = @{}
    }

    AfterEach {
        # Restore original state
        $script:MenuRegistry = $script:OrigMenuRegistry
        $script:MenuOrder    = $script:OrigMenuOrder
        $script:HelpContent  = $script:OrigHelpContent
    }

    It 'does nothing when no plugin items exist' {
        $CountBefore = $script:MenuRegistry.Count
        Merge-PluginMenuItems
        $script:MenuRegistry.Count | Should -Be $CountBefore
    }

    It 'merges a valid Wizard-mode item into the registry' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:wizard-action'
            Label       = 'Test Action'
            Description = 'A test wizard action'
            Menu        = 'Encje'
            Function    = 'Get-Entity'
            _PluginName = 'test-plugin'
        })

        $CountBefore = $script:MenuRegistry.Count
        Merge-PluginMenuItems
        $script:MenuRegistry.Count | Should -Be ($CountBefore + 1)

        $Entry = Get-RegistryEntry -ID 'test-plugin:wizard-action'
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.Label | Should -Be 'Test Action'
    }

    It 'merges a valid Query-mode item into the registry' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:query-action'
            Label       = 'Test Query'
            Menu        = 'Encje'
            Mode        = 'Query'
            Function    = 'Get-Entity'
            Columns     = @('Name', 'Type')
            Headers     = @('Nazwa', 'Typ')
            _PluginName = 'test-plugin'
        })

        Merge-PluginMenuItems

        $Entry = Get-RegistryEntry -ID 'test-plugin:query-action'
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.Mode | Should -Be 'Query'
    }

    It 'merges a valid Workflow-mode item into the registry' {
        [void]$script:PluginMenuItems.Add(@{
            ID               = 'test-plugin:workflow-action'
            Label            = 'Test Workflow'
            Menu             = 'Encje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-TestWorkflow'
            _PluginName      = 'test-plugin'
        })

        Merge-PluginMenuItems

        $Entry = Get-RegistryEntry -ID 'test-plugin:workflow-action'
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.WorkflowFunction | Should -Be 'Invoke-TestWorkflow'
    }

    It 'skips items with duplicate IDs and warns' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'new-session'   # already exists in core registry
            Label       = 'Duplicate'
            Menu        = 'Sesje'
            Function    = 'New-Session'
            _PluginName = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $CountBefore = $script:MenuRegistry.Count
            Merge-PluginMenuItems
            $script:MenuRegistry.Count | Should -Be $CountBefore
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*menu ID 'new-session' already exists*"
    }

    It 'skips items with missing required fields and warns' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:no-label'
            Menu        = 'Encje'
            Function    = 'Get-Entity'
            _PluginName = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $CountBefore = $script:MenuRegistry.Count
            Merge-PluginMenuItems
            $script:MenuRegistry.Count | Should -Be $CountBefore
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike '*missing ID, Label, or Menu*'
    }

    It 'skips items referencing unknown categories and warns' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:bad-category'
            Label       = 'Bad Category'
            Menu        = 'NonExistentCategory'
            Function    = 'Get-Entity'
            _PluginName = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $CountBefore = $script:MenuRegistry.Count
            Merge-PluginMenuItems
            $script:MenuRegistry.Count | Should -Be $CountBefore
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*menu category 'NonExistentCategory' not in MenuOrder*"
    }

    It 'skips Wizard items missing Function and warns' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:no-function'
            Label       = 'No Function'
            Menu        = 'Encje'
            _PluginName = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $CountBefore = $script:MenuRegistry.Count
            Merge-PluginMenuItems
            $script:MenuRegistry.Count | Should -Be $CountBefore
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*Wizard item*missing Function*"
    }

    It 'skips Workflow items missing WorkflowFunction and warns' {
        [void]$script:PluginMenuItems.Add(@{
            ID               = 'test-plugin:no-wf'
            Label            = 'No Workflow'
            Menu             = 'Encje'
            Mode             = 'Workflow'
            _PluginName      = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $CountBefore = $script:MenuRegistry.Count
            Merge-PluginMenuItems
            $script:MenuRegistry.Count | Should -Be $CountBefore
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*Workflow item*missing WorkflowFunction*"
    }

    It 'skips Query items with Columns/Headers count mismatch and warns' {
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:bad-query'
            Label       = 'Bad Query'
            Menu        = 'Encje'
            Mode        = 'Query'
            Function    = 'Get-Entity'
            Columns     = @('Name', 'Type')
            Headers     = @('Nazwa')
            _PluginName = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $CountBefore = $script:MenuRegistry.Count
            Merge-PluginMenuItems
            $script:MenuRegistry.Count | Should -Be $CountBefore
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*Columns/Headers count mismatch*"
    }

    It 'merges new categories into MenuOrder' {
        [void]$script:PluginMenuCategories.Add('Narzędzia pluginu')
        [void]$script:PluginMenuItems.Add(@{
            ID          = 'test-plugin:action'
            Label       = 'Plugin Action'
            Menu        = 'Narzędzia pluginu'
            Function    = 'Get-Entity'
            _PluginName = 'test-plugin'
        })

        Merge-PluginMenuItems
        $script:MenuOrder | Should -Contain 'Narzędzia pluginu'

        $Entry = Get-RegistryEntry -ID 'test-plugin:action'
        $Entry | Should -Not -BeNullOrEmpty
    }

    It 'merges help content for new categories' {
        [void]$script:PluginMenuCategories.Add('Test Category')
        $script:PluginHelpContent['Test Category'] = [System.Collections.Generic.List[hashtable]]::new()
        [void]$script:PluginHelpContent['Test Category'].Add(@{
            Title       = 'Test Category - Pomoc'
            Body        = @('Line 1', 'Line 2')
            _PluginName = 'test-plugin'
        })

        Merge-PluginMenuItems

        $script:HelpContent.ContainsKey('Test Category') | Should -BeTrue
        $script:HelpContent['Test Category'].Title | Should -Be 'Test Category - Pomoc'
        $script:HelpContent['Test Category'].Body.Count | Should -Be 2
    }

    It 'appends help body lines to existing categories' {
        $OrigBodyCount = $script:HelpContent['Encje'].Body.Count

        $script:PluginHelpContent['Encje'] = [System.Collections.Generic.List[hashtable]]::new()
        [void]$script:PluginHelpContent['Encje'].Add(@{
            Body        = @('Plugin help line 1', 'Plugin help line 2')
            _PluginName = 'test-plugin'
        })

        Merge-PluginMenuItems

        # Original lines + blank separator + 2 plugin lines
        $script:HelpContent['Encje'].Body.Count | Should -Be ($OrigBodyCount + 3)
        $script:HelpContent['Encje'].Body[-1] | Should -Be 'Plugin help line 2'
    }

    It 'warns on new category help missing Title or Body' {
        [void]$script:PluginMenuCategories.Add('Broken Help')
        $script:PluginHelpContent['Broken Help'] = [System.Collections.Generic.List[hashtable]]::new()
        [void]$script:PluginHelpContent['Broken Help'].Add(@{
            Title       = 'Only Title, No Body'
            _PluginName = 'test-plugin'
        })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            Merge-PluginMenuItems
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*help for 'Broken Help' missing Title or Body*"
        $script:HelpContent.ContainsKey('Broken Help') | Should -BeFalse
    }
}

# ── Migration Phase Registry ───────────────────────────────────────────────

Describe 'Migration Phase Registry' {
    BeforeAll {
        $MigrationRoot = Join-Path $script:ModuleRoot 'migration'
        $MigrationPhasesPath = Join-Path $MigrationRoot 'migration-phases.ps1'
        $MigrationUIPath = Join-Path $MigrationRoot 'migration-ui.ps1'
        $MigrationStatePath = Join-Path $MigrationRoot 'migration-state.ps1'

        $script:MigrationAvailable = $false

        if ([System.IO.File]::Exists($MigrationUIPath) -and
            [System.IO.File]::Exists($MigrationStatePath) -and
            [System.IO.File]::Exists($MigrationPhasesPath)) {
            try {
                # Load in dependency order: UI first (provides output helpers),
                # then state (provides Get-MigrationState), then phases (provides
                # registry + dot-sources phase scripts that depend on both)
                . $MigrationUIPath
                . $MigrationStatePath
                . $MigrationPhasesPath
                $script:MigrationAvailable = $true
            }
            catch {
                # Migration files may fail in test context (e.g. missing repo root).
                # Tests will be skipped gracefully.
            }
        }
    }

    It 'PhaseRegistry is defined' -Skip:(-not $script:MigrationAvailable) {
        $script:PhaseRegistry | Should -Not -BeNullOrEmpty
    }

    It 'PhaseRegistry has expected phase count (7 phases: 0-6)' -Skip:(-not $script:MigrationAvailable) {
        $script:PhaseRegistry.Count | Should -Be 7
    }

    It 'all phases have unique IDs' -Skip:(-not $script:MigrationAvailable) {
        $IDs = $script:PhaseRegistry | ForEach-Object { $_.ID }
        $UniqueIDs = $IDs | Select-Object -Unique
        $UniqueIDs.Count | Should -Be $IDs.Count
    }

    It 'all phases have IDs in sequence 0-6' -Skip:(-not $script:MigrationAvailable) {
        for ($I = 0; $I -le 6; $I++) {
            $Phase = $script:PhaseRegistry | Where-Object { $_.ID -eq $I }
            $Phase | Should -Not -BeNullOrEmpty -Because "Phase $I should exist in registry"
        }
    }

    It 'all phases have a Name, Script, and Function' -Skip:(-not $script:MigrationAvailable) {
        foreach ($Phase in $script:PhaseRegistry) {
            $Phase.Name | Should -Not -BeNullOrEmpty -Because "Phase $($Phase.ID) needs a Name"
            $Phase.Script | Should -Not -BeNullOrEmpty -Because "Phase $($Phase.ID) needs a Script"
            $Phase.Function | Should -Not -BeNullOrEmpty -Because "Phase $($Phase.ID) needs a Function"
        }
    }

    It 'all phase Script files exist on disk' -Skip:(-not $script:MigrationAvailable) {
        $MigrationRoot = Join-Path $script:ModuleRoot 'migration'
        foreach ($Phase in $script:PhaseRegistry) {
            $ScriptPath = [System.IO.Path]::Combine($MigrationRoot, $Phase.Script)
            [System.IO.File]::Exists($ScriptPath) | Should -BeTrue -Because "Phase $($Phase.ID) script '$($Phase.Script)' should exist"
        }
    }

    It 'all phase Function names follow naming convention' -Skip:(-not $script:MigrationAvailable) {
        foreach ($Phase in $script:PhaseRegistry) {
            $Phase.Function | Should -Match '^Invoke-MigrationPhase\d+$' -Because "Phase $($Phase.ID) function should follow convention"
        }
    }

    It 'PhaseNames dictionary matches registry names' -Skip:(-not $script:MigrationAvailable) {
        if (-not $script:PhaseNames) { Set-ItResult -Skipped -Because 'PhaseNames not defined'; return }
        foreach ($Phase in $script:PhaseRegistry) {
            $RegistryName = $Phase.Name
            $DictName = $script:PhaseNames[$Phase.ID]
            $RegistryName | Should -Be $DictName -Because "Phase $($Phase.ID) names should be consistent"
        }
    }
}

# ── Migration UI Backward Compatibility ────────────────────────────────────

Describe 'Migration UI color resolution' {
    BeforeAll {
        $MigrationUIPath = Join-Path $script:ModuleRoot 'migration' 'migration-ui.ps1'
        if ([System.IO.File]::Exists($MigrationUIPath)) {
            . $MigrationUIPath
        }
    }

    It 'Resolve-MigrationColor returns a valid ConsoleColor for each role' -Skip:(-not (Get-Command 'Resolve-MigrationColor' -ErrorAction SilentlyContinue)) {
        $ValidColors = [System.Enum]::GetNames([System.ConsoleColor])
        foreach ($Role in @('Accent', 'Success', 'Warning', 'Error', 'Disabled', 'Info')) {
            $Color = Resolve-MigrationColor -Role $Role
            $Color | Should -BeIn $ValidColors -Because "Role '$Role' should return a valid ConsoleColor"
        }
    }

    It 'StatusDisplay uses Role keys instead of Color keys' -Skip:(-not $script:StatusDisplay) {
        foreach ($Key in $script:StatusDisplay.Keys) {
            $Entry = $script:StatusDisplay[$Key]
            $Entry.Role | Should -Not -BeNullOrEmpty -Because "StatusDisplay[$Key] should have a Role"
            $Entry.Symbol | Should -Not -BeNullOrEmpty -Because "StatusDisplay[$Key] should have a Symbol"
            $Entry.Text | Should -Not -BeNullOrEmpty -Because "StatusDisplay[$Key] should have a Text"
        }
    }
}

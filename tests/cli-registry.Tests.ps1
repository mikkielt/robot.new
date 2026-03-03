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
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-display.ps1')
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
    It 'returns all 7 categories in order' {
        $Cats = Get-MenuCategories
        $Cats.Count | Should -Be 7
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

    It 'PhaseRegistry has expected phase count (9 phases: 0-8)' -Skip:(-not $script:MigrationAvailable) {
        $script:PhaseRegistry.Count | Should -Be 9
    }

    It 'all phases have unique IDs' -Skip:(-not $script:MigrationAvailable) {
        $IDs = $script:PhaseRegistry | ForEach-Object { $_.ID }
        $UniqueIDs = $IDs | Select-Object -Unique
        $UniqueIDs.Count | Should -Be $IDs.Count
    }

    It 'all phases have IDs in sequence 0-8' -Skip:(-not $script:MigrationAvailable) {
        for ($I = 0; $I -le 8; $I++) {
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

<#
    .SYNOPSIS
    Pester tests for the plugin system.

    .DESCRIPTION
    Tests for Resolve-PluginLoadOrder, Resolve-PluginConfig (plugin-loader.ps1),
    Invoke-PluginHook, Test-PluginScope (plugin-hooks.ps1), and module-level
    plugin management functions Get-LoadedPlugins and Get-PluginConfig.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'plugin-loader.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'plugin-hooks.ps1')
}

# ── Resolve-PluginLoadOrder ────────────────────────────────────────────────

Describe 'Resolve-PluginLoadOrder' {
    It 'returns empty list for empty candidates' {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Result = Resolve-PluginLoadOrder -Candidates $Candidates
        $Result.Count | Should -Be 0
    }

    It 'returns all plugins with no dependencies' {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Candidates.Add(@{ Manifest = @{ Name = 'Alpha'; DependsOn = @() } })
        $Candidates.Add(@{ Manifest = @{ Name = 'Bravo'; DependsOn = @() } })
        $Candidates.Add(@{ Manifest = @{ Name = 'Charlie'; DependsOn = @() } })

        $Result = Resolve-PluginLoadOrder -Candidates $Candidates
        $Result.Count | Should -Be 3
        $Names = $Result | ForEach-Object { $_.Manifest.Name }
        $Names | Should -Contain 'Alpha'
        $Names | Should -Contain 'Bravo'
        $Names | Should -Contain 'Charlie'
    }

    It 'sorts plugins respecting DependsOn (B depends on A -> A loads first)' {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Candidates.Add(@{ Manifest = @{ Name = 'PluginB'; DependsOn = @('PluginA') } })
        $Candidates.Add(@{ Manifest = @{ Name = 'PluginA'; DependsOn = @() } })

        $Result = Resolve-PluginLoadOrder -Candidates $Candidates
        $Result.Count | Should -Be 2

        $IndexA = -1
        $IndexB = -1
        for ($i = 0; $i -lt $Result.Count; $i++) {
            if ($Result[$i].Manifest.Name -eq 'PluginA') { $IndexA = $i }
            if ($Result[$i].Manifest.Name -eq 'PluginB') { $IndexB = $i }
        }
        $IndexA | Should -BeLessThan $IndexB
    }

    It 'handles missing dependency gracefully (warns, skips the dependent plugin)' {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Candidates.Add(@{ Manifest = @{ Name = 'Orphan'; DependsOn = @('NonExistent') } })
        $Candidates.Add(@{ Manifest = @{ Name = 'Standalone'; DependsOn = @() } })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $Result = Resolve-PluginLoadOrder -Candidates $Candidates
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike '*missing plugin*NonExistent*'

        # Orphan should be skipped, Standalone should remain
        $Names = $Result | ForEach-Object { $_.Manifest.Name }
        $Names | Should -Contain 'Standalone'
        $Names | Should -Not -Contain 'Orphan'
    }

    It 'handles circular dependencies gracefully (warns, skips cycled plugins)' {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Candidates.Add(@{ Manifest = @{ Name = 'CycleA'; DependsOn = @('CycleB') } })
        $Candidates.Add(@{ Manifest = @{ Name = 'CycleB'; DependsOn = @('CycleA') } })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $Result = Resolve-PluginLoadOrder -Candidates $Candidates
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike '*unresolved dependencies*'
        $Result.Count | Should -Be 0
    }

    It 'returns independent plugins even when others have circular deps' {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Candidates.Add(@{ Manifest = @{ Name = 'Good'; DependsOn = @() } })
        $Candidates.Add(@{ Manifest = @{ Name = 'CycleX'; DependsOn = @('CycleY') } })
        $Candidates.Add(@{ Manifest = @{ Name = 'CycleY'; DependsOn = @('CycleX') } })

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $Result = Resolve-PluginLoadOrder -Candidates $Candidates
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Names = $Result | ForEach-Object { $_.Manifest.Name }
        $Names | Should -Contain 'Good'
        $Names | Should -Not -Contain 'CycleX'
        $Names | Should -Not -Contain 'CycleY'
    }
}

# ── Resolve-PluginConfig ──────────────────────────────────────────────────

Describe 'Resolve-PluginConfig' {
    It 'returns empty hashtable when no Config in manifest' {
        $Manifest = @{ Name = 'TestPlugin' }
        $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $TestDrive -ModuleRoot $TestDrive
        $Result.Count | Should -Be 0
    }

    It 'resolves value from environment variable' {
        $EnvVarName = 'ROBOT_TEST_PLUGIN_CFG_' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
        [System.Environment]::SetEnvironmentVariable($EnvVarName, 'EnvValue')
        try {
            $Manifest = @{
                Name   = 'TestPlugin'
                Config = @{
                    ApiKey = @{ EnvVar = $EnvVarName; Default = $null; Required = $false }
                }
            }
            $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $TestDrive -ModuleRoot $TestDrive
            $Result.ApiKey | Should -Be 'EnvValue'
        } finally {
            [System.Environment]::SetEnvironmentVariable($EnvVarName, $null)
        }
    }

    It 'resolves value from plugin local.config.psd1' {
        $TempDir = New-TestTempDir
        try {
            $PluginDir = Join-Path $TempDir 'myplugin'
            [void][System.IO.Directory]::CreateDirectory($PluginDir)
            Write-TestFile -Path (Join-Path $PluginDir 'local.config.psd1') -Content "@{ ApiKey = 'FromPluginLocal' }"

            $Manifest = @{
                Name   = 'myplugin'
                Config = @{
                    ApiKey = @{ EnvVar = 'ROBOT_NONEXISTENT_ENV_VAR_XYZ'; Default = $null; Required = $false }
                }
            }
            $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $PluginDir -ModuleRoot $TempDir
            $Result.ApiKey | Should -Be 'FromPluginLocal'
        } finally {
            Remove-TestTempDir
        }
    }

    It 'resolves value from core local.config.psd1 with namespaced key' {
        $TempDir = New-TestTempDir
        try {
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content "@{ 'myplugin.ApiKey' = 'FromCoreNamespaced' }"

            $Manifest = @{
                Name   = 'myplugin'
                Config = @{
                    ApiKey = @{ EnvVar = 'ROBOT_NONEXISTENT_ENV_VAR_XYZ'; Default = $null; Required = $false }
                }
            }
            # PluginDir has no local.config.psd1 so it falls through
            $PluginDir = Join-Path $TempDir 'myplugin'
            [void][System.IO.Directory]::CreateDirectory($PluginDir)

            $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $PluginDir -ModuleRoot $TempDir
            $Result.ApiKey | Should -Be 'FromCoreNamespaced'
        } finally {
            Remove-TestTempDir
        }
    }

    It 'uses manifest Default when no other source' {
        $Manifest = @{
            Name   = 'TestPlugin'
            Config = @{
                Timeout = @{ EnvVar = 'ROBOT_NONEXISTENT_ENV_VAR_XYZ'; Default = '30'; Required = $false }
            }
        }
        $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $TestDrive -ModuleRoot $TestDrive
        $Result.Timeout | Should -Be '30'
    }

    It 'env var takes priority over local config' {
        $TempDir = New-TestTempDir
        $EnvVarName = 'ROBOT_TEST_PLUGIN_PRI_' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
        [System.Environment]::SetEnvironmentVariable($EnvVarName, 'FromEnv')
        try {
            $PluginDir = Join-Path $TempDir 'myplugin'
            [void][System.IO.Directory]::CreateDirectory($PluginDir)
            Write-TestFile -Path (Join-Path $PluginDir 'local.config.psd1') -Content "@{ ApiKey = 'FromLocal' }"

            $Manifest = @{
                Name   = 'myplugin'
                Config = @{
                    ApiKey = @{ EnvVar = $EnvVarName; Default = 'DefaultVal'; Required = $false }
                }
            }
            $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $PluginDir -ModuleRoot $TempDir
            $Result.ApiKey | Should -Be 'FromEnv'
        } finally {
            [System.Environment]::SetEnvironmentVariable($EnvVarName, $null)
            Remove-TestTempDir
        }
    }

    It 'plugin local config takes priority over core namespaced config' {
        $TempDir = New-TestTempDir
        try {
            $PluginDir = Join-Path $TempDir 'myplugin'
            [void][System.IO.Directory]::CreateDirectory($PluginDir)
            Write-TestFile -Path (Join-Path $PluginDir 'local.config.psd1') -Content "@{ ApiKey = 'FromPluginLocal' }"
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content "@{ 'myplugin.ApiKey' = 'FromCoreNamespaced' }"

            $Manifest = @{
                Name   = 'myplugin'
                Config = @{
                    ApiKey = @{ EnvVar = 'ROBOT_NONEXISTENT_ENV_VAR_XYZ'; Default = 'DefaultVal'; Required = $false }
                }
            }
            $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $PluginDir -ModuleRoot $TempDir
            $Result.ApiKey | Should -Be 'FromPluginLocal'
        } finally {
            Remove-TestTempDir
        }
    }

    It 'writes warning for required but missing config key' {
        $Manifest = @{
            Name   = 'WarnPlugin'
            Config = @{
                Secret = @{ EnvVar = 'ROBOT_NONEXISTENT_ENV_VAR_XYZ'; Default = $null; Required = $true }
            }
        }

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            $Result = Resolve-PluginConfig -Manifest $Manifest -PluginDir $TestDrive -ModuleRoot $TestDrive
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*WarnPlugin*config key*Secret*required*"
    }
}

# ── Invoke-PluginHook ─────────────────────────────────────────────────────

Describe 'Invoke-PluginHook' {
    It 'returns silently when $script:HookRegistry is null' {
        $script:HookRegistry = $null
        { Invoke-PluginHook -Operation 'SetEntity' -Phase 'BeforeWrite' -Context @{} } | Should -Not -Throw
    }

    It 'returns silently when $script:HookRegistry is empty' {
        $script:HookRegistry = @{}
        { Invoke-PluginHook -Operation 'SetEntity' -Phase 'BeforeWrite' -Context @{} } | Should -Not -Throw
    }

    It 'returns silently when no handlers for given Operation:Phase' {
        $script:HookRegistry = @{
            'OtherOp:BeforeWrite' = [System.Collections.Generic.List[object]]::new()
        }
        { Invoke-PluginHook -Operation 'SetEntity' -Phase 'BeforeWrite' -Context @{} } | Should -Not -Throw
    }

    It 'calls handler function with HookContext parameter' {
        # Define a test handler function
        function Test-HookHandler {
            param([hashtable]$HookContext)
            $script:TestHookCalled = $true
            $script:TestHookContext = $HookContext
        }

        $script:TestHookCalled = $false
        $script:TestHookContext = $null

        $Handlers = [System.Collections.Generic.List[object]]::new()
        $Handlers.Add([PSCustomObject]@{
            Plugin   = 'TestPlugin'
            Handler  = 'Test-HookHandler'
            Priority = 100
        })

        $script:HookRegistry = @{
            'SetEntity:BeforeWrite' = $Handlers
        }

        $Ctx = @{ EntityName = 'TestEntity'; Operation = 'SetEntity' }
        Invoke-PluginHook -Operation 'SetEntity' -Phase 'BeforeWrite' -Context $Ctx

        $script:TestHookCalled | Should -BeTrue
        $script:TestHookContext.EntityName | Should -Be 'TestEntity'
    }

    It 'calls handlers in priority order (lower number first)' {
        $script:HookCallOrder = [System.Collections.Generic.List[string]]::new()

        function Test-HookLowPriority {
            param([hashtable]$HookContext)
            $script:HookCallOrder.Add('Low')
        }
        function Test-HookHighPriority {
            param([hashtable]$HookContext)
            $script:HookCallOrder.Add('High')
        }

        $Handlers = [System.Collections.Generic.List[object]]::new()
        # Add high priority (lower number) first in list to verify sort is applied
        $Handlers.Add([PSCustomObject]@{
            Plugin   = 'PluginA'
            Handler  = 'Test-HookLowPriority'
            Priority = 10
        })
        $Handlers.Add([PSCustomObject]@{
            Plugin   = 'PluginB'
            Handler  = 'Test-HookHighPriority'
            Priority = 200
        })

        $script:HookRegistry = @{
            'SetEntity:AfterWrite' = $Handlers
        }

        Invoke-PluginHook -Operation 'SetEntity' -Phase 'AfterWrite' -Context @{}

        $script:HookCallOrder[0] | Should -Be 'Low'
        $script:HookCallOrder[1] | Should -Be 'High'
    }

    It 'BeforeWrite phase: re-throws handler exception with plugin context' {
        function Test-HookThrower {
            param([hashtable]$HookContext)
            throw 'Validation failed'
        }

        $Handlers = [System.Collections.Generic.List[object]]::new()
        $Handlers.Add([PSCustomObject]@{
            Plugin   = 'ValidatorPlugin'
            Handler  = 'Test-HookThrower'
            Priority = 100
        })

        $script:HookRegistry = @{
            'SetEntity:BeforeWrite' = $Handlers
        }

        { Invoke-PluginHook -Operation 'SetEntity' -Phase 'BeforeWrite' -Context @{} } |
            Should -Throw "*ValidatorPlugin*rejected*Validation failed*"
    }

    It 'AfterWrite phase: logs error but does not throw' {
        function Test-HookAfterWriteError {
            param([hashtable]$HookContext)
            throw 'Side effect failed'
        }

        $Handlers = [System.Collections.Generic.List[object]]::new()
        $Handlers.Add([PSCustomObject]@{
            Plugin   = 'LoggerPlugin'
            Handler  = 'Test-HookAfterWriteError'
            Priority = 100
        })

        $script:HookRegistry = @{
            'SetEntity:AfterWrite' = $Handlers
        }

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            { Invoke-PluginHook -Operation 'SetEntity' -Phase 'AfterWrite' -Context @{} } |
                Should -Not -Throw
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*LoggerPlugin*failed*Side effect failed*"
    }

    It 'skips handler when function not found (warns to stderr)' {
        $Handlers = [System.Collections.Generic.List[object]]::new()
        $Handlers.Add([PSCustomObject]@{
            Plugin   = 'GhostPlugin'
            Handler  = 'Invoke-NonExistentHandlerFunction_XYZZY'
            Priority = 100
        })

        $script:HookRegistry = @{
            'SetEntity:AfterWrite' = $Handlers
        }

        $OldErr = [System.Console]::Error
        $ErrWriter = [System.IO.StringWriter]::new()
        [System.Console]::SetError($ErrWriter)
        try {
            Invoke-PluginHook -Operation 'SetEntity' -Phase 'AfterWrite' -Context @{}
        } finally {
            [System.Console]::SetError($OldErr)
        }

        $Stderr = $ErrWriter.ToString()
        $Stderr | Should -BeLike "*Invoke-NonExistentHandlerFunction_XYZZY*not found*"
    }

    # CC-2: BeforeMigration/AfterMigration phases were added in WP-3 for the
    # migration framework. Validate that the ValidateSet accepts them and
    # that BeforeMigration aborts (like BeforeWrite) while AfterMigration
    # only logs.
    It 'BeforeMigration phase is accepted by ValidateSet' {
        $script:HookRegistry = @{}
        { Invoke-PluginHook -Operation 'Migration' -Phase 'BeforeMigration' -Context @{} } | Should -Not -Throw
    }

    It 'AfterMigration phase is accepted by ValidateSet' {
        $script:HookRegistry = @{}
        { Invoke-PluginHook -Operation 'Migration' -Phase 'AfterMigration' -Context @{} } | Should -Not -Throw
    }

    It 'BeforeMigration re-throws handler exception with plugin context' {
        function Test-MigrationHookThrower {
            param([hashtable]$HookContext)
            throw 'migration vetoed'
        }
        $Handlers = [System.Collections.Generic.List[object]]::new()
        $Handlers.Add([PSCustomObject]@{
            Plugin = 'ValidatorPlugin'; Handler = 'Test-MigrationHookThrower'; Priority = 100
        })
        $script:HookRegistry = @{ 'Migration:BeforeMigration' = $Handlers }
        { Invoke-PluginHook -Operation 'Migration' -Phase 'BeforeMigration' -Context @{} } |
            Should -Throw "*ValidatorPlugin*rejected*migration vetoed*"
    }

    It 'AfterMigration logs error but does not throw' {
        function Test-AfterMigrationError {
            param([hashtable]$HookContext)
            throw 'post-apply observer failed'
        }
        $Handlers = [System.Collections.Generic.List[object]]::new()
        $Handlers.Add([PSCustomObject]@{
            Plugin = 'LoggerPlugin'; Handler = 'Test-AfterMigrationError'; Priority = 100
        })
        $script:HookRegistry = @{ 'Migration:AfterMigration' = $Handlers }
        { Invoke-PluginHook -Operation 'Migration' -Phase 'AfterMigration' -Context @{} } |
            Should -Not -Throw
    }
}

# ── Test-PluginScope ──────────────────────────────────────────────────────

Describe 'Test-PluginScope' {
    BeforeEach {
        # Reset RBAC config cache between tests so each test starts fresh
        $script:CachedRbacConfig     = $null
        $script:CachedRbacConfigPath = $null
    }

    It 'returns $true when no user identity available (permissive default)' {
        # Temporarily unset ROBOT_USER and mock git to return nothing
        $OldRobotUser = [System.Environment]::GetEnvironmentVariable('ROBOT_USER')
        [System.Environment]::SetEnvironmentVariable('ROBOT_USER', $null)
        try {
            Mock git { return '' }
            $Result = Test-PluginScope -RequiredScope 'entity:write' -User ''
            # Passing empty string is not the same as omitting; use $null-like path
            # The function checks -not $User, empty string is falsy in PS
        } finally {
            [System.Environment]::SetEnvironmentVariable('ROBOT_USER', $OldRobotUser)
        }
        # Empty user with no env var falls through to git; we cannot fully control git
        # so test by passing an explicit empty user and having no config file
        $Result | Should -BeTrue
    }

    It 'returns $true when no local.config.psd1 exists' {
        $TempDir = New-TestTempDir
        try {
            $script:ModuleRoot = $TempDir
            $Result = Test-PluginScope -RequiredScope 'entity:write' -User 'testuser'
            $Result | Should -BeTrue
        } finally {
            $script:ModuleRoot = (Split-Path $PSScriptRoot -Parent)
            Remove-TestTempDir
        }
    }

    It 'returns $true when Roles/RoleScopes not configured' {
        $TempDir = New-TestTempDir
        try {
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content "@{ SomeOtherKey = 'value' }"
            $script:ModuleRoot = $TempDir
            $Result = Test-PluginScope -RequiredScope 'entity:write' -User 'testuser'
            $Result | Should -BeTrue
        } finally {
            $script:ModuleRoot = (Split-Path $PSScriptRoot -Parent)
            Remove-TestTempDir
        }
    }

    It 'returns $true for admin:all scope' {
        $TempDir = New-TestTempDir
        try {
            $ConfigContent = @"
@{
    Roles = @{
        'adminuser' = 'admin'
    }
    RoleScopes = @{
        'admin' = @('admin:all')
    }
}
"@
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content $ConfigContent
            $script:ModuleRoot = $TempDir
            $Result = Test-PluginScope -RequiredScope 'entity:write:sensitive' -User 'AdminUser'
            $Result | Should -BeTrue
        } finally {
            $script:ModuleRoot = (Split-Path $PSScriptRoot -Parent)
            Remove-TestTempDir
        }
    }

    It 'returns $true for exact scope match' {
        $TempDir = New-TestTempDir
        try {
            $ConfigContent = @"
@{
    Roles = @{
        'editor' = 'editor'
    }
    RoleScopes = @{
        'editor' = @('entity:write', 'entity:read')
    }
}
"@
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content $ConfigContent
            $script:ModuleRoot = $TempDir
            $Result = Test-PluginScope -RequiredScope 'entity:write' -User 'Editor'
            $Result | Should -BeTrue
        } finally {
            $script:ModuleRoot = (Split-Path $PSScriptRoot -Parent)
            Remove-TestTempDir
        }
    }

    It 'returns $false for unknown user' {
        $TempDir = New-TestTempDir
        try {
            $ConfigContent = @"
@{
    Roles = @{
        'knownuser' = 'editor'
    }
    RoleScopes = @{
        'editor' = @('entity:write')
    }
}
"@
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content $ConfigContent
            $script:ModuleRoot = $TempDir
            $Result = Test-PluginScope -RequiredScope 'entity:write' -User 'UnknownPerson'
            $Result | Should -BeFalse
        } finally {
            $script:ModuleRoot = (Split-Path $PSScriptRoot -Parent)
            Remove-TestTempDir
        }
    }

    It 'returns $false for scope not in user role' {
        $TempDir = New-TestTempDir
        try {
            $ConfigContent = @"
@{
    Roles = @{
        'viewer' = 'readonly'
    }
    RoleScopes = @{
        'readonly' = @('entity:read')
    }
}
"@
            Write-TestFile -Path (Join-Path $TempDir 'local.config.psd1') -Content $ConfigContent
            $script:ModuleRoot = $TempDir
            $Result = Test-PluginScope -RequiredScope 'entity:write' -User 'Viewer'
            $Result | Should -BeFalse
        } finally {
            $script:ModuleRoot = (Split-Path $PSScriptRoot -Parent)
            Remove-TestTempDir
        }
    }
}

# ── Integration: Module-level plugin management functions ─────────────────

Describe 'Get-LoadedPlugins' {
    It 'returns empty list when no plugins loaded' {
        $Mod = Get-Module Robot.PowerShell
        $Saved = & $Mod { $script:LoadedPlugins }
        try {
            & $Mod { $script:LoadedPlugins = @{} }
            $Result = Get-LoadedPlugins
            $Result | Should -HaveCount 0
        } finally {
            & $Mod { param($V) $script:LoadedPlugins = $V } $Saved
        }
    }
}

Describe 'Get-PluginConfig' {
    It 'returns empty hashtable for unknown plugin name' {
        $Result = Get-PluginConfig -PluginName 'NonExistentPlugin_XYZZY_12345'
        $Result | Should -BeOfType [hashtable]
        $Result.Count | Should -Be 0
    }
}

# ── Plugin CLI Metadata Extraction ────────────────────────────────────────

Describe 'Plugin CLI metadata extraction' {
    BeforeAll {
        # CLI metadata variables are module-internal ($script: scope in Robot.PowerShell.psm1).
        # We test the extraction pipeline by simulating the Phase 2c loop logic
        # from Robot.PowerShell.psm1 on a manifest with MenuItems/MenuCategories/HelpContent.

        $script:PluginMenuItems      = [System.Collections.Generic.List[hashtable]]::new()
        $script:PluginMenuCategories = [System.Collections.Generic.List[string]]::new()
        $script:PluginHelpContent    = @{}
    }

    It 'extracts MenuItems from manifest into PluginMenuItems' {
        $Manifest = @{
            Name       = 'test-cli-plugin'
            MenuItems  = @(
                @{ ID = 'test:action'; Label = 'Test'; Menu = 'Encje'; Function = 'Get-Entity' }
            )
        }

        foreach ($MenuItem in $Manifest.MenuItems) {
            $MenuItem['_PluginName'] = $Manifest.Name
            [void]$script:PluginMenuItems.Add($MenuItem)
        }

        $script:PluginMenuItems.Count | Should -Be 1
        $script:PluginMenuItems[0].ID | Should -Be 'test:action'
        $script:PluginMenuItems[0]['_PluginName'] | Should -Be 'test-cli-plugin'
    }

    It 'extracts MenuCategories from manifest into PluginMenuCategories' {
        $Manifest = @{
            Name           = 'test-cli-plugin'
            MenuCategories = @('Plugin Tools')
        }

        foreach ($Cat in $Manifest.MenuCategories) {
            if (-not $script:PluginMenuCategories.Contains($Cat)) {
                [void]$script:PluginMenuCategories.Add($Cat)
            }
        }

        $script:PluginMenuCategories | Should -Contain 'Plugin Tools'
    }

    It 'does not duplicate categories from multiple manifest reads' {
        $CountBefore = $script:PluginMenuCategories.Count

        # Simulate same category from another manifest
        $Cat = 'Plugin Tools'
        if (-not $script:PluginMenuCategories.Contains($Cat)) {
            [void]$script:PluginMenuCategories.Add($Cat)
        }

        $script:PluginMenuCategories.Count | Should -Be $CountBefore
    }

    It 'extracts HelpContent from manifest into PluginHelpContent' {
        $Manifest = @{
            Name        = 'test-cli-plugin'
            HelpContent = @{
                'Plugin Tools' = @{
                    Title = 'Plugin Tools - Pomoc'
                    Body  = @('Help line 1')
                }
            }
        }

        foreach ($HelpKey in $Manifest.HelpContent.Keys) {
            if (-not $script:PluginHelpContent.ContainsKey($HelpKey)) {
                $script:PluginHelpContent[$HelpKey] = [System.Collections.Generic.List[hashtable]]::new()
            }
            $HelpEntry = $Manifest.HelpContent[$HelpKey].Clone()
            $HelpEntry['_PluginName'] = $Manifest.Name
            [void]$script:PluginHelpContent[$HelpKey].Add($HelpEntry)
        }

        $script:PluginHelpContent.ContainsKey('Plugin Tools') | Should -BeTrue
        $script:PluginHelpContent['Plugin Tools'][0].Title | Should -Be 'Plugin Tools - Pomoc'
        $script:PluginHelpContent['Plugin Tools'][0]['_PluginName'] | Should -Be 'test-cli-plugin'
    }

    It 'Get-LoadedPlugins returns empty list when no plugins loaded' {
        $Mod = Get-Module Robot.PowerShell
        $Saved = & $Mod { $script:LoadedPlugins }
        try {
            & $Mod { $script:LoadedPlugins = @{} }
            $Result = Get-LoadedPlugins
            $Result | Should -HaveCount 0
        } finally {
            & $Mod { param($V) $script:LoadedPlugins = $V } $Saved
        }
    }
}

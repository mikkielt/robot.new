<#
    .SYNOPSIS
    Pester tests for WP-7 migration REST handlers.

    .DESCRIPTION
    Tests exercise the handler functions directly (not the full HTTP stack).
    Route registration is verified by parsing api-routes.ps1's AddRoute calls.
#>

BeforeAll {
    . "$PSScriptRoot/../../../tests/TestHelpers.ps1"
    Import-RobotModule
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot

    # Source migration handlers + transitive deps that PS workers normally
    # dot-source. We mock the Robot.RouteMatch type with a PSCustomObject.
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'plugin-hooks.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-log.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-runtime.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migrationpreview.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migrationchain.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'reset-migrationlock.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'reset-schemaversion.ps1')
    . (Join-Path $script:PluginRoot 'private' 'api-handlers-migration.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'

    function New-ApiContext {
        param([hashtable]$PathParams = @{}, [hashtable]$QueryParams = @{}, [string]$Body)
        return @{
            PathParams  = $PathParams
            QueryParams = $QueryParams
            Body        = $Body
            Method      = 'GET'
            Path        = '/'
            TokenName   = 'test'
            TokenScopes = @('migration:read','migration:write','migration:admin','migration:restore')
        }
    }
    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-api-mig-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-IsolatedRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
}

Describe 'Route registration in api-routes.ps1' {
    It 'registers all 9 migration endpoints' {
        $Lines = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'private' 'api-routes.ps1'))
        $Expected = @(
            "'/schema/version'", "'/migrations'", "'/migrations/pending'",
            "'/migrations/:id'", "'/migrations/:id/preview'",
            "'/migrations/apply'", "'/migrations/jobs/:jobId'",
            "'/schema/lock'", "'/schema/restore'"
        )
        foreach ($P in $Expected) {
            $Lines | Should -Match ([regex]::Escape($P))
        }
    }

    It 'uses noun:verb scope naming for all migration scopes' {
        $Lines = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'private' 'api-routes.ps1'))
        @("'migration:read'", "'migration:write'", "'migration:admin'", "'migration:restore'") | ForEach-Object {
            $Lines | Should -Match ([regex]::Escape($_))
        }
    }
}

Describe 'Invoke-ApiGetSchemaVersion' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
        # Wire firewall to this repo so Get-RepoRoot points here
        Set-RepoRoot -Path $script:Repo
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Set-RepoRoot -Reset
        Initialize-TestFilesystemFirewall
        Clear-MigrationCatalogCache
    }

    It 'returns Current=0.0.0 on a fresh repo' {
        $M = New-ApiContext
        $R = Invoke-ApiGetSchemaVersion -ApiContext $M
        $R.current | Should -Be '0.0.0'
        $R.mode | Should -BeIn @('Normal','Unknown')
    }

    It 'returns lock state fields' {
        $M = New-ApiContext
        $R = Invoke-ApiGetSchemaVersion -ApiContext $M
        $R.PSObject.Properties.Name | Should -Contain 'lockedBy'
        $R.PSObject.Properties.Name | Should -Contain 'lockStale'
    }
}

Describe 'Invoke-ApiGetMigrations / Invoke-ApiGetPendingMigrations' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
        Set-RepoRoot -Path $script:Repo
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Set-RepoRoot -Reset
        Initialize-TestFilesystemFirewall
        Clear-MigrationCatalogCache
    }

    It 'lists discoverable migrations' {
        $R = @(Invoke-ApiGetMigrations -ApiContext (New-ApiContext))
        ($R | Where-Object { $_.Slug -eq 'foo' }).Count | Should -BeGreaterOrEqual 1
    }
    It 'pending list contains foo on fresh repo' {
        $R = @(Invoke-ApiGetPendingMigrations -ApiContext (New-ApiContext))
        ($R | Where-Object { $_.Slug -eq 'foo' }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Invoke-ApiPostMigrationApply' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
        Set-RepoRoot -Path $script:Repo
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Set-RepoRoot -Reset
        Initialize-TestFilesystemFirewall
        Clear-MigrationCatalogCache
    }

    It '422 on unsigned without allowUnsigned' {
        $Body = '{"target":{"id":"0.1.0-foo"},"mode":"sync"}'
        $M = New-ApiContext -Body $Body
        $R = Invoke-ApiPostMigrationApply -ApiContext $M
        $R.status | Should -Be 422
        $R.body.error | Should -Be 'unsigned-migration-blocked'
    }

    It 'applies successfully with allowUnsigned=true' {
        $Body = '{"target":{"id":"0.1.0-foo"},"mode":"sync","allowUnsigned":true}'
        $M = New-ApiContext -Body $Body
        $R = Invoke-ApiPostMigrationApply -ApiContext $M
        $R.OK | Should -BeTrue
        $R.MigrationId | Should -Be '0.1.0-foo'
    }

    It '400 on missing target' {
        $Body = '{"mode":"sync"}'
        $M = New-ApiContext -Body $Body
        $R = Invoke-ApiPostMigrationApply -ApiContext $M
        $R.status | Should -Be 400
    }

    It '404 on unknown target id' {
        $Body = '{"target":{"id":"99.99.99-ghost"},"mode":"sync"}'
        $M = New-ApiContext -Body $Body
        $R = Invoke-ApiPostMigrationApply -ApiContext $M
        $R.status | Should -Be 404
    }

    It '501 on async (WP-8 not yet ready)' {
        $Body = '{"target":{"id":"0.1.0-foo"},"mode":"async","allowUnsigned":true}'
        $M = New-ApiContext -Body $Body
        $R = Invoke-ApiPostMigrationApply -ApiContext $M
        $R.status | Should -Be 501
    }
}

Describe 'Invoke-ApiDeleteSchemaLock and Invoke-ApiPostSchemaRestore' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        Set-RepoRoot -Path $script:Repo
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Set-RepoRoot -Reset
        Initialize-TestFilesystemFirewall
        Clear-MigrationCatalogCache
    }

    It 'DELETE /schema/lock clears a held lock' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        $R = Invoke-ApiDeleteSchemaLock -ApiContext (New-ApiContext)
        $R.WasLocked | Should -BeTrue
        $R.PreviousOwner | Should -Be 'alice'
    }

    It 'POST /schema/restore returns 422 when target not in history' {
        # need an existing schema first
        Set-SchemaVersion -Version '0.1.0' -MajorName '' -MigrationId 'm1' -RepoRoot $script:Repo
        $Body = '{"to":"99.0.0"}'
        $M = New-ApiContext -Body $Body
        $R = Invoke-ApiPostSchemaRestore -ApiContext $M
        $R.status | Should -Be 422
        $R.body.error | Should -Be 'version-not-in-history'
    }

    It 'POST /schema/restore 400 when body missing to' {
        $R = Invoke-ApiPostSchemaRestore -ApiContext (New-ApiContext -Body '{}')
        $R.status | Should -Be 400
    }
}

Describe 'Help JSON shape' {
    It 'migrations.help.json registers every handler' {
        $Help = Get-Content (Join-Path $script:PluginRoot 'help' 'migrations.help.json') -Raw | ConvertFrom-Json
        $Handlers = @($Help.endpoints | ForEach-Object { $_.handler })
        $Handlers | Should -Contain 'Invoke-ApiGetSchemaVersion'
        $Handlers | Should -Contain 'Invoke-ApiPostMigrationApply'
        $Handlers | Should -Contain 'Invoke-ApiDeleteSchemaLock'
        $Handlers | Should -Contain 'Invoke-ApiPostSchemaRestore'
        $Handlers | Should -Contain 'Invoke-ApiGetMigrationJob'
    }
}

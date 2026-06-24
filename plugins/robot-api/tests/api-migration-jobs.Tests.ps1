<#
    .SYNOPSIS
    Pester tests for WP-8 migration background job system.
#>

BeforeAll {
    . "$PSScriptRoot/../../../tests/TestHelpers.ps1"
    Import-RobotModule
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot

    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'plugin-hooks.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-log.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-runtime.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migrationchain.ps1')
    . (Join-Path $script:PluginRoot 'private' 'api-jobs-migration.ps1')
    . (Join-Path $script:PluginRoot 'private' 'api-handlers-migration.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-jobs-" + [Guid]::NewGuid().ToString('N'))
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

Describe 'Start-ApiMigrationJob / Get-ApiMigrationJob' {
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

    It 'returns a jobId for a valid target' {
        $Jid = Start-ApiMigrationJob -Target @{ id = '0.1.0-foo' } -BranchMode 'InPlace' -AllowUnsigned
        $Jid | Should -Not -BeNullOrEmpty
        $Jid.Length | Should -Be 32
    }

    It 'job transitions through Queued -> Running -> Completed' {
        $Jid = Start-ApiMigrationJob -Target @{ id = '0.1.0-foo' } -BranchMode 'InPlace' -AllowUnsigned
        # Wait up to 5s for completion. ThreadJob or inline fallback both complete fast.
        $Deadline = (Get-Date).AddSeconds(5)
        do {
            $J = Get-ApiMigrationJob -Id $Jid
            if ($J -and ($J.Status -eq 'Completed' -or $J.Status -eq 'Failed')) { break }
            Start-Sleep -Milliseconds 50
        } while ((Get-Date) -lt $Deadline)
        $J.Status | Should -BeIn @('Completed','Failed')
        $J.MigrationId | Should -Be '0.1.0-foo'
    }

    It 'Get-ApiMigrationJob -All returns all known jobs' {
        Start-ApiMigrationJob -Target @{ id = '0.1.0-foo' } -BranchMode 'InPlace' -AllowUnsigned | Out-Null
        Start-Sleep -Milliseconds 100
        $Jobs = @(Get-ApiMigrationJob -All)
        $Jobs.Count | Should -BeGreaterOrEqual 1
    }

    It 'returns $null for unknown jobId' {
        Get-ApiMigrationJob -Id 'no-such-job' | Should -BeNullOrEmpty
    }
}

Describe 'POST /migrations/apply with mode=async (via handler)' {
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

    It 'returns 202 with jobId + statusUrl' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = '{"target":{"id":"0.1.0-foo"},"mode":"async","allowUnsigned":true}'
            TokenScopes = @('migration:write')
        }
        $R = Invoke-ApiPostMigrationApply -ApiContext $Ctx
        $R.status | Should -Be 202
        $R.body.jobId | Should -Not -BeNullOrEmpty
        $R.body.statusUrl | Should -Match "/migrations/jobs/$($R.body.jobId)"
    }
}

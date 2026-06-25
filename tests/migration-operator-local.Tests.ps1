<#
    .SYNOPSIS
    Pester tests for WP-12 operator-local migrations (unsigned warning + gate).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'plugin-hooks.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-config.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-artifact.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-log.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-runtime.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migration.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-oplocal-" + [Guid]::NewGuid().ToString('N'))
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

Describe 'WP-12 operator-local migration gate' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo; Clear-MigrationCatalogCache }

    It 'catalog tags operator-local migration with Origin=OperatorLocal' {
        $C = Get-MigrationCatalog -RepoRoot $script:Repo
        $M = $C | Where-Object { $_.Slug -eq 'foo' } | Select-Object -First 1
        $M.Origin | Should -Be 'OperatorLocal'
    }

    It 'manifest validation flags operator-local origin with Unsigned warning' {
        $C = Get-MigrationCatalog -RepoRoot $script:Repo
        $M = $C | Where-Object { $_.Slug -eq 'foo' } | Select-Object -First 1
        ($M.Validation.Warnings -join "`n") | Should -Match 'Unsigned operator-local'
    }

    It 'apply without -AllowUnsigned throws UnsignedMigrationBlocked' {
        { Invoke-Migration -Version '0.1.0' -RepoRoot $script:Repo -Confirm:$false } |
            Should -Throw -ErrorId 'UnsignedMigrationBlocked,Invoke-MigrationInternal'
    }

    It 'apply with -AllowUnsigned succeeds' {
        $R = Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        $R.OK | Should -BeTrue
    }

    It 'Module-origin migration apply does NOT require -AllowUnsigned' {
        # Synthesize a Module-origin migration by writing into the module's
        # migrations/ directory (cleaned up after).
        $ModMigDir = Join-Path $script:ModuleRoot 'migrations' '0.99.0-modtest'
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $ModMigDir -Recurse -ErrorAction Stop
        # Rewrite manifest version + slug
        @"
@{
    Version              = '0.99.0'
    MajorName            = ''
    Slug                 = 'modtest'
    Description          = 'Module-origin synthetic'
    Author               = 'test'
    AffectsCategories    = @('DataRewrite')
    EstimatedDurationSec = 1
}
"@ | Set-Content (Join-Path $ModMigDir 'migration.psd1') -Encoding UTF8
        Clear-MigrationCatalogCache
        try {
            $C = Get-MigrationCatalog -RepoRoot $script:Repo
            $M = $C | Where-Object { $_.Slug -eq 'modtest' } | Select-Object -First 1
            $M.Origin | Should -Be 'Module'
            # No -AllowUnsigned needed
            $R = Invoke-Migration -Version '0.99.0' -RepoRoot $script:Repo -Confirm:$false
            $R.OK | Should -BeTrue
        } finally {
            Remove-Item -Recurse -Force $ModMigDir
            Clear-MigrationCatalogCache
        }
    }
}

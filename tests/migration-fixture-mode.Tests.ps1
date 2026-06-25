<#
    .SYNOPSIS
    Pester tests for WP-14 fixture migration mode.
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
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migrationchain.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'
}

Describe 'WP-14 Invoke-FixtureMigrations' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Fix = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-fixmig-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:Fix)
        $LocalDir = Join-Path $script:Fix '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
        Copy-Item (Join-Path $script:FixtureMigRoot '0.2.0-bar') $LocalDir -Recurse
    }
    AfterEach {
        if ([System.IO.Directory]::Exists($script:Fix)) {
            [System.IO.Directory]::Delete($script:Fix, $true)
        }
        Clear-MigrationCatalogCache
        Initialize-TestFilesystemFirewall
    }

    It 'advances schema.json against the fixture directory' {
        # 'latest' for OperatorLocal-only catalog returns empty; use explicit version.
        Set-RepoRoot -Path $script:Fix
        try {
            Invoke-MigrationChain -To '0.2.0' -BranchMode InPlace -AllowUnsigned -Confirm:$false | Out-Null
        } finally { Set-RepoRoot -Reset; Initialize-TestFilesystemFirewall }
        $Schema = Read-JsonStateFile -Path (Join-Path $script:Fix '.robot.local' 'schema.json')
        $Schema.current | Should -Be '0.2.0'
    }

    It 'is idempotent — second invocation is a no-op' {
        Set-RepoRoot -Path $script:Fix
        try {
            Invoke-MigrationChain -To '0.2.0' -BranchMode InPlace -AllowUnsigned -Confirm:$false | Out-Null
            $R2 = Invoke-MigrationChain -To '0.2.0' -BranchMode InPlace -AllowUnsigned -Confirm:$false
            @($R2.Applied).Count | Should -Be 0
        } finally { Set-RepoRoot -Reset; Initialize-TestFilesystemFirewall }
    }
}

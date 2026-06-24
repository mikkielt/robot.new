<#
    .SYNOPSIS
    Pester tests for WP-9 cache-format migration fast path.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-cache.ps1')

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-cache-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-IsolatedRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
    function Add-CacheMigration {
        param([string]$LocalDir, [string]$Slug, [string]$Version, [string]$Origin = 'OperatorLocal')
        $MDir = Join-Path $LocalDir "$Version-$Slug"
        [void][System.IO.Directory]::CreateDirectory($MDir)
        @"
@{
    Version              = '$Version'
    MajorName            = ''
    Slug                 = '$Slug'
    Description          = 'Cache fixture'
    Author               = 'test'
    AffectsCategories    = @('Cache')
    EstimatedDurationSec = 0
}
"@ | Set-Content (Join-Path $MDir 'migration.psd1') -Encoding UTF8
        @'
function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{ Migration = '__cache__' }
}
function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)] param([hashtable]$Config)
    return [PSCustomObject]@{ OK = $true }
}
function Invoke-CacheMigration {
    [CmdletBinding()] param()
    return $true
}
'@ | Set-Content (Join-Path $MDir 'migrate.ps1') -Encoding UTF8
    }
}

Describe 'WP-9 cache fast path' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'records applied cache migration in .robot.local/.cache/migrations.json' {
        # We use a Module-origin synthetic fixture to bypass the OperatorLocal filter.
        $ModMigDir = Join-Path $script:ModuleRoot 'migrations' '0.99.0-cachetest'
        Add-CacheMigration -LocalDir (Join-Path $script:ModuleRoot 'migrations') -Slug 'cachetest' -Version '0.99.0'
        try {
            Clear-MigrationCatalogCache
            Invoke-CacheMigrations -RepoRoot $script:Repo
            $Path = Join-Path $script:Repo '.robot.local' '.cache' 'migrations.json'
            [System.IO.File]::Exists($Path) | Should -BeTrue
            $Raw = Read-JsonStateFile -Path $Path
            $Raw.applied.PSObject.Properties.Name | Should -Contain '0.99.0-cachetest'
        } finally {
            Remove-Item -Recurse -Force $ModMigDir -ErrorAction SilentlyContinue
            Clear-MigrationCatalogCache
        }
    }

    It 'skips OperatorLocal cache migrations (security filter)' {
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Add-CacheMigration -LocalDir $LocalDir -Slug 'rogue' -Version '0.99.0' -Origin 'OperatorLocal'
        Clear-MigrationCatalogCache
        Invoke-CacheMigrations -RepoRoot $script:Repo
        $Path = Join-Path $script:Repo '.robot.local' '.cache' 'migrations.json'
        if ([System.IO.File]::Exists($Path)) {
            $Raw = Read-JsonStateFile -Path $Path
            ($Raw.applied.PSObject.Properties.Name) | Should -Not -Contain '0.99.0-rogue'
        }
    }

    It 'is idempotent — second invocation does not re-run' {
        $ModMigDir = Join-Path $script:ModuleRoot 'migrations' '0.99.1-cachetest'
        Add-CacheMigration -LocalDir (Join-Path $script:ModuleRoot 'migrations') -Slug 'cachetest' -Version '0.99.1'
        try {
            Clear-MigrationCatalogCache
            Invoke-CacheMigrations -RepoRoot $script:Repo
            $Path = Join-Path $script:Repo '.robot.local' '.cache' 'migrations.json'
            $FirstStamp = (Get-Item $Path).LastWriteTimeUtc
            Start-Sleep -Milliseconds 50
            Invoke-CacheMigrations -RepoRoot $script:Repo
            $SecondStamp = (Get-Item $Path).LastWriteTimeUtc
            $SecondStamp | Should -Be $FirstStamp
        } finally {
            Remove-Item -Recurse -Force $ModMigDir -ErrorAction SilentlyContinue
            Clear-MigrationCatalogCache
        }
    }
}

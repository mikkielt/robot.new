<#
    .SYNOPSIS
    Pester tests for the migration preview contract (WP-4).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migrationpreview.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-preview-" + [Guid]::NewGuid().ToString('N'))
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

Describe 'Get-MigrationPreview' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'dispatches to the migration script and returns Object form' {
        $P = Get-MigrationPreview -Version '0.1.0' -RepoRoot $script:Repo
        $P.Migration | Should -Be '0.1.0-foo'
        $P.NetworkRequired | Should -BeFalse
    }

    It 'returns Json form when -Format Json' {
        $J = Get-MigrationPreview -Version '0.1.0' -Format Json -RepoRoot $script:Repo
        $J | Should -BeOfType [string]
        $Parsed = $J | ConvertFrom-Json
        $Parsed.Migration | Should -Be '0.1.0-foo'
    }

    It 'returns Markdown form when -Format Markdown' {
        $M = Get-MigrationPreview -Version '0.1.0' -Format Markdown -RepoRoot $script:Repo
        $M | Should -Match 'Migration 0\.1\.0-foo'
        $M | Should -Match '### Files'
    }

    It 'throws when migration not found' {
        { Get-MigrationPreview -Version '99.0.0' -RepoRoot $script:Repo } |
            Should -Throw -ErrorId 'MigrationNotFound,Get-MigrationPreview'
    }

    It 'preview does not write to the filesystem' {
        $Sentinel = Join-Path $script:Repo 'sentinel.txt'
        [System.IO.File]::WriteAllText($Sentinel, 'before')
        $Before = (Get-Item $Sentinel).LastWriteTimeUtc
        Get-MigrationPreview -Version '0.1.0' -RepoRoot $script:Repo | Out-Null
        $After = (Get-Item $Sentinel).LastWriteTimeUtc
        $Before | Should -Be $After
    }
}

Describe 'Get-MigrationPreview RequiresNetwork degradation' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        $MDir = Join-Path $LocalDir '0.1.0-netty'
        [void][System.IO.Directory]::CreateDirectory($MDir)
        @'
@{
    Version              = '0.1.0'
    MajorName            = ''
    Slug                 = 'netty'
    Description          = 'Network-bound preview fixture'
    Author               = 'test'
    AffectsCategories    = @('ExternalImport')
    EstimatedDurationSec = 5
    RequiresNetwork      = $true
}
'@ | Set-Content (Join-Path $MDir 'migration.psd1') -Encoding UTF8
        @'
function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.1.0-netty'
        EstimatedDurationSec = 5
        FilesToModify        = @('cached-file.json')
        FilesToCreate        = @()
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @()
        NetworkRequired      = $true
        SourceUnchanged      = $false
    }
}
function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)] param([hashtable]$Config)
    return [PSCustomObject]@{ OK = $true }
}
'@ | Set-Content (Join-Path $MDir 'migrate.ps1') -Encoding UTF8
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo; Clear-MigrationCatalogCache }

    It 'blanks file lists and warns when network not allowed' {
        $P = Get-MigrationPreview -Version '0.1.0' -RepoRoot $script:Repo
        @($P.FilesToModify).Count | Should -Be 0
        ($P.Warnings -join "`n") | Should -Match 'Network required'
    }

    It 'returns real preview when -AllowNetworkInPreview is set' {
        $P = Get-MigrationPreview -Version '0.1.0' -AllowNetworkInPreview -RepoRoot $script:Repo
        @($P.FilesToModify).Count | Should -Be 1
    }
}

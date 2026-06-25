<#
    .SYNOPSIS
    Pester tests for WP-10 OnlyIfSourceChanged external-import idempotency.
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

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-extimp-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-IsolatedRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
    function Add-ExternalImportMigration {
        param([string]$Dir, [string]$Hash)
        [void][System.IO.Directory]::CreateDirectory($Dir)
        @"
@{
    Version              = '0.1.0'
    MajorName            = ''
    Slug                 = 'import'
    Description          = 'External import fixture'
    Author               = 'test'
    AffectsCategories    = @('ExternalImport')
    EstimatedDurationSec = 1
    OnlyIfSourceChanged  = `$true
    SourceHashScript     = 'source-hash.ps1'
}
"@ | Set-Content (Join-Path $Dir 'migration.psd1') -Encoding UTF8
        @"
param(`[hashtable]`$Config)
return '$Hash'
"@ | Set-Content (Join-Path $Dir 'source-hash.ps1') -Encoding UTF8
        @'
function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration = '0.1.0-import'; EstimatedDurationSec = 1
        FilesToModify = @(); FilesToCreate = @(); FilesToDelete = @()
        EntityCountsBefore = @{}; EntityCountsAfter = @{}
        SampleDiffs = @(); Warnings = @()
        NetworkRequired = $false; SourceUnchanged = $false
    }
}
function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(Mandatory)][hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [hashtable]$Checklist
    )
    return [PSCustomObject]@{ OK = $true; FilesWritten = @() }
}
'@ | Set-Content (Join-Path $Dir 'migrate.ps1') -Encoding UTF8
    }
}

Describe 'WP-10 OnlyIfSourceChanged' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        Add-ExternalImportMigration -Dir (Join-Path $LocalDir '0.1.0-import') -Hash 'sha256:aaa'
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo; Clear-MigrationCatalogCache }

    It 'first apply runs the migration and records the source hash' {
        $R = Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        $R.OK | Should -BeTrue
        $R.Skipped | Should -BeFalse
        $Rec = Get-MigrationRecord -MigrationId '0.1.0-import' -RepoRoot $script:Repo
        $Rec.sourceHash | Should -Be 'sha256:aaa'
    }

    It 'second apply is skipped when source hash unchanged' {
        Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        # Schema is now 0.1.0; bump it back to allow the second apply.
        # The runtime is still callable for already-applied migrations and will
        # consult OnlyIfSourceChanged. Reset the schema pointer to 0.0.0 first
        # so the prerequisite check passes on a re-run.
        $StatePath = Join-Path $script:Repo '.robot.local' 'schema.json'
        $Raw = Read-JsonStateFile -Path $StatePath
        $Raw.current = '0.0.0'
        Save-JsonStateFile -Path $StatePath -Data $Raw
        $R = Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        $R.Skipped | Should -BeTrue
        $R.Reason | Should -Be 'source-unchanged'
    }

    It 're-applies when source hash changes' {
        Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        # Rewrite the hash script to return a new value
        $HashScript = Join-Path $script:Repo '.robot.local' 'migrations' '0.1.0-import' 'source-hash.ps1'
        @'
param([hashtable]$Config)
return 'sha256:bbb'
'@ | Set-Content $HashScript -Encoding UTF8
        # Reset schema pointer to allow re-apply
        $StatePath = Join-Path $script:Repo '.robot.local' 'schema.json'
        $Raw = Read-JsonStateFile -Path $StatePath
        $Raw.current = '0.0.0'
        Save-JsonStateFile -Path $StatePath -Data $Raw

        $R = Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        $R.Skipped | Should -BeFalse
        $Rec = Get-MigrationRecord -MigrationId '0.1.0-import' -RepoRoot $script:Repo
        $Rec.sourceHash | Should -Be 'sha256:bbb'
    }
}

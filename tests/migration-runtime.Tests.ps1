<#
    .SYNOPSIS
    Pester tests for the migration runtime (WP-3).

    .DESCRIPTION
    Covers Invoke-MigrationInternal (single-migration apply, per-record state
    update, schema advance), Invoke-Migration (lock acquisition, prerequisite
    check), Invoke-MigrationChain (sequential apply, lock once for the whole
    chain), Reset-MigrationLock, Reset-SchemaVersion (downgrade), the legacy
    state-file shim, and BeforeMigration/AfterMigration plugin hook firing.
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
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'reset-migrationlock.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'reset-schemaversion.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-runtime-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-IsolatedRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
    function Initialize-RepoWithFixtures {
        param([string]$Repo, [string[]]$Slugs)
        $LocalDir = Join-Path $Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        $Map = @{ 'foo' = '0.1.0-foo'; 'bar' = '0.2.0-bar'; 'baz' = '0.3.0-baz' }
        foreach ($S in $Slugs) {
            Copy-Item (Join-Path $script:FixtureMigRoot $Map[$S]) $LocalDir -Recurse
        }
    }
}

Describe 'Invoke-Migration (single)' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        Initialize-RepoWithFixtures -Repo $script:Repo -Slugs @('foo')
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'applies an operator-local migration with -AllowUnsigned and advances schema' {
        $R = Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        $R.OK | Should -BeTrue
        $R.MigrationId | Should -Be '0.1.0-foo'
        $S = Get-SchemaVersion -RepoRoot $script:Repo
        $S.Current | Should -Be '0.1.0'
        $S.AppliedMigrationId | Should -Be '0.1.0-foo'
    }

    It 'refuses operator-local migration without -AllowUnsigned' {
        { Invoke-Migration -Version '0.1.0' -RepoRoot $script:Repo -Confirm:$false } |
            Should -Throw -ErrorId 'UnsignedMigrationBlocked,Invoke-MigrationInternal'
    }

    It 'releases lock in finally even when migration throws' {
        { Invoke-Migration -Version '0.1.0' -RepoRoot $script:Repo -Confirm:$false } | Should -Throw
        $S = Get-SchemaVersion -RepoRoot $script:Repo
        $S.LockedBy | Should -BeNullOrEmpty
    }

    It 'refuses to apply when prerequisite version is not met' {
        # 0.2.0-bar requires 0.1.0; with fresh schema (0.0.0) it should fail.
        Initialize-RepoWithFixtures -Repo $script:Repo -Slugs @('bar')
        Clear-MigrationCatalogCache
        { Invoke-Migration -Version '0.2.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false } |
            Should -Throw -ErrorId 'PrerequisiteNotMet,Invoke-Migration'
    }
}

Describe 'Invoke-MigrationChain' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        Initialize-RepoWithFixtures -Repo $script:Repo -Slugs @('foo','bar','baz')
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'applies foo -> bar -> baz in order' {
        $R = Invoke-MigrationChain -To '0.3.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        $R.OK | Should -BeTrue
        # Chain includes module-shipped 0.1.1-bootstrap-entities and 0.1.2-commit-bootstrap
        # alongside operator-local foo/bar/baz overrides at the minor-version boundaries.
        $AppliedIds = @($R.Applied | ForEach-Object { $_.MigrationId })
        $AppliedIds | Should -Contain '0.1.0-foo'
        $AppliedIds | Should -Contain '0.2.0-bar'
        $AppliedIds | Should -Contain '0.3.0-baz'
        $S = Get-SchemaVersion -RepoRoot $script:Repo
        $S.Current | Should -Be '0.3.0'
    }

    It 'is a no-op when current schema already equals target' {
        Invoke-MigrationChain -To '0.3.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        $R = Invoke-MigrationChain -To '0.3.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false
        @($R.Applied).Count | Should -Be 0
    }

    It 'releases lock at the end of the chain' {
        Invoke-MigrationChain -To '0.3.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        $S = Get-SchemaVersion -RepoRoot $script:Repo
        $S.LockedBy | Should -BeNullOrEmpty
    }
}

Describe 'Reset-MigrationLock' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo }

    It 'reports no-op when no lock is held' {
        $R = Reset-MigrationLock -Force -RepoRoot $script:Repo
        $R.WasLocked | Should -BeFalse
    }

    It 'clears an existing lock with -Force' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        $R = Reset-MigrationLock -Force -RepoRoot $script:Repo
        $R.WasLocked | Should -BeTrue
        $R.PreviousOwner | Should -Be 'alice'
        $S = Get-SchemaVersion -RepoRoot $script:Repo
        $S.LockedBy | Should -BeNullOrEmpty
    }
}

Describe 'Reset-SchemaVersion (downgrade)' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        Initialize-RepoWithFixtures -Repo $script:Repo -Slugs @('foo','bar')
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo; Clear-MigrationCatalogCache }

    It 'refuses to downgrade to a version not in history' {
        Invoke-MigrationChain -To '0.2.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        { Reset-SchemaVersion -To '99.0.0' -RepoRoot $script:Repo -Confirm:$false } |
            Should -Throw -ErrorId 'VersionNotInHistory,Reset-SchemaVersion'
    }

    It 'downgrades the pointer when target is in history' {
        Invoke-MigrationChain -To '0.2.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        $R = Reset-SchemaVersion -To '0.1.0' -Reason 'reverted via git' -RepoRoot $script:Repo -Confirm:$false
        $R.OK | Should -BeTrue
        $R.From | Should -Be '0.2.0'
        $R.To | Should -Be '0.1.0'
        $S = Get-SchemaVersion -RepoRoot $script:Repo
        $S.Current | Should -Be '0.1.0'
    }
}

Describe 'Legacy migration-state.json shim' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo }

    It 'converts legacy Phases dict into migrations dict on read' {
        $StatePath = Join-Path $script:Repo '.robot.local' 'res' 'migration-state.json'
        [void][System.IO.Directory]::CreateDirectory((Split-Path $StatePath -Parent))
        $Legacy = [ordered]@{
            Version = '2.0'
            Phases = [ordered]@{
                '0' = [ordered]@{ Status = 'Completed'; Checklist = @{ done = $true } }
                '5' = [ordered]@{ Status = 'InProgress'; Checklist = @{ part1 = $true } }
            }
        }
        Save-JsonStateFile -Path $StatePath -Data $Legacy
        $State = Get-MigrationStateFile -RepoRoot $script:Repo
        $State.Migrations.ContainsKey('0.1.0-bootstrap-entities') | Should -BeTrue
        $State.Migrations['0.1.0-bootstrap-entities'].status | Should -Be 'Completed'
        $State.Migrations.ContainsKey('0.6.0-upgrade-session-formats') | Should -BeTrue
        $State.Migrations['0.6.0-upgrade-session-formats'].status | Should -Be 'InProgress'
    }
}

Describe 'BeforeMigration/AfterMigration plugin hook firing' {
    BeforeEach {
        Clear-MigrationCatalogCache
        Clear-KnownMajorNameCache
        $script:Repo = New-IsolatedRepoRoot
        Initialize-RepoWithFixtures -Repo $script:Repo -Slugs @('foo')
        $script:HookCalls = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach { Remove-IsolatedRepoRoot -Path $script:Repo; Clear-MigrationCatalogCache }

    It 'fires BeforeMigration then AfterMigration' {
        Mock Invoke-PluginHook {
            param($Operation, $Phase, $Context)
            $script:HookCalls.Add(("{0}:{1}" -f $Operation, $Phase))
        }
        Invoke-Migration -Version '0.1.0' -AllowUnsigned -RepoRoot $script:Repo -Confirm:$false | Out-Null
        $script:HookCalls | Should -Contain 'Migration:BeforeMigration'
        $script:HookCalls | Should -Contain 'Migration:AfterMigration'
        $BeforeIdx = $script:HookCalls.IndexOf('Migration:BeforeMigration')
        $AfterIdx  = $script:HookCalls.IndexOf('Migration:AfterMigration')
        $BeforeIdx | Should -BeLessThan $AfterIdx
    }
}

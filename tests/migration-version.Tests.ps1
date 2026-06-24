<#
    .SYNOPSIS
    Pester tests for the schema version store (WP-1).

    .DESCRIPTION
    Covers Get-SchemaVersion (public projection + fresh-repo fabrication),
    Set-SchemaVersion (atomic write + history append), Lock-Schema /
    Unlock-Schema (contention + stale-lock detection), Compare-SchemaVersion
    (SemVer ordering, composite plugin-version ordering), Test-MajorNameDrift.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    # Pattern B: dot-source private helpers so test scope sees them
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-schema-" + [Guid]::NewGuid().ToString('N'))
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

Describe 'Compare-SchemaVersion' {
    It 'returns 0 for identical versions' {
        Compare-SchemaVersion '1.0.0' '1.0.0' | Should -Be 0
    }
    It 'returns -1 when A is older by patch' {
        Compare-SchemaVersion '1.0.0' '1.0.1' | Should -Be -1
    }
    It 'returns 1 when A is newer by major' {
        Compare-SchemaVersion '2.0.0' '1.99.99' | Should -Be 1
    }
    It 'handles double-digit minor numerically (not lexically)' {
        Compare-SchemaVersion '10.0.0' '9.99.99' | Should -Be 1
    }
    It 'treats build-tagged version as greater than untagged at same core' {
        Compare-SchemaVersion '21.3.7+plugin-foo.1' '21.3.7' | Should -Be 1
        Compare-SchemaVersion '21.3.7' '21.3.7+plugin-foo.1' | Should -Be -1
    }
    It 'orders two build-tagged versions lexically' {
        Compare-SchemaVersion '21.3.7+foo.1' '21.3.7+foo.2' | Should -Be -1
        Compare-SchemaVersion '21.3.7+bar.9' '21.3.7+foo.1' | Should -Be -1
    }
    It 'still orders by core when build tags exist on both sides' {
        Compare-SchemaVersion '21.3.7+foo.99' '21.3.8' | Should -Be -1
    }
}

Describe 'Get-SchemaVersion on fresh repo' {
    BeforeEach {
        $script:Repo = New-IsolatedRepoRoot
        Clear-KnownMajorNameCache
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
    }

    It 'fabricates 0.0.0 with Exists=$false when schema.json missing' {
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.Current | Should -Be '0.0.0'
        $V.MajorName | Should -Be ''
        $V.Exists | Should -BeFalse
        @($V.History).Count | Should -Be 0
    }
}

Describe 'Set-SchemaVersion' {
    BeforeEach {
        $script:Repo = New-IsolatedRepoRoot
        Clear-KnownMajorNameCache
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
    }

    It 'writes initial schema.json on a fresh repo' {
        Set-SchemaVersion -Version '0.1.0' -MajorName '' -MigrationId '0.1.0-bootstrap-entities' -AppliedBy 'tester' -RepoRoot $script:Repo
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.Current | Should -Be '0.1.0'
        $V.AppliedBy | Should -Be 'tester'
        $V.Exists | Should -BeTrue
        @($V.History).Count | Should -Be 0      # nothing prior
    }

    It 'appends previous current to history on second write' {
        Set-SchemaVersion -Version '0.1.0' -MajorName '' -MigrationId '0.1.0-a' -AppliedBy 'tester' -RepoRoot $script:Repo
        Set-SchemaVersion -Version '0.2.0' -MajorName '' -MigrationId '0.2.0-b' -AppliedBy 'tester' -RepoRoot $script:Repo
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.Current | Should -Be '0.2.0'
        @($V.History).Count | Should -Be 1
        @($V.History)[0].version | Should -Be '0.1.0'
    }

    It 'creates .bak on subsequent write (atomic swap)' {
        Set-SchemaVersion -Version '0.1.0' -MajorName '' -MigrationId 'a' -AppliedBy 'tester' -RepoRoot $script:Repo
        Set-SchemaVersion -Version '0.2.0' -MajorName '' -MigrationId 'b' -AppliedBy 'tester' -RepoRoot $script:Repo
        $Path = Join-Path $script:Repo '.robot.local' 'schema.json'
        [System.IO.File]::Exists("$Path.bak") | Should -BeTrue
        [System.IO.File]::Exists("$Path.tmp") | Should -BeFalse
    }
}

Describe 'Lock-Schema / Unlock-Schema' {
    BeforeEach {
        $script:Repo = New-IsolatedRepoRoot
        Clear-KnownMajorNameCache
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
    }

    It 'acquires a lock on a fresh repo and fabricates 0.0.0' {
        Lock-Schema -LockOwner 'alice@host/123' -RepoRoot $script:Repo
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.LockedBy | Should -Be 'alice@host/123'
        $V.LockedAt | Should -Not -BeNullOrEmpty
        $V.Current | Should -Be '0.0.0'
    }

    It 'refuses a second concurrent lock' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        { Lock-Schema -LockOwner 'bob' -RepoRoot $script:Repo } | Should -Throw -ErrorId 'SchemaLocked,Lock-Schema'
    }

    It 'allows -Force to override an existing lock' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        Lock-Schema -LockOwner 'bob' -Force -RepoRoot $script:Repo
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.LockedBy | Should -Be 'bob'
    }

    It 'Unlock-Schema clears lockedBy/lockedAt' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        Unlock-Schema -RepoRoot $script:Repo
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.LockedBy | Should -BeNullOrEmpty
        $V.LockedAt | Should -BeNullOrEmpty
    }

    It 'Unlock-Schema is a no-op when no lock exists' {
        { Unlock-Schema -RepoRoot $script:Repo } | Should -Not -Throw
    }

    It 'Lock survives Set-SchemaVersion (Set preserves lock fields)' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        Set-SchemaVersion -Version '0.1.0' -MajorName '' -MigrationId 'm1' -AppliedBy 'alice' -RepoRoot $script:Repo
        $V = Get-SchemaVersion -RepoRoot $script:Repo
        $V.LockedBy | Should -Be 'alice'
        $V.Current | Should -Be '0.1.0'
    }
}

Describe 'Test-SchemaLockStale' {
    BeforeEach {
        $script:Repo = New-IsolatedRepoRoot
        Clear-KnownMajorNameCache
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
    }

    It 'returns $false for a fresh lock' {
        Lock-Schema -LockOwner 'alice' -RepoRoot $script:Repo
        Test-SchemaLockStale -RepoRoot $script:Repo | Should -BeFalse
    }

    It 'returns $false when no lock is held' {
        Test-SchemaLockStale -RepoRoot $script:Repo | Should -BeFalse
    }

    It 'returns $true when lockedAt exceeds TTL' {
        # Hand-craft a state file with an ancient lock.
        $Path = Join-Path $script:Repo '.robot.local' 'schema.json'
        [void][System.IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
        $Ancient = [datetime]::UtcNow.AddHours(-2).ToString('o')
        $Data = [ordered]@{
            schemaFileVersion = 1; current = '0.0.0'; majorName = ''
            appliedAt = ''; appliedBy = ''; appliedMigrationId = ''
            lockedBy = 'alice'; lockedAt = $Ancient; history = @()
        }
        Save-JsonStateFile -Path $Path -Data $Data
        Test-SchemaLockStale -RepoRoot $script:Repo | Should -BeTrue
    }
}

Describe 'Test-MajorNameDrift' {
    BeforeEach {
        $script:Repo = New-IsolatedRepoRoot
        Clear-KnownMajorNameCache
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
    }

    It 'reports no drift on a fresh repo' {
        $R = Test-MajorNameDrift -Version '21.3.7' -ProposedName 'Yellow Threat' -RepoRoot $script:Repo
        $R.Drift | Should -BeFalse
    }

    It 'reports drift when a known MAJOR has a different name' {
        Set-SchemaVersion -Version '21.3.6' -MajorName 'Yellow Threat' -MigrationId 'm1' -AppliedBy 't' -RepoRoot $script:Repo
        Clear-KnownMajorNameCache
        $R = Test-MajorNameDrift -Version '21.3.7' -ProposedName 'Crimson Tide' -RepoRoot $script:Repo
        $R.Drift | Should -BeTrue
        $R.KnownName | Should -Be 'Yellow Threat'
        $R.Proposed | Should -Be 'Crimson Tide'
    }
}

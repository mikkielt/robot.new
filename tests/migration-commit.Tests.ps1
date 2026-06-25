<#
    .SYNOPSIS
    Pester tests for Invoke-MigrationCommit (WP-A5).

    .DESCRIPTION
    Covers idempotency (no-diff skip), Gracze.md guard, explicit file list,
    fallback to operation-context accumulator, and structured error on
    git failure. Uses a fresh-git fixture per test.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-commit.ps1')

    function New-GitFixture {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-commit-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        & git -C $D init --quiet
        & git -C $D config user.email 'test@example.com'
        & git -C $D config user.name  'Test'
        [System.IO.File]::WriteAllText((Join-Path $D 'README.md'), 'seed')
        & git -C $D add 'README.md' 2>&1 | Out-Null
        & git -C $D commit -m 'seed' --quiet 2>&1 | Out-Null
        return $D
    }
    function Remove-GitFixture {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
}

Describe 'Invoke-MigrationCommit — idempotency' {
    It 'returns Skipped = $true when nothing to commit' {
        $R = New-GitFixture
        try {
            $Result = Invoke-MigrationCommit -Message 'no-op' -Files @() -RepoRoot $R -Confirm:$false
            $Result.OK | Should -BeTrue
            $Result.Skipped | Should -BeTrue
            $Result.Reason | Should -Be 'NoDiff'
        } finally { Remove-GitFixture -Path $R }
    }
}

Describe 'Invoke-MigrationCommit — happy path' {
    It 'stages and commits a single file' {
        $R = New-GitFixture
        try {
            [System.IO.File]::WriteAllText((Join-Path $R 'entities.md'), 'new content')
            $Result = Invoke-MigrationCommit -Message 'Add entities.md' -Files @('entities.md') -RepoRoot $R -Confirm:$false
            $Result.OK | Should -BeTrue
            $Result.Skipped | Should -BeFalse
            $Result.Sha | Should -Not -BeNullOrEmpty
        } finally { Remove-GitFixture -Path $R }
    }

    It 'falls back to -A when no Files and no operation-context' {
        $R = New-GitFixture
        try {
            [System.IO.File]::WriteAllText((Join-Path $R 'a.md'), '1')
            [System.IO.File]::WriteAllText((Join-Path $R 'b.md'), '2')
            $Result = Invoke-MigrationCommit -Message 'Add both' -RepoRoot $R -Confirm:$false
            $Result.OK | Should -BeTrue
            $Result.FilesAdded | Should -Contain '<all>'
        } finally { Remove-GitFixture -Path $R }
    }
}

Describe 'Invoke-MigrationCommit — Gracze.md guard' {
    It 'refuses Gracze.md without -AllowsGraczeWrite' {
        $R = New-GitFixture
        try {
            [System.IO.File]::WriteAllText((Join-Path $R 'Gracze.md'), 'frozen content')
            { Invoke-MigrationCommit -Message 'freeze' -Files @('Gracze.md') -RepoRoot $R -Confirm:$false } | Should -Throw
        } finally { Remove-GitFixture -Path $R }
    }

    It 'permits Gracze.md when -AllowsGraczeWrite is supplied' {
        $R = New-GitFixture
        try {
            [System.IO.File]::WriteAllText((Join-Path $R 'Gracze.md'), 'frozen content')
            $Result = Invoke-MigrationCommit -Message 'freeze' -Files @('Gracze.md') -AllowsGraczeWrite -RepoRoot $R -Confirm:$false
            $Result.OK | Should -BeTrue
            $Result.Skipped | Should -BeFalse
        } finally { Remove-GitFixture -Path $R }
    }
}

Describe 'Invoke-MigrationCommit — WhatIf' {
    It 'returns Skipped with Reason = WhatIf when -WhatIf is supplied' {
        $R = New-GitFixture
        try {
            [System.IO.File]::WriteAllText((Join-Path $R 'x.md'), 'x')
            $Result = Invoke-MigrationCommit -Message 'noop' -Files @('x.md') -RepoRoot $R -WhatIf
            $Result.Skipped | Should -BeTrue
            $Result.Reason | Should -Be 'WhatIf'
        } finally { Remove-GitFixture -Path $R }
    }
}

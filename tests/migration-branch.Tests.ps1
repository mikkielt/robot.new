<#
    .SYNOPSIS
    Pester tests for WP-6 branching modes.

    .DESCRIPTION
    Uses throwaway git repos under temp directory; never touches a real remote.
    Skips if `git` is not available.
#>

# Probe git at discovery time so -Skip can read the result.
$script:GitAvailable = $null
try {
    $null = & git --version 2>&1
    $script:GitAvailable = $LASTEXITCODE -eq 0
} catch { $script:GitAvailable = $false }

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-branch.ps1')

    function New-TempGitRepo {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-branch-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        & git -C $D init -q -b main 2>&1 | Out-Null
        & git -C $D config user.email "test@example.com" 2>&1 | Out-Null
        & git -C $D config user.name "Test User" 2>&1 | Out-Null
        # initial commit so HEAD is non-empty
        [System.IO.File]::WriteAllText((Join-Path $D 'README.md'), 'init')
        & git -C $D add -A 2>&1 | Out-Null
        & git -C $D commit -q -m 'init' 2>&1 | Out-Null
        return $D
    }
    function Remove-TempGitRepo {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
}

Describe 'Test-WorkingTreeDirty' -Skip:(-not $script:GitAvailable) {
    BeforeEach { $script:Repo = New-TempGitRepo }
    AfterEach { Remove-TempGitRepo -Path $script:Repo }

    It 'returns $false on a clean tree' {
        Test-WorkingTreeDirty -RepoRoot $script:Repo | Should -BeFalse
    }
    It 'returns $true when there is an unstaged change' {
        [System.IO.File]::WriteAllText((Join-Path $script:Repo 'README.md'), 'changed')
        Test-WorkingTreeDirty -RepoRoot $script:Repo | Should -BeTrue
    }
    It 'returns $false for a non-git directory' {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("not-git-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        try {
            Test-WorkingTreeDirty -RepoRoot $D | Should -BeFalse
        } finally { [System.IO.Directory]::Delete($D, $true) }
    }
}

Describe 'Enter-MigrationBranch + Save-MigrationCommit + Exit-MigrationBranch' -Skip:(-not $script:GitAvailable) {
    BeforeEach { $script:Repo = New-TempGitRepo }
    AfterEach { Remove-TempGitRepo -Path $script:Repo }

    It 'creates and checks out a migration branch' {
        Enter-MigrationBranch -BranchName 'migration/add-foo-0.1.0' -RepoRoot $script:Repo -Confirm:$false
        $Cur = (& git -C $script:Repo rev-parse --abbrev-ref HEAD).Trim()
        $Cur | Should -Be 'migration/add-foo-0.1.0'
    }

    It 'Save-MigrationCommit stages and commits with structured message' {
        Enter-MigrationBranch -BranchName 'migration/test' -RepoRoot $script:Repo -Confirm:$false
        [System.IO.File]::WriteAllText((Join-Path $script:Repo 'newfile.md'), 'hello')
        $Result = [PSCustomObject]@{ FilesWritten = @('newfile.md') }
        Save-MigrationCommit -RunResult $Result -MigrationId '0.1.0-foo' -RepoRoot $script:Repo -Confirm:$false
        # %B = full raw message including subject
        $Log = ((& git -C $script:Repo log --format=%B -n 1) -join "`n").Trim()
        $Log | Should -Match 'migrate: 0\.1\.0-foo'
        $Log | Should -Match 'Files-Modified: 1'
    }

    It 'Exit-MigrationBranch MergeBack ff-merges into original' {
        Enter-MigrationBranch -BranchName 'migration/ff' -RepoRoot $script:Repo -Confirm:$false
        [System.IO.File]::WriteAllText((Join-Path $script:Repo 'newfile.md'), 'hello')
        Save-MigrationCommit -RunResult ([PSCustomObject]@{ FilesWritten = @('newfile.md') }) -MigrationId 'x' -RepoRoot $script:Repo -Confirm:$false
        Exit-MigrationBranch -Mode MergeBack -RepoRoot $script:Repo -Confirm:$false
        $Cur = (& git -C $script:Repo rev-parse --abbrev-ref HEAD).Trim()
        $Cur | Should -Be 'main'
        Test-Path (Join-Path $script:Repo 'newfile.md') | Should -BeTrue
        # branch was deleted
        $Branches = (& git -C $script:Repo branch).Trim()
        $Branches | Should -Not -Match 'migration/ff'
    }
}

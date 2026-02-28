<#
    .SYNOPSIS
    Pester tests for get-reporoot.ps1.

    .DESCRIPTION
    Tests for Get-RepoRoot and Get-ParentRepoRoot covering .git directory
    discovery, parent repo traversal, submodule boundary detection, and
    error when no repository is found.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path $script:ModuleRoot 'robot.psd1'
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
    . (Join-Path $script:ModuleRoot 'public' 'get-reporoot.ps1')
}

Describe 'Get-RepoRoot' {
    Context 'repository root discovery' {
        It 'returns a path containing a .git directory' {
            $RepoRoot = Get-RepoRoot
            [System.IO.Directory]::Exists((Join-Path $RepoRoot '.git')) | Should -BeTrue
        }

        It 'returns the parent repo root, not the module directory itself' {
            $RepoRoot = [System.IO.Path]::GetFullPath((Get-RepoRoot)).TrimEnd('\', '/')
            $ExpectedRoot = [System.IO.Path]::GetFullPath((Split-Path $script:ModuleRoot -Parent)).TrimEnd('\', '/')

            $RepoRoot | Should -Be $ExpectedRoot
        }

        It 'is independent of the process working directory' {
            $OriginalCwd = [System.IO.Directory]::GetCurrentDirectory()
            try {
                [System.IO.Directory]::SetCurrentDirectory([System.IO.Path]::GetTempPath())

                $RepoRoot = [System.IO.Path]::GetFullPath((Get-RepoRoot)).TrimEnd('\', '/')
                $ExpectedRoot = [System.IO.Path]::GetFullPath((Split-Path $script:ModuleRoot -Parent)).TrimEnd('\', '/')

                $RepoRoot | Should -Be $ExpectedRoot
            }
            finally {
                [System.IO.Directory]::SetCurrentDirectory($OriginalCwd)
            }
        }

        It 'is independent of PowerShell $PWD' {
            $OriginalLocation = Get-Location
            try {
                Set-Location -Path 'Variable:\'

                $RepoRoot = [System.IO.Path]::GetFullPath((Get-RepoRoot)).TrimEnd('\', '/')
                $ExpectedRoot = [System.IO.Path]::GetFullPath((Split-Path $script:ModuleRoot -Parent)).TrimEnd('\', '/')

                $RepoRoot | Should -Be $ExpectedRoot
            }
            finally {
                Set-Location -Path $OriginalLocation.Path
            }
        }

        It 'throws when no .git exists in any parent of the specified module root' {
            $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-get-reporoot-" + [System.Guid]::NewGuid().ToString('N'))
            $TempModule = Join-Path $TempRoot 'fake-module'
            try {
                [void][System.IO.Directory]::CreateDirectory($TempModule)

                { Get-RepoRoot -ModuleRoot $TempModule } | Should -Throw '*No git repository found*'
            }
            finally {
                if ([System.IO.Directory]::Exists($TempRoot)) {
                    [System.IO.Directory]::Delete($TempRoot, $true)
                }
            }
        }

        It 'accepts an explicit -ModuleRoot override' {
            $RepoRoot = [System.IO.Path]::GetFullPath((Get-RepoRoot -ModuleRoot $script:ModuleRoot)).TrimEnd('\', '/')
            $ExpectedRoot = [System.IO.Path]::GetFullPath((Split-Path $script:ModuleRoot -Parent)).TrimEnd('\', '/')

            $RepoRoot | Should -Be $ExpectedRoot
        }
    }
}

Describe 'Get-ParentRepoRoot' {
    It 'returns null when no parent repo exists above temp dir' {
        $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-parent-test-" + [System.Guid]::NewGuid().ToString('N'))
        $FakeRepo = Join-Path $TempRoot 'child-repo'
        try {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $FakeRepo '.git'))
            $Result = Get-ParentRepoRoot -RepoRoot $FakeRepo
            $Result | Should -BeNullOrEmpty
        } finally {
            if ([System.IO.Directory]::Exists($TempRoot)) {
                [System.IO.Directory]::Delete($TempRoot, $true)
            }
        }
    }

    It 'finds parent repo when submodule structure exists' {
        $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-parent-test-" + [System.Guid]::NewGuid().ToString('N'))
        $ParentRepo = Join-Path $TempRoot 'parent'
        $ChildRepo = Join-Path $ParentRepo 'sub' 'child'
        try {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $ParentRepo '.git'))
            [void][System.IO.Directory]::CreateDirectory((Join-Path $ChildRepo '.git'))
            $Result = [System.IO.Path]::GetFullPath((Get-ParentRepoRoot -RepoRoot $ChildRepo)).TrimEnd('\', '/')
            $Expected = [System.IO.Path]::GetFullPath($ParentRepo).TrimEnd('\', '/')
            $Result | Should -Be $Expected
        } finally {
            if ([System.IO.Directory]::Exists($TempRoot)) {
                [System.IO.Directory]::Delete($TempRoot, $true)
            }
        }
    }
}

AfterAll {
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
}

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path $script:ModuleRoot 'robot.psd1'
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
}

Describe 'Get-RepoRoot' {
    Context 'repository root discovery' {
        It 'returns a path containing a .git directory when called from within a git repository' {
            $OriginalProcessCwd = [System.IO.Directory]::GetCurrentDirectory()
            try {
                [System.IO.Directory]::SetCurrentDirectory($PSScriptRoot)
                $RepoRoot = Get-RepoRoot

                [System.IO.Directory]::Exists((Join-Path $RepoRoot '.git')) | Should -BeTrue
            }
            finally {
                [System.IO.Directory]::SetCurrentDirectory($OriginalProcessCwd)
            }
        }

        It 'returns an ancestor or equal path of the process working directory' {
            $OriginalProcessCwd = [System.IO.Directory]::GetCurrentDirectory()
            try {
                [System.IO.Directory]::SetCurrentDirectory($PSScriptRoot)

                $RepoRoot = [System.IO.Path]::GetFullPath((Get-RepoRoot)).TrimEnd('\', '/')
                $CurrentDir = [System.IO.Path]::GetFullPath([System.IO.Directory]::GetCurrentDirectory()).TrimEnd('\', '/')

                $IsAncestor = $CurrentDir.Equals($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $CurrentDir.StartsWith("$RepoRoot$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase) -or
                    $CurrentDir.StartsWith("$RepoRoot$([System.IO.Path]::AltDirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase)

                $IsAncestor | Should -BeTrue
            }
            finally {
                [System.IO.Directory]::SetCurrentDirectory($OriginalProcessCwd)
            }
        }

        It 'throws when no .git exists in any parent directory' {
            $OriginalProcessCwd = [System.IO.Directory]::GetCurrentDirectory()
            $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-get-reporoot-" + [System.Guid]::NewGuid().ToString('N'))
            $TempNested = Join-Path $TempRoot 'nested/child'
            try {
                [System.IO.Directory]::CreateDirectory($TempNested) | Out-Null
                [System.IO.Directory]::SetCurrentDirectory($TempNested)

                { Get-RepoRoot } | Should -Throw 'No git repository found*'
            }
            finally {
                [System.IO.Directory]::SetCurrentDirectory($OriginalProcessCwd)
                if ([System.IO.Directory]::Exists($TempRoot)) {
                    Remove-Item -LiteralPath $TempRoot -Recurse -Force
                }
            }
        }

        It 'uses process current directory and not PowerShell $PWD' {
            $OriginalProcessCwd = [System.IO.Directory]::GetCurrentDirectory()
            $OriginalLocation = Get-Location
            try {
                [System.IO.Directory]::SetCurrentDirectory($PSScriptRoot)
                Set-Location -Path 'Variable:\'

                $ExpectedRepoRoot = [System.IO.Path]::GetFullPath((Split-Path $script:ModuleRoot -Parent)).TrimEnd('\', '/')
                $ActualRepoRoot = [System.IO.Path]::GetFullPath((Get-RepoRoot)).TrimEnd('\', '/')

                $ActualRepoRoot | Should -Be $ExpectedRepoRoot
            }
            finally {
                [System.IO.Directory]::SetCurrentDirectory($OriginalProcessCwd)
                Set-Location -Path $OriginalLocation.Path
            }
        }
    }
}

AfterAll {
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
}

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path $script:ModuleRoot 'robot.psd1'
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
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
                [System.IO.Directory]::CreateDirectory($TempModule) | Out-Null

                { Get-RepoRoot -ModuleRoot $TempModule } | Should -Throw '*No git repository found*'
            }
            finally {
                if ([System.IO.Directory]::Exists($TempRoot)) {
                    Remove-Item -LiteralPath $TempRoot -Recurse -Force
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

AfterAll {
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
}

BeforeAll {
    Import-Module "$PSScriptRoot/../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Test-GitignoreIntegrity' {
    BeforeAll {
        # Use a temp module-root sandbox so we never touch the live .gitignore
        $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rb-gi-" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Sandbox 'templates'))

        # Mirror the shipped required-fragment so the test is self-contained
        [System.IO.File]::WriteAllText(
            (Join-Path $script:Sandbox 'templates/gitignore.required'),
            "# comment`n`n**/.robot.local/.cache/`n")
    }

    AfterAll {
        if (Test-Path $script:Sandbox) {
            Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Required line present' {
        It 'returns Ok=$true when .gitignore has the required entry' {
            [System.IO.File]::WriteAllText(
                (Join-Path $script:Sandbox '.gitignore'),
                "**/.robot.local/.cache/`nthumbs.db`n")
            $R = Test-GitignoreIntegrity -ModuleRoot $script:Sandbox -ForceRefresh
            $R.Ok | Should -BeTrue
            $R.Missing.Count   | Should -Be 0
            $R.Unignored.Count | Should -Be 0
        }
    }

    Context 'Required line removed' {
        It 'returns Ok=$false with Missing populated' {
            [System.IO.File]::WriteAllText(
                (Join-Path $script:Sandbox '.gitignore'),
                "thumbs.db`n")
            $R = Test-GitignoreIntegrity -ModuleRoot $script:Sandbox -ForceRefresh
            $R.Ok | Should -BeFalse
            $R.Missing | Should -Contain '**/.robot.local/.cache/'
        }
    }

    Context 'Negative pattern bypasses protection' {
        It 'detects an `!`-line un-ignoring a protected path' {
            [System.IO.File]::WriteAllText(
                (Join-Path $script:Sandbox '.gitignore'),
                "**/.robot.local/.cache/`n!.robot.local/.cache/api-tokens.psd1`n")
            $R = Test-GitignoreIntegrity -ModuleRoot $script:Sandbox -ForceRefresh
            $R.Ok | Should -BeFalse
            $R.Unignored.Count | Should -BeGreaterThan 0
        }
    }

    Context 'mtime cache' {
        It 'returns the cached result when .gitignore mtime is unchanged' {
            [System.IO.File]::WriteAllText(
                (Join-Path $script:Sandbox '.gitignore'),
                "**/.robot.local/.cache/`n")
            $First  = Test-GitignoreIntegrity -ModuleRoot $script:Sandbox -ForceRefresh
            $First.Ok | Should -BeTrue
            # Second call without ForceRefresh — caller relies on returned hashtable identity
            $Second = Test-GitignoreIntegrity -ModuleRoot $script:Sandbox
            $Second.Ok | Should -BeTrue
        }
    }
}

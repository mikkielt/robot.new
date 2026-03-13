<#
    .SYNOPSIS
    Pester tests for session-decomposehelpers.ps1 (URL localization).

    .DESCRIPTION
    Tests for Resolve-LogUrlToLocalPath, ConvertFrom-PlainTextLog (with
    -LogDirectory), and ConvertTo-Gen4FromRawBlock (with -LogDirectory for
    'logs' tag) covering URL-to-local-path replacement when cached log files
    exist on disk.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Pattern C: dot-source standalone helper files
    . (Join-Path $script:ModuleRoot 'private' 'log-fetchhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'format-sessionblock.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-decomposehelpers.ps1')

    # Create temp directory with fake log files for file-exists tests
    $script:TempDir = New-TestTempDir
    $script:LogDir = Join-Path $script:TempRoot 'logs'
    [void][System.IO.Directory]::CreateDirectory($script:LogDir)

    # Pre-compute expected filenames for known URLs
    # https://pastebin.com/raw/wqhtQ5Wq → pastebincomrawwqhtQ5Wq
    $script:PastebinFileName = ConvertTo-LogFileName -NormalizedUrl (Normalize-LogUrl -Url 'https://pastebin.com/raw/wqhtQ5Wq')
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($script:LogDir, $script:PastebinFileName),
        'fake log content')

    # https://example.com/log1 → examplecomlog1
    $script:ExampleFileName = ConvertTo-LogFileName -NormalizedUrl (Normalize-LogUrl -Url 'https://example.com/log1')
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($script:LogDir, $script:ExampleFileName),
        'fake log content 1')
}

AfterAll {
    Remove-TestTempDir
}

# ── Resolve-LogUrlToLocalPath ────────────────────────────────────────────────

Describe 'Resolve-LogUrlToLocalPath' {
    Context 'LogDirectory is empty or null' {
        It 'returns original URL when LogDirectory is empty string' {
            $Result = Resolve-LogUrlToLocalPath -Url 'https://pastebin.com/raw/wqhtQ5Wq' -LogDirectory ''
            $Result | Should -Be 'https://pastebin.com/raw/wqhtQ5Wq'
        }

        It 'returns original URL when LogDirectory is null' {
            $Result = Resolve-LogUrlToLocalPath -Url 'https://pastebin.com/raw/wqhtQ5Wq' -LogDirectory $null
            $Result | Should -Be 'https://pastebin.com/raw/wqhtQ5Wq'
        }
    }

    Context 'no local file exists' {
        It 'returns original URL when cached file is not found' {
            $Result = Resolve-LogUrlToLocalPath -Url 'https://example.com/nonexistent' -LogDirectory $script:LogDir
            $Result | Should -Be 'https://example.com/nonexistent'
        }
    }

    Context 'local file exists' {
        It 'returns res/logs/filename when cached file exists' {
            $Result = Resolve-LogUrlToLocalPath -Url 'https://pastebin.com/raw/wqhtQ5Wq' -LogDirectory $script:LogDir
            $Result | Should -Be "res/logs/$($script:PastebinFileName)"
        }

        It 'normalizes non-raw pastebin URL before lookup' {
            # https://pastebin.com/wqhtQ5Wq normalizes to https://pastebin.com/raw/wqhtQ5Wq
            $Result = Resolve-LogUrlToLocalPath -Url 'https://pastebin.com/wqhtQ5Wq' -LogDirectory $script:LogDir
            $Result | Should -Be "res/logs/$($script:PastebinFileName)"
        }
    }

    Context 'non-HTTP paths' {
        It 'returns non-HTTP paths unchanged' {
            $Result = Resolve-LogUrlToLocalPath -Url 'res/logs/some-local-file' -LogDirectory $script:LogDir
            $Result | Should -Be 'res/logs/some-local-file'
        }

        It 'returns relative path unchanged' {
            $Result = Resolve-LogUrlToLocalPath -Url 'logs/mylog.txt' -LogDirectory $script:LogDir
            $Result | Should -Be 'logs/mylog.txt'
        }
    }
}

# ── ConvertFrom-PlainTextLog with -LogDirectory ─────────────────────────────

Describe 'ConvertFrom-PlainTextLog with -LogDirectory' {
    Context 'URLs replaced with local paths when file exists' {
        It 'replaces URL with local path when cached file exists' {
            $Result = ConvertFrom-PlainTextLog -Lines @('Logi: https://example.com/log1') `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -Not -BeNullOrEmpty
            $Result | Should -BeLike '*@Logi:*'
            $Result | Should -BeLike "*res/logs/$($script:ExampleFileName)*"
            $Result | Should -Not -BeLike '*https://example.com/log1*'
        }

        It 'replaces pastebin URL with local path' {
            $Result = ConvertFrom-PlainTextLog -Lines @('Logi: https://pastebin.com/wqhtQ5Wq') `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -Not -BeNullOrEmpty
            $Result | Should -BeLike "*res/logs/$($script:PastebinFileName)*"
        }
    }

    Context 'URLs kept when file does not exist' {
        It 'keeps URL when no cached file is found' {
            $Result = ConvertFrom-PlainTextLog -Lines @('Logi: https://example.com/missing-log') `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -Not -BeNullOrEmpty
            $Result | Should -BeLike '*https://example.com/missing-log*'
        }
    }

    Context 'mixed URLs - some exist, some do not' {
        It 'localizes existing and keeps missing' {
            $Result = ConvertFrom-PlainTextLog -Lines @(
                'Logi: https://example.com/log1'
                'Logi: https://example.com/missing-log'
            ) -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -Not -BeNullOrEmpty
            $Result | Should -BeLike "*res/logs/$($script:ExampleFileName)*"
            $Result | Should -BeLike '*https://example.com/missing-log*'
        }
    }

    Context 'without LogDirectory (backward compat)' {
        It 'leaves URLs unchanged when LogDirectory is not provided' {
            $Result = ConvertFrom-PlainTextLog -Lines @('Logi: https://example.com/log1') -NL "`n"
            $Result | Should -Not -BeNullOrEmpty
            $Result | Should -BeLike '*https://example.com/log1*'
        }
    }
}

# ── ConvertTo-Gen4FromRawBlock with -LogDirectory for 'logs' tag ─────────────

Describe 'ConvertTo-Gen4FromRawBlock with -LogDirectory' {
    Context 'child URLs localized when files exist' {
        It 'localizes log child URL when cached file exists' {
            $Lines = @('- Logi:', '    - https://example.com/log1')
            $Result = ConvertTo-Gen4FromRawBlock -Tag 'logs' -Lines $Lines `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -BeLike '*@Logi:*'
            $Result | Should -BeLike "*res/logs/$($script:ExampleFileName)*"
            $Result | Should -Not -BeLike '*https://example.com/log1*'
        }

        It 'keeps log child URL when cached file does not exist' {
            $Lines = @('- Logi:', '    - https://example.com/unknown-log')
            $Result = ConvertTo-Gen4FromRawBlock -Tag 'logs' -Lines $Lines `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -BeLike '*@Logi:*'
            $Result | Should -BeLike '*https://example.com/unknown-log*'
        }

        It 'localizes multiple log children selectively' {
            $Lines = @(
                '- Logi:'
                '    - https://example.com/log1'
                '    - https://example.com/no-such-log'
                '    - https://pastebin.com/wqhtQ5Wq'
            )
            $Result = ConvertTo-Gen4FromRawBlock -Tag 'logs' -Lines $Lines `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -BeLike "*res/logs/$($script:ExampleFileName)*"
            $Result | Should -BeLike '*https://example.com/no-such-log*'
            $Result | Should -BeLike "*res/logs/$($script:PastebinFileName)*"
        }
    }

    Context 'non-logs tags are unaffected by LogDirectory' {
        It 'does not localize URLs in locations block' {
            $Lines = @('- Lokalizacje:', '    - Erathia', '    - Steadwick')
            $Result = ConvertTo-Gen4FromRawBlock -Tag 'locations' -Lines $Lines `
                -NL "`n" -LogDirectory $script:LogDir
            $Result | Should -BeLike '*@Lokacje:*'
            $Result | Should -BeLike '*Erathia*'
            $Result | Should -BeLike '*Steadwick*'
        }
    }

    Context 'without LogDirectory (backward compat)' {
        It 'leaves log URLs unchanged when LogDirectory is not provided' {
            $Lines = @('- Logi:', '    - https://example.com/log1')
            $Result = ConvertTo-Gen4FromRawBlock -Tag 'logs' -Lines $Lines -NL "`n"
            $Result | Should -BeLike '*@Logi:*'
            $Result | Should -BeLike '*https://example.com/log1*'
        }
    }
}

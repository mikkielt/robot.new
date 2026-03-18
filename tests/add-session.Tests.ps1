<#
    .SYNOPSIS
    Pester tests for add-session.ps1.

    .DESCRIPTION
    Tests for Add-Session covering chronological insertion, batch mode,
    duplicate rejection, multi-path writes, NL preservation,
    ShouldProcess support, and path validation.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:TempRoot }
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'format-sessionblock.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-decomposehelpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'new-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'add-session.ps1')
}

Describe 'Add-Session' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
    }
    AfterEach {
        Remove-TestTempDir
    }

    Context 'Chronological insertion' {
        It 'inserts session between two existing sessions in date order' {
            $FilePath = Join-Path $script:TempDir 'sessions.md'
            $Content = "# Sesje`n`n## Historia`n`n### 2026-01-10, Session A, GM`n`nContent A`n`n### 2026-03-01, Session C, GM`n`nContent C`n"
            Write-TestFile -Path $FilePath -Content $Content

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 2, 1)) `
                -Title 'Session B' -Narrator 'GM' -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $Lines = $Result.Split("`n")
            $Headers = @($Lines | Where-Object { $_.StartsWith('### ') })
            $Headers.Count | Should -Be 3
            $Headers[0] | Should -BeLike '*2026-01-10*Session A*'
            $Headers[1] | Should -BeLike '*2026-02-01*Session B*'
            $Headers[2] | Should -BeLike '*2026-03-01*Session C*'
        }

        It 'inserts session before all existing when date is earliest' {
            $FilePath = Join-Path $script:TempDir 'sessions.md'
            $Content = "# Sesje`n`n### 2026-06-01, Late, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $Content

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 1, 1)) `
                -Title 'Early' -Narrator 'GM' -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $Headers = @($Result.Split("`n") | Where-Object { $_.StartsWith('### ') })
            $Headers[0] | Should -BeLike '*2026-01-01*Early*'
            $Headers[1] | Should -BeLike '*2026-06-01*Late*'
        }

        It 'appends at end when date is latest' {
            $FilePath = Join-Path $script:TempDir 'sessions.md'
            $Content = "### 2026-01-01, First, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $Content

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 12, 31)) `
                -Title 'Last' -Narrator 'GM' -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $Headers = @($Result.Split("`n") | Where-Object { $_.StartsWith('### ') })
            $Headers[0] | Should -BeLike '*2026-01-01*First*'
            $Headers[1] | Should -BeLike '*2026-12-31*Last*'
        }

        It 'inserts same-date session after existing same-date sessions' {
            $FilePath = Join-Path $script:TempDir 'sessions.md'
            $Content = "### 2026-03-01, Existing A, GM`n`nContent A`n`n### 2026-03-01, Existing B, GM2`n`nContent B`n`n### 2026-04-01, Later, GM`n`nContent C`n"
            Write-TestFile -Path $FilePath -Content $Content

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 3, 1)) `
                -Title 'New Same Date' -Narrator 'GM3' -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $Headers = @($Result.Split("`n") | Where-Object { $_.StartsWith('### ') })
            $Headers.Count | Should -Be 4
            # New same-date session goes after both existing Mar 1 sessions
            $Headers[0] | Should -BeLike '*Existing A*'
            $Headers[1] | Should -BeLike '*Existing B*'
            $Headers[2] | Should -BeLike '*New Same Date*'
            $Headers[3] | Should -BeLike '*Later*'
        }
    }

    Context 'New file creation' {
        It 'creates new file when target does not exist' {
            $FilePath = Join-Path $script:TempDir 'new-sessions.md'

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 5, 15)) `
                -Title 'Brand New' -Narrator 'GM' -Confirm:$false

            [System.IO.File]::Exists($FilePath) | Should -BeTrue
            $Content = [System.IO.File]::ReadAllText($FilePath)
            $Content | Should -BeLike '### 2026-05-15, Brand New, GM*'
        }

        It 'creates parent directories for new file' {
            $FilePath = Join-Path $script:TempDir 'sub' 'dir' 'sessions.md'

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 1, 1)) `
                -Title 'Nested' -Narrator 'GM' -Confirm:$false

            [System.IO.File]::Exists($FilePath) | Should -BeTrue
        }
    }

    Context 'Duplicate rejection' {
        It 'throws DuplicateSessionHeader when header already exists' {
            $FilePath = Join-Path $script:TempDir 'sessions.md'
            $Content = "### 2026-03-01, Duplicate Test, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $Content

            { Add-Session -Path $FilePath -Date ([datetime]::new(2026, 3, 1)) `
                -Title 'Duplicate Test' -Narrator 'GM' -Confirm:$false } |
                Should -Throw '*already exists*'
        }
    }

    Context 'Multi-path writes' {
        It 'writes the same session to multiple target files' {
            $Path1 = Join-Path $script:TempDir 'file1.md'
            $Path2 = Join-Path $script:TempDir 'file2.md'
            $UTF8 = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Path1, '', $UTF8)
            [System.IO.File]::WriteAllText($Path2, '', $UTF8)

            Add-Session -Path @($Path1, $Path2) -Date ([datetime]::new(2026, 7, 4)) `
                -Title 'Multi' -Narrator 'GM' -Confirm:$false

            $C1 = [System.IO.File]::ReadAllText($Path1)
            $C2 = [System.IO.File]::ReadAllText($Path2)
            $C1 | Should -BeLike '*### 2026-07-04, Multi, GM*'
            $C2 | Should -BeLike '*### 2026-07-04, Multi, GM*'
        }
    }

    Context 'Newline preservation' {
        It 'preserves CRLF in existing files' {
            $FilePath = Join-Path $script:TempDir 'crlf.md'
            $CRLFContent = "# Sesje`r`n`r`n### 2026-01-01, First, GM`r`n`r`nContent`r`n"
            Write-TestFile -Path $FilePath -Content $CRLFContent

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 6, 1)) `
                -Title 'After' -Narrator 'GM' -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $Result | Should -BeLike "*`r`n*"
            # Ensure no bare LF (that isn't part of CRLF)
            $StrippedCR = $Result.Replace("`r`n", '<<CRLF>>')
            $StrippedCR | Should -Not -BeLike "*`n*"
        }

        It 'preserves LF in existing files' {
            $FilePath = Join-Path $script:TempDir 'lf.md'
            $LFContent = "# Sesje`n`n### 2026-01-01, First, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $LFContent

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 6, 1)) `
                -Title 'After' -Narrator 'GM' -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $Result | Should -Not -BeLike "*`r`n*"
        }
    }

    Context 'ShouldProcess' {
        It 'does not modify file when -WhatIf is passed' {
            $FilePath = Join-Path $script:TempDir 'whatif.md'
            Write-TestFile -Path $FilePath -Content "# Empty`n"
            $OrigSize = ([System.IO.FileInfo]::new($FilePath)).Length

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 1, 1)) `
                -Title 'Ghost' -Narrator 'GM' -WhatIf

            $NewSize = ([System.IO.FileInfo]::new($FilePath)).Length
            $NewSize | Should -Be $OrigSize
        }
    }

    Context 'Return value' {
        It 'returns header text array for single session' {
            $FilePath = Join-Path $script:TempDir 'ret.md'
            [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))

            $Result = Add-Session -Path $FilePath -Date ([datetime]::new(2026, 8, 20)) `
                -Title 'Return Test' -Narrator 'Narrator1' -Confirm:$false

            $Result | Should -HaveCount 1
            $Result[0] | Should -Be '2026-08-20, Return Test, Narrator1'
        }
    }

    Context 'Metadata rendering' {
        It 'renders all metadata blocks in output' {
            $FilePath = Join-Path $script:TempDir 'meta.md'
            [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 4, 10)) `
                -Title 'Full' -Narrator 'GM' `
                -Locations @('Erathia') `
                -PU @([PSCustomObject]@{ Character = 'Xeron'; Value = 0.5 }) `
                -Logs @('https://example.com/log') `
                -Content 'Body text.' `
                -Confirm:$false

            $Content = [System.IO.File]::ReadAllText($FilePath)
            $Content | Should -BeLike '*@Lokacje:*'
            $Content | Should -BeLike '*Erathia*'
            $Content | Should -BeLike '*@PU:*'
            $Content | Should -BeLike '*Xeron*'
            $Content | Should -BeLike '*@Logi:*'
            $Content | Should -BeLike '*Body text.*'
        }
    }

    Context 'Multi-day sessions' {
        It 'generates header with /DD suffix for DateEnd' {
            $FilePath = Join-Path $script:TempDir 'multiday.md'
            [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))

            Add-Session -Path $FilePath -Date ([datetime]::new(2026, 3, 10)) `
                -DateEnd ([datetime]::new(2026, 3, 15)) `
                -Title 'Multi Day' -Narrator 'GM' -Confirm:$false

            $Content = [System.IO.File]::ReadAllText($FilePath)
            $Content | Should -BeLike '*### 2026-03-10/15, Multi Day, GM*'
        }
    }

    Context 'Batch mode' {
        It 'adds multiple sessions in correct chronological order' {
            $FilePath = Join-Path $script:TempDir 'batch.md'
            $Content = "### 2026-02-01, Middle, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $Content

            $Sessions = @(
                @{ Date = [datetime]::new(2026, 3, 15); Title = 'Third'; Narrator = 'GM' }
                @{ Date = [datetime]::new(2026, 1, 10); Title = 'First'; Narrator = 'GM' }
            )

            $Headers = Add-Session -Path $FilePath -Sessions $Sessions -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $FileHeaders = @($Result.Split("`n") | Where-Object { $_.StartsWith('### ') })
            $FileHeaders.Count | Should -Be 3
            $FileHeaders[0] | Should -BeLike '*First*'
            $FileHeaders[1] | Should -BeLike '*Middle*'
            $FileHeaders[2] | Should -BeLike '*Third*'

            @($Headers).Count | Should -Be 2
        }

        It 'creates new file with batch sessions in date order' {
            $FilePath = Join-Path $script:TempDir 'batch-new.md'

            $Sessions = @(
                @{ Date = [datetime]::new(2026, 6, 1); Title = 'June'; Narrator = 'GM' }
                @{ Date = [datetime]::new(2026, 3, 1); Title = 'March'; Narrator = 'GM' }
                @{ Date = [datetime]::new(2026, 9, 1); Title = 'September'; Narrator = 'GM' }
            )

            Add-Session -Path $FilePath -Sessions $Sessions -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $FileHeaders = @($Result.Split("`n") | Where-Object { $_.StartsWith('### ') })
            $FileHeaders.Count | Should -Be 3
            $FileHeaders[0] | Should -BeLike '*March*'
            $FileHeaders[1] | Should -BeLike '*June*'
            $FileHeaders[2] | Should -BeLike '*September*'
        }

        It 'batch with same-date sessions preserves input order after existing' {
            $FilePath = Join-Path $script:TempDir 'batch-same.md'
            $Content = "### 2026-05-01, Existing, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $Content

            $Sessions = @(
                @{ Date = [datetime]::new(2026, 5, 1); Title = 'New A'; Narrator = 'GM' }
                @{ Date = [datetime]::new(2026, 5, 1); Title = 'New B'; Narrator = 'GM2' }
            )

            Add-Session -Path $FilePath -Sessions $Sessions -Confirm:$false

            $Result = [System.IO.File]::ReadAllText($FilePath)
            $FileHeaders = @($Result.Split("`n") | Where-Object { $_.StartsWith('### ') })
            $FileHeaders.Count | Should -Be 3
            $FileHeaders[0] | Should -BeLike '*Existing*'
            $FileHeaders[1] | Should -BeLike '*New A*'
            $FileHeaders[2] | Should -BeLike '*New B*'
        }

        It 'batch rejects when any session has duplicate header' {
            $FilePath = Join-Path $script:TempDir 'batch-dup.md'
            $Content = "### 2026-01-01, Existing, GM`n`nContent`n"
            Write-TestFile -Path $FilePath -Content $Content

            $Sessions = @(
                @{ Date = [datetime]::new(2026, 2, 1); Title = 'OK'; Narrator = 'GM' }
                @{ Date = [datetime]::new(2026, 1, 1); Title = 'Existing'; Narrator = 'GM' }
            )

            { Add-Session -Path $FilePath -Sessions $Sessions -Confirm:$false } |
                Should -Throw '*already exists*'
        }
    }

    Context 'Path validation' {
        It 'rejects paths outside repository root' {
            $OutsidePath = Join-Path ([System.IO.Path]::GetTempPath()) 'outside.md'

            { Add-Session -Path $OutsidePath -Date ([datetime]::new(2026, 1, 1)) `
                -Title 'Evil' -Narrator 'GM' -Confirm:$false } |
                Should -Throw '*outside repository root*'
        }
    }

    Context 'Gen4 header format' {
        It 'generates correct header format YYYY-MM-DD, Title, Narrator' {
            $FilePath = Join-Path $script:TempDir 'format.md'
            [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))

            $Result = Add-Session -Path $FilePath -Date ([datetime]::new(2026, 11, 3)) `
                -Title 'Format Check' -Narrator 'TestNarrator' -Confirm:$false

            $Content = [System.IO.File]::ReadAllText($FilePath)
            $Content | Should -BeLike '*### 2026-11-03, Format Check, TestNarrator*'
            $Result[0] | Should -Be '2026-11-03, Format Check, TestNarrator'
        }
    }
}

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'format-sessionblock.ps1')
    . (Join-Path $script:ModuleRoot 'new-session.ps1')
}

Describe 'New-Session' {
    It 'generates Gen4 session with header, metadata, and content' {
        $Result = New-Session -Date ([datetime]::new(2026, 3, 1)) -Title 'Test Session' -Narrator 'Solmyr' `
            -Locations @('Erathia') -PU @([PSCustomObject]@{ Character = 'Xeron'; Value = 0.5 }) `
            -Logs @('https://example.com/log') -Content 'Session body text.'

        $Result | Should -Not -BeNullOrEmpty
        $Result | Should -BeLike '### 2026-03-01, Test Session, Solmyr*'
        $Result | Should -BeLike '*@Lokacje:*'
        $Result | Should -BeLike '*Erathia*'
        $Result | Should -BeLike '*@PU:*'
        $Result | Should -BeLike '*Xeron*'
        $Result | Should -BeLike '*@Logi:*'
        $Result | Should -BeLike '*https://example.com/log*'
        $Result | Should -BeLike '*Session body text.*'
    }

    It 'generates header with date range' {
        $Result = New-Session -Date ([datetime]::new(2026, 3, 1)) -DateEnd ([datetime]::new(2026, 3, 3)) `
            -Title 'Multi-Day Session' -Narrator 'Crag Hack'
        $Result | Should -BeLike '### 2026-03-01/03, Multi-Day Session, Crag Hack*'
    }

    It 'throws if DateEnd is in different month' {
        { New-Session -Date ([datetime]::new(2026, 3, 1)) -DateEnd ([datetime]::new(2026, 4, 1)) `
            -Title 'Bad Range' -Narrator 'Test' } | Should -Throw '*same month*'
    }

    It 'throws if DateEnd is before Date' {
        { New-Session -Date ([datetime]::new(2026, 3, 15)) -DateEnd ([datetime]::new(2026, 3, 10)) `
            -Title 'Bad Range' -Narrator 'Test' } | Should -Throw '*later than*'
    }

    It 'generates minimal session with only required parameters' {
        $Result = New-Session -Date ([datetime]::new(2026, 1, 1)) -Title 'Minimal' -Narrator 'N'
        $Result | Should -BeLike '### 2026-01-01, Minimal, N*'
    }

    It 'includes Zmiany block when Changes provided' {
        $Changes = @([PSCustomObject]@{
            EntityName = 'Rion'
            Tags = @([PSCustomObject]@{ Tag = '@lokacja'; Value = 'Steadwick' })
        })
        $Result = New-Session -Date ([datetime]::new(2026, 3, 1)) -Title 'With Changes' -Narrator 'N' -Changes $Changes
        $Result | Should -BeLike '*@Zmiany:*'
        $Result | Should -BeLike '*Rion*'
    }

    It 'includes Intel block when Intel provided' {
        $Intel = @([PSCustomObject]@{ RawTarget = 'Rion'; Message = 'Secret info' })
        $Result = New-Session -Date ([datetime]::new(2026, 3, 1)) -Title 'With Intel' -Narrator 'N' -Intel $Intel
        $Result | Should -BeLike '*@Intel:*'
        $Result | Should -BeLike '*Rion*'
        $Result | Should -BeLike '*Secret info*'
    }
}

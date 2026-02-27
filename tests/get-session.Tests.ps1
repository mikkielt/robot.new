BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'get-session.ps1')
}

Describe 'ConvertFrom-SessionHeader' {
    BeforeAll {
        $script:DateRegex = [regex]::new('\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b')
    }

    It 'parses standard yyyy-MM-dd date' {
        $Result = ConvertFrom-SessionHeader -Header '2024-06-15, Sesja, Narrator' -DateRegex $script:DateRegex
        $Result | Should -Not -BeNullOrEmpty
        $Result.Date | Should -Be ([datetime]::new(2024, 6, 15))
        $Result.DateEnd | Should -BeNullOrEmpty
    }

    It 'parses date range yyyy-MM-dd/DD' {
        $Result = ConvertFrom-SessionHeader -Header '2024-06-15/17, Sesja, Narrator' -DateRegex $script:DateRegex
        $Result.Date | Should -Be ([datetime]::new(2024, 6, 15))
        $Result.DateEnd | Should -Be ([datetime]::new(2024, 6, 17))
    }

    It 'returns $null for header without date' {
        $Result = ConvertFrom-SessionHeader -Header 'No date header' -DateRegex $script:DateRegex
        $Result | Should -BeNullOrEmpty
    }

    It 'returns $null for malformed date' {
        $Result = ConvertFrom-SessionHeader -Header '2024-1-5, Sesja, Narrator' -DateRegex $script:DateRegex
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Get-SessionTitle' {
    It 'extracts title from header with narrator' {
        $DateInfo = @{ Date = [datetime]::new(2024, 6, 15); DateStr = '2024-06-15'; EndDayStr = $null }
        $Title = Get-SessionTitle -Header '2024-06-15, Ucieczka z Erathii, Solmyr' -DateInfo $DateInfo
        $Title | Should -Be 'Ucieczka z Erathii'
    }

    It 'handles header with no narrator (single comma)' {
        $DateInfo = @{ Date = [datetime]::new(2024, 6, 15); DateStr = '2024-06-15'; EndDayStr = $null }
        $Title = Get-SessionTitle -Header '2024-06-15, Sesja bez narratora' -DateInfo $DateInfo
        $Title | Should -Be 'Sesja bez narratora'
    }
}

Describe 'Get-SessionFormat' {
    It 'detects Gen2 from italic location line' {
        $Format = Get-SessionFormat -FirstNonEmptyLine '*Lokalizacja: Erathia*' -SectionLists @()
        $Format | Should -Be 'Gen2'
    }

    It 'detects Gen1 when no structured metadata' {
        $Format = Get-SessionFormat -FirstNonEmptyLine 'Plain text content' -SectionLists @()
        $Format | Should -Be 'Gen1'
    }

    It 'detects Gen4 from @-prefixed list items' {
        $MockLI = [PSCustomObject]@{ Text = '@Lokacje:'; Indent = 0 }
        $Format = Get-SessionFormat -FirstNonEmptyLine $null -SectionLists @($MockLI)
        $Format | Should -Be 'Gen4'
    }

    It 'detects Gen3 from PU list items' {
        $MockLI = [PSCustomObject]@{ Text = 'PU:'; Indent = 0 }
        $Format = Get-SessionFormat -FirstNonEmptyLine $null -SectionLists @($MockLI)
        $Format | Should -Be 'Gen3'
    }
}

Describe 'Get-Session — Gen1' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen1.md')
    }

    It 'parses Gen1 sessions' {
        $script:Sessions.Count | Should -Be 2
    }

    It 'detects Gen1 format' {
        $script:Sessions[0].Format | Should -Be 'Gen1'
    }

    It 'extracts log URL via plain text fallback' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen1-1'
    }

    It 'parses date correctly' {
        $script:Sessions[0].Date | Should -Be ([datetime]::new(2022, 3, 10))
    }

    It 'extracts title' {
        $script:Sessions[0].Title | Should -Be 'Początek przygody'
    }
}

Describe 'Get-Session — Gen2' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen2.md')
    }

    It 'parses Gen2 sessions' {
        $script:Sessions.Count | Should -Be 2
    }

    It 'detects Gen2 format' {
        $script:Sessions[0].Format | Should -Be 'Gen2'
    }

    It 'extracts locations from italic line' {
        $script:Sessions[0].Locations | Should -Contain 'Erathia'
        $script:Sessions[0].Locations | Should -Contain 'Steadwick'
    }

    It 'extracts log URL via plain text fallback' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen2-1'
    }
}

Describe 'Get-Session — Gen3' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md')
    }

    It 'parses Gen3 sessions' {
        $script:Sessions.Count | Should -Be 3
    }

    It 'detects Gen3 format' {
        $script:Sessions[0].Format | Should -Be 'Gen3'
    }

    It 'extracts locations from list items' {
        $script:Sessions[0].Locations | Should -Contain 'Erathia'
        $script:Sessions[0].Locations | Should -Contain 'Ratusz Erathii'
    }

    It 'extracts PU values' {
        $PU = $script:Sessions[0].PU
        $PU.Count | Should -Be 2
        $XeronPU = $PU | Where-Object { $_.Character -eq 'Xeron Demonlord' }
        $XeronPU.Value | Should -Be 0.3
    }

    It 'extracts log URLs' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen3-1'
    }

    It 'extracts Zmiany (entity state changes)' {
        $Session2 = $script:Sessions[1]
        $Session2.Changes.Count | Should -BeGreaterThan 0
        $RionChange = $Session2.Changes | Where-Object { $_.EntityName -eq 'Rion' }
        $RionChange | Should -Not -BeNullOrEmpty
    }

    It 'resolves narrator' {
        $script:Sessions[0].Narrator | Should -Not -BeNullOrEmpty
        $script:Sessions[0].Narrator.Narrators.Count | Should -Be 1
    }
}

Describe 'Get-Session — Gen4' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen4.md')
    }

    It 'parses Gen4 sessions' {
        $script:Sessions.Count | Should -Be 2
    }

    It 'detects Gen4 format' {
        $script:Sessions[0].Format | Should -Be 'Gen4'
    }

    It 'extracts @Lokacje locations' {
        $script:Sessions[0].Locations | Should -Contain 'Erathia'
        $script:Sessions[0].Locations | Should -Contain 'Ratusz Erathii'
    }

    It 'extracts @PU values' {
        $PU = $script:Sessions[0].PU
        $PU.Count | Should -Be 2
    }

    It 'extracts @Logi URLs' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen4-1'
    }

    It 'extracts @Zmiany' {
        $script:Sessions[0].Changes.Count | Should -BeGreaterThan 0
    }

    It 'extracts @Intel entries' {
        $script:Sessions[0].Intel.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-Session — date filtering' {
    It 'MinDate filters out sessions before the date' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md') -MinDate ([datetime]::new(2024, 7, 1))
        $Sessions.Count | Should -BeLessThan 3
        foreach ($S in $Sessions) {
            $S.Date | Should -BeGreaterOrEqual ([datetime]::new(2024, 7, 1))
        }
    }

    It 'MaxDate filters out sessions after the date' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md') -MaxDate ([datetime]::new(2024, 7, 1))
        foreach ($S in $Sessions) {
            $S.Date | Should -BeLessOrEqual ([datetime]::new(2024, 7, 1))
        }
    }
}

Describe 'Get-Session — deduplication' {
    It 'merges duplicate sessions across files' {
        $Sessions = Get-Session -Directory $script:FixturesRoot
        $Ucieczka = $Sessions | Where-Object { $_.Title -eq 'Ucieczka z Erathii' }
        # Should be deduplicated into a single session
        $Ucieczka.Count | Should -Be 1
    }

    It 'merged session has IsMerged = $true when duplicates exist' {
        $Sessions = Get-Session -Directory $script:FixturesRoot
        $Ucieczka = $Sessions | Where-Object { $_.Title -eq 'Ucieczka z Erathii' }
        $Ucieczka.IsMerged | Should -BeTrue
        $Ucieczka.DuplicateCount | Should -BeGreaterThan 1
    }

    It 'merged session combines locations from all sources' {
        $Sessions = Get-Session -Directory $script:FixturesRoot
        $Ucieczka = $Sessions | Where-Object { $_.Title -eq 'Ucieczka z Erathii' }
        $Ucieczka.Locations | Should -Contain 'Erathia'
    }
}

Describe 'Get-Session — failed sessions' {
    It 'excludes failed sessions by default' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-failed.md')
        $Sessions.Count | Should -Be 0
    }

    It 'includes failed sessions with -IncludeFailed' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-failed.md') -IncludeFailed
        $Failed = $Sessions | Where-Object { $null -eq $_.Date }
        $Failed.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-Session — IncludeContent' {
    It 'includes content text when -IncludeContent is set' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md') -IncludeContent
        $Sessions[0].Content | Should -Not -BeNullOrEmpty
    }

    It 'content is $null by default' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md')
        $Sessions[0].Content | Should -BeNullOrEmpty
    }
}

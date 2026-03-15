<#
    .SYNOPSIS
    Pester tests for seasonal temporality, @nazwa_nerthus, and door-path name features.

    .DESCRIPTION
    Tests for:
    - ConvertFrom-ValidityString with season markers (wiosna, lato, jesień, zima)
    - Resolve-SeasonForDate default + custom mapping
    - Test-TemporalActivity with season constraints
    - @nazwa_nerthus tag parsing and NerthusNameHistory
    - Door-path name generation in Names HashSet
    - @margonemid multi-valued overrides
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
}

Describe 'ConvertFrom-ValidityString - Seasonal' {
    It 'parses season-only "(zima)" into Season without dates' {
        $Result = ConvertFrom-ValidityString -InputText 'winter.png (zima)'
        $Result.Text | Should -Be 'winter.png'
        $Result.Season | Should -Be 'zima'
        $Result.ValidFrom | Should -BeNullOrEmpty
        $Result.ValidTo | Should -BeNullOrEmpty
    }

    It 'parses "(lato)" case-insensitively' {
        $Result = ConvertFrom-ValidityString -InputText 'summer.png (Lato)'
        $Result.Text | Should -Be 'summer.png'
        $Result.Season | Should -Be 'lato'
    }

    It 'parses "jesień" season keyword' {
        $Result = ConvertFrom-ValidityString -InputText 'autumn.png (jesień)'
        $Result.Text | Should -Be 'autumn.png'
        $Result.Season | Should -Be 'jesień'
    }

    It 'parses "wiosna" season keyword' {
        $Result = ConvertFrom-ValidityString -InputText 'spring.png (wiosna)'
        $Result.Text | Should -Be 'spring.png'
        $Result.Season | Should -Be 'wiosna'
    }

    It 'parses date range + season "(2024-01:, zima)"' {
        $Result = ConvertFrom-ValidityString -InputText 'Value (2024-01:, zima)'
        $Result.Text | Should -Be 'Value'
        $Result.Season | Should -Be 'zima'
        $Result.ValidFrom | Should -Be ([datetime]::new(2024, 1, 1))
        $Result.ValidTo | Should -BeNullOrEmpty
    }

    It 'parses season + date range "(lato, 2024-06:2024-08)"' {
        $Result = ConvertFrom-ValidityString -InputText 'Value (lato, 2024-06:2024-08)'
        $Result.Text | Should -Be 'Value'
        $Result.Season | Should -Be 'lato'
        $Result.ValidFrom | Should -Be ([datetime]::new(2024, 6, 1))
        $Result.ValidTo | Should -Be ([datetime]::new(2024, 8, 31))
    }

    It 'preserves literal text for non-temporal parenthetical content' {
        $Result = ConvertFrom-ValidityString -InputText 'Something (random text)'
        $Result.Text | Should -Be 'Something (random text)'
        $Result.Season | Should -BeNullOrEmpty
        $Result.ValidFrom | Should -BeNullOrEmpty
        $Result.ValidTo | Should -BeNullOrEmpty
    }

    It 'still parses standard date ranges without season' {
        $Result = ConvertFrom-ValidityString -InputText 'Orrin (2024-01:)'
        $Result.Text | Should -Be 'Orrin'
        $Result.ValidFrom | Should -Be ([datetime]::new(2024, 1, 1))
        $Result.ValidTo | Should -BeNullOrEmpty
        $Result.Season | Should -BeNullOrEmpty
    }

    It 'still parses plain text without parentheses' {
        $Result = ConvertFrom-ValidityString -InputText 'PlainValue'
        $Result.Text | Should -Be 'PlainValue'
        $Result.Season | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SeasonForDate' {
    It 'returns "wiosna" for March' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 3, 15))
        $Result | Should -Be 'wiosna'
    }

    It 'returns "lato" for July' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 7, 1))
        $Result | Should -Be 'lato'
    }

    It 'returns "jesień" for October' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 10, 20))
        $Result | Should -Be 'jesień'
    }

    It 'returns "zima" for January' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 1, 15))
        $Result | Should -Be 'zima'
    }

    It 'returns "zima" for December' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 12, 25))
        $Result | Should -Be 'zima'
    }

    It 'returns "zima" for February' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 2, 14))
        $Result | Should -Be 'zima'
    }

    It 'returns "wiosna" for May' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 5, 31))
        $Result | Should -Be 'wiosna'
    }

    It 'returns "jesień" for September' {
        $Result = Resolve-SeasonForDate -Date ([datetime]::new(2024, 9, 1))
        $Result | Should -Be 'jesień'
    }
}

Describe 'Test-TemporalActivity - Seasonal' {
    It 'returns $true when item has matching season' {
        $Item = @{ ValidFrom = $null; ValidTo = $null; Season = 'zima' }
        # January = zima
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2024, 1, 15)) | Should -BeTrue
    }

    It 'returns $false when item has non-matching season' {
        $Item = @{ ValidFrom = $null; ValidTo = $null; Season = 'zima' }
        # July = lato
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2024, 7, 15)) | Should -BeFalse
    }

    It 'returns $true when item has both date range and matching season' {
        $Item = @{ ValidFrom = [datetime]::new(2024, 1, 1); ValidTo = $null; Season = 'lato' }
        # June 2024 = lato, after ValidFrom
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2024, 6, 15)) | Should -BeTrue
    }

    It 'returns $false when date matches but season does not' {
        $Item = @{ ValidFrom = [datetime]::new(2024, 1, 1); ValidTo = $null; Season = 'zima' }
        # June 2024 = lato, not zima
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2024, 6, 15)) | Should -BeFalse
    }

    It 'returns $true when ActiveOn is $null (no filter) even with season' {
        $Item = @{ ValidFrom = $null; ValidTo = $null; Season = 'zima' }
        Test-TemporalActivity -Item $Item -ActiveOn $null | Should -BeTrue
    }

    It 'returns $true when item has no Season constraint' {
        $Item = @{ ValidFrom = $null; ValidTo = $null; Season = $null }
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2024, 7, 15)) | Should -BeTrue
    }
}

Describe 'Get-Entity - @nazwa_nerthus' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md')
    }

    It 'parses NerthusNameHistory for entity with @nazwa_nerthus' {
        $Tunele = $script:Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele | Should -Not -BeNullOrEmpty
        $Tunele.NerthusNameHistory.Count | Should -Be 1
        $Tunele.NerthusNameHistory[0].Value | Should -Be 'Kryjówka Craga Hacka'
    }

    It 'sets active NerthusName scalar property' {
        $Tunele = $script:Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele.NerthusName | Should -Be 'Kryjówka Craga Hacka'
    }

    It 'adds active NerthusName to Names for resolution' {
        $Tunele = $script:Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele.Names | Should -Contain 'Kryjówka Craga Hacka'
    }

    It 'tracks multiple NerthusNameHistory entries with temporal ranges' {
        $Bazar = $script:Entities | Where-Object { $_.Name -eq 'Bazar Bracady' }
        $Bazar | Should -Not -BeNullOrEmpty
        $Bazar.NerthusNameHistory.Count | Should -Be 2
    }

    It 'resolves last active NerthusName from temporal entries' {
        $Bazar = $script:Entities | Where-Object { $_.Name -eq 'Bazar Bracady' }
        # No -ActiveOn, so last entry wins (both always active when no filter)
        $Bazar.NerthusName | Should -Be 'Wielki Bazar Bracady'
    }

    It 'filters NerthusName by ActiveOn date' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2023, 6, 1))
        $Bazar = $Entities | Where-Object { $_.Name -eq 'Bazar Bracady' }
        $Bazar.NerthusName | Should -Be 'Bazar Alchemików'
    }

    It 'returns $null NerthusName for entities without the tag' {
        $Bracada = $script:Entities | Where-Object { $_.Name -eq 'Bracada' }
        $Bracada.NerthusName | Should -BeNullOrEmpty
        $Bracada.NerthusNameHistory.Count | Should -Be 0
    }
}

Describe 'Get-Entity - Door-Path Names' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md')
    }

    It 'adds door-path names to Names for locations with @drzwi' {
        $Tunele = $script:Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele.Names | Should -Contain 'Deyja/Tunele Nighonu'
        $Tunele.Names | Should -Contain 'Bracada/Tunele Nighonu'
    }

    It 'does not add door-path names for non-location entities' {
        $NPC = $script:Entities | Where-Object { $_.Name -eq 'Astral' }
        $NPC.Names | Should -Not -Contain 'Bracada/Astral'
    }

    It 'does not add door-path names for locations without @drzwi' {
        $Bracada = $script:Entities | Where-Object { $_.Name -eq 'Bracada' }
        # Bracada has no @drzwi, only @lokacja
        $HasPathName = $false
        foreach ($N in $Bracada.Names) {
            if ($N.Contains('/')) { $HasPathName = $true; break }
        }
        $HasPathName | Should -BeFalse
    }
}

Describe 'Get-Entity - @margonemid Multi-Valued Override' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md')
    }

    It 'stores multiple @margonemid values in Overrides' {
        $Tunele = $script:Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele.Overrides['margonemid'].Count | Should -Be 4
        $Tunele.Overrides['margonemid'] | Should -Contain '117'
        $Tunele.Overrides['margonemid'] | Should -Contain '118'
        $Tunele.Overrides['margonemid'] | Should -Contain '119'
        $Tunele.Overrides['margonemid'] | Should -Contain '120'
    }
}

Describe 'Get-Entity - Seasonal @tlo Override' {
    It 'stores seasonal @tlo values when active in summer' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 7, 15))
        $Tunele = $Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele.Overrides['tlo'] | Should -Contain 'nighon-lato.png'
        $Tunele.Overrides['tlo'] | Should -Not -Contain 'nighon-zima.png'
    }

    It 'stores seasonal @tlo values when active in winter' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 1, 15))
        $Tunele = $Entities | Where-Object { $_.Name -eq 'Tunele Nighonu' }
        $Tunele.Overrides['tlo'] | Should -Contain 'nighon-zima.png'
        $Tunele.Overrides['tlo'] | Should -Not -Contain 'nighon-lato.png'
    }
}

Describe 'Get-Entity - Seasonal @lokacja' {
    It 'filters seasonal @lokacja by ActiveOn date' {
        # In summer, Astral should be in Bracada
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 7, 15))
        $NPC = $Entities | Where-Object { $_.Name -eq 'Astral' }
        $NPC.Location | Should -Be 'Bracada'
    }

    It 'returns winter location when ActiveOn is in winter' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 1, 15))
        $NPC = $Entities | Where-Object { $_.Name -eq 'Astral' }
        $NPC.Location | Should -Be 'Antagarich'
    }
}

Describe 'Get-Entity - Seasonal @alias' {
    It 'includes seasonal alias when season matches' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 1, 15))
        $Grota = $Entities | Where-Object { $_.Name -eq 'Lodowa Grota' }
        $Grota.Names | Should -Contain 'Krypta Lodu'
    }

    It 'excludes seasonal alias when season does not match' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 7, 15))
        $Grota = $Entities | Where-Object { $_.Name -eq 'Lodowa Grota' }
        $Grota.Names | Should -Not -Contain 'Krypta Lodu'
    }
}

Describe 'Get-Entity - Combined Date + Season' {
    It 'filters by both date range and season' {
        # Fiona: @lokacja: Bazar Bracady (2024-01:, lato)
        # In summer 2024 -> should be at Bazar Bracady
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 7, 15))
        $Fiona = $Entities | Where-Object { $_.Name -eq 'Fiona' }
        $Fiona.Location | Should -Be 'Bazar Bracady'
    }

    It 'excludes when date matches but season does not' {
        # In winter 2024 -> Fiona: lato lokacja inactive, zima lokacja active
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-seasonal.md') -ActiveOn ([datetime]::new(2024, 1, 15))
        $Fiona = $Entities | Where-Object { $_.Name -eq 'Fiona' }
        $Fiona.Location | Should -Be 'Bracada'
    }
}

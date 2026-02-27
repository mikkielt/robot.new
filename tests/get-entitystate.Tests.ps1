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
    . (Join-Path $script:ModuleRoot 'get-entitystate.ps1')
}

Describe 'Get-EntityState' {
    BeforeAll {
        $script:Entities = Get-Entity
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md')
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions
    }

    It 'returns enriched entities' {
        $script:Enriched | Should -Not -BeNullOrEmpty
        $script:Enriched.Count | Should -BeGreaterThan 0
    }

    It 'applies @lokacja override from Zmiany to Kupiec Orrin' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin | Should -Not -BeNullOrEmpty
        # sessions-zmiany.md moves Orrin to Steadwick from 2025-03
        $OrrinLocations = $Orrin.LocationHistory | ForEach-Object { $_.Location }
        $OrrinLocations | Should -Contain 'Steadwick'
    }

    It 'applies @grupa override from Zmiany to Kupiec Orrin' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $OrrinGroups = $Orrin.GroupHistory | ForEach-Object { $_.Group }
        $OrrinGroups | Should -Contain 'Kupcy Steadwicku'
    }

    It 'applies @alias override from Zmiany to Rion' {
        $Rion = $script:Enriched | Where-Object { $_.Name -eq 'Rion' }
        $Rion.Names | Should -Contain 'Wielki Rion'
    }

    It 'applies generic @tag (e.g. @stan) as override' {
        $Xeron = $script:Enriched | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Overrides.ContainsKey('stan') | Should -BeTrue
        $StanValues = $Xeron.Overrides['stan']
        $StanValues | Should -Contain 'Ranny'
    }

    It 'sorts history by ValidFrom after merge' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Dates = $Orrin.LocationHistory | Where-Object { $null -ne $_.ValidFrom } | ForEach-Object { $_.ValidFrom }
        for ($i = 1; $i -lt $Dates.Count; $i++) {
            $Dates[$i] | Should -BeGreaterOrEqual $Dates[$i - 1]
        }
    }

    It 'recomputes Location for modified entity' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        # Latest location in fixture should be Steadwick (2025-03)
        $Orrin.Location | Should -Be 'Steadwick'
    }

    It 'preserves unmodified entities unchanged' {
        $Enroth = $script:Enriched | Where-Object { $_.Name -eq 'Enroth' }
        $Enroth | Should -Not -BeNullOrEmpty
        $Enroth.Type | Should -Be 'Lokacja'
    }

    It 'applies @ilość addition delta from Zmiany' {
        $Korony = $script:Enriched | Where-Object { $_.Name -eq 'Korony Elanckie' }
        $Korony | Should -Not -BeNullOrEmpty
        # Base: 50, session adds +25 → 75
        $Korony.Quantity | Should -Be '75'
    }

    It 'applies @ilość subtraction delta from Zmiany' {
        $Straznik = $script:Enriched | Where-Object { $_.Name -eq 'Strażnik Bramy' }
        $Straznik | Should -Not -BeNullOrEmpty
        # Base: 3, session subtracts -1 → 2
        $Straznik.Quantity | Should -Be '2'
    }

    It 'applies @generyczne_nazwy from Zmiany session' {
        $Straznik = $script:Enriched | Where-Object { $_.Name -eq 'Strażnik Bramy' }
        $Straznik.GenericNames | Should -Contain 'Ochroniarz'
        $Straznik.Names | Should -Contain 'Ochroniarz'
    }

    It 'preserves original @generyczne_nazwy after Zmiany merge' {
        $Straznik = $script:Enriched | Where-Object { $_.Name -eq 'Strażnik Bramy' }
        $Straznik.GenericNames | Should -Contain 'Strażnik Miasta'
        $Straznik.GenericNames | Should -Contain 'Wartownik'
    }
}

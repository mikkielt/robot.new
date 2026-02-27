<#
    .SYNOPSIS
    Pester tests for get-entitystate.ps1.

    .DESCRIPTION
    Tests for Get-EntityState covering @lokacja, @grupa, @alias, @drzwi,
    @typ, @należy_do, @status, @ilość, @generyczne_nazwy overrides from
    session Zmiany, @Transfer expansion, temporal sorting, CN recomputation,
    and unresolved entity warnings.
#>

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
        $script:Entities = Get-Entity -Path $script:FixturesRoot
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
        $Korony = $script:Enriched | Where-Object { $_.Name -eq 'Korony Xeron Demonlorda' }
        $Korony | Should -Not -BeNullOrEmpty
        # Base: 50, session adds +25, transfer subtracts -10 → 65
        $Korony.Quantity | Should -Be '65'
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

    It 'applies @Transfer as symmetric quantity deltas' {
        # @Transfer: 10 koron, Xeron Demonlord -> Kupiec Orrin
        # Source (Korony Xeron Demonlorda): 50 base + 25 zmiany - 10 transfer = 65
        $Source = $script:Enriched | Where-Object { $_.Name -eq 'Korony Xeron Demonlorda' }
        $Source | Should -Not -BeNullOrEmpty
        $Source.Quantity | Should -Be '65'

        # Destination (Korony Kupca Orrina): 30 base + 10 transfer = 40
        $Dest = $script:Enriched | Where-Object { $_.Name -eq 'Korony Kupca Orrina' }
        $Dest | Should -Not -BeNullOrEmpty
        $Dest.Quantity | Should -Be '40'
    }

    It 'parses @Transfer from session' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md')
        $WithTransfers = $Sessions | Where-Object { $_.Transfers -and $_.Transfers.Count -gt 0 }
        $WithTransfers | Should -Not -BeNullOrEmpty
        $Transfer = $WithTransfers[0].Transfers[0]
        $Transfer.Amount | Should -Be 10
        $Transfer.Source | Should -Be 'Xeron Demonlord'
        $Transfer.Destination | Should -Be 'Kupiec Orrin'
    }
}

Describe 'Get-EntityState — @drzwi, @typ, @należy_do, @grupa changes' {
    BeforeAll {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-changes.md')
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-changes.md')
        $script:Enriched = Get-EntityState -Entities $Entities -Sessions $Sessions
    }

    It 'adds @drzwi to DoorHistory' {
        $NPC = $script:Enriched | Where-Object { $_.Name -eq 'Rycerz Erathii' }
        $NPC.DoorHistory | Should -Not -BeNullOrEmpty
        ($NPC.DoorHistory | Where-Object { $_.Location -eq 'Brama Główna' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds @typ to TypeHistory' {
        $NPC = $script:Enriched | Where-Object { $_.Name -eq 'Rycerz Erathii' }
        $NPC.TypeHistory | Should -Not -BeNullOrEmpty
        ($NPC.TypeHistory | Where-Object { $_.Type -eq 'Dowódca' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds @należy_do to OwnerHistory' {
        $NPC = $script:Enriched | Where-Object { $_.Name -eq 'Rycerz Erathii' }
        $NPC.OwnerHistory | Should -Not -BeNullOrEmpty
        ($NPC.OwnerHistory | Where-Object { $_.OwnerName -eq 'Ktoś Inny' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds @grupa to GroupHistory' {
        $NPC = $script:Enriched | Where-Object { $_.Name -eq 'Rycerz Erathii' }
        $NPC.GroupHistory | Should -Not -BeNullOrEmpty
        ($NPC.GroupHistory | Where-Object { $_.Group -eq 'Złoczyńcy' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds @status to StatusHistory with lazy init' {
        $NPC = $script:Enriched | Where-Object { $_.Name -eq 'Rycerz Erathii' }
        $NPC.StatusHistory | Should -Not -BeNullOrEmpty
        ($NPC.StatusHistory | Where-Object { $_.Status -eq 'Ranny' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles @ilość with arithmetic delta (+N)' {
        $Sword = $script:Enriched | Where-Object { $_.Name -eq 'Miecz Rycerza' }
        $Sword.QuantityHistory | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-EntityState — unresolved entity warning' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-unresolved.md')
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-unresolved.md')
    }

    It 'warns about unresolved entities and continues' {
        $Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions
        $Enriched | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-EntityState — @Transfer expansion' {
    It 'applies transfer amounts to source and destination currency entities' {
        $Entities = Get-Entity -Path $script:FixturesRoot
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md')
        $Enriched = Get-EntityState -Entities $Entities -Sessions $Sessions

        # Korony Xeron Demonlorda should have transfer debit
        $XeronKorony = $Enriched | Where-Object { $_.Name -eq 'Korony Xeron Demonlorda' }
        $XeronKorony.QuantityHistory | Should -Not -BeNullOrEmpty

        # Korony Kupca Orrina should have transfer credit
        $OrrinKorony = $Enriched | Where-Object { $_.Name -eq 'Korony Kupca Orrina' }
        $OrrinKorony.QuantityHistory | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-EntityState — deep Zmiany from session' {
    BeforeAll {
        $Entities = Get-Entity -Path $script:FixturesRoot
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-deep-zmiany.md')
        $script:Enriched = Get-EntityState -Entities $Entities -Sessions $Sessions
    }

    It 'applies @lokacja change to Kupiec Orrin' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $OrrinLocations = $Orrin.LocationHistory | ForEach-Object { $_.Location }
        $OrrinLocations | Should -Contain 'Steadwick'
    }

    It 'applies @grupa change to Kupiec Orrin' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $OrrinGroups = $Orrin.GroupHistory | ForEach-Object { $_.Group }
        $OrrinGroups | Should -Contain 'Kupcy Steadwicku'
    }

    It 'applies @alias change to Kupiec Orrin' {
        $Orrin = $script:Enriched | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin.Names | Should -Contain 'Orrin z Steadwicku'
    }

    It 'applies @status change to Thant' {
        $Thant = $script:Enriched | Where-Object { $_.Name -eq 'Thant' }
        $ThantStatuses = $Thant.StatusHistory | ForEach-Object { $_.Status }
        $ThantStatuses | Should -Contain 'Nieaktywny'
    }

    It 'applies temporal @stan override to Xeron Demonlord' {
        $Xeron = $script:Enriched | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Overrides.ContainsKey('stan') | Should -BeTrue
        $StanValues = $Xeron.Overrides['stan']
        $StanValues | Should -Contain 'Ranny'
    }

    It 'applies @info override from Zmiany' {
        $Xeron = $script:Enriched | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Overrides.ContainsKey('info') | Should -BeTrue
    }
}

Describe 'Get-EntityState — multi-Transfer' {
    BeforeAll {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-multi-transfer.md')
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-multi-transfer.md')
        $script:Enriched = Get-EntityState -Entities $Entities -Sessions $Sessions
    }

    It 'applies three transfers to entities' {
        $Source = $script:Enriched | Where-Object { $_.Name -eq 'Korony Źródła' }
        $Source | Should -Not -BeNullOrEmpty
    }

    It 'source entity has combined debit from two outgoing transfers' {
        $Source = $script:Enriched | Where-Object { $_.Name -eq 'Korony Źródła' }
        # Base: 100, +50 from zmiany, -20 transfer to Odbiorca, -15 transfer to Trzeci = 115
        $Source.Quantity | Should -Be '115'
    }

    It 'first destination has net credit from one transfer and one debit' {
        $Dest = $script:Enriched | Where-Object { $_.Name -eq 'Korony Celu' }
        # Base: 50, +20 from Dawca, -5 to Trzeci = 65
        $Dest.Quantity | Should -Be '65'
    }

    It 'second destination has credits from two incoming transfers' {
        $Third = $script:Enriched | Where-Object { $_.Name -eq 'Korony Trzeciego' }
        # Base: 200, +15 from Dawca, +5 from Odbiorca = 220
        $Third.Quantity | Should -Be '220'
    }
}

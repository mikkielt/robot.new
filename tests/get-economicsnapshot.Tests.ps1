<#
    .SYNOPSIS
    Pester tests for get-economicsnapshot.ps1.

    .DESCRIPTION
    Tests for Get-EconomicSnapshot covering supply breakdown, physical/virtual
    classification, Gini coefficient, top holders, and transaction volume.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-entitystate.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'currency-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'reporting-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'economy-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-economicsnapshot.ps1')
}

Describe 'Get-EconomicSnapshot - basic' {
    BeforeAll {
        $script:EconEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-economy.md')
        $script:EconEnriched = Get-EntityState -Entities $script:EconEntities -Sessions @()
        $script:Snapshot = Get-EconomicSnapshot -Entities $script:EconEnriched -Sessions @() -Quiet
    }

    It 'returns a snapshot object' {
        $script:Snapshot | Should -Not -BeNullOrEmpty
        $script:Snapshot.PSObject.Properties['SnapshotDate'] | Should -Not -BeNullOrEmpty
    }

    It 'has supply breakdown by denomination' {
        $script:Snapshot.SupplyByDenomination | Should -Not -BeNullOrEmpty
        $script:Snapshot.SupplyByDenomination.Count | Should -BeGreaterThan 0
    }

    It 'computes total supply in Kogi' {
        # 100+50+200+500=850 Korony * 10000 = 8,500,000 + 50 Talary * 100 = 5,000
        $script:Snapshot.TotalSupplyKogi | Should -Be 8505000
    }

    It 'separates physical and virtual supply' {
        # Physical: Bohater Artur (100 Korony) + Bohaterka Ewa (50 Korony) = 150 * 10000 = 1,500,000
        $script:Snapshot.PhysicalSupplyKogi | Should -Be 1500000
        # Virtual: Handlarz (200) + Gildia (500) = 700 Korony * 10000 + 50 Talary * 100 = 7,005,000
        $script:Snapshot.VirtualSupplyKogi | Should -Be 7005000
    }

    It 'computes physical ratio' {
        # 1500000 / 8505000 ≈ 0.1764
        $script:Snapshot.PhysicalRatio | Should -BeGreaterThan 0.17
        $script:Snapshot.PhysicalRatio | Should -BeLessThan 0.18
    }

    It 'counts holders with balance > 0' {
        $script:Snapshot.HolderCount | Should -Be 5
    }

    It 'returns top holders sorted by wealth' {
        $script:Snapshot.TopHolders.Count | Should -BeGreaterOrEqual 5
        $script:Snapshot.TopHolders[0].Owner | Should -Be 'Gildia Kupców'
        $script:Snapshot.TopHolders[0].WealthKogi | Should -Be 5000000
        $script:Snapshot.TopHolders[0].OwnerCategory | Should -Be 'Virtual'
    }

    It 'computes Gini coefficient between 0 and 1' {
        $script:Snapshot.GiniCoefficient | Should -BeGreaterThan 0
        $script:Snapshot.GiniCoefficient | Should -BeLessThan 1
    }

    It 'returns zero transaction volume when no sessions have transfers' {
        $script:Snapshot.TransactionVolume | Should -Be 0
        $script:Snapshot.TransactionValueKogi | Should -Be 0
    }
}

Describe 'Get-EconomicSnapshot - with transfers' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md')
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions
        $script:Snapshot = Get-EconomicSnapshot -Entities $script:Enriched -Sessions $script:Sessions -Quiet
    }

    It 'counts transfers in transaction volume' {
        $script:Snapshot.TransactionVolume | Should -BeGreaterThan 0
    }

    It 'computes transaction value in Kogi' {
        # 10 koron = 10 * 10000 = 100000 Kogi
        $script:Snapshot.TransactionValueKogi | Should -Be 100000
    }
}

Describe 'Get-EconomicSnapshot - denomination filter' {
    BeforeAll {
        $script:EconEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-economy.md')
        $script:EconEnriched = Get-EntityState -Entities $script:EconEntities -Sessions @()
        $script:Snapshot = Get-EconomicSnapshot -Entities $script:EconEnriched -Sessions @() -Denomination 'Talary' -Quiet
    }

    It 'filters to specified denomination only' {
        $script:Snapshot.SupplyByDenomination.Count | Should -Be 1
        $script:Snapshot.SupplyByDenomination.ContainsKey('Talary Hirońskie') | Should -BeTrue
    }

    It 'computes supply for filtered denomination' {
        # 50 Talary * 100 = 5000 Kogi
        $script:Snapshot.TotalSupplyKogi | Should -Be 5000
    }
}

Describe 'Get-EconomicSnapshot - empty entities' {
    It 'handles empty entities without error' {
        $Result = Get-EconomicSnapshot -Entities @() -Sessions @() -Quiet
        $Result | Should -Not -BeNullOrEmpty
        $Result.TotalSupplyKogi | Should -Be 0
        $Result.HolderCount | Should -Be 0
        $Result.GiniCoefficient | Should -Be 0
    }
}

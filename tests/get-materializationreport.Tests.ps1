<#
    .SYNOPSIS
    Pester tests for get-materializationreport.ps1.

    .DESCRIPTION
    Tests for Get-MaterializationReport covering denomination breakdown,
    player breakdown, orphaned physical currency detection, and summary.
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
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-materializationreport.ps1')
}

Describe 'Get-MaterializationReport - basic' {
    BeforeAll {
        $script:EconEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-economy.md')
        $script:EconEnriched = Get-EntityState -Entities $script:EconEntities -Sessions @()
        $script:EconPlayers = Get-Player -Entities $script:EconEntities
        $script:Report = Get-MaterializationReport -Entities $script:EconEnriched -Players $script:EconPlayers -Quiet
    }

    It 'returns a report object' {
        $script:Report | Should -Not -BeNullOrEmpty
        $script:Report.PSObject.Properties['DenominationBreakdown'] | Should -Not -BeNullOrEmpty
        $script:Report.PSObject.Properties['PlayerBreakdown'] | Should -Not -BeNullOrEmpty
        $script:Report.PSObject.Properties['OrphanedPhysical'] | Should -Not -BeNullOrEmpty
        $script:Report.PSObject.Properties['Summary'] | Should -Not -BeNullOrEmpty
    }

    It 'has denomination breakdown' {
        $script:Report.DenominationBreakdown.Count | Should -BeGreaterThan 0
    }

    It 'denomination breakdown includes physical and virtual' {
        $Korony = $script:Report.DenominationBreakdown | Where-Object { $_.Denomination -eq 'Korony Elanckie' }
        $Korony | Should -Not -BeNullOrEmpty
        $Korony.Physical | Should -BeGreaterThan 0
        $Korony.Virtual | Should -BeGreaterThan 0
    }

    It 'computes physical percentage correctly' {
        $Korony = $script:Report.DenominationBreakdown | Where-Object { $_.Denomination -eq 'Korony Elanckie' }
        # Physical: 100+50=150, Total: 100+50+200+500=850
        # PhysicalPct ≈ 17.6%
        $Korony.PhysicalPct | Should -BeGreaterThan 17
        $Korony.PhysicalPct | Should -BeLessThan 18
    }

    It 'has player breakdown for physical currency' {
        $script:Report.PlayerBreakdown.Count | Should -BeGreaterThan 0
        $Solmyr = $script:Report.PlayerBreakdown | Where-Object { $_.PlayerName -eq 'Solmyr' }
        $Solmyr | Should -Not -BeNullOrEmpty
        $Solmyr.TotalPhysicalKogi | Should -BeGreaterThan 0
    }

    It 'maps characters to player in breakdown' {
        $Solmyr = $script:Report.PlayerBreakdown | Where-Object { $_.PlayerName -eq 'Solmyr' }
        $Solmyr.Characters | Should -Contain 'Bohater Artur'
        $Solmyr.Characters | Should -Contain 'Bohaterka Ewa'
    }

    It 'reports no orphaned physical currency for active entities' {
        $script:Report.OrphanedPhysical.Count | Should -Be 0
    }

    It 'summary includes totals' {
        $script:Report.Summary.TotalPhysical | Should -BeGreaterThan 0
        $script:Report.Summary.TotalVirtual | Should -BeGreaterThan 0
        $script:Report.Summary.OrphanedCount | Should -Be 0
    }
}

Describe 'Get-MaterializationReport - orphaned physical currency' {
    BeforeAll {
        $script:MatEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-economy-materialization.md')
        $script:MatEnriched = Get-EntityState -Entities $script:MatEntities -Sessions @()
        $script:MatPlayers = Get-Player -Entities $script:MatEntities
        $script:Report = Get-MaterializationReport -Entities $script:MatEnriched -Players $script:MatPlayers -Quiet
    }

    It 'detects orphaned physical currency from inactive Postać' {
        $script:Report.OrphanedPhysical.Count | Should -Be 1
    }

    It 'orphaned entry names the correct entity' {
        $Orphan = $script:Report.OrphanedPhysical[0]
        $Orphan.Entity | Should -Be 'Korony Maga'
        $Orphan.Owner | Should -Be 'Nieaktywny Mag'
        $Orphan.OwnerStatus | Should -Be 'Nieaktywny'
    }

    It 'orphaned entry has correct quantity' {
        $Orphan = $script:Report.OrphanedPhysical[0]
        $Orphan.Quantity | Should -Be 30
    }

    It 'summary counts orphans' {
        $script:Report.Summary.OrphanedCount | Should -Be 1
    }
}

Describe 'Get-MaterializationReport - empty entities' {
    It 'handles empty entities without error' {
        $Result = Get-MaterializationReport -Entities @() -Players @() -Quiet
        $Result | Should -Not -BeNullOrEmpty
        $Result.DenominationBreakdown.Count | Should -Be 0
        $Result.Summary.TotalPhysical | Should -Be 0
    }
}

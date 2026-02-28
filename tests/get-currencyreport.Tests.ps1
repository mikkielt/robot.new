<#
    .SYNOPSIS
    Pester tests for get-currencyreport.ps1.

    .DESCRIPTION
    Tests for Get-CurrencyReport covering currency entity filtering,
    denomination and owner filters, base unit conversion, history
    inclusion, and report structure validation.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'currency-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-currencyreport.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-entitystate.ps1')
}

Describe 'Get-CurrencyReport' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md') -Entities $script:Entities -Players $script:Players
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions
    }

    It 'returns currency entities only' {
        $Report = Get-CurrencyReport -Entities $script:Enriched
        $Report | Should -Not -BeNullOrEmpty
        $Report.Count | Should -BeGreaterThan 0
        foreach ($Entry in $Report) {
            $Entry.Denomination | Should -BeIn @('Korony Elanckie', 'Talary Hirońskie', 'Kogi Skeltvorskie')
        }
    }

    It 'filters by denomination' {
        $Report = Get-CurrencyReport -Entities $script:Enriched -Denomination 'Korony Elanckie'
        $Report | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Report) {
            $Entry.Denomination | Should -Be 'Korony Elanckie'
        }
    }

    It 'filters by denomination using stem' {
        $Report = Get-CurrencyReport -Entities $script:Enriched -Denomination 'koron'
        $Report | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Report) {
            $Entry.Denomination | Should -Be 'Korony Elanckie'
        }
    }

    It 'filters by owner' {
        $Report = Get-CurrencyReport -Entities $script:Enriched -Owner 'Kyrre'
        $Report.Count | Should -Be 1
        $Report[0].Owner | Should -Be 'Kyrre'
    }

    It 'computes base unit values with -AsBaseUnit' {
        $Report = Get-CurrencyReport -Entities $script:Enriched -AsBaseUnit
        $Report | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Report) {
            $Entry.BaseUnitValue | Should -Not -BeNullOrEmpty
        }
    }

    It 'includes history with -ShowHistory' {
        $Report = Get-CurrencyReport -Entities $script:Enriched -ShowHistory
        $WithHistory = $Report | Where-Object { $_.PSObject.Properties['History'] }
        $WithHistory | Should -Not -BeNullOrEmpty
    }

    It 'has correct entity structure' {
        $Report = Get-CurrencyReport -Entities $script:Enriched
        $Entry = $Report[0]
        $Entry.PSObject.Properties['EntityName'] | Should -Not -BeNullOrEmpty
        $Entry.PSObject.Properties['Denomination'] | Should -Not -BeNullOrEmpty
        $Entry.PSObject.Properties['Balance'] | Should -Not -BeNullOrEmpty
        $Entry.PSObject.Properties['OwnerType'] | Should -Not -BeNullOrEmpty
        $Entry.PSObject.Properties['Warnings'] | Should -Not -BeNullOrEmpty
    }
}

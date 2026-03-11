<#
    .SYNOPSIS
    Pester tests for get-economictimeline.ps1.

    .DESCRIPTION
    Tests for Get-EconomicTimeline covering monthly data point generation,
    supply tracking, and date range handling.
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
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'reporting-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'economy-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-economictimeline.ps1')
}

Describe 'Get-EconomicTimeline - basic' {
    BeforeAll {
        # Uses default fixtures/entities.md via mocked Get-RepoRoot
        $script:Sessions = @()
        $script:Timeline = Get-EconomicTimeline -Sessions $script:Sessions `
            -MinDate ([datetime]::new(2024, 6, 1)) -MaxDate ([datetime]::new(2024, 8, 31)) -Quiet
    }

    It 'returns monthly data points' {
        $script:Timeline | Should -Not -BeNullOrEmpty
        $script:Timeline.Count | Should -Be 3
    }

    It 'first month is June 2024' {
        $script:Timeline[0].Month | Should -Be '2024-06'
    }

    It 'last month is August 2024' {
        $script:Timeline[2].Month | Should -Be '2024-08'
    }

    It 'each data point has supply fields' {
        $Point = $script:Timeline[0]
        $Point.PSObject.Properties['TotalSupplyKogi'] | Should -Not -BeNullOrEmpty
        $Point.PSObject.Properties['PhysicalSupplyKogi'] | Should -Not -BeNullOrEmpty
        $Point.PSObject.Properties['VirtualSupplyKogi'] | Should -Not -BeNullOrEmpty
        $Point.PSObject.Properties['TransferCount'] | Should -Not -BeNullOrEmpty
    }

    It 'supply values are non-negative' {
        foreach ($Point in $script:Timeline) {
            $Point.TotalSupplyKogi | Should -BeGreaterOrEqual 0
        }
    }
}

Describe 'Get-EconomicTimeline - single month' {
    It 'returns one data point for single month range' {
        $Timeline = Get-EconomicTimeline -Sessions @() `
            -MinDate ([datetime]::new(2024, 6, 1)) -MaxDate ([datetime]::new(2024, 6, 30)) -Quiet
        $Timeline | Should -Not -BeNullOrEmpty
        $Timeline.Count | Should -Be 1
        $Timeline[0].Month | Should -Be '2024-06'
    }
}

Describe 'Get-EconomicTimeline - with transfers' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md')
        $script:Timeline = Get-EconomicTimeline -Sessions $script:Sessions `
            -MinDate ([datetime]::new(2025, 5, 1)) -MaxDate ([datetime]::new(2025, 7, 31)) -Quiet
    }

    It 'includes transfer count for months with transfers' {
        # The transfer is on 2025-06-01
        $JunePoint = $script:Timeline | Where-Object { $_.Month -eq '2025-06' }
        $JunePoint | Should -Not -BeNullOrEmpty
        $JunePoint.TransferCount | Should -BeGreaterThan 0
    }

    It 'has zero transfers for months without transfers' {
        $MayPoint = $script:Timeline | Where-Object { $_.Month -eq '2025-05' }
        $MayPoint | Should -Not -BeNullOrEmpty
        $MayPoint.TransferCount | Should -Be 0
    }
}

Describe 'Get-EconomicTimeline - empty data' {
    It 'handles months with no currency entities' {
        # Use dates before any entities exist (2020)
        $Timeline = Get-EconomicTimeline -Sessions @() `
            -MinDate ([datetime]::new(2020, 1, 1)) -MaxDate ([datetime]::new(2020, 1, 31)) -Quiet
        $Timeline | Should -Not -BeNullOrEmpty
        $Timeline.Count | Should -Be 1
        $Timeline[0].TotalSupplyKogi | Should -Be 0
    }
}

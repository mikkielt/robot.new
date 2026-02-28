<#
    .SYNOPSIS
    Pester tests for get-entityhistory.ps1.

    .DESCRIPTION
    Tests for Get-EntityHistory covering timeline merging from multiple
    history arrays, date filtering, sorting, and entity lookup by name/alias.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-entitystate.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-entityhistory.ps1')
}

Describe 'Get-EntityHistory' {
    BeforeAll {
        # Use entities from main entities.md + deep-zmiany session which modifies Kupiec Orrin, Rion, Thant
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-deep-zmiany.md') -Entities $script:Entities -Players $script:Players
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions
    }

    It 'returns timeline entries for an entity with history' {
        # Kupiec Orrin has LocationHistory and GroupHistory from entities.md + session overrides
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched
        $Result | Should -Not -BeNullOrEmpty
        $Result.Count | Should -BeGreaterThan 0
    }

    It 'returns entries with correct property names' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched
        $First = $Result[0]
        $First.PSObject.Properties['Property'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Value'] | Should -Not -BeNullOrEmpty
    }

    It 'includes location history' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched
        $LocEntries = $Result | Where-Object { $_.Property -eq 'Lokacja' }
        $LocEntries | Should -Not -BeNullOrEmpty
    }

    It 'includes multiple history types' {
        # Rion has LocationHistory, GroupHistory from entities.md (multiple temporal entries)
        $Result = Get-EntityHistory -Name 'Rion' -Entities $script:Enriched
        $Properties = $Result | ForEach-Object { $_.Property } | Sort-Object -Unique
        $Properties | Should -Contain 'Lokacja'
        $Properties | Should -Contain 'Grupa'
    }

    It 'sorts entries chronologically with nulls first' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched
        if ($Result.Count -gt 1) {
            $PrevDate = $null
            foreach ($Entry in $Result) {
                if ($null -ne $PrevDate -and $null -ne $Entry.Date) {
                    $Entry.Date | Should -BeGreaterOrEqual $PrevDate
                }
                if ($null -ne $Entry.Date) { $PrevDate = $Entry.Date }
            }
        }
    }

    It 'returns empty array for unknown entity' {
        $Result = Get-EntityHistory -Name 'NieistniejącaPostać' -Entities $script:Enriched
        $Result.Count | Should -Be 0
    }

    It 'filters by MinDate' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched -MinDate ([datetime]'2024-06-01')
        foreach ($Entry in $Result) {
            if ($null -ne $Entry.Date) {
                $Entry.Date | Should -BeGreaterOrEqual ([datetime]'2024-06-01')
            }
        }
    }

    It 'filters by MaxDate' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched -MaxDate ([datetime]'2024-06-30')
        foreach ($Entry in $Result) {
            if ($null -ne $Entry.Date) {
                $Entry.Date | Should -BeLessOrEqual ([datetime]'2024-06-30')
            }
        }
    }

    It 'handles entity with no history gracefully' {
        $TestEntities = @(
            [PSCustomObject]@{
                Name            = 'Empty NPC'
                Names           = [System.Collections.Generic.List[string]]@('Empty NPC')
                LocationHistory = [System.Collections.Generic.List[object]]::new()
                StatusHistory   = $null
                GroupHistory    = [System.Collections.Generic.List[object]]::new()
                OwnerHistory    = [System.Collections.Generic.List[object]]::new()
                TypeHistory     = [System.Collections.Generic.List[object]]::new()
                DoorHistory     = [System.Collections.Generic.List[object]]::new()
                QuantityHistory = $null
            }
        )
        $Result = Get-EntityHistory -Name 'Empty NPC' -Entities $TestEntities
        $Result.Count | Should -Be 0
    }
}

Describe 'Get-EntityHistory - entity with rich history' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-deep-zmiany.md') -Entities $script:Entities -Players $script:Players
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions
    }

    It 'returns changes from deep zmiany session' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched
        $Result | Should -Not -BeNullOrEmpty
        $LocEntries = $Result | Where-Object { $_.Property -eq 'Lokacja' }
        $LocEntries | Should -Not -BeNullOrEmpty
    }

    It 'includes group history' {
        $Result = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $script:Enriched
        $GroupEntries = $Result | Where-Object { $_.Property -eq 'Grupa' }
        $GroupEntries | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-EntityHistory - quantity history' {
    BeforeAll {
        # Kogi Kyrre in entities.md has @ilość: 1500 (2024-08:) and @ilość: 800 (2025-02:)
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions @()
    }

    It 'includes quantity changes' {
        $Result = Get-EntityHistory -Name 'Kogi Kyrre' -Entities $script:Enriched
        $QtyEntries = $Result | Where-Object { $_.Property -eq 'Ilość' }
        $QtyEntries | Should -Not -BeNullOrEmpty
        $QtyEntries.Count | Should -BeGreaterOrEqual 2
    }
}

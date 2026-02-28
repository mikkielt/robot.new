<#
    .SYNOPSIS
    Pester tests for @status tag parsing in Get-Entity.

    .DESCRIPTION
    Tests for @status tag handling covering basic parsing (Aktywny,
    Nieaktywny, Usunięty), default status, temporal transitions,
    and Przedmiot entity type support.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
}

Describe '@status tag parsing in Get-Entity' {
    Context 'Basic @status parsing' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-basic.md')
        }

        It 'parses Aktywny status' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Arcydemona Xerona Sojusznik' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'parses Nieaktywny status' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Nieaktywny Mag Bracady' }
            $E.Status | Should -Be 'Nieaktywny'
        }

        It 'parses Usunięty status' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Usunięty Elf z AvLee' }
            $E.Status | Should -Be 'Usunięty'
        }

        It 'has StatusHistory entries' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Arcydemona Xerona Sojusznik' }
            $E.StatusHistory.Count | Should -Be 1
            $E.StatusHistory[0].Status | Should -Be 'Aktywny'
        }
    }

    Context 'Default Aktywny when no @status' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-default.md')
        }

        It 'defaults to Aktywny' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Bohater bez Statusu' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'has empty StatusHistory' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Bohater bez Statusu' }
            $E.StatusHistory.Count | Should -Be 0
        }
    }

    Context 'Temporal status transitions' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-transitions.md')
        }

        It 'resolves most recent status without date filter' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Mag Przemieniający się' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'resolves status at specific date (mid inactive period)' {
            $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-transitions.md') -ActiveOn ([datetime]::ParseExact('2024-10-15', 'yyyy-MM-dd', $null))
            $E = $Entities | Where-Object { $_.Name -eq 'Mag Przemieniający się' }
            $E.Status | Should -Be 'Nieaktywny'
        }
    }

    Context 'Przedmiot entity type' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-przedmiot.md')
        }

        It 'parses Przedmiot type' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Kielich Gryfona' }
            $E.Type | Should -Be 'Przedmiot'
        }

        It 'resolves ownership' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Kielich Gryfona' }
            $E.Owner | Should -Be 'Solmyr'
        }
    }

    Context 'Temporal transitions - edge cases' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-transitions.md')
        }

        It 'resolves status at exact boundary of first period end' {
            $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-transitions.md') -ActiveOn ([datetime]::ParseExact('2024-06-30', 'yyyy-MM-dd', $null))
            $E = $Entities | Where-Object { $_.Name -eq 'Mag Przemieniający się' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'resolves status at exact boundary of second period start' {
            $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-transitions.md') -ActiveOn ([datetime]::ParseExact('2024-07-01', 'yyyy-MM-dd', $null))
            $E = $Entities | Where-Object { $_.Name -eq 'Mag Przemieniający się' }
            $E.Status | Should -Be 'Nieaktywny'
        }

        It 'resolves status at boundary of reactivation' {
            $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-status-transitions.md') -ActiveOn ([datetime]::ParseExact('2025-02-01', 'yyyy-MM-dd', $null))
            $E = $Entities | Where-Object { $_.Name -eq 'Mag Przemieniający się' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'has three StatusHistory entries for all transitions' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Mag Przemieniający się' }
            $E.StatusHistory.Count | Should -Be 3
        }
    }

    Context 'Overlapping temporal ranges' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-overlapping-temporal.md')
        }

        It 'parses entity with overlapping location periods' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Wędrowny Druid' }
            $E | Should -Not -BeNullOrEmpty
            $E.LocationHistory.Count | Should -Be 4
        }

        It 'resolves latest location from overlapping periods' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Wędrowny Druid' }
            $E.Location | Should -Be 'Dolina Elfów'
        }

        It 'resolves location during overlap period' {
            $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-overlapping-temporal.md') -ActiveOn ([datetime]::ParseExact('2023-05-15', 'yyyy-MM-dd', $null))
            $E = $Entities | Where-Object { $_.Name -eq 'Wędrowny Druid' }
            $E.LocationHistory | Should -Not -BeNullOrEmpty
        }

        It 'has multiple status transitions' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Wędrowny Druid' }
            $E.StatusHistory.Count | Should -Be 3
        }
    }
}

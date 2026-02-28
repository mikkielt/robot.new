<#
    .SYNOPSIS
    Pester tests for get-transactionledger.ps1.

    .DESCRIPTION
    Tests for Get-TransactionLedger covering @Transfer extraction from sessions,
    entity filtering, denomination filtering, running balance computation, and
    chronological sorting.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'currency-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-transactionledger.ps1')
}

Describe 'Get-TransactionLedger' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-multi-transfer.md') -Entities $script:Entities -Players $script:Players
    }

    It 'returns transfer entries from sessions' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions
        $Result | Should -Not -BeNullOrEmpty
        $Result.Count | Should -BeGreaterThan 0
    }

    It 'returns entries with correct output shape' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions
        $First = $Result[0]
        $First.PSObject.Properties['Date'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Amount'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Source'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Destination'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Denomination'] | Should -Not -BeNullOrEmpty
    }

    It 'extracts all transfers from session' {
        # sessions-multi-transfer.md has 3 @Transfer directives
        $Result = Get-TransactionLedger -Sessions $script:Sessions
        $Result.Count | Should -Be 3
    }

    It 'sorts chronologically' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions
        if ($Result.Count -gt 1) {
            for ($i = 1; $i -lt $Result.Count; $i++) {
                $Result[$i].Date | Should -BeGreaterOrEqual $Result[$i - 1].Date
            }
        }
    }

    It 'filters by entity (source)' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions -Entity 'Dawca'
        $Result | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Result) {
            ($Entry.Source -eq 'Dawca' -or $Entry.Destination -eq 'Dawca') | Should -BeTrue
        }
    }

    It 'filters by entity (destination)' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions -Entity 'Trzeci'
        $Result | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Result) {
            ($Entry.Source -eq 'Trzeci' -or $Entry.Destination -eq 'Trzeci') | Should -BeTrue
        }
    }

    It 'adds Direction property when entity filter is active' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions -Entity 'Dawca'
        foreach ($Entry in $Result) {
            $Entry.PSObject.Properties['Direction'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'computes running balance when entity filter is active' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions -Entity 'Dawca'
        foreach ($Entry in $Result) {
            $Entry.PSObject.Properties['RunningBalance'] | Should -Not -BeNullOrEmpty
        }
        # Dawca sends 20 to Odbiorca and 15 to Trzeci = -35 total
        $Last = $Result[-1]
        $Last.RunningBalance | Should -Be -35
    }

    It 'marks outgoing as Out and incoming as In' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions -Entity 'Odbiorca'
        $InEntries = $Result | Where-Object { $_.Direction -eq 'In' }
        $OutEntries = $Result | Where-Object { $_.Direction -eq 'Out' }
        # Odbiorca receives 20 from Dawca (In) and sends 5 to Trzeci (Out)
        $InEntries.Count | Should -Be 1
        $OutEntries.Count | Should -Be 1
    }

    It 'returns empty array for sessions without transfers' {
        $NoTransferSessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-empty-body.md') -Entities $script:Entities -Players $script:Players
        $Result = Get-TransactionLedger -Sessions $NoTransferSessions
        $Result.Count | Should -Be 0
    }

    It 'returns empty array when entity filter matches nothing' {
        $Result = Get-TransactionLedger -Sessions $script:Sessions -Entity 'Nieistniejący'
        $Result.Count | Should -Be 0
    }
}

Describe 'Get-TransactionLedger - with zmiany session' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-zmiany.md') -Entities $script:Entities -Players $script:Players
    }

    It 'extracts transfer from zmiany session' {
        # sessions-zmiany.md has 1 @Transfer directive
        $Result = Get-TransactionLedger -Sessions $script:Sessions
        $Result.Count | Should -Be 1
        $Result[0].Source | Should -Be 'Xeron Demonlord'
        $Result[0].Destination | Should -Be 'Kupiec Orrin'
    }
}

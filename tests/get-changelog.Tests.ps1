<#
    .SYNOPSIS
    Pester tests for get-changelog.ps1.

    .DESCRIPTION
    Tests for Get-ChangeLog covering extraction of @Zmiany from sessions,
    entity name filtering, property filtering, date range filtering, and sorting.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-changelog.ps1')
}

Describe 'Get-ChangeLog' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-deep-zmiany.md') -Entities $script:Entities -Players $script:Players
    }

    It 'returns change entries from sessions with @Zmiany' {
        $Result = Get-ChangeLog -Sessions $script:Sessions
        $Result | Should -Not -BeNullOrEmpty
        $Result.Count | Should -BeGreaterThan 0
    }

    It 'returns entries with correct output shape' {
        $Result = Get-ChangeLog -Sessions $script:Sessions
        $First = $Result[0]
        $First.PSObject.Properties['Date'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['SessionTitle'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['EntityName'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Property'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Value'] | Should -Not -BeNullOrEmpty
    }

    It 'strips @ prefix from property names' {
        $Result = Get-ChangeLog -Sessions $script:Sessions
        foreach ($Entry in $Result) {
            $Entry.Property | Should -Not -BeLike '@*'
        }
    }

    It 'filters by entity name' {
        $Result = Get-ChangeLog -Sessions $script:Sessions -EntityName 'Kupiec Orrin'
        $Result | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Result) {
            $Entry.EntityName | Should -Be 'Kupiec Orrin'
        }
    }

    It 'filters by property name' {
        $Result = Get-ChangeLog -Sessions $script:Sessions -Property 'lokacja'
        $Result | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Result) {
            $Entry.Property | Should -Be 'lokacja'
        }
    }

    It 'sorts chronologically' {
        $Result = Get-ChangeLog -Sessions $script:Sessions
        if ($Result.Count -gt 1) {
            for ($i = 1; $i -lt $Result.Count; $i++) {
                $Result[$i].Date | Should -BeGreaterOrEqual $Result[$i - 1].Date
            }
        }
    }

    It 'returns empty array for sessions without changes' {
        $NoChangeSessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-empty-body.md') -Entities $script:Entities -Players $script:Players
        $Result = Get-ChangeLog -Sessions $NoChangeSessions
        $Result.Count | Should -Be 0
    }

    It 'returns empty array when entity name filter matches nothing' {
        $Result = Get-ChangeLog -Sessions $script:Sessions -EntityName 'NieistniejącaPostać'
        $Result.Count | Should -Be 0
    }
}

Describe 'Get-ChangeLog - multiple sessions' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        # Load sessions from both change fixtures
        $File1 = Join-Path $script:FixturesRoot 'sessions-changes.md'
        $File2 = Join-Path $script:FixturesRoot 'sessions-deep-zmiany.md'
        $Sessions1 = Get-Session -File $File1 -Entities $script:Entities -Players $script:Players
        $Sessions2 = Get-Session -File $File2 -Entities $script:Entities -Players $script:Players
        $script:AllSessions = @($Sessions1) + @($Sessions2)
    }

    It 'aggregates changes across multiple sessions' {
        $Result = Get-ChangeLog -Sessions $script:AllSessions
        $Result.Count | Should -BeGreaterThan 2
    }

    It 'date range filtering works' {
        $Result = Get-ChangeLog -Sessions $script:AllSessions -MinDate ([datetime]'2025-01-01') -MaxDate ([datetime]'2025-12-31')
        foreach ($Entry in $Result) {
            $Entry.Date | Should -BeGreaterOrEqual ([datetime]'2025-01-01')
            $Entry.Date | Should -BeLessOrEqual ([datetime]'2025-12-31')
        }
    }
}

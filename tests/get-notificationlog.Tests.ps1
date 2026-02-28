<#
    .SYNOPSIS
    Pester tests for get-notificationlog.ps1.

    .DESCRIPTION
    Tests for Get-NotificationLog covering @Intel extraction from sessions,
    directive filtering, target filtering, date range filtering, and
    recipient resolution.
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
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-notificationlog.ps1')
}

Describe 'Get-NotificationLog' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen4-full.md') -Entities $script:Entities -Players $script:Players
    }

    It 'returns notification entries from sessions with @Intel' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities
        $Result | Should -Not -BeNullOrEmpty
        $Result.Count | Should -BeGreaterThan 0
    }

    It 'returns entries with correct output shape' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities
        $First = $Result[0]
        $First.PSObject.Properties['Date'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['SessionTitle'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Directive'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['TargetName'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Message'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['RecipientCount'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Recipients'] | Should -Not -BeNullOrEmpty
    }

    It 'extracts multiple Intel entries from one session' {
        # sessions-gen4-full.md has 4 @Intel entries
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities
        $Result.Count | Should -Be 4
    }

    It 'identifies directive types correctly' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities
        $Directives = $Result | ForEach-Object { $_.Directive } | Sort-Object -Unique
        $Directives | Should -Contain 'Grupa'
        $Directives | Should -Contain 'Lokacja'
        $Directives | Should -Contain 'Direct'
    }

    It 'filters by directive type' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities -Directive 'Grupa'
        $Result | Should -Not -BeNullOrEmpty
        foreach ($Entry in $Result) {
            $Entry.Directive | Should -Be 'Grupa'
        }
    }

    It 'filters by target name' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities -Target 'Xeron Demonlord'
        $Result | Should -Not -BeNullOrEmpty
        # Should find the direct Intel targeting Xeron Demonlord
        $Result.Count | Should -BeGreaterOrEqual 1
    }

    It 'sorts chronologically' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities
        if ($Result.Count -gt 1) {
            for ($i = 1; $i -lt $Result.Count; $i++) {
                $Result[$i].Date | Should -BeGreaterOrEqual $Result[$i - 1].Date
            }
        }
    }

    It 'returns empty array for sessions without Intel' {
        $NoIntelSessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-empty-body.md') -Entities $script:Entities -Players $script:Players
        $Result = Get-NotificationLog -Sessions $NoIntelSessions -Entities $script:Entities
        $Result.Count | Should -Be 0
    }

    It 'returns empty array when target filter matches nothing' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities -Target 'Nieistniejący'
        $Result.Count | Should -Be 0
    }

    It 'includes message text' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities
        $XeronIntel = $Result | Where-Object { $_.TargetName -eq 'Xeron Demonlord' }
        if ($XeronIntel) {
            $XeronIntel.Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-NotificationLog - date filtering' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -File (Join-Path $script:FixturesRoot 'Gracze.md') -Entities $script:Entities
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen4-full.md') -Entities $script:Entities -Players $script:Players
    }

    It 'filters by MinDate' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities -MinDate ([datetime]'2026-01-01')
        # Session date is 2025-03-01, so no results after 2026
        $Result.Count | Should -Be 0
    }

    It 'includes sessions within date range' {
        $Result = Get-NotificationLog -Sessions $script:Sessions -Entities $script:Entities -MinDate ([datetime]'2025-01-01') -MaxDate ([datetime]'2025-12-31')
        $Result | Should -Not -BeNullOrEmpty
    }
}

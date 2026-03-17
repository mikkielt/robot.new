<#
    .SYNOPSIS
    Pester tests for get-discorddeliverylog.ps1.

    .DESCRIPTION
    Tests for Get-DiscordDeliveryLog covering filtering by operation, recipient,
    date range, FailedOnly, combined filters, sort order, and edge cases.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'discord-state.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-discorddeliverylog.ps1')
}

Describe 'Get-DiscordDeliveryLog' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
        $script:SamplePath = Join-Path $script:TempDir 'discord-delivery.md'
        $FixtureContent = @"
# Discord Delivery Log

- 2026-02-15 10:00:00 (UTC+01:00) [OK] PU -> Jan (HTTP 204)
    - 2026-01 PU: Solmyr +3.00
- 2026-02-15 10:00:01 (UTC+01:00) [FAIL] PU -> Tomek
    - 2026-01 PU: Arden +5.00
    - ERROR: Discord webhook returned HTTP 429: rate limited
- 2026-03-01 09:15:22 (UTC+01:00) [OK] PU -> Jan (HTTP 204)
    - 2026-02 PU: Solmyr +2.00, Kael +1.00
- 2026-03-01 09:15:23 (UTC+01:00) [FAIL] PU -> Tomek
    - 2026-02 PU: Arden +4.00
    - ERROR: Connection timeout
- 2026-03-12 18:30:05 (UTC+01:00) [OK] Announcement -> Announcement (HTTP 204)
    - Ogłoszenie: Następna sesja w piątek
- 2026-03-15 10:00:00 (UTC+01:00) [OK] PU-Resend -> Tomek (HTTP 204)
    - 2026-01 PU: Arden +5.00
"@
        Write-TestFile -Path $script:SamplePath -Content $FixtureContent
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'returns all entries when no filters applied' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath
        $Result.Count | Should -Be 6
    }

    It 'returns entries with correct output shape' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath
        $First = $Result[0]
        $First.PSObject.Properties['Timestamp'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Timezone'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Status'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Operation'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Recipient'] | Should -Not -BeNullOrEmpty
    }

    It 'sorts by timestamp descending (most recent first)' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath
        if ($Result.Count -gt 1) {
            for ($i = 1; $i -lt $Result.Count; $i++) {
                $Result[$i].Timestamp | Should -BeLessOrEqual $Result[$i - 1].Timestamp
            }
        }
    }

    It 'filters by Operation' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -Operation 'Announcement'
        $Result.Count | Should -Be 1
        $Result[0].Operation | Should -Be 'Announcement'
    }

    It 'filters by Recipient' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -Recipient 'Jan'
        $Result.Count | Should -Be 2
        foreach ($Entry in $Result) {
            $Entry.Recipient | Should -Be 'Jan'
        }
    }

    It 'filters by FailedOnly' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -FailedOnly
        $Result.Count | Should -Be 2
        foreach ($Entry in $Result) {
            $Entry.Status | Should -Be 'FAIL'
        }
    }

    It 'filters by MinDate' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -MinDate ([datetime]'2026-03-01')
        foreach ($Entry in $Result) {
            $Entry.Timestamp | Should -BeGreaterOrEqual ([datetime]'2026-03-01')
        }
    }

    It 'filters by MaxDate' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -MaxDate ([datetime]'2026-02-28')
        $Result.Count | Should -Be 2
        foreach ($Entry in $Result) {
            $Entry.Timestamp | Should -BeLessOrEqual ([datetime]'2026-02-28')
        }
    }

    It 'combines FailedOnly and Operation filters' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -FailedOnly -Operation 'PU'
        $Result.Count | Should -Be 2
        foreach ($Entry in $Result) {
            $Entry.Status | Should -Be 'FAIL'
            $Entry.Operation | Should -Be 'PU'
        }
    }

    It 'combines Recipient and MinDate filters' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -Recipient 'Tomek' -MinDate ([datetime]'2026-03-01')
        foreach ($Entry in $Result) {
            $Entry.Recipient | Should -Be 'Tomek'
            $Entry.Timestamp | Should -BeGreaterOrEqual ([datetime]'2026-03-01')
        }
    }

    It 'filters by PU-Resend operation' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -Operation 'PU-Resend'
        $Result.Count | Should -Be 1
        $Result[0].Recipient | Should -Be 'Tomek'
    }

    It 'returns empty array for nonexistent file' {
        $Result = Get-DiscordDeliveryLog -Path '/nonexistent/path/delivery.md'
        $Result.Count | Should -Be 0
    }

    It 'returns empty array for file with no entries' {
        $EmptyPath = Join-Path $script:TempDir 'empty-delivery.md'
        Write-TestFile -Path $EmptyPath -Content '# Discord Delivery Log'
        $Result = Get-DiscordDeliveryLog -Path $EmptyPath
        $Result.Count | Should -Be 0
    }

    It 'returns empty array when filters match nothing' {
        $Result = Get-DiscordDeliveryLog -Path $script:SamplePath -Operation 'Intel'
        $Result.Count | Should -Be 0
    }
}

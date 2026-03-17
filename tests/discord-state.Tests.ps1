<#
    .SYNOPSIS
    Pester tests for discord-state.ps1.

    .DESCRIPTION
    Tests for Add-DiscordDeliveryEntry and Get-DiscordDeliveryEntries covering
    state file creation, write/read round-trip, mixed OK/FAIL entries,
    context and error lines, and edge cases.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'discord-state.ps1')
}

Describe 'Add-DiscordDeliveryEntry' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates state file with preamble when missing' {
        $Path = Join-Path $script:TempDir 'new-delivery.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        [System.IO.File]::Exists($Path) | Should -BeTrue
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*Discord Delivery Log*'
    }

    It 'creates parent directory if it does not exist' {
        $Path = Join-Path $script:TempDir 'sub' 'dir' 'delivery.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }

    It 'writes OK entry with status code' {
        $Path = Join-Path $script:TempDir 'ok-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*`[OK`] PU -> Jan (HTTP 204)*'
    }

    It 'writes FAIL entry with error message' {
        $Path = Join-Path $script:TempDir 'fail-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Tomek' -Success $false `
            -ErrorMessage 'Discord webhook returned HTTP 429: rate limited'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*`[FAIL`] PU -> Tomek*'
        $Content | Should -BeLike '*ERROR: Discord webhook returned HTTP 429*'
    }

    It 'writes context line' {
        $Path = Join-Path $script:TempDir 'ctx-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true `
            -StatusCode 204 -Context '2026-02 PU: Solmyr +3.00'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*2026-02 PU: Solmyr +3.00*'
    }

    It 'appends multiple entries to existing file' {
        $Path = Join-Path $script:TempDir 'multi-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        Add-DiscordDeliveryEntry -Path $Path -Operation 'Announcement' -Recipient 'General' -Success $true -StatusCode 204
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*PU -> Jan*'
        $Content | Should -BeLike '*Announcement -> General*'
    }

    It 'writes entry without status code' {
        $Path = Join-Path $script:TempDir 'no-code-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Tomek' -Success $false `
            -ErrorMessage 'Connection timeout'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*`[FAIL`] PU -> Tomek*'
        $Content | Should -Not -BeLike '*HTTP*'
    }

    It 'writes Announcement operation' {
        $Path = Join-Path $script:TempDir 'announce-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'Announcement' -Recipient 'Announcement' `
            -Success $true -StatusCode 204 -Context 'Ogłoszenie: Sesja w piątek'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*Announcement -> Announcement*'
        $Content | Should -BeLike '*Ogłoszenie: Sesja*'
    }

    It 'writes PU-Resend operation' {
        $Path = Join-Path $script:TempDir 'resend-entry.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU-Resend' -Recipient 'Jan' `
            -Success $true -StatusCode 204 -Context '2026-02 PU: Solmyr +3.00'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*PU-Resend -> Jan*'
    }
}

Describe 'Get-DiscordDeliveryEntries' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
        # Create a fixture with mixed entries
        $script:FixturePath = Join-Path $script:TempDir 'delivery-fixture.md'
        $FixtureContent = @"
# Discord Delivery Log

- 2026-03-01 09:15:22 (UTC+01:00) [OK] PU -> Jan (HTTP 204)
    - 2026-02 PU: Solmyr +3.00, Kael +2.00
- 2026-03-01 09:15:23 (UTC+01:00) [FAIL] PU -> Tomek
    - 2026-02 PU: Arden +5.00
    - ERROR: Discord webhook returned HTTP 429: rate limited
- 2026-03-12 18:30:05 (UTC+01:00) [OK] Announcement -> Announcement (HTTP 204)
    - Ogłoszenie: Następna sesja w piątek
- 2026-03-15 10:00:00 (UTC+01:00) [OK] PU-Resend -> Tomek (HTTP 204)
    - 2026-02 PU: Arden +5.00
"@
        Write-TestFile -Path $script:FixturePath -Content $FixtureContent
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'parses all entries from state file' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $Result.Count | Should -Be 4
    }

    It 'parses OK entry with status code' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $First = $Result[0]
        $First.Status | Should -Be 'OK'
        $First.Operation | Should -Be 'PU'
        $First.Recipient | Should -Be 'Jan'
        $First.StatusCode | Should -Be 204
        $First.Context | Should -Be '2026-02 PU: Solmyr +3.00, Kael +2.00'
        $First.ErrorMessage | Should -BeNullOrEmpty
    }

    It 'parses FAIL entry with error message' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $Second = $Result[1]
        $Second.Status | Should -Be 'FAIL'
        $Second.Operation | Should -Be 'PU'
        $Second.Recipient | Should -Be 'Tomek'
        $Second.StatusCode | Should -BeNullOrEmpty
        $Second.Context | Should -Be '2026-02 PU: Arden +5.00'
        $Second.ErrorMessage | Should -Be 'Discord webhook returned HTTP 429: rate limited'
    }

    It 'parses Announcement entry' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $Third = $Result[2]
        $Third.Operation | Should -Be 'Announcement'
        $Third.Recipient | Should -Be 'Announcement'
        $Third.Context | Should -BeLike '*Następna sesja*'
    }

    It 'parses PU-Resend entry' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $Fourth = $Result[3]
        $Fourth.Operation | Should -Be 'PU-Resend'
        $Fourth.Recipient | Should -Be 'Tomek'
        $Fourth.StatusCode | Should -Be 204
    }

    It 'parses timestamps correctly' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $Result[0].Timestamp.Year | Should -Be 2026
        $Result[0].Timestamp.Month | Should -Be 3
        $Result[0].Timestamp.Day | Should -Be 1
        $Result[0].Timestamp.Hour | Should -Be 9
        $Result[0].Timestamp.Minute | Should -Be 15
        $Result[0].Timestamp.Second | Should -Be 22
    }

    It 'parses timezone string' {
        $Result = Get-DiscordDeliveryEntries -Path $script:FixturePath
        $Result[0].Timezone | Should -Be 'UTC+01:00'
    }

    It 'returns empty array for non-existent file' {
        $Result = Get-DiscordDeliveryEntries -Path '/nonexistent/path/delivery.md'
        $Result.Count | Should -Be 0
    }

    It 'returns empty array for file with no entries' {
        $EmptyPath = Join-Path $script:TempDir 'empty-delivery.md'
        Write-TestFile -Path $EmptyPath -Content '# Discord Delivery Log'
        $Result = Get-DiscordDeliveryEntries -Path $EmptyPath
        $Result.Count | Should -Be 0
    }

    It 'handles entry with no context or error lines' {
        $BarePath = Join-Path $script:TempDir 'bare-delivery.md'
        $BareContent = @"
# Discord Delivery Log

- 2026-03-01 09:15:22 (UTC+01:00) [OK] PU -> Jan (HTTP 204)
"@
        Write-TestFile -Path $BarePath -Content $BareContent
        $Result = Get-DiscordDeliveryEntries -Path $BarePath
        $Result.Count | Should -Be 1
        $Result[0].Context | Should -BeNullOrEmpty
        $Result[0].ErrorMessage | Should -BeNullOrEmpty
    }
}

Describe 'Discord state round-trip' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'written entries are readable by Get-DiscordDeliveryEntries' {
        $Path = Join-Path $script:TempDir 'roundtrip.md'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' `
            -Success $true -StatusCode 204 -Context '2026-02 PU: Solmyr +3.00'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Tomek' `
            -Success $false -ErrorMessage 'Connection timeout' -Context '2026-02 PU: Arden +5.00'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'Announcement' -Recipient 'Announcement' `
            -Success $true -StatusCode 204 -Context 'Ogłoszenie: Test'

        $Result = Get-DiscordDeliveryEntries -Path $Path
        $Result.Count | Should -Be 3

        $Result[0].Status | Should -Be 'OK'
        $Result[0].Operation | Should -Be 'PU'
        $Result[0].Recipient | Should -Be 'Jan'
        $Result[0].StatusCode | Should -Be 204
        $Result[0].Context | Should -Be '2026-02 PU: Solmyr +3.00'

        $Result[1].Status | Should -Be 'FAIL'
        $Result[1].Recipient | Should -Be 'Tomek'
        $Result[1].ErrorMessage | Should -Be 'Connection timeout'
        $Result[1].Context | Should -Be '2026-02 PU: Arden +5.00'

        $Result[2].Operation | Should -Be 'Announcement'
    }
}

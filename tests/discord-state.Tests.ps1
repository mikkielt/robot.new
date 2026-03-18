<#
    .SYNOPSIS
    Pester tests for discord-state.ps1.

    .DESCRIPTION
    Tests for Add-DiscordDeliveryEntry, Get-DiscordDeliveryEntries, and
    Convert-DiscordDeliveryToJson covering JSON state file operations,
    write/read round-trip, mixed OK/FAIL entries, and migration conversion.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'discord-state.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'phase0-helpers.ps1')
}

Describe 'Add-DiscordDeliveryEntry' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates JSON state file when missing' {
        $Path = Join-Path $script:TempDir 'new-delivery.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        [System.IO.File]::Exists($Path) | Should -BeTrue
        $Parsed = Read-JsonStateFile -Path $Path
        $Parsed.version | Should -Be 1
        @($Parsed.entries).Count | Should -Be 1
    }

    It 'creates parent directory if it does not exist' {
        $Path = Join-Path $script:TempDir 'sub' 'dir' 'delivery.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }

    It 'writes OK entry with status code' {
        $Path = Join-Path $script:TempDir 'ok-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        $Parsed = Read-JsonStateFile -Path $Path
        $Entry = $Parsed.entries[0]
        $Entry.status | Should -Be 'OK'
        $Entry.operation | Should -Be 'PU'
        $Entry.recipient | Should -Be 'Jan'
        $Entry.statusCode | Should -Be 204
    }

    It 'writes FAIL entry with error message' {
        $Path = Join-Path $script:TempDir 'fail-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Tomek' -Success $false `
            -ErrorMessage 'Discord webhook returned HTTP 429: rate limited'
        $Parsed = Read-JsonStateFile -Path $Path
        $Entry = $Parsed.entries[0]
        $Entry.status | Should -Be 'FAIL'
        $Entry.errorMessage | Should -Be 'Discord webhook returned HTTP 429: rate limited'
    }

    It 'writes context line' {
        $Path = Join-Path $script:TempDir 'ctx-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true `
            -StatusCode 204 -Context '2026-02 PU: Solmyr +3.00'
        $Parsed = Read-JsonStateFile -Path $Path
        $Parsed.entries[0].context | Should -Be '2026-02 PU: Solmyr +3.00'
    }

    It 'appends multiple entries to existing file' {
        $Path = Join-Path $script:TempDir 'multi-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Jan' -Success $true -StatusCode 204
        Add-DiscordDeliveryEntry -Path $Path -Operation 'Announcement' -Recipient 'General' -Success $true -StatusCode 204
        $Parsed = Read-JsonStateFile -Path $Path
        @($Parsed.entries).Count | Should -Be 2
    }

    It 'writes entry without status code' {
        $Path = Join-Path $script:TempDir 'no-code-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU' -Recipient 'Tomek' -Success $false `
            -ErrorMessage 'Connection timeout'
        $Parsed = Read-JsonStateFile -Path $Path
        $Parsed.entries[0].statusCode | Should -BeNullOrEmpty
    }

    It 'writes Announcement operation' {
        $Path = Join-Path $script:TempDir 'announce-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'Announcement' -Recipient 'Announcement' `
            -Success $true -StatusCode 204 -Context 'Ogłoszenie: Sesja w piątek'
        $Parsed = Read-JsonStateFile -Path $Path
        $Entry = $Parsed.entries[0]
        $Entry.operation | Should -Be 'Announcement'
        $Entry.recipient | Should -Be 'Announcement'
        $Entry.context | Should -BeLike '*Ogłoszenie: Sesja*'
    }

    It 'writes PU-Resend operation' {
        $Path = Join-Path $script:TempDir 'resend-entry.json'
        Add-DiscordDeliveryEntry -Path $Path -Operation 'PU-Resend' -Recipient 'Jan' `
            -Success $true -StatusCode 204 -Context '2026-02 PU: Solmyr +3.00'
        $Parsed = Read-JsonStateFile -Path $Path
        $Parsed.entries[0].operation | Should -Be 'PU-Resend'
    }
}

Describe 'Get-DiscordDeliveryEntries' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
        $script:FixturePath = Join-Path $script:TempDir 'delivery-fixture.json'
        $FixtureData = [ordered]@{
            version = 1
            entries = @(
                [ordered]@{
                    timestamp    = '2026-03-01T09:15:22'
                    timezone     = 'UTC+01:00'
                    status       = 'OK'
                    operation    = 'PU'
                    recipient    = 'Jan'
                    statusCode   = 204
                    context      = '2026-02 PU: Solmyr +3.00, Kael +2.00'
                    errorMessage = $null
                }
                [ordered]@{
                    timestamp    = '2026-03-01T09:15:23'
                    timezone     = 'UTC+01:00'
                    status       = 'FAIL'
                    operation    = 'PU'
                    recipient    = 'Tomek'
                    statusCode   = $null
                    context      = '2026-02 PU: Arden +5.00'
                    errorMessage = 'Discord webhook returned HTTP 429: rate limited'
                }
                [ordered]@{
                    timestamp    = '2026-03-12T18:30:05'
                    timezone     = 'UTC+01:00'
                    status       = 'OK'
                    operation    = 'Announcement'
                    recipient    = 'Announcement'
                    statusCode   = 204
                    context      = 'Ogłoszenie: Następna sesja w piątek'
                    errorMessage = $null
                }
                [ordered]@{
                    timestamp    = '2026-03-15T10:00:00'
                    timezone     = 'UTC+01:00'
                    status       = 'OK'
                    operation    = 'PU-Resend'
                    recipient    = 'Tomek'
                    statusCode   = 204
                    context      = '2026-02 PU: Arden +5.00'
                    errorMessage = $null
                }
            )
        }
        Save-JsonStateFile -Path $script:FixturePath -Data $FixtureData
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
        $Result = Get-DiscordDeliveryEntries -Path '/nonexistent/path/delivery.json'
        $Result.Count | Should -Be 0
    }

    It 'returns empty array for file with no entries' {
        $EmptyPath = Join-Path $script:TempDir 'empty-delivery.json'
        Save-JsonStateFile -Path $EmptyPath -Data ([ordered]@{ version = 1; entries = @() })
        $Result = Get-DiscordDeliveryEntries -Path $EmptyPath
        $Result.Count | Should -Be 0
    }

    It 'handles entry with no context or error lines' {
        $BarePath = Join-Path $script:TempDir 'bare-delivery.json'
        $BareData = [ordered]@{
            version = 1
            entries = @(
                [ordered]@{
                    timestamp = '2026-03-01T09:15:22'
                    timezone = 'UTC+01:00'
                    status = 'OK'
                    operation = 'PU'
                    recipient = 'Jan'
                    statusCode = 204
                    context = $null
                    errorMessage = $null
                }
            )
        }
        Save-JsonStateFile -Path $BarePath -Data $BareData
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
        $Path = Join-Path $script:TempDir 'roundtrip.json'
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

Describe 'Convert-DiscordDeliveryToJson' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
        # Create a Markdown fixture for conversion testing
        $script:MdFixturePath = Join-Path $script:TempDir 'discord-delivery-source.md'
        $MdContent = @"
# Discord Delivery Log

- 2026-03-01 09:15:22 (UTC+01:00) [OK] PU -> Jan (HTTP 204)
    - 2026-02 PU: Solmyr +3.00, Kael +2.00
- 2026-03-01 09:15:23 (UTC+01:00) [FAIL] PU -> Tomek
    - 2026-02 PU: Arden +5.00
    - ERROR: Discord webhook returned HTTP 429: rate limited
- 2026-03-12 18:30:05 (UTC+01:00) [OK] Announcement -> Announcement (HTTP 204)
    - Ogłoszenie: Następna sesja w piątek
"@
        Write-TestFile -Path $script:MdFixturePath -Content $MdContent
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'converts Markdown fixture to JSON with correct entry count' {
        $TargetPath = Join-Path $script:TempDir 'converted-discord.json'
        $Result = Convert-DiscordDeliveryToJson -SourcePath $script:MdFixturePath -TargetPath $TargetPath
        $Result | Should -BeTrue
        $Parsed = Read-JsonStateFile -Path $TargetPath
        $Parsed.version | Should -Be 1
        @($Parsed.entries).Count | Should -Be 3
    }

    It 'preserves all fields through conversion' {
        $TargetPath = Join-Path $script:TempDir 'converted-fields.json'
        Convert-DiscordDeliveryToJson -SourcePath $script:MdFixturePath -TargetPath $TargetPath -Force
        $Entries = Get-DiscordDeliveryEntries -Path $TargetPath
        $Entries[0].Status | Should -Be 'OK'
        $Entries[0].Operation | Should -Be 'PU'
        $Entries[0].Recipient | Should -Be 'Jan'
        $Entries[0].StatusCode | Should -Be 204
        $Entries[0].Context | Should -Be '2026-02 PU: Solmyr +3.00, Kael +2.00'
        $Entries[1].Status | Should -Be 'FAIL'
        $Entries[1].ErrorMessage | Should -Be 'Discord webhook returned HTTP 429: rate limited'
    }

    It 'returns false when target exists without -Force' {
        $TargetPath = Join-Path $script:TempDir 'existing-discord.json'
        Save-JsonStateFile -Path $TargetPath -Data ([ordered]@{ version = 1; entries = @() })
        $Result = Convert-DiscordDeliveryToJson -SourcePath $script:MdFixturePath -TargetPath $TargetPath
        $Result | Should -BeFalse
    }

    It 'returns true when source file does not exist' {
        $TargetPath = Join-Path $script:TempDir 'no-source-discord.json'
        $Result = Convert-DiscordDeliveryToJson -SourcePath '/nonexistent/source.md' -TargetPath $TargetPath
        $Result | Should -BeTrue
    }
}

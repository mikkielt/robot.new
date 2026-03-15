BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-narratorsessionprofile.ps1')

    $script:FixtureIndex = @{
        '### 2024-03-15, Oblężenie Steadwick, Solmyr' = @{
            Date = '2024-03-15'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Erathia'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md')
        }
        '### 2024-07-01, Upadek Deyji, Solmyr' = @{
            Date = '2024-07-01'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 1; Source = 'PU'; Weight = 0.8 }
                @{ Name = 'Deyja'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
            )
            FilePaths = @('Świat gry/Deyja/Sesje lokalne.md')
        }
        '### 2026-01-10, Nowy poczatek, MG4' = @{
            Date = '2026-01-10'
            Format = 'Gen4'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 1; Source = 'PU'; Weight = 0.4 }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md')
        }
    }
}

Describe 'Get-NarratorSessionProfile' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
        $GraphDir = Join-Path $script:TempDir 'session-graph'
        [void][System.IO.Directory]::CreateDirectory($GraphDir)
        $IndexPath = Join-Path $GraphDir '_index.json'
        Write-SessionGraphIndex -IndexPath $IndexPath -Index $script:FixtureIndex

        Mock Get-AdminConfig {
            return @{
                RepoRoot = $script:TempDir
                ResDir   = $script:TempDir
            }
        }
    }

    AfterEach {
        Remove-TestTempDir
    }

    It 'returns profile for narrator with matching sessions' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.NarratorName | Should -Be 'Solmyr'
        $Result.SessionCount | Should -Be 2
    }

    It 'calculates date range' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.DateFirst | Should -Be '2024-03-15'
        $Result.DateLast | Should -Be '2024-07-01'
    }

    It 'counts unique participants' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.UniqueParticipants | Should -BeGreaterOrEqual 3
    }

    It 'breaks down participants by type' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.ParticipantsByType.Keys | Should -Contain 'Postać'
        $Result.ParticipantsByType.Keys | Should -Contain 'Lokacja'
    }

    It 'calculates average party size' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.AveragePartySize | Should -BeGreaterThan 0
    }

    It 'returns sessions sorted by date' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.Sessions | Should -HaveCount 2
        $Result.Sessions[0].Date | Should -Be '2024-03-15'
        $Result.Sessions[1].Date | Should -Be '2024-07-01'
    }

    It 'returns empty profile for unknown narrator' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Nieznany' -Quiet
        $Result.SessionCount | Should -Be 0
        $Result.Sessions | Should -HaveCount 0
    }

    It 'respects date filters' {
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -MinDate ([datetime]'2024-06-01') -Quiet
        $Result.SessionCount | Should -Be 1
    }

    It 'returns profile for narrator with one session' {
        $Result = Get-NarratorSessionProfile -NarratorName 'MG4' -Quiet
        $Result.SessionCount | Should -Be 1
        $Result.UniqueParticipants | Should -Be 1
    }

    It 'returns empty for missing index' {
        Mock Get-AdminConfig {
            return @{
                RepoRoot = $script:TempDir
                ResDir   = (Join-Path $script:TempDir 'nonexistent')
            }
        }
        $Result = Get-NarratorSessionProfile -NarratorName 'Solmyr' -Quiet
        $Result.SessionCount | Should -Be 0
    }
}

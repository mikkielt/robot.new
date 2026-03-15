BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-sessiongraphleaderboard.ps1')

    $script:FixtureIndex = @{
        '### 2024-03-15, Oblężenie Steadwick, Solmyr' = @{
            Date = '2024-03-15'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Erathia'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 1; Source = 'PU'; Weight = 0.5 }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md')
        }
        '### 2024-07-01, Upadek Deyji, MG3' = @{
            Date = '2024-07-01'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 1; Source = 'PU'; Weight = 0.8 }
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 1; Source = 'PU'; Weight = 0.5 }
                @{ Name = 'Deyja'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md')
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

Describe 'Get-SessionGraphLeaderboard' {
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

    It 'returns entities ranked by session count' {
        $Result = Get-SessionGraphLeaderboard -Quiet
        $Result.Count | Should -BeGreaterThan 0
        # Xeron appears in all 3 sessions
        $Result[0].Name | Should -Be 'Xeron'
        $Result[0].SessionCount | Should -Be 3
        $Result[0].Rank | Should -Be 1
    }

    It 'includes tier breakdown' {
        $Result = Get-SessionGraphLeaderboard -Quiet
        $Xeron = $Result | Where-Object { $_.Name -eq 'Xeron' }
        $Xeron.Tier0 | Should -Be 1
        $Xeron.Tier1 | Should -Be 2
    }

    It 'respects Top parameter' {
        $Result = Get-SessionGraphLeaderboard -Top 2 -Quiet
        $Result.Count | Should -BeLessOrEqual 2
    }

    It 'filters by entity type' {
        $Result = Get-SessionGraphLeaderboard -EntityType 'Lokacja' -Quiet
        foreach ($R in $Result) {
            $R.Type | Should -Be 'Lokacja'
        }
    }

    It 'respects MinTier filter' {
        $Result = Get-SessionGraphLeaderboard -MinTier 0 -Quiet
        # Only Tier 0 participants
        foreach ($R in $Result) {
            $R.Tier1 | Should -Be 0
            $R.Tier2 | Should -Be 0
        }
    }

    It 'respects date filter' {
        $Result = Get-SessionGraphLeaderboard -MinDate ([datetime]'2026-01-01') -Quiet
        # Only Nowy poczatek session (Xeron only)
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron'
    }

    It 'returns empty for missing index' {
        Mock Get-AdminConfig {
            return @{
                RepoRoot = $script:TempDir
                ResDir   = (Join-Path $script:TempDir 'nonexistent')
            }
        }
        $Result = Get-SessionGraphLeaderboard -Quiet
        $Result | Should -HaveCount 0
    }
}

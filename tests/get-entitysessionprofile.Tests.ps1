BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-sessiongraph.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-entitysessionprofile.ps1')

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

Describe 'Get-EntitySessionProfile' {
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

    It 'returns profile with correct session count' {
        $Result = Get-EntitySessionProfile -EntityName 'Xeron' -Quiet
        $Result.EntityName | Should -Be 'Xeron'
        $Result.TotalSessions | Should -Be 3
    }

    It 'calculates date range' {
        $Result = Get-EntitySessionProfile -EntityName 'Xeron' -Quiet
        $Result.DateFirst | Should -Be '2024-03-15'
        $Result.DateLast | Should -Be '2026-01-10'
    }

    It 'sums PU weight correctly' {
        $Result = Get-EntitySessionProfile -EntityName 'Xeron' -Quiet
        $Result.TotalPUWeight | Should -Be 1.2
    }

    It 'breaks down by tier' {
        $Result = Get-EntitySessionProfile -EntityName 'Xeron' -Quiet
        $Result.TierBreakdown.Tier0 | Should -Be 1
        $Result.TierBreakdown.Tier1 | Should -Be 2
    }

    It 'returns top co-participants' {
        $Result = Get-EntitySessionProfile -EntityName 'Xeron' -Quiet
        $Result.TopCoParticipants.Count | Should -BeGreaterThan 0
        $Sandro = $Result.TopCoParticipants | Where-Object { $_.Name -eq 'Sandro' }
        $Sandro | Should -Not -BeNullOrEmpty
    }

    It 'returns activity by month' {
        $Result = Get-EntitySessionProfile -EntityName 'Xeron' -Quiet
        $Result.ActivityByMonth.Keys | Should -HaveCount 3
        $Result.ActivityByMonth['2024-03'] | Should -Be 1
    }

    It 'returns empty profile for unknown entity' {
        $Result = Get-EntitySessionProfile -EntityName 'Nieznany' -Quiet
        $Result.TotalSessions | Should -Be 0
        $Result.TopCoParticipants | Should -HaveCount 0
    }

    It 'respects MinTier filter' {
        $Result = Get-EntitySessionProfile -EntityName 'Sandro' -MinTier 0 -Quiet
        # Sandro has no Tier 0 participation
        $Result.TotalSessions | Should -Be 0
    }
}

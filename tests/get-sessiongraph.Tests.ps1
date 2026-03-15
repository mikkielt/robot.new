BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-sessiongraph.ps1')

    # Build a fixture index with a mix of Gen1/Gen2/Gen3 sessions
    $script:FixtureIndex = @{
        '### 2021-05-10, Pradawne czasy, MG1' = @{
            Date = '2021-05-10'
            Format = 'Gen1'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Erathia'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 2; Source = 'BodyText'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md', 'Świat gry/Erathia/Sesje lokalne.md')
        }
        '### 2022-08-20, Podróż przez Ithan, MG2' = @{
            Date = '2022-08-20'
            Format = 'Gen2'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Gelu'; Type = 'NPC'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Ithan'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md', 'Postaci/NPC/Gelu.md', 'Świat gry/Ithan/Sesje lokalne.md')
        }
        '### 2024-03-15, Oblężenie Steadwick, Solmyr' = @{
            Date = '2024-03-15'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 1; Source = 'PU'; Weight = 0.5 }
                @{ Name = 'Erathia'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Gelu'; Type = 'NPC'; Tier = 2; Source = 'BodyText'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md', 'Świat gry/Erathia/Sesje lokalne.md')
        }
        '### 2024-07-01, Upadek Deyji, MG3' = @{
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
                @{ Name = 'Erathia'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Rycerze Gryfów'; Type = 'Grupa'; Tier = 1; Source = 'Changes'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md', 'Świat gry/Erathia/Sesje lokalne.md')
        }
    }
}

Describe 'Get-SessionGraph' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
        $GraphDir = Join-Path $script:TempDir 'session-graph'
        [void][System.IO.Directory]::CreateDirectory($GraphDir)
        $IndexPath = Join-Path $GraphDir '_index.json'
        Write-SessionGraphIndex -IndexPath $IndexPath -Index $script:FixtureIndex

        # Mock Get-AdminConfig to point ResDir to temp
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

    Context 'Missing index' {
        It 'returns empty array with warning when index does not exist' {
            Mock Get-AdminConfig {
                return @{
                    RepoRoot = $script:TempDir
                    ResDir   = (Join-Path $script:TempDir 'nonexistent')
                }
            }
            $Result = Get-SessionGraph -EntityName 'Xeron' -Quiet
            $Result | Should -HaveCount 0
        }
    }

    Context 'Sessions mode' {
        It 'finds all sessions for an entity' {
            $Result = Get-SessionGraph -EntityName 'Xeron' -Mode Sessions -Quiet
            $Result.Count | Should -Be 4
        }

        It 'respects MinDate filter' {
            $Result = Get-SessionGraph -EntityName 'Xeron' -MinDate ([datetime]'2024-01-01') -Mode Sessions -Quiet
            $Result.Count | Should -Be 2
        }

        It 'respects MaxDate filter' {
            $Result = Get-SessionGraph -EntityName 'Xeron' -MaxDate ([datetime]'2023-01-01') -Mode Sessions -Quiet
            $Result.Count | Should -Be 2
        }

        It 'respects MinTier filter (Tier 0 only)' {
            # Sandro appears as Tier 2 in session 1, Tier 1 in sessions 3 and 4
            $Result = Get-SessionGraph -EntityName 'Sandro' -MinTier 0 -Mode Sessions -Quiet
            # Sandro has no Tier 0 participation
            $Result.Count | Should -Be 0
        }

        It 'includes Tier 1 when MinTier >= 1' {
            $Result = Get-SessionGraph -EntityName 'Sandro' -MinTier 1 -Mode Sessions -Quiet
            $Result.Count | Should -Be 2
        }

        It 'includes all tiers by default (MinTier=2)' {
            $Result = Get-SessionGraph -EntityName 'Sandro' -Mode Sessions -Quiet
            $Result.Count | Should -Be 3
        }

        It 'returns session details with entity participation info' {
            $Result = Get-SessionGraph -EntityName 'Xeron' -MinDate ([datetime]'2026-01-01') -Mode Sessions -Quiet
            $Result.Count | Should -Be 1
            $Result[0].Header | Should -BeLike '*Nowy poczatek*'
            $Result[0].Format | Should -Be 'Gen4'
            $Result[0].EntityTier | Should -Be 1
            $Result[0].EntityWeight | Should -Be 0.4
        }
    }

    Context 'CoParticipants mode' {
        It 'returns co-participants sorted by shared session count' {
            $Result = Get-SessionGraph -EntityName 'Xeron' -Mode CoParticipants -Quiet
            $Result.Count | Should -BeGreaterThan 0

            # Erathia co-appears with Xeron in 3 sessions (2021, 2024, 2026)
            $Erathia = $Result | Where-Object { $_.Name -eq 'Erathia' }
            $Erathia.SharedSessions | Should -Be 3
        }

        It 'excludes the queried entity itself' {
            $Result = Get-SessionGraph -EntityName 'Xeron' -Mode CoParticipants -Quiet
            $Self = $Result | Where-Object { $_.Name -eq 'Xeron' }
            $Self | Should -BeNullOrEmpty
        }

        It 'respects MinTier filter for co-participants' {
            # With MinTier 0, only filesystem-placed entities qualify
            $Result = Get-SessionGraph -EntityName 'Xeron' -MinTier 0 -Mode CoParticipants -Quiet
            # Sandro is Tier 2 in session 1 and Tier 1 in session 3 → excluded at MinTier 0
            $Sandro = $Result | Where-Object { $_.Name -eq 'Sandro' }
            $Sandro | Should -BeNullOrEmpty
        }
    }

    Context 'EntityTimeline mode' {
        It 'returns participants for a specific session' {
            $Result = Get-SessionGraph -SessionHeader '### 2024-03-15, Oblężenie Steadwick, Solmyr' -Mode EntityTimeline -Quiet
            $Result.Count | Should -Be 4
        }

        It 'returns empty when session not found' {
            $Result = Get-SessionGraph -SessionHeader '### 9999-01-01, Nonexistent, Nobody' -Mode EntityTimeline -Quiet
            $Result | Should -HaveCount 0
        }

        It 'respects MinTier filter' {
            $Result = Get-SessionGraph -SessionHeader '### 2024-03-15, Oblężenie Steadwick, Solmyr' -MinTier 1 -Mode EntityTimeline -Quiet
            # 4 participants total, Gelu is Tier 2 → excluded
            $Result.Count | Should -Be 3
            $Gelu = $Result | Where-Object { $_.Name -eq 'Gelu' }
            $Gelu | Should -BeNullOrEmpty
        }

        It 'requires -SessionHeader parameter' {
            $Result = Get-SessionGraph -Mode EntityTimeline -Quiet
            $Result | Should -HaveCount 0
        }
    }

    Context 'Summary mode' {
        It 'returns global statistics' {
            $Result = Get-SessionGraph -Mode Summary -Quiet
            $Result.TotalSessions | Should -Be 5
            $Result.TotalParticipants | Should -BeGreaterThan 0
        }

        It 'breaks down by format generation' {
            $Result = Get-SessionGraph -Mode Summary -Quiet
            $Result.FormatBreakdown.Gen1 | Should -Be 1
            $Result.FormatBreakdown.Gen2 | Should -Be 1
            $Result.FormatBreakdown.Gen3 | Should -Be 2
            $Result.FormatBreakdown.Gen4 | Should -Be 1
        }

        It 'respects date range in summary' {
            $Result = Get-SessionGraph -MinDate ([datetime]'2024-01-01') -Mode Summary -Quiet
            $Result.TotalSessions | Should -Be 3
        }
    }

    Context 'Tier coverage by format generation' {
        It 'Gen1 session has only Tier 0 and Tier 2 participants' {
            $Result = Get-SessionGraph -SessionHeader '### 2021-05-10, Pradawne czasy, MG1' -Mode EntityTimeline -Quiet
            $Tiers = $Result | ForEach-Object { $_.Tier } | Sort-Object -Unique
            $Tiers | Should -Contain 0
            $Tiers | Should -Contain 2
            $Tiers | Should -Not -Contain 1
        }

        It 'Gen3 session has Tier 0, Tier 1, and Tier 2 participants' {
            $Result = Get-SessionGraph -SessionHeader '### 2024-03-15, Oblężenie Steadwick, Solmyr' -Mode EntityTimeline -Quiet
            $Tiers = $Result | ForEach-Object { $_.Tier } | Sort-Object -Unique
            $Tiers | Should -Contain 0
            $Tiers | Should -Contain 1
            $Tiers | Should -Contain 2
        }
    }
}

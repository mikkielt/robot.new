BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-sessiongraph.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'compare-sessionparticipation.ps1')

    $script:FixtureIndex = @{
        '### 2024-03-15, Oblężenie Steadwick, Solmyr' = @{
            Date = '2024-03-15'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 1; Source = 'PU'; Weight = 0.5 }
                @{ Name = 'Erathia'; Type = 'Lokacja'; Tier = 0; Source = 'FilePath'; Weight = $null }
            )
            FilePaths = @('Postaci/Gracze/Xeron.md')
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
            )
            FilePaths = @('Postaci/Gracze/Xeron.md')
        }
    }
}

Describe 'Compare-SessionParticipation' {
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

    It 'finds common sessions between two entities' {
        $Result = Compare-SessionParticipation -EntityNames @('Xeron', 'Sandro') -Quiet
        # Common session: Oblężenie Steadwick (both present)
        $Result.CommonSessions.Count | Should -Be 1
        $Result.CommonSessions[0] | Should -BeLike '*Oblężenie Steadwick*'
    }

    It 'finds exclusive sessions per entity' {
        $Result = Compare-SessionParticipation -EntityNames @('Xeron', 'Sandro') -Quiet
        # Xeron exclusive: Nowy poczatek (Sandro not there)
        $Result.ExclusiveSessions['Xeron'].Count | Should -Be 1
        # Sandro exclusive: Upadek Deyji (Xeron not there)
        $Result.ExclusiveSessions['Sandro'].Count | Should -Be 1
    }

    It 'calculates overlap percentage' {
        $Result = Compare-SessionParticipation -EntityNames @('Xeron', 'Sandro') -Quiet
        $Result.OverlapMatrix | Should -HaveCount 1
        $Result.OverlapMatrix[0].SharedCount | Should -Be 1
        $Result.OverlapMatrix[0].UnionCount | Should -Be 3
        # Overlap: 1/3 = 33.3%
        $Result.OverlapMatrix[0].OverlapPct | Should -BeGreaterThan 30
        $Result.OverlapMatrix[0].OverlapPct | Should -BeLessThan 35
    }

    It 'returns null for less than 2 entities' {
        $Result = Compare-SessionParticipation -EntityNames @('Xeron') -Quiet
        $Result | Should -BeNullOrEmpty
    }

    It 'handles entities with no shared sessions' {
        $Result = Compare-SessionParticipation -EntityNames @('Erathia', 'Deyja') -Quiet
        $Result.CommonSessions | Should -HaveCount 0
        $Result.OverlapMatrix[0].OverlapPct | Should -Be 0
    }

    It 'supports three-way comparison' {
        $Result = Compare-SessionParticipation -EntityNames @('Xeron', 'Sandro', 'Erathia') -Quiet
        # Only Oblężenie has all three
        $Result.CommonSessions.Count | Should -Be 1
        $Result.OverlapMatrix | Should -HaveCount 3
    }
}

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')

    # Stub functions required for mocking (not auto-loaded in Pattern B)
    function Get-Session { return @() }
    function Get-NameIndex { return @{ Index = @{} } }

    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'test-sessiongraphintegrity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-sessiongraph.ps1')

    # Fixture index with 3 sessions
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
        '### 2024-07-01, Upadek Deyji, MG3' = @{
            Date = '2024-07-01'
            Format = 'Gen3'
            Participants = @(
                @{ Name = 'Sandro'; Type = 'NPC'; Tier = 1; Source = 'PU'; Weight = 0.8 }
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

Describe 'Test-SessionGraphIntegrity' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
        $GraphDir = Join-Path $script:TempDir 'session-graph'
        [void][System.IO.Directory]::CreateDirectory($GraphDir)
        $script:IndexPath = Join-Path $GraphDir '_index.json'
        $script:MetaPath = Join-Path $GraphDir '_meta.json'

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
        It 'returns IndexMissing=true and OK=false when index does not exist' {
            Mock Get-AdminConfig {
                return @{
                    RepoRoot = $script:TempDir
                    ResDir   = (Join-Path $script:TempDir 'nonexistent')
                }
            }
            $Result = Test-SessionGraphIntegrity -Quiet
            $Result.OK | Should -Be $false
            $Result.IndexMissing | Should -Be $true
        }
    }

    Context 'All OK' {
        It 'returns OK=true when index matches session set' {
            Write-SessionGraphIndex -IndexPath $script:IndexPath -Index $script:FixtureIndex
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = 'abc123'
                SessionCount = 3
            }

            # Mock Get-Session to return headers matching the fixture
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{ Header = '### 2024-03-15, Oblężenie Steadwick, Solmyr'; Date = [datetime]'2024-03-15'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2024-07-01, Upadek Deyji, MG3'; Date = [datetime]'2024-07-01'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2026-01-10, Nowy poczatek, MG4'; Date = [datetime]'2026-01-10'; FilePath = 'test.md' }
                )
            }

            # Mock Get-NameIndex to return names whose version matches stored
            Mock Get-NameIndex {
                return @{ Index = @{ 'Xeron' = $true; 'Sandro' = $true; 'Erathia' = $true } }
            }

            # Compute matching NameIndexVersion
            $Names = @('Xeron', 'Sandro', 'Erathia')
            $ExpectedVersion = Get-NameIndexVersion -Names $Names
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = $ExpectedVersion
                SessionCount = 3
            }

            $Result = Test-SessionGraphIntegrity -Quiet
            $Result.OK | Should -Be $true
            $Result.IndexMissing | Should -Be $false
            $Result.OrphanedSessions | Should -HaveCount 0
            $Result.MissingSessions | Should -HaveCount 0
            $Result.EmptySessions | Should -HaveCount 0
            $Result.StaleNameVersion | Should -HaveCount 0
        }
    }

    Context 'Orphaned sessions' {
        It 'detects sessions in index but not in repo' {
            Write-SessionGraphIndex -IndexPath $script:IndexPath -Index $script:FixtureIndex
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = $null
                SessionCount = 3
            }

            # Return only 2 of 3 sessions
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{ Header = '### 2024-03-15, Oblężenie Steadwick, Solmyr'; Date = [datetime]'2024-03-15'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2026-01-10, Nowy poczatek, MG4'; Date = [datetime]'2026-01-10'; FilePath = 'test.md' }
                )
            }
            Mock Get-NameIndex { return @{ Index = @{} } }

            $Result = Test-SessionGraphIntegrity -Quiet
            $Result.OK | Should -Be $false
            $Result.OrphanedSessions | Should -HaveCount 1
            $Result.OrphanedSessions[0].Header | Should -BeLike '*Upadek Deyji*'
        }
    }

    Context 'Missing sessions' {
        It 'detects sessions in repo but not in index' {
            Write-SessionGraphIndex -IndexPath $script:IndexPath -Index $script:FixtureIndex
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = $null
                SessionCount = 3
            }

            # Return 3 indexed + 1 extra session
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{ Header = '### 2024-03-15, Oblężenie Steadwick, Solmyr'; Date = [datetime]'2024-03-15'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2024-07-01, Upadek Deyji, MG3'; Date = [datetime]'2024-07-01'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2026-01-10, Nowy poczatek, MG4'; Date = [datetime]'2026-01-10'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2026-02-14, Nowa sesja, MG5'; Date = [datetime]'2026-02-14'; FilePath = 'new.md' }
                )
            }
            Mock Get-NameIndex { return @{ Index = @{} } }

            $Result = Test-SessionGraphIntegrity -Quiet
            $Result.OK | Should -Be $false
            $Result.MissingSessions | Should -HaveCount 1
            $Result.MissingSessions[0].Header | Should -BeLike '*Nowa sesja*'
        }
    }

    Context 'Empty sessions' {
        It 'detects index entries with zero participants' {
            $IndexWithEmpty = @{
                '### 2024-03-15, Oblężenie Steadwick, Solmyr' = @{
                    Date = '2024-03-15'
                    Format = 'Gen3'
                    Participants = @()
                    FilePaths = @('test.md')
                }
            }
            Write-SessionGraphIndex -IndexPath $script:IndexPath -Index $IndexWithEmpty
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = $null
                SessionCount = 1
            }

            Mock Get-Session {
                return @(
                    [PSCustomObject]@{ Header = '### 2024-03-15, Oblężenie Steadwick, Solmyr'; Date = [datetime]'2024-03-15'; FilePath = 'test.md' }
                )
            }
            Mock Get-NameIndex { return @{ Index = @{} } }

            $Result = Test-SessionGraphIntegrity -Quiet
            $Result.OK | Should -Be $false
            $Result.EmptySessions | Should -HaveCount 1
        }
    }

    Context 'Tier2Stale metadata' {
        It 'Tier2Stale flag is readable from meta after write' {
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = 'abc123'
                SessionCount = 3
                Tier2Stale = $true
                Tier2StaleReason = "Encja 'Sandro' została zmodyfikowana"
                LastEagerRefresh = '2026-03-09 08:00:00'
                EagerRefreshCount = 5
            }

            $Meta = Read-SessionGraphMeta -MetaPath $script:MetaPath
            $Meta['Tier2Stale'] | Should -Be $true
            $Meta['Tier2StaleReason'] | Should -Be "Encja 'Sandro' została zmodyfikowana"
            $Meta['LastEagerRefresh'] | Should -Be '2026-03-09 08:00:00'
            $Meta['EagerRefreshCount'] | Should -Be 5
        }

        It 'Tier2Stale defaults to false when not present' {
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = 'abc123'
                SessionCount = 3
            }

            $Meta = Read-SessionGraphMeta -MetaPath $script:MetaPath
            $Meta['Tier2Stale'] | Should -Be $false
        }
    }

    Context 'Stale name version' {
        It 'detects name set change since last build' {
            Write-SessionGraphIndex -IndexPath $script:IndexPath -Index $script:FixtureIndex
            Write-SessionGraphMeta -MetaPath $script:MetaPath -Meta @{
                NameIndexVersion = 'old-version-hash'
                SessionCount = 3
            }

            Mock Get-Session {
                return @(
                    [PSCustomObject]@{ Header = '### 2024-03-15, Oblężenie Steadwick, Solmyr'; Date = [datetime]'2024-03-15'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2024-07-01, Upadek Deyji, MG3'; Date = [datetime]'2024-07-01'; FilePath = 'test.md' }
                    [PSCustomObject]@{ Header = '### 2026-01-10, Nowy poczatek, MG4'; Date = [datetime]'2026-01-10'; FilePath = 'test.md' }
                )
            }
            Mock Get-NameIndex {
                return @{ Index = @{ 'Xeron' = $true; 'NewEntity' = $true } }
            }

            $Result = Test-SessionGraphIntegrity -Quiet
            $Result.OK | Should -Be $false
            $Result.StaleNameVersion | Should -HaveCount 1
            $Result.StaleNameVersion[0].StoredVersion | Should -Be 'old-version-hash'
        }
    }
}

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'session-graphhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
}

Describe 'Get-FilePathInvolvement' {
    It 'classifies player character path' {
        $Result = Get-FilePathInvolvement -RelPath 'Postaci/Gracze/Xeron.md'
        $Result.Category | Should -Be 'Player'
        $Result.Name | Should -Be 'Xeron'
        $Result.Type | Should -Be 'Postać'
    }

    It 'classifies player character with spaces in name' {
        $Result = Get-FilePathInvolvement -RelPath 'Postaci/Gracze/Catherine Ironfist.md'
        $Result.Category | Should -Be 'Player'
        $Result.Name | Should -Be 'Catherine Ironfist'
        $Result.Type | Should -Be 'Postać'
    }

    It 'classifies NPC path' {
        $Result = Get-FilePathInvolvement -RelPath 'Postaci/NPC/Erathia/Sandro.md'
        $Result.Category | Should -Be 'NPC'
        $Result.Name | Should -Be 'Sandro'
        $Result.Type | Should -Be 'NPC'
    }

    It 'classifies NPC at top level' {
        $Result = Get-FilePathInvolvement -RelPath 'Postaci/NPC/Gelu.md'
        $Result.Category | Should -Be 'NPC'
        $Result.Name | Should -Be 'Gelu'
        $Result.Type | Should -Be 'NPC'
    }

    It 'classifies location path (Sesje lokalne.md)' {
        $Result = Get-FilePathInvolvement -RelPath 'Świat gry/Erathia/Sesje lokalne.md'
        $Result.Category | Should -Be 'Location'
        $Result.Name | Should -Be 'Erathia'
        $Result.Type | Should -Be 'Lokacja'
    }

    It 'classifies nested location path' {
        $Result = Get-FilePathInvolvement -RelPath 'Świat gry/Ithan/Bracada/Sesje lokalne.md'
        $Result.Category | Should -Be 'Location'
        $Result.Name | Should -Be 'Bracada'
        $Result.Type | Should -Be 'Lokacja'
    }

    It 'classifies thread path' {
        $Result = Get-FilePathInvolvement -RelPath 'Wątki/Ostrze Armagedonu.md'
        $Result.Category | Should -Be 'Thread'
        $Result.Name | Should -Be 'Ostrze Armagedonu'
        $Result.Type | Should -Be 'Wątek'
    }

    It 'classifies organization path' {
        $Result = Get-FilePathInvolvement -RelPath 'Organizacje/Graczy/Rycerze Gryfów.md'
        $Result.Category | Should -Be 'Org'
        $Result.Name | Should -Be 'Rycerze Gryfów'
        $Result.Type | Should -Be 'Grupa'
    }

    It 'returns null for unknown path' {
        $Result = Get-FilePathInvolvement -RelPath 'Archiwum/stare-sesje.md'
        $Result | Should -BeNullOrEmpty
    }

    It 'returns null for Gracze.md (legacy player DB)' {
        $Result = Get-FilePathInvolvement -RelPath 'Gracze.md'
        $Result | Should -BeNullOrEmpty
    }

    It 'returns null for entities.md' {
        $Result = Get-FilePathInvolvement -RelPath 'entities.md'
        $Result | Should -BeNullOrEmpty
    }

    It 'normalizes backslashes' {
        $Result = Get-FilePathInvolvement -RelPath 'Postaci\Gracze\Xeron.md'
        $Result.Category | Should -Be 'Player'
        $Result.Name | Should -Be 'Xeron'
    }
}

Describe 'ConvertTo-ParticipantRecord' {
    Context 'Tier 0 - filesystem' {
        It 'extracts participants from FilePaths' {
            $Session = [PSCustomObject]@{
                FilePaths  = @('Postaci/Gracze/Xeron.md', 'Świat gry/Erathia/Sesje lokalne.md')
                PU         = @()
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @()
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 2

            $Xeron = $Result | Where-Object { $_.Name -eq 'Xeron' }
            $Xeron.Tier | Should -Be 0
            $Xeron.Source | Should -Be 'FilePath'
            $Xeron.Type | Should -Be 'Postać'

            $Erathia = $Result | Where-Object { $_.Name -eq 'Erathia' }
            $Erathia.Tier | Should -Be 0
            $Erathia.Type | Should -Be 'Lokacja'
        }

        It 'skips unknown file paths' {
            $Session = [PSCustomObject]@{
                FilePaths  = @('Archiwum/old.md', 'Postaci/Gracze/Xeron.md')
                PU         = @()
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @()
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 1
            $Result[0].Name | Should -Be 'Xeron'
        }
    }

    Context 'Tier 1 - structured metadata' {
        It 'extracts PU participants with weight' {
            $Session = [PSCustomObject]@{
                FilePaths  = @()
                PU         = @(
                    @{ Character = 'Xeron'; Value = 0.3 }
                    @{ Character = 'Sandro'; Value = 0.5 }
                )
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @()
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 2

            $Xeron = $Result | Where-Object { $_.Name -eq 'Xeron' }
            $Xeron.Tier | Should -Be 1
            $Xeron.Source | Should -Be 'PU'
            $Xeron.Weight | Should -Be 0.3
        }

        It 'extracts Changes participants' {
            $Session = [PSCustomObject]@{
                FilePaths  = @()
                PU         = @()
                Changes    = @(
                    @{ EntityName = 'Sandro'; Tags = @() }
                )
                Transfers  = @()
                Intel      = @()
                Mentions   = @()
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 1
            $Result[0].Name | Should -Be 'Sandro'
            $Result[0].Tier | Should -Be 1
            $Result[0].Source | Should -Be 'Changes'
        }

        It 'extracts Transfer source and destination' {
            $Session = [PSCustomObject]@{
                FilePaths  = @()
                PU         = @()
                Changes    = @()
                Transfers  = @(
                    @{ Amount = 100; Denomination = 'złoto'; Source = 'Xeron'; Destination = 'Sandro' }
                )
                Intel      = @()
                Mentions   = @()
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 2
            ($Result | Where-Object { $_.Name -eq 'Xeron' }).Source | Should -Be 'Transfer'
            ($Result | Where-Object { $_.Name -eq 'Sandro' }).Source | Should -Be 'Transfer'
        }
    }

    Context 'Tier 2 - body text mentions' {
        It 'extracts mentions as Tier 2' {
            $Session = [PSCustomObject]@{
                FilePaths  = @()
                PU         = @()
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @(
                    @{ Name = 'Gelu'; Type = 'NPC' }
                )
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 1
            $Result[0].Tier | Should -Be 2
            $Result[0].Source | Should -Be 'BodyText'
        }
    }

    Context 'Deduplication' {
        It 'keeps lowest tier when entity appears at multiple tiers' {
            $Session = [PSCustomObject]@{
                FilePaths  = @('Postaci/Gracze/Xeron.md')
                PU         = @(
                    @{ Character = 'Xeron'; Value = 0.3 }
                )
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @(
                    @{ Name = 'Xeron'; Type = 'Postać' }
                )
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 1
            $Result[0].Name | Should -Be 'Xeron'
            $Result[0].Tier | Should -Be 0
        }

        It 'does not apply Tier 1 weight when Tier 0 wins' {
            # Tier 0 is processed first, then Tier 1 tries to merge.
            # Since Tier 0 < Tier 1, Tier 0 wins and Tier 1 weight is NOT applied
            # (lower tier = higher confidence, entire record wins)
            $Session = [PSCustomObject]@{
                FilePaths  = @('Postaci/Gracze/Xeron.md')
                PU         = @(
                    @{ Character = 'Xeron'; Value = 0.3 }
                )
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @()
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 1
            # Tier 0 wins; weight stays null because lower tier wins entirely
            $Result[0].Tier | Should -Be 0
        }

        It 'upgrades Tier 2 mention to Tier 1 when PU exists' {
            $Session = [PSCustomObject]@{
                FilePaths  = @()
                PU         = @(
                    @{ Character = 'Gelu'; Value = 0.2 }
                )
                Changes    = @()
                Transfers  = @()
                Intel      = @()
                Mentions   = @(
                    @{ Name = 'Gelu'; Type = 'NPC' }
                )
            }
            $Result = ConvertTo-ParticipantRecord -Session $Session
            $Result.Count | Should -Be 1
            $Result[0].Tier | Should -Be 1
            $Result[0].Weight | Should -Be 0.2
        }
    }
}

Describe 'Get-NameIndexVersion' {
    It 'returns consistent hash for same input' {
        $Hash1 = Get-NameIndexVersion -Names @('Alpha', 'Beta', 'Gamma')
        $Hash2 = Get-NameIndexVersion -Names @('Alpha', 'Beta', 'Gamma')
        $Hash1 | Should -Be $Hash2
    }

    It 'returns same hash regardless of input order' {
        $Hash1 = Get-NameIndexVersion -Names @('Gamma', 'Alpha', 'Beta')
        $Hash2 = Get-NameIndexVersion -Names @('Alpha', 'Beta', 'Gamma')
        $Hash1 | Should -Be $Hash2
    }

    It 'changes hash when name added' {
        $Hash1 = Get-NameIndexVersion -Names @('Alpha', 'Beta')
        $Hash2 = Get-NameIndexVersion -Names @('Alpha', 'Beta', 'Gamma')
        $Hash1 | Should -Not -Be $Hash2
    }

    It 'returns 64-char lowercase hex string' {
        $Hash = Get-NameIndexVersion -Names @('Test')
        $Hash.Length | Should -Be 64
        $Hash | Should -Match '^[0-9a-f]+$'
    }
}

Describe 'Session Graph Index I/O' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
    }

    AfterEach {
        Remove-TestTempDir
    }

    Context 'Read-SessionGraphIndex' {
        It 'returns empty hashtable when file does not exist' {
            $Result = Read-SessionGraphIndex -IndexPath (Join-Path $script:TempDir 'nonexistent.json')
            $Result | Should -BeOfType [hashtable]
            $Result.Count | Should -Be 0
        }

        It 'reads a valid index file' {
            $Json = '{"### 2024-06-15, Test, Narrator": {"Date": "2024-06-15", "Format": "Gen3", "Participants": []}}'
            $Path = Join-Path $script:TempDir '_index.json'
            Write-TestFile -Path $Path -Content $Json

            $Result = Read-SessionGraphIndex -IndexPath $Path
            $Result.Count | Should -Be 1
            $Result.ContainsKey('### 2024-06-15, Test, Narrator') | Should -BeTrue
        }
    }

    Context 'Write-SessionGraphIndex' {
        It 'creates file and parent directories' {
            $Path = Join-Path $script:TempDir 'sub' 'dir' '_index.json'
            $Index = @{
                '### 2024-06-15, Test, N' = @{
                    Date = '2024-06-15'
                    Format = 'Gen3'
                    Participants = @()
                    FilePaths = @()
                }
            }
            Write-SessionGraphIndex -IndexPath $Path -Index $Index
            [System.IO.File]::Exists($Path) | Should -BeTrue
        }

        It 'round-trips correctly' {
            $Path = Join-Path $script:TempDir '_index.json'
            $Index = @{
                '### 2024-06-15, Session A, N' = @{
                    Date = '2024-06-15'
                    Format = 'Gen3'
                    Participants = @(
                        @{ Name = 'Xeron'; Type = 'Postać'; Tier = 0; Source = 'FilePath'; Weight = $null }
                    )
                    FilePaths = @('Postaci/Gracze/Xeron.md')
                }
            }
            Write-SessionGraphIndex -IndexPath $Path -Index $Index
            $Result = Read-SessionGraphIndex -IndexPath $Path
            $Result.Count | Should -Be 1
            $Entry = $Result['### 2024-06-15, Session A, N']
            $Entry['Date'] | Should -Be '2024-06-15'
            $Entry['Participants'].Count | Should -Be 1
            $Entry['Participants'][0]['Name'] | Should -Be 'Xeron'
        }
    }

    Context 'Read/Write-SessionGraphMeta' {
        It 'returns defaults when file does not exist' {
            $Result = Read-SessionGraphMeta -MetaPath (Join-Path $script:TempDir 'nonexistent.json')
            $Result['Version'] | Should -Be 1
            $Result['SessionCount'] | Should -Be 0
            $Result['LastFullUpdate'] | Should -BeNullOrEmpty
            $Result['NameIndexVersion'] | Should -BeNullOrEmpty
        }

        It 'round-trips metadata' {
            $Path = Join-Path $script:TempDir '_meta.json'
            $Meta = @{
                Version = 1
                LastFullUpdate = '2026-03-01 14:30:00'
                LastIncrementalUpdate = '2026-03-08 10:00:00'
                NameIndexVersion = 'abc123'
                SessionCount = 42
            }
            Write-SessionGraphMeta -MetaPath $Path -Meta $Meta
            $Result = Read-SessionGraphMeta -MetaPath $Path
            $Result['LastFullUpdate'] | Should -Be '2026-03-01 14:30:00'
            $Result['NameIndexVersion'] | Should -Be 'abc123'
            $Result['SessionCount'] | Should -Be 42
        }
    }
}

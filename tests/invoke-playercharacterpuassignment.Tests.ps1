BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'invoke-playercharacterpuassignment.ps1')
}

Describe 'Invoke-PlayerCharacterPUAssignment' {
    BeforeAll {
        # Mock config
        Mock Get-AdminConfig {
            return @{
                RepoRoot = $script:FixturesRoot
                ResDir   = $script:FixturesRoot
            }
        }

        # Mock git optimization (skip, fall back to full scan)
        Mock Get-GitChangeLog { return @() }

        # Mock history (nothing processed yet)
        Mock Get-AdminHistoryEntries {
            return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        # Mock side-effect functions
        Mock Set-PlayerCharacter {}
        Mock Send-DiscordMessage { return @{ Success = $true } }
        Mock Add-AdminHistoryEntry {}

        # Build mock sessions
        $script:MockSessions = @(
            [PSCustomObject]@{
                Header   = '### 2024-06-15, Test Session A, Narrator'
                PU       = @(
                    [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                    [PSCustomObject]@{ Character = 'Kyrre'; Value = [decimal]0.5 }
                )
                FilePath = 'sessions-gen3.md'
            },
            [PSCustomObject]@{
                Header   = '### 2024-06-20, Test Session B, Narrator'
                PU       = @(
                    [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]1.0 }
                )
                FilePath = 'sessions-gen3.md'
            }
        )

        # Build mock characters
        $script:MockCharacters = @(
            [PSCustomObject]@{
                Name       = 'Xeron Demonlord'
                PlayerName = 'Solmyr'
                Aliases    = @('Xeron')
                PUSum      = [decimal]10
                PUTaken    = [decimal]5
                PUExceeded = [decimal]0
                IsActive   = $true
                Player     = @{ PRFWebhook = 'https://discord.com/api/webhooks/123/abc' }
            },
            [PSCustomObject]@{
                Name       = 'Kyrre'
                PlayerName = 'Solmyr'
                Aliases    = @()
                PUSum      = [decimal]8
                PUTaken    = [decimal]3
                PUExceeded = [decimal]0
                IsActive   = $true
                Player     = @{ PRFWebhook = 'https://discord.com/api/webhooks/123/abc' }
            },
            [PSCustomObject]@{
                Name       = 'Dracon'
                PlayerName = 'Crag Hack'
                Aliases    = @()
                PUSum      = [decimal]5
                PUTaken    = [decimal]2
                PUExceeded = [decimal]2
                IsActive   = $true
                Player     = @{ PRFWebhook = $null }
            }
        )
    }

    Context 'PU calculation' {
        BeforeAll {
            Mock Get-Session { return $script:MockSessions }
            Mock Get-PlayerCharacter { return $script:MockCharacters }
        }

        It 'computes BasePU = 1 + Sum(session PU)' {
            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            # Xeron: sessions total 0.3 + 1.0 = 1.3, BasePU = 1 + 1.3 = 2.3
            $Xeron = $Result | Where-Object { $_.CharacterName -eq 'Xeron Demonlord' }
            $Xeron | Should -Not -BeNullOrEmpty
            $Xeron.BasePU | Should -Be 2.3
        }

        It 'caps GrantedPU at 5' {
            # Set up a session with high PU to exceed cap
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, High PU Session, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]6.0 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Xeron = $Result | Where-Object { $_.CharacterName -eq 'Xeron Demonlord' }
            $Xeron.BasePU | Should -Be 7  # 1 + 6
            $Xeron.GrantedPU | Should -Be 5
            $Xeron.OverflowPU | Should -Be 2  # 7 - 5
        }

        It 'supplements from overflow pool when under cap' {
            # Dracon has PUExceeded=2, give low session PU
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, Low PU Session, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'Dracon'; Value = [decimal]0.5 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Dracon = $Result | Where-Object { $_.CharacterName -eq 'Dracon' }
            $Dracon | Should -Not -BeNullOrEmpty
            $Dracon.BasePU | Should -Be 1.5   # 1 + 0.5
            $Dracon.UsedExceeded | Should -Be 2  # min(5-1.5, 2) = min(3.5, 2) = 2
            $Dracon.GrantedPU | Should -Be 3.5   # min(1.5+2, 5) = 3.5
            $Dracon.RemainingPUExceeded | Should -Be 0  # (2-2)+0 = 0
        }

        It 'sets OverflowPU when BasePU exceeds cap' {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, Big Session, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'Kyrre'; Value = [decimal]5.5 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Kyr = $Result | Where-Object { $_.CharacterName -eq 'Kyrre' }
            $Kyr.BasePU | Should -Be 6.5      # 1 + 5.5
            $Kyr.OverflowPU | Should -Be 1.5  # 6.5 - 5
            $Kyr.GrantedPU | Should -Be 5
            $Kyr.RemainingPUExceeded | Should -Be 1.5  # (0-0)+1.5
        }

        It 'computes new PU totals' {
            Mock Get-Session { return $script:MockSessions }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Xeron = $Result | Where-Object { $_.CharacterName -eq 'Xeron Demonlord' }
            # Xeron: PUSum=10, PUTaken=5, GrantedPU=2.3
            $Xeron.NewPUSum | Should -Be 12.3   # 10 + 2.3
            $Xeron.NewPUTaken | Should -Be 7.3  # 5 + 2.3
        }

        It 'returns result per character' {
            Mock Get-Session { return $script:MockSessions }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Result.Count | Should -Be 2  # Xeron and Kyrre
        }

        It 'includes Message and SessionCount in result' {
            Mock Get-Session { return $script:MockSessions }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Xeron = $Result | Where-Object { $_.CharacterName -eq 'Xeron Demonlord' }
            $Xeron.SessionCount | Should -Be 2
            $Xeron.Message | Should -Not -BeNullOrEmpty
            $Xeron.Message | Should -BeLike '*Xeron Demonlord*'
            $Xeron.Resolved | Should -BeTrue
        }
    }

    Context 'fail-early on unresolved characters' {
        It 'throws when a PU character name does not resolve' {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, Unknown Char, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'NonExistentHero'; Value = [decimal]0.5 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }
            Mock Get-PlayerCharacter { return $script:MockCharacters }

            { Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf } |
                Should -Throw '*Unresolved character name*NonExistentHero*'
        }
    }

    Context 'PlayerName filter' {
        It 'only returns characters matching -PlayerName' {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, Multi Player, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                        [PSCustomObject]@{ Character = 'Dracon'; Value = [decimal]0.5 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }
            Mock Get-PlayerCharacter { return $script:MockCharacters }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -PlayerName 'Crag Hack' -WhatIf
            $Result.Count | Should -Be 1
            $Result[0].CharacterName | Should -Be 'Dracon'
            $Result[0].PlayerName | Should -Be 'Crag Hack'
        }
    }

    Context 'empty results' {
        It 'returns empty array when no sessions have PU' {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, No PU Session, Narrator'
                    PU       = @()
                    FilePath = 'sessions-gen3.md'
                })
            }
            Mock Get-PlayerCharacter { return $script:MockCharacters }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Result.Count | Should -Be 0
        }

        It 'returns empty array when all sessions already processed' {
            Mock Get-Session { return $script:MockSessions }
            Mock Get-PlayerCharacter { return $script:MockCharacters }
            Mock Get-AdminHistoryEntries {
                $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                [void]$Set.Add('2024-06-15, Test Session A, Narrator')
                [void]$Set.Add('2024-06-20, Test Session B, Narrator')
                return , $Set
            }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Result.Count | Should -Be 0
        }
    }

    Context 'alias resolution' {
        It 'resolves character by alias' {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, Alias Session, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'Xeron'; Value = [decimal]0.5 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }
            Mock Get-PlayerCharacter { return $script:MockCharacters }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }

            $Result = Invoke-PlayerCharacterPUAssignment -Year 2024 -Month 6 -WhatIf
            $Result.Count | Should -Be 1
            $Result[0].CharacterName | Should -Be 'Xeron Demonlord'
        }
    }
}

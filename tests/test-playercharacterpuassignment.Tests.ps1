<#
    .SYNOPSIS
    Pester tests for test-playercharacterpuassignment.ps1.

    .DESCRIPTION
    Tests for Test-PlayerCharacterPUAssignment covering PU assignment
    validation, expected vs actual PU comparison, discrepancy detection,
    and assignment correctness reporting.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'invoke-playercharacterpuassignment.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'test-playercharacterpuassignment.ps1')
}

Describe 'Test-PlayerCharacterPUAssignment' {
    BeforeAll {
        # Mock config
        Mock Get-AdminConfig {
            return @{
                RepoRoot = $script:FixturesRoot
                ResDir   = $script:FixturesRoot
            }
        }

        # Mock characters for the inner Invoke- call
        $script:MockCharacters = @(
            [PSCustomObject]@{
                Name       = 'Xeron Demonlord'
                PlayerName = 'Solmyr'
                Aliases    = @('Xeron')
                PUSum      = [decimal]10
                PUTaken    = [decimal]5
                PUExceeded = [decimal]0
                IsActive   = $true
                Player     = @{ PRFWebhook = $null }
            },
            [PSCustomObject]@{
                Name       = 'Kyrre'
                PlayerName = 'Solmyr'
                Aliases    = @()
                PUSum      = [decimal]8
                PUTaken    = [decimal]3
                PUExceeded = [decimal]0
                IsActive   = $true
                Player     = @{ PRFWebhook = $null }
            }
        )

        Mock Get-GitChangeLog { return @() }
        Mock Get-PlayerCharacter { return $script:MockCharacters }
    }

    Context 'clean data returns OK' {
        BeforeAll {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header     = '### 2024-06-15, Clean Session, Narrator'
                    PU         = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                    )
                    ParseError = $null
                    Content    = $null
                    FilePath   = 'sessions-gen3.md'
                })
            }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'returns OK=true when no issues found' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.OK | Should -BeTrue
            $Result.UnresolvedCharacters.Count | Should -Be 0
            $Result.MalformedPU.Count | Should -Be 0
            $Result.DuplicateEntries.Count | Should -Be 0
            $Result.FailedSessionsWithPU.Count | Should -Be 0
            $Result.StaleHistoryEntries.Count | Should -Be 0
        }

        It 'includes AssignmentResults' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.AssignmentResults | Should -Not -BeNullOrEmpty
        }
    }

    Context 'unresolved characters' {
        BeforeAll {
            # Two mock calls: Invoke- (which throws) and Get-Session for diagnostics
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header     = '### 2024-06-15, Unresolved Session, Narrator'
                    PU         = @(
                        [PSCustomObject]@{ Character = 'UnknownHero'; Value = [decimal]0.5 }
                    )
                    ParseError = $null
                    Content    = $null
                    FilePath   = 'sessions-gen3.md'
                })
            }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'captures unresolved characters from Invoke- error' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.OK | Should -BeFalse
            $Result.UnresolvedCharacters.Count | Should -BeGreaterThan 0
            $Result.UnresolvedCharacters[0].CharacterName | Should -Be 'UnknownHero'
        }
    }

    Context 'malformed PU values' {
        BeforeAll {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header     = '### 2024-06-15, Malformed PU, Narrator'
                    PU         = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = $null }
                    )
                    ParseError = $null
                    Content    = $null
                    FilePath   = 'sessions-gen3.md'
                })
            }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'detects null PU values' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.OK | Should -BeFalse
            $Result.MalformedPU.Count | Should -BeGreaterThan 0
            $Result.MalformedPU[0].CharacterName | Should -Be 'Xeron Demonlord'
            $Result.MalformedPU[0].Issue | Should -Be 'Null PU value'
        }
    }

    Context 'duplicate PU entries' {
        BeforeAll {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header     = '### 2024-06-15, Duplicate PU, Narrator'
                    PU         = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.5 }
                    )
                    ParseError = $null
                    Content    = $null
                    FilePath   = 'sessions-gen3.md'
                })
            }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'detects same character in multiple PU lines within one session' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.OK | Should -BeFalse
            $Result.DuplicateEntries.Count | Should -BeGreaterThan 0
            $Result.DuplicateEntries[0].CharacterName | Should -Be 'Xeron Demonlord'
            $Result.DuplicateEntries[0].Count | Should -Be 2
        }
    }

    Context 'failed sessions with PU data' {
        BeforeAll {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header     = '### 2024-06-15, Good Session, Narrator'
                        PU         = @(
                            [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                        )
                        ParseError = $null
                        Content    = $null
                        FilePath   = 'sessions-gen3.md'
                    },
                    [PSCustomObject]@{
                        Header     = '### 2024-1-5, Bad Date Session, Narrator'
                        PU         = @()
                        ParseError = 'Invalid date format'
                        Content    = "- PU:`n    - SomeChar: 0,5`n"
                        FilePath   = 'sessions-failed.md'
                    }
                )
            }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'detects PU data in failed sessions' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.OK | Should -BeFalse
            $Result.FailedSessionsWithPU.Count | Should -BeGreaterThan 0
            $Result.FailedSessionsWithPU[0].ParseError | Should -Be 'Invalid date format'
            $Result.FailedSessionsWithPU[0].PUCandidates | Should -Contain 'SomeChar'
        }
    }

    Context 'stale history entries' {
        BeforeAll {
            Mock Get-Session -ParameterFilter { $IncludeFailed } {
                return @([PSCustomObject]@{
                    Header     = '### 2024-06-15, Known Session, Narrator'
                    PU         = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                    )
                    ParseError = $null
                    Content    = $null
                    FilePath   = 'sessions-gen3.md'
                })
            }
            Mock Get-Session -ParameterFilter { -not $IncludeFailed } {
                return @([PSCustomObject]@{
                    Header   = '### 2024-06-15, Known Session, Narrator'
                    PU       = @(
                        [PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = [decimal]0.3 }
                    )
                    FilePath = 'sessions-gen3.md'
                })
            }

            Mock Get-AdminHistoryEntries {
                $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                [void]$Set.Add('2024-06-15, Known Session, Narrator')
                [void]$Set.Add('2024-03-10, Deleted Session, OldNarrator')
                return , $Set
            }
        }

        It 'detects headers in history not found in repo sessions' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.StaleHistoryEntries.Count | Should -BeGreaterThan 0
            $StaleHeaders = $Result.StaleHistoryEntries | ForEach-Object { $_.Header }
            $StaleHeaders | Should -Contain '2024-03-10, Deleted Session, OldNarrator'
        }
    }

    Context 'diagnostic output structure' {
        BeforeAll {
            Mock Get-Session {
                return @([PSCustomObject]@{
                    Header     = '### 2024-06-15, Struct Test, Narrator'
                    PU         = @(
                        [PSCustomObject]@{ Character = 'Kyrre'; Value = [decimal]0.3 }
                    )
                    ParseError = $null
                    Content    = $null
                    FilePath   = 'sessions-gen3.md'
                })
            }
            Mock Get-AdminHistoryEntries {
                return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'returns object with all expected properties' {
            $Result = Test-PlayerCharacterPUAssignment -Year 2024 -Month 6
            $Result.PSObject.Properties.Name | Should -Contain 'OK'
            $Result.PSObject.Properties.Name | Should -Contain 'UnresolvedCharacters'
            $Result.PSObject.Properties.Name | Should -Contain 'MalformedPU'
            $Result.PSObject.Properties.Name | Should -Contain 'DuplicateEntries'
            $Result.PSObject.Properties.Name | Should -Contain 'FailedSessionsWithPU'
            $Result.PSObject.Properties.Name | Should -Contain 'StaleHistoryEntries'
            $Result.PSObject.Properties.Name | Should -Contain 'AssignmentResults'
        }
    }
}

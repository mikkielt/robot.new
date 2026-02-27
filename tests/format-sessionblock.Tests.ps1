<#
    .SYNOPSIS
    Pester tests for format-sessionblock.ps1.

    .DESCRIPTION
    Tests for ConvertTo-Gen4MetadataBlock and ConvertTo-SessionMetadata
    covering Gen4 metadata block rendering for Lokacje, PU, Logi, Zmiany,
    and Intel tags, canonical block ordering, and empty/null handling.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'format-sessionblock.ps1')

    $script:NL = "`n"
}

Describe 'ConvertTo-Gen4MetadataBlock' {
    Context 'Lokacje' {
        It 'renders "- @Lokacje:" with nested location items' {
            # Arrange
            $Items = @('Erathia', 'Steadwick')

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'Lokacje' -Items $Items -NL $script:NL

            # Assert
            $Result | Should -Not -BeNullOrEmpty
            $Lines = $Result -split "`n"
            $Lines[0] | Should -Be '- @Lokacje:'
            $Lines[1] | Should -Be '    - Erathia'
            $Lines[2] | Should -Be '    - Steadwick'
        }
    }

    Context 'PU' {
        It 'renders PU entries with "Character: Value" and invariant culture decimal' {
            # Arrange
            $Items = @(
                [PSCustomObject]@{ Character = 'Solmyr'; Value = 0.3 }
                [PSCustomObject]@{ Character = 'Xeron'; Value = 1.5 }
            )

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'PU' -Items $Items -NL $script:NL

            # Assert
            $Lines = $Result -split "`n"
            $Lines[0] | Should -Be '- @PU:'
            $Lines[1] | Should -Be '    - Solmyr: 0.3'
            $Lines[2] | Should -Be '    - Xeron: 1.5'
        }

        It 'renders PU entry with null value as "Character:" (no value)' {
            # Arrange
            $Items = @(
                [PSCustomObject]@{ Character = 'Crag Hack'; Value = $null }
            )

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'PU' -Items $Items -NL $script:NL

            # Assert
            $Lines = $Result -split "`n"
            $Lines[1] | Should -Be '    - Crag Hack:'
        }
    }

    Context 'Logi' {
        It 'renders log URLs as nested items' {
            # Arrange
            $Items = @('https://example.com/log1', 'https://example.com/log2')

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'Logi' -Items $Items -NL $script:NL

            # Assert
            $Lines = $Result -split "`n"
            $Lines[0] | Should -Be '- @Logi:'
            $Lines[1] | Should -Be '    - https://example.com/log1'
            $Lines[2] | Should -Be '    - https://example.com/log2'
        }
    }

    Context 'Zmiany' {
        It 'renders three-level structure with entity name and @tag: value children' {
            # Arrange
            $Items = @(
                [PSCustomObject]@{
                    EntityName = 'Xeron Demonlord'
                    Tags = @(
                        [PSCustomObject]@{ Tag = '@lokacja'; Value = 'Erathia' }
                        [PSCustomObject]@{ Tag = 'status'; Value = 'Nieaktywny (2025-01:)' }
                    )
                }
            )

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'Zmiany' -Items $Items -NL $script:NL

            # Assert
            $Lines = $Result -split "`n"
            $Lines[0] | Should -Be '- @Zmiany:'
            $Lines[1] | Should -Be '    - Xeron Demonlord'
            $Lines[2] | Should -Be '        - @lokacja: Erathia'
            $Lines[3] | Should -Be '        - @status: Nieaktywny (2025-01:)'
        }

        It 'prepends @ to tag names that do not already start with @' {
            # Arrange
            $Items = @(
                [PSCustomObject]@{
                    EntityName = 'TestEntity'
                    Tags = @(
                        [PSCustomObject]@{ Tag = 'grupa'; Value = 'Nocarze' }
                    )
                }
            )

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'Zmiany' -Items $Items -NL $script:NL

            # Assert
            $Lines = $Result -split "`n"
            $Lines[2] | Should -Be '        - @grupa: Nocarze'
        }
    }

    Context 'Intel' {
        It 'renders "RawTarget: Message" pairs' {
            # Arrange
            $Items = @(
                [PSCustomObject]@{ RawTarget = 'Grupa/Nocarze'; Message = 'Discovered their hideout' }
                [PSCustomObject]@{ RawTarget = 'Rion'; Message = 'Sent a warning' }
            )

            # Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'Intel' -Items $Items -NL $script:NL

            # Assert
            $Lines = $Result -split "`n"
            $Lines[0] | Should -Be '- @Intel:'
            $Lines[1] | Should -Be '    - Grupa/Nocarze: Discovered their hideout'
            $Lines[2] | Should -Be '    - Rion: Sent a warning'
        }
    }

    Context 'Empty/null Items' {
        It 'returns $null for null Items' {
            # Arrange / Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'Lokacje' -Items $null -NL $script:NL

            # Assert
            $Result | Should -BeNullOrEmpty
        }

        It 'returns $null for empty Items array' {
            # Arrange / Act
            $Result = ConvertTo-Gen4MetadataBlock -Tag 'PU' -Items @() -NL $script:NL

            # Assert
            $Result | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-SessionMetadata' {
    Context 'All blocks present' {
        It 'renders all blocks in canonical order: Lokacje, Logi, PU, Zmiany, Intel' {
            # Arrange
            $Locations = @('Erathia')
            $Logs = @('https://example.com/log1')
            $PU = @([PSCustomObject]@{ Character = 'Solmyr'; Value = 0.5 })
            $Changes = @([PSCustomObject]@{
                EntityName = 'Xeron'
                Tags = @([PSCustomObject]@{ Tag = '@lokacja'; Value = 'Steadwick' })
            })
            $Intel = @([PSCustomObject]@{ RawTarget = 'Rion'; Message = 'Test' })

            # Act
            $Result = ConvertTo-SessionMetadata `
                -Locations $Locations `
                -Logs $Logs `
                -PU $PU `
                -Changes $Changes `
                -Intel $Intel `
                -NL $script:NL

            # Assert
            $Result | Should -Not -BeNullOrEmpty
            $Blocks = $Result -split "`n"
            # First block should be Lokacje
            $Blocks[0] | Should -Be '- @Lokacje:'
            # Find block starts by looking for "- @"
            $BlockStarts = @()
            for ($i = 0; $i -lt $Blocks.Count; $i++) {
                if ($Blocks[$i] -match '^\- @') { $BlockStarts += $Blocks[$i] }
            }
            $BlockStarts[0] | Should -Be '- @Lokacje:'
            $BlockStarts[1] | Should -Be '- @Logi:'
            $BlockStarts[2] | Should -Be '- @PU:'
            $BlockStarts[3] | Should -Be '- @Zmiany:'
            $BlockStarts[4] | Should -Be '- @Intel:'
        }
    }

    Context 'Null blocks skipped' {
        It 'omits blocks when their source data is null/empty' {
            # Arrange — only Lokacje and PU have data
            $Locations = @('Erathia')
            $PU = @([PSCustomObject]@{ Character = 'Solmyr'; Value = 1 })

            # Act
            $Result = ConvertTo-SessionMetadata `
                -Locations $Locations `
                -Logs $null `
                -PU $PU `
                -Changes $null `
                -Intel $null `
                -NL $script:NL

            # Assert
            $Result | Should -BeLike '*@Lokacje:*'
            $Result | Should -BeLike '*@PU:*'
            $Result | Should -Not -BeLike '*@Logi:*'
            $Result | Should -Not -BeLike '*@Zmiany:*'
            $Result | Should -Not -BeLike '*@Intel:*'
        }
    }

    Context 'All empty' {
        It 'returns empty string when all blocks are empty' {
            # Arrange / Act
            $Result = ConvertTo-SessionMetadata `
                -Locations $null `
                -Logs $null `
                -PU $null `
                -Changes $null `
                -Intel $null `
                -NL $script:NL

            # Assert
            $Result | Should -Be ''
        }
    }

    Context 'Blocks joined by newline' {
        It 'joins blocks with the NL parameter' {
            # Arrange
            $Locations = @('Erathia')
            $Logs = @('https://example.com/log1')

            # Act
            $Result = ConvertTo-SessionMetadata `
                -Locations $Locations `
                -Logs $Logs `
                -PU $null `
                -Changes $null `
                -Intel $null `
                -NL $script:NL

            # Assert — two blocks separated by NL
            $LocBlock = ConvertTo-Gen4MetadataBlock -Tag 'Lokacje' -Items $Locations -NL $script:NL
            $LogBlock = ConvertTo-Gen4MetadataBlock -Tag 'Logi' -Items $Logs -NL $script:NL
            $Expected = $LocBlock + $script:NL + $LogBlock
            $Result | Should -Be $Expected
        }
    }
}

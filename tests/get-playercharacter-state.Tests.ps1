BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    # Dot-source the helpers directly for unit testing merge functions
    . "$script:ModuleRoot/get-entity.ps1"
    . "$script:ModuleRoot/charfile-helpers.ps1"

    # Source Get-PlayerCharacter to test the merge helpers
    . "$script:ModuleRoot/Get-PlayerCharacter.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-gpc-state-" + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Merge-ScalarProperty' {
    It 'returns character file value when no overrides' {
        $Result = Merge-ScalarProperty -CharFileValue 'Zdrowy.' -Entity $null -OverrideKey 'stan' -ActiveOn $null
        $Result | Should -Be 'Zdrowy.'
    }

    It 'returns null when no value from any layer' {
        $Result = Merge-ScalarProperty -CharFileValue $null -Entity $null -OverrideKey 'stan' -ActiveOn $null
        $Result | Should -BeNullOrEmpty
    }

    It 'override with date wins over undated character file value' {
        $Entity = [PSCustomObject]@{
            Overrides = @{
                'stan' = [System.Collections.Generic.List[string]]::new(@('Ranny (2025-06:)'))
            }
        }
        $Result = Merge-ScalarProperty -CharFileValue 'Zdrowy.' -Entity $Entity -OverrideKey 'stan' -ActiveOn $null
        $Result | Should -Be 'Ranny'
    }

    It 'respects ActiveOn for temporal filtering' {
        $Entity = [PSCustomObject]@{
            Overrides = @{
                'stan' = [System.Collections.Generic.List[string]]::new(@('Ranny (2025-06:2025-12)'))
            }
        }
        # Query before override range — should fall back to char file value
        $Before = [datetime]::ParseExact('2025-03-15', 'yyyy-MM-dd', $null)
        $Result = Merge-ScalarProperty -CharFileValue 'Zdrowy.' -Entity $Entity -OverrideKey 'stan' -ActiveOn $Before
        $Result | Should -Be 'Zdrowy.'

        # Query during override range
        $During = [datetime]::ParseExact('2025-08-15', 'yyyy-MM-dd', $null)
        $Result = Merge-ScalarProperty -CharFileValue 'Zdrowy.' -Entity $Entity -OverrideKey 'stan' -ActiveOn $During
        $Result | Should -Be 'Ranny'
    }
}

Describe 'Merge-MultiValuedProperty' {
    It 'returns character file values when no overrides' {
        $Result = Merge-MultiValuedProperty -CharFileValues @('Item1', 'Item2') -Entity $null -OverrideKey 'przedmiot_specjalny' -ActiveOn $null
        $Result.Count | Should -Be 2
        $Result[0] | Should -Be 'Item1'
    }

    It 'returns empty array when no values' {
        $Result = Merge-MultiValuedProperty -CharFileValues @() -Entity $null -OverrideKey 'przedmiot_specjalny' -ActiveOn $null
        $Result.Count | Should -Be 0
    }

    It 'combines character file and override values' {
        $Entity = [PSCustomObject]@{
            Overrides = @{
                'przedmiot_specjalny' = [System.Collections.Generic.List[string]]::new(@('New Item (2025-06:)'))
            }
        }
        $Result = Merge-MultiValuedProperty -CharFileValues @('Existing Item') -Entity $Entity -OverrideKey 'przedmiot_specjalny' -ActiveOn $null
        $Result.Count | Should -Be 2
        $Result | Should -Contain 'Existing Item'
        $Result | Should -Contain 'New Item'
    }
}

Describe 'Merge-ReputationTier' {
    It 'returns character file tier entries when no overrides' {
        $CharTier = @(
            [PSCustomObject]@{ Location = 'Erathia'; Detail = 'pomógł' }
        )
        $Result = Merge-ReputationTier -CharFileTier $CharTier -Entity $null -OverrideKey 'reputacja_pozytywna' -ActiveOn $null
        $Result.Count | Should -Be 1
        $Result[0].Location | Should -Be 'Erathia'
        $Result[0].Detail | Should -Be 'pomógł'
    }

    It 'combines character file and override locations' {
        $CharTier = @(
            [PSCustomObject]@{ Location = 'Erathia'; Detail = $null }
        )
        $Entity = [PSCustomObject]@{
            Overrides = @{
                'reputacja_pozytywna' = [System.Collections.Generic.List[string]]::new(@('Steadwick (2025-06:)'))
            }
        }
        $Result = Merge-ReputationTier -CharFileTier $CharTier -Entity $Entity -OverrideKey 'reputacja_pozytywna' -ActiveOn $null
        $Result.Count | Should -Be 2
        ($Result | ForEach-Object { $_.Location }) | Should -Contain 'Erathia'
        ($Result | ForEach-Object { $_.Location }) | Should -Contain 'Steadwick'
    }
}

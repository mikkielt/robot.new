<#
    .SYNOPSIS
    Pester tests for migration/narrator-normalization.ps1.

    .DESCRIPTION
    Tests for Import-NarratorMappings, Export-NarratorMappings, and
    Get-NarratorMappingsPath covering file parsing, round-trip export,
    edge cases, and case-insensitive key lookup.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'migration' 'narrator-normalization.ps1')
}

Describe 'Import-NarratorMappings' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'parses single canonical mapping line' {
        $Path = Join-Path $script:TempRoot 'single.txt'
        Write-TestFile -Path $Path -Content "Air Archmage -> Solmyr`n"
        $Dict = Import-NarratorMappings -Path $Path
        $Dict.Count | Should -Be 1
        $Dict['Air Archmage'] | Should -Be @('Solmyr')
    }

    It 'parses multi-canonical mapping line' {
        $Path = Join-Path $script:TempRoot 'multi.txt'
        Write-TestFile -Path $Path -Content "Soymlrrr i Drcn -> Solmyr, Dracon`n"
        $Dict = Import-NarratorMappings -Path $Path
        $Dict['Soymlrrr i Drcn'].Count | Should -Be 2
        $Dict['Soymlrrr i Drcn'][0] | Should -Be 'Solmyr'
        $Dict['Soymlrrr i Drcn'][1] | Should -Be 'Dracon'
    }

    It 'ignores comments and blank lines' {
        $Path = Join-Path $script:TempRoot 'comments.txt'
        $Content = "# This is a comment`n`nAir Archmage -> Solmyr`n# Another comment`n"
        Write-TestFile -Path $Path -Content $Content
        $Dict = Import-NarratorMappings -Path $Path
        $Dict.Count | Should -Be 1
    }

    It 'returns empty dictionary for missing file' {
        $Dict = Import-NarratorMappings -Path (Join-Path $script:TempRoot 'nonexistent.txt')
        $Dict | Should -Not -BeNull
        $Dict.Count | Should -Be 0
    }

    It 'supports case-insensitive key lookup' {
        $Path = Join-Path $script:TempRoot 'case.txt'
        Write-TestFile -Path $Path -Content "Air Archmage -> Solmyr`n"
        $Dict = Import-NarratorMappings -Path $Path
        $Dict.ContainsKey('air archmage') | Should -BeTrue
        $Dict.ContainsKey('AIR ARCHMAGE') | Should -BeTrue
    }

    It 'skips lines without arrow separator' {
        $Path = Join-Path $script:TempRoot 'noadrrow.txt'
        Write-TestFile -Path $Path -Content "This line has no arrow`nAir Archmage -> Solmyr`n"
        $Dict = Import-NarratorMappings -Path $Path
        $Dict.Count | Should -Be 1
    }
}

Describe 'Export-NarratorMappings' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'exports mappings sorted alphabetically' {
        $Dict = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Dict['Zebra'] = @('PlayerZ')
        $Dict['Air Archmage'] = @('Solmyr')
        $Path = Join-Path $script:TempRoot 'sorted.txt'
        Export-NarratorMappings -Mappings $Dict -Path $Path
        $Lines = [System.IO.File]::ReadAllLines($Path)
        # First non-comment, non-blank line should be Air Archmage (alphabetically first)
        $DataLines = $Lines | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('#') }
        $DataLines[0] | Should -BeLike 'Air Archmage -> Solmyr'
        $DataLines[1] | Should -BeLike 'Zebra -> PlayerZ'
    }

    It 'includes header comment' {
        $Dict = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Dict['Test'] = @('Player')
        $Path = Join-Path $script:TempRoot 'header.txt'
        Export-NarratorMappings -Mappings $Dict -Path $Path
        $Lines = [System.IO.File]::ReadAllLines($Path)
        $Lines[0] | Should -BeLike '#*'
    }

    It 'round-trips correctly (export then import)' {
        $Original = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Original['Air Archmage'] = @('Solmyr')
        $Original['Soymlrrr i Drcn'] = @('Solmyr', 'Dracon')
        $Path = Join-Path $script:TempRoot 'roundtrip.txt'
        Export-NarratorMappings -Mappings $Original -Path $Path
        $Imported = Import-NarratorMappings -Path $Path
        $Imported.Count | Should -Be 2
        $Imported['Air Archmage'] | Should -Be @('Solmyr')
        $Imported['Soymlrrr i Drcn'] | Should -Be @('Solmyr', 'Dracon')
    }

    It 'creates directory if it does not exist' {
        $SubDir = Join-Path $script:TempRoot 'newdir'
        $Path = Join-Path $SubDir 'mappings.txt'
        $Dict = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Dict['Test'] = @('Player')
        Export-NarratorMappings -Mappings $Dict -Path $Path
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }
}

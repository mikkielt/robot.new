<#
    .SYNOPSIS
    Pester tests for @koordynaty parsing in get-entity.ps1.

    .DESCRIPTION
    Tests that @koordynaty tags are parsed into Coordinates and CoordinateHistory
    properties on entity objects, including temporal validity.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
}

Describe '@koordynaty parsing' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-koordynaty.md')
    }

    It 'parses simple @koordynaty into Coordinates' {
        $ZamekGryfow = $script:Entities | Where-Object { $_.Name -eq 'Zamek Gryfów' }
        $ZamekGryfow | Should -Not -BeNullOrEmpty
        $ZamekGryfow.Coordinates | Should -Not -BeNullOrEmpty
        $ZamekGryfow.Coordinates.X | Should -Be 19
        $ZamekGryfow.Coordinates.Y | Should -Be 11
    }

    It 'builds CoordinateHistory with single entry' {
        $ZamekGryfow = $script:Entities | Where-Object { $_.Name -eq 'Zamek Gryfów' }
        $ZamekGryfow.CoordinateHistory | Should -Not -BeNullOrEmpty
        $ZamekGryfow.CoordinateHistory.Count | Should -Be 1
        $ZamekGryfow.CoordinateHistory[0].X | Should -Be 19
        $ZamekGryfow.CoordinateHistory[0].Y | Should -Be 11
    }

    It 'parses @koordynaty without other tags' {
        $Erathia = $script:Entities | Where-Object { $_.Name -eq 'Erathia' }
        $Erathia | Should -Not -BeNullOrEmpty
        $Erathia.Coordinates | Should -Not -BeNullOrEmpty
        $Erathia.Coordinates.X | Should -Be 15
        $Erathia.Coordinates.Y | Should -Be 8
    }

    It 'entity without @koordynaty has null Coordinates' {
        $Podziemia = $script:Entities | Where-Object { $_.Name -eq 'Podziemia Gryfów' }
        $Podziemia | Should -Not -BeNullOrEmpty
        $Podziemia.Coordinates | Should -BeNullOrEmpty
    }

    It 'entity without @koordynaty has empty CoordinateHistory' {
        $Podziemia = $script:Entities | Where-Object { $_.Name -eq 'Podziemia Gryfów' }
        $Podziemia.CoordinateHistory.Count | Should -Be 0
    }

    It 'handles temporal @koordynaty with multiple entries' {
        $ZamekKreegan = $script:Entities | Where-Object { $_.Name -eq 'Zamek Kreegan' }
        $ZamekKreegan | Should -Not -BeNullOrEmpty
        $ZamekKreegan.CoordinateHistory.Count | Should -Be 2
    }

    It 'resolves active coordinates from temporal history' {
        $ZamekKreegan = $script:Entities | Where-Object { $_.Name -eq 'Zamek Kreegan' }
        # The latest active coordinates should be 20, 15 (from 2024-07 onward)
        $ZamekKreegan.Coordinates | Should -Not -BeNullOrEmpty
        $ZamekKreegan.Coordinates.X | Should -Be 20
        $ZamekKreegan.Coordinates.Y | Should -Be 15
    }
}

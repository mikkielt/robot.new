<#
    .SYNOPSIS
    Pester tests for IsExterior classification and exterior-qualified paths in Get-Entity.

    .DESCRIPTION
    Tests the post-parse IsExterior computation on Lokacja entities and the
    exterior-qualified path generation for interior locations. Uses the
    entities-exterior.md fixture with Lokacja + Mapa entities.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-isext-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force

    $script:FixturePath = Join-Path $script:ModuleRoot 'tests/fixtures/entities-exterior.md'
    $script:Entities = Get-Entity -Path $script:FixturePath
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'IsExterior Classification' {
    It 'Lokacja with @koordynaty has IsExterior = $true' {
        $Ironhold = $script:Entities | Where-Object { $_.Name -eq 'Ironhold' -and $_.Type -eq 'Lokacja' }
        $Ironhold.IsExterior | Should -BeTrue
    }

    It 'Lokacja with exterior Mapa child has IsExterior = $true' {
        $Steadwick = $script:Entities | Where-Object { $_.Name -eq 'Steadwick' -and $_.Type -eq 'Lokacja' }
        $Steadwick.IsExterior | Should -BeTrue
    }

    It 'Lokacja with only wewnętrzna Mapa children has IsExterior = $false' {
        $Ratusz = $script:Entities | Where-Object { $_.Name -eq 'Ratusz Steadwick' -and $_.Type -ne 'wewnętrzna' }
        $Ratusz.IsExterior | Should -BeFalse
    }

    It 'Lokacja with no coordinates and no Mapa children has IsExterior = $null' {
        $Sala = $script:Entities | Where-Object { $_.Name -eq 'Sala Główna' }
        $Sala.IsExterior | Should -BeNullOrEmpty
    }

    It 'Lokacja with no parent and no evidence has IsExterior = $null' {
        $Tower = $script:Entities | Where-Object { $_.Name -eq 'Samotna Wieża' }
        $Tower.IsExterior | Should -BeNullOrEmpty
    }

    It 'Non-Lokacja entities have IsExterior = $null' {
        $Maps = $script:Entities | Where-Object { $_.Type -eq 'zewnętrzna' -or $_.Type -eq 'wewnętrzna' }
        $Maps | Should -Not -BeNullOrEmpty
        foreach ($M in $Maps) {
            $M.IsExterior | Should -BeNullOrEmpty
        }
    }
}

Describe 'Exterior-Qualified Paths' {
    It 'interior entity directly under exterior gets "Exterior/Name" in Names' {
        $Ratusz = $script:Entities | Where-Object { $_.Name -eq 'Ratusz Steadwick' -and $_.Type -ne 'wewnętrzna' }
        $Ratusz.Names | Should -Contain 'Steadwick/Ratusz Steadwick'
    }

    It 'interior entity 2 levels deep walks to exterior ancestor' {
        $Sala = $script:Entities | Where-Object { $_.Name -eq 'Sala Główna' }
        $Sala.Names | Should -Contain 'Steadwick/Sala Główna'
    }

    It 'interior entity with no exterior ancestor has no qualified path' {
        $Tower = $script:Entities | Where-Object { $_.Name -eq 'Samotna Wieża' }
        $HasSlashName = $false
        foreach ($N in $Tower.Names) {
            if ($N.Contains('/')) { $HasSlashName = $true }
        }
        $HasSlashName | Should -BeFalse
    }

    It 'exterior entity does not get a qualified path' {
        $Ironhold = $script:Entities | Where-Object { $_.Name -eq 'Ironhold' -and $_.Type -eq 'Lokacja' }
        $HasSlashName = $false
        foreach ($N in $Ironhold.Names) {
            if ($N.Contains('/')) { $HasSlashName = $true }
        }
        $HasSlashName | Should -BeFalse
    }

    It 'qualified path resolves via Resolve-Name' {
        $NameIdx = Get-NameIndex -Entities $script:Entities -Players @()
        $Resolved = Resolve-Name -Query 'Steadwick/Ratusz Steadwick' -Index $NameIdx.Index -StemIndex $NameIdx.StemIndex -BKTree $NameIdx.BKTree
        $Resolved | Should -Not -BeNullOrEmpty
        $Resolved.Name | Should -Be 'Ratusz Steadwick'
    }

    It 'bare interior name without same-name Mapa resolves to entity' {
        $NameIdx = Get-NameIndex -Entities $script:Entities -Players @()
        $Resolved = Resolve-Name -Query 'Sala Główna' -Index $NameIdx.Index -StemIndex $NameIdx.StemIndex -BKTree $NameIdx.BKTree
        $Resolved | Should -Not -BeNullOrEmpty
        $Resolved.Name | Should -Be 'Sala Główna'
    }
}

Describe 'Temporal IsExterior with -ActiveOn' {
    BeforeAll {
        # Create a fixture with temporal @lokacja
        $script:TemporalFixture = Join-Path $script:TempRoot 'entities-temporal-ext.md'
        @"
## Lokacja

* Eder
    - @koordynaty: 5, 5

* Bracada
    - @koordynaty: 20, 30

* Travelling Market
    - @lokacja: Eder (:2025-06)
    - @lokacja: Bracada (2025-07:)

## Mapa

* Eder
    - @lokacja: Eder
    - @margonemid: 100
    - @typ: zewnętrzna
"@ | Set-Content -Path $script:TemporalFixture -Encoding UTF8
    }

    It 'qualified path reflects -ActiveOn date (early period)' {
        $Entities = Get-Entity -Path $script:TemporalFixture -ActiveOn ([datetime]'2025-05-01')
        $Market = $Entities | Where-Object { $_.Name -eq 'Travelling Market' }
        $Market.Names | Should -Contain 'Eder/Travelling Market'
    }

    It 'qualified path reflects -ActiveOn date (later period)' {
        $Entities = Get-Entity -Path $script:TemporalFixture -ActiveOn ([datetime]'2025-08-01')
        $Market = $Entities | Where-Object { $_.Name -eq 'Travelling Market' }
        $Market.Names | Should -Contain 'Bracada/Travelling Market'
    }
}

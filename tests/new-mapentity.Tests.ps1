<#
    .SYNOPSIS
    Pester tests for New-MapEntity.

    .DESCRIPTION
    Tests for New-MapEntity covering slug uniqueness, dimensions validation,
    parent validation, URL tags, and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-new-map-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'New-MapEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-location-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'creates a basic map entity under ## Mapa' {
        $Result = New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -EntitiesFile $script:EntFile

        $Result.Name | Should -Be 'Nowa Mapa'
        $Result.Type | Should -Be 'Mapa'
        $Result.Created | Should -BeTrue

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Nowa Mapa'
        $Content | Should -Match '@slug:\s*nowa-mapa'
    }

    It 'creates map with parent, url, dimensions' {
        New-MapEntity -Name 'Wieża Magów' -Slug 'wieza-magow' `
            -Parent 'Steadwick' `
            -Url 'https://cdn.margonem.pl/maps/wieza-magow.png' `
            -UrlNerthus 'https://nerthus.margonem.pl/maps/wieza-magow.png' `
            -Dimensions '30, 25' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Steadwick'
        $Content | Should -Match '@slug:\s*wieza-magow'
        $Content | Should -Match '@url:\s*https://cdn.margonem.pl/maps/wieza-magow.png'
        $Content | Should -Match '@url_nerthus:\s*https://nerthus.margonem.pl/maps/wieza-magow.png'
        $Content | Should -Match '@wymiary:\s*30, 25'
    }

    It 'creates map with info description' {
        New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Info 'Opis mapy.' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@info:\s*Opis mapy\.'
    }

    It 'creates map with doors (multi-valued)' {
        New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Doors 'Steadwick', 'Ratusz Steadwicku' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@drzwi:\s*Steadwick'
        $Content | Should -Match '@drzwi:\s*Ratusz Steadwicku'
    }

    It 'throws on duplicate slug' {
        { New-MapEntity -Name 'Inna Komnata' -Slug 'komnata-rady-ratusz' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Slug*already exists*'
    }

    It 'throws on duplicate slug (case-insensitive)' {
        { New-MapEntity -Name 'Inna Komnata' -Slug 'KOMNATA-RADY-RATUSZ' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Slug*already exists*'
    }

    It 'throws on invalid dimensions format — single value' {
        { New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Dimensions '20' -EntitiesFile $script:EntFile } |
            Should -Throw '*Invalid dimensions format*'
    }

    It 'throws on invalid dimensions — non-positive' {
        { New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Dimensions '0, 15' -EntitiesFile $script:EntFile } |
            Should -Throw '*positive integers*'
    }

    It 'throws on invalid dimensions — non-integer' {
        { New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Dimensions 'abc, def' -EntitiesFile $script:EntFile } |
            Should -Throw '*positive integers*'
    }

    It 'throws on non-existent parent' {
        { New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Parent 'NieistniejącaLokacja' -EntitiesFile $script:EntFile } |
            Should -Throw '*Parent location*not found*'
    }

    It 'applies ValidFrom temporal suffix' {
        New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -Parent 'Steadwick' -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Steadwick \(2026-03:\)'
        $Content | Should -Match '@slug:\s*nowa-mapa \(2026-03:\)'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        New-MapEntity -Name 'Nowa Mapa' -Slug 'nowa-mapa' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }
}

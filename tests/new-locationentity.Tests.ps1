<#
    .SYNOPSIS
    Pester tests for New-LocationEntity.

    .DESCRIPTION
    Tests for New-LocationEntity covering parent validation, coordinate
    validation, door warning, multi-valued tag insertion, and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-new-loc-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'New-LocationEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-location-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'creates a basic location under ## Lokacja' {
        $Result = New-LocationEntity -Name 'Nowa Wieża' -EntitiesFile $script:EntFile

        $Result.Name | Should -Be 'Nowa Wieża'
        $Result.Type | Should -Be 'Lokacja'
        $Result.Created | Should -BeTrue

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Nowa Wieża'
    }

    It 'creates location with parent' {
        $Result = New-LocationEntity -Name 'Sala Tronowa' -Parent 'Steadwick' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Sala Tronowa'
        $Content | Should -Match '@lokacja:\s*Steadwick'
    }

    It 'creates location with coordinates' {
        New-LocationEntity -Name 'Nowa Wioska' -Coordinates '10, 20' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@koordynaty:\s*10, 20'
    }

    It 'creates location with NerthusName' {
        New-LocationEntity -Name 'Nowa Wioska' -NerthusName 'Wioska Nad Rzeką' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@nazwa_nerthus:\s*Wioska Nad Rzeką'
    }

    It 'creates location with doors (multi-valued)' {
        New-LocationEntity -Name 'Nowa Wieża' -Parent 'Steadwick' `
            -Doors 'Steadwick', 'Ratusz Steadwicku' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@drzwi:\s*Steadwick'
        $Content | Should -Match '@drzwi:\s*Ratusz Steadwicku'
    }

    It 'creates location with margonemIds (multi-valued)' {
        New-LocationEntity -Name 'Nowa Wieża' -MargonemIds 500, 501 `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@margonemid:\s*500'
        $Content | Should -Match '@margonemid:\s*501'
    }

    It 'applies ValidFrom temporal suffix to tags' {
        New-LocationEntity -Name 'Nowa Wieża' -Parent 'Steadwick' `
            -Coordinates '5, 5' -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Steadwick \(2026-03:\)'
        $Content | Should -Match '@koordynaty:\s*5, 5 \(2026-03:\)'
    }

    It 'applies ValidFrom to door entries' {
        New-LocationEntity -Name 'Nowa Wieża' -Doors 'Steadwick' `
            -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@drzwi:\s*Steadwick \(2026-03:\)'
    }

    It 'throws on non-existent parent' {
        { New-LocationEntity -Name 'Nowa Wieża' -Parent 'NieistniejącaLokacja' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Parent location*not found*'
    }

    It 'throws on invalid coordinate format — single value' {
        { New-LocationEntity -Name 'Nowa Wieża' -Coordinates '10' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Invalid coordinates format*'
    }

    It 'throws on invalid coordinate format — non-integer' {
        { New-LocationEntity -Name 'Nowa Wieża' -Coordinates 'abc, def' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*X and Y must be integers*'
    }

    It 'throws on invalid coordinate format — three values' {
        { New-LocationEntity -Name 'Nowa Wieża' -Coordinates '1, 2, 3' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Invalid coordinates format*'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        New-LocationEntity -Name 'Nowa Wieża' -Parent 'Steadwick' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }

    It 'merges custom tags via -Tags parameter' {
        New-LocationEntity -Name 'Nowa Wieża' -Tags @{ info = 'Wieża strażnicza' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@info:\s*Wieża strażnicza'
    }
}

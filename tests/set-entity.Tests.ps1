<#
    .SYNOPSIS
    Pester tests for Set-Entity.

    .DESCRIPTION
    Tests for Set-Entity covering tag upsert, auto-creation when entity
    not found, disambiguation via -Type, temporal suffix, and cross-section
    search.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-set-entity-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Set-Entity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-generic-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'upserts a tag on an existing entity' {
        Set-Entity -Name 'Kupiec Orrin' -Tags @{ rasa = 'Człowiek' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@rasa:\s*Człowiek'
        # Original tags preserved
        $Content | Should -Match '@lokacja:\s*Targ Główny'
    }

    It 'updates an existing tag value' {
        Set-Entity -Name 'Kupiec Orrin' -Tags @{ lokacja = 'Rynek Zachodni' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Rynek Zachodni'
        $Content | Should -Not -Match '@lokacja:\s*Targ Główny'
    }

    It 'finds entity across sections without -Type' {
        Set-Entity -Name 'Gildia Kupców' -Tags @{ typ = 'Handlowa' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@typ:\s*Handlowa'
    }

    It 'scopes search to -Type when provided' {
        Set-Entity -Name 'Kupiec Orrin' -Type 'NPC' -Tags @{ rasa = 'Człowiek' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@rasa:\s*Człowiek'
    }

    It 'auto-creates entity when not found and -Type provided' {
        Set-Entity -Name 'Nowa Lokacja' -Type 'Lokacja' `
            -Tags @{ region = 'Północ' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Nowa Lokacja'
        $Content | Should -Match '@region:\s*Północ'
    }

    It 'throws when entity not found and -Type not provided' {
        { Set-Entity -Name 'Nieistniejący' -Tags @{ foo = 'bar' } `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*not found*'
    }

    It 'applies ValidFrom temporal suffix to tags' {
        Set-Entity -Name 'Kupiec Orrin' -Tags @{ status = 'Nieaktywny' } `
            -ValidFrom '2026-01' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@status:\s*Nieaktywny \(2026-01:\)'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        Set-Entity -Name 'Kupiec Orrin' -Tags @{ rasa = 'Elf' } `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }

    It 'upserts multiple tags in one call' {
        Set-Entity -Name 'Kupiec Orrin' -Tags @{ rasa = 'Człowiek'; profesja = 'Handlarz' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@rasa:\s*Człowiek'
        $Content | Should -Match '@profesja:\s*Handlarz'
    }
}

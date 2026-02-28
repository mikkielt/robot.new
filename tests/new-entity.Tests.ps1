<#
    .SYNOPSIS
    Pester tests for New-Entity.

    .DESCRIPTION
    Tests for New-Entity covering entity creation, duplicate detection,
    tag writing, ValidFrom temporal suffix, and type validation.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-new-entity-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'New-Entity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-generic-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'creates a new NPC entity' {
        $Result = New-Entity -Type 'NPC' -Name 'Strażnik Varen' `
            -Tags @{ lokacja = 'Brama Północna' } `
            -EntitiesFile $script:EntFile

        $Result.Name | Should -Be 'Strażnik Varen'
        $Result.Type | Should -Be 'NPC'
        $Result.Created | Should -BeTrue

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Strażnik Varen'
        $Content | Should -Match '@lokacja:\s*Brama Północna'
    }

    It 'creates entity under correct section type' {
        New-Entity -Type 'Organizacja' -Name 'Zakon Cieni' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        # Verify entity is under ## Organizacja section
        $Lines = $Content.Split("`n")
        $OrgIdx = -1
        $EntityIdx = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^## Organizacja') { $OrgIdx = $i }
            if ($Lines[$i] -match '\*\s*Zakon Cieni') { $EntityIdx = $i }
        }
        $EntityIdx | Should -BeGreaterThan $OrgIdx
    }

    It 'throws on duplicate entity name' {
        { New-Entity -Type 'NPC' -Name 'Kupiec Orrin' -EntitiesFile $script:EntFile } |
            Should -Throw '*already exists*'
    }

    It 'applies ValidFrom temporal suffix to tags' {
        New-Entity -Type 'Lokacja' -Name 'Wieża Magów' `
            -Tags @{ region = 'Góry Wschodnie' } `
            -ValidFrom '2026-03' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@region:\s*Góry Wschodnie \(2026-03:\)'
    }

    It 'creates entity with no tags' {
        $Result = New-Entity -Type 'Przedmiot' -Name 'Kamień Duszy' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Kamień Duszy'
        $Result.Tags.Count | Should -Be 0
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        New-Entity -Type 'NPC' -Name 'Nowy NPC' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }

    It 'creates entity with multiple tags' {
        New-Entity -Type 'NPC' -Name 'Kapłan Morven' `
            -Tags @{ lokacja = 'Świątynia'; status = 'Aktywny'; rasa = 'Elf' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Świątynia'
        $Content | Should -Match '@status:\s*Aktywny'
        $Content | Should -Match '@rasa:\s*Elf'
    }
}

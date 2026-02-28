<#
    .SYNOPSIS
    Pester tests for Remove-Entity.

    .DESCRIPTION
    Tests for Remove-Entity covering soft-delete via @status: Usunięty,
    entity search across sections, disambiguation via -Type,
    default ValidFrom, and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-remove-entity-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Remove-Entity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-generic-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'sets @status: Usunięty on an NPC entity' {
        Remove-Entity -Name 'Kupiec Orrin' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@status:\s*Usunięty\s*\(2026-02:\)'
    }

    It 'does not delete the entity entry' {
        Remove-Entity -Name 'Kupiec Orrin' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Kupiec Orrin'
        $Content | Should -Match '@lokacja:\s*Targ Główny'
    }

    It 'defaults ValidFrom to current month' {
        Remove-Entity -Name 'Kupiec Orrin' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Expected = (Get-Date).ToString('yyyy-MM')
        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match "@status:\s*Usunięty\s*\($Expected`:\)"
    }

    It 'finds entity across sections without -Type' {
        Remove-Entity -Name 'Gildia Kupców' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Gildia Kupców'
        $Content | Should -Match '@status:\s*Usunięty\s*\(2026-02:\)'
    }

    It 'scopes search to -Type when provided' {
        Remove-Entity -Name 'Kupiec Orrin' -Type 'NPC' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@status:\s*Usunięty\s*\(2026-02:\)'
    }

    It 'throws when entity not found' {
        { Remove-Entity -Name 'Nieistniejący' -EntitiesFile $script:EntFile -Confirm:$false } |
            Should -Throw '*not found*'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        Remove-Entity -Name 'Kupiec Orrin' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }

    It 'soft-deletes Przedmiot entity' {
        Remove-Entity -Name 'Miecz Słońca' -Type 'Przedmiot' -ValidFrom '2026-03' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Miecz Słońca'
        $Content | Should -Match '@status:\s*Usunięty\s*\(2026-03:\)'
    }
}

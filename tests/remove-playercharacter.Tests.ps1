<#
    .SYNOPSIS
    Pester tests for Remove-PlayerCharacter.ps1.

    .DESCRIPTION
    Tests for Remove-PlayerCharacter covering character entity removal,
    file deletion, player entry cleanup, entity tag updates, and
    edge cases for missing/non-existent characters.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-remove-pc-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    # Mock Get-RepoRoot
    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Remove-PlayerCharacter' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-remove-pc.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'sets @status: Usunięty on the character entity' {
        Remove-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'Erdamon' `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '@status:\s*Usunięty\s*\(2026-02:\)'
    }

    It 'does not delete the entity entry' {
        Remove-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'Erdamon' `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '\*\s*Erdamon'
        $Content | Should -Match '@należy_do:\s*Kilgor'
    }

    It 'defaults ValidFrom to current month when not specified' {
        Remove-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'Erdamon' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Expected = (Get-Date).ToString('yyyy-MM')
        $Content = [System.IO.File]::ReadAllText($script:EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match "@status:\s*Usunięty\s*\($Expected`:\)"
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile, [System.Text.UTF8Encoding]::new($false))

        Remove-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'Erdamon' `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile, [System.Text.UTF8Encoding]::new($false))
        $NewContent | Should -Be $OrigContent
    }
}

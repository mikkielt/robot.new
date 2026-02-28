<#
    .SYNOPSIS
    Pester tests for Set-CurrencyEntity.

    .DESCRIPTION
    Tests for Set-CurrencyEntity covering absolute quantity, delta arithmetic,
    owner transfer, location assignment, mutual exclusion validation, and
    WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"
    . "$script:ModuleRoot/private/currency-helpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-set-currency-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Set-CurrencyEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-currency-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'sets absolute quantity' {
        Set-CurrencyEntity -Name 'Korony Erdamon' -Amount 75 `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@ilość:\s*75 \(2026-02:\)'
    }

    It 'applies delta to current quantity' {
        Set-CurrencyEntity -Name 'Korony Erdamon' -AmountDelta 25 `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        # 50 + 25 = 75
        $Content | Should -Match '@ilość:\s*75 \(2026-02:\)'
    }

    It 'applies negative delta' {
        Set-CurrencyEntity -Name 'Talary Erdamon' -AmountDelta -50 `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        # 200 - 50 = 150
        $Content | Should -Match '@ilość:\s*150 \(2026-02:\)'
    }

    It 'transfers ownership' {
        Set-CurrencyEntity -Name 'Korony Erdamon' -Owner 'Kupiec Orrin' `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@należy_do:\s*Kupiec Orrin \(2026-02:\)'
    }

    It 'sets location for dropped currency' {
        Set-CurrencyEntity -Name 'Korony Erdamon' -Location 'Droga Handlowa' `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Droga Handlowa \(2026-02:\)'
    }

    It 'throws when both Amount and AmountDelta are provided' {
        { Set-CurrencyEntity -Name 'Korony Erdamon' -Amount 100 -AmountDelta 10 `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Cannot specify both*'
    }

    It 'throws when both Owner and Location are provided' {
        { Set-CurrencyEntity -Name 'Korony Erdamon' -Owner 'X' -Location 'Y' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Cannot specify both*'
    }

    It 'throws when entity not found' {
        { Set-CurrencyEntity -Name 'Nonexistent' -Amount 10 `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*not found*'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        Set-CurrencyEntity -Name 'Korony Erdamon' -Amount 999 `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }

    It 'defaults ValidFrom to current month' {
        Set-CurrencyEntity -Name 'Korony Erdamon' -Amount 30 `
            -EntitiesFile $script:EntFile

        $Expected = (Get-Date).ToString('yyyy-MM')
        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match "@ilość:\s*30 \($Expected`:\)"
    }
}

<#
    .SYNOPSIS
    Pester tests for New-CurrencyEntity.

    .DESCRIPTION
    Tests for New-CurrencyEntity covering denomination validation,
    auto-generated naming, duplicate detection, template rendering,
    and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"
    . "$script:ModuleRoot/private/currency-helpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-new-currency-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'New-CurrencyEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-currency-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'creates a new currency entity with auto-generated name' {
        $Result = New-CurrencyEntity -Denomination 'Korony' -Owner 'Kupiec Orrin' `
            -Amount 100 -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Result.EntityName | Should -Be 'Korony Kupiec Orrin'
        $Result.Denomination | Should -Be 'Korony Elanckie'
        $Result.DenomShort | Should -Be 'Korony'
        $Result.Owner | Should -Be 'Kupiec Orrin'
        $Result.Amount | Should -Be 100

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Korony Kupiec Orrin'
        $Content | Should -Match '@generyczne_nazwy:\s*Korony Elanckie'
        $Content | Should -Match '@ilość:\s*100 \(2026-02:\)'
        $Content | Should -Match '@należy_do:\s*Kupiec Orrin \(2026-02:\)'
        $Content | Should -Match '@status:\s*Aktywny \(2026-02:\)'
    }

    It 'resolves denomination by stem' {
        $Result = New-CurrencyEntity -Denomination 'tal' -Owner 'Nowy Gracz' `
            -Amount 50 -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Result.Denomination | Should -Be 'Talary Hirońskie'
        $Result.EntityName | Should -Be 'Talary Nowy Gracz'
    }

    It 'throws on unknown denomination' {
        { New-CurrencyEntity -Denomination 'Złotówki' -Owner 'Test' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Unknown currency denomination*'
    }

    It 'throws on duplicate currency entity' {
        { New-CurrencyEntity -Denomination 'Korony' -Owner 'Erdamon' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*already exists*'
    }

    It 'defaults amount to 0' {
        $Result = New-CurrencyEntity -Denomination 'Kogi' -Owner 'Nowa Postać' `
            -ValidFrom '2026-02' -EntitiesFile $script:EntFile

        $Result.Amount | Should -Be 0

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@ilość:\s*0 \(2026-02:\)'
    }

    It 'defaults ValidFrom to current month' {
        New-CurrencyEntity -Denomination 'Korony' -Owner 'Test Gracz' `
            -EntitiesFile $script:EntFile

        $Expected = (Get-Date).ToString('yyyy-MM')
        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match "@ilość:\s*0 \($Expected`:\)"
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        New-CurrencyEntity -Denomination 'Korony' -Owner 'WhatIf Test' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }
}

<#
    .SYNOPSIS
    Pester tests for Remove-CurrencyEntity.

    .DESCRIPTION
    Tests for Remove-CurrencyEntity covering soft-delete, non-zero balance
    warning, default ValidFrom, entity not found, and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-remove-currency-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Remove-CurrencyEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-currency-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'sets @status: Usunięty on currency entity' {
        Remove-CurrencyEntity -Name 'Kogi Skrzynka Targowa' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@status:\s*Usunięty\s*\(2026-02:\)'
    }

    It 'preserves the entity entry' {
        Remove-CurrencyEntity -Name 'Kogi Skrzynka Targowa' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Kogi Skrzynka Targowa'
        $Content | Should -Match '@generyczne_nazwy:\s*Kogi Skeltvorskie'
    }

    It 'warns on non-zero balance' {
        # Capture stderr
        $StderrOutput = $null
        $OldErr = [System.Console]::Error
        $Writer = [System.IO.StringWriter]::new()
        [System.Console]::SetError($Writer)
        try {
            Remove-CurrencyEntity -Name 'Korony Erdamon' -ValidFrom '2026-02' `
                -EntitiesFile $script:EntFile -Confirm:$false
            $StderrOutput = $Writer.ToString()
        } finally {
            [System.Console]::SetError($OldErr)
            $Writer.Dispose()
        }

        $StderrOutput | Should -Match 'non-zero balance'
    }

    It 'does not warn when balance is zero' {
        $StderrOutput = $null
        $OldErr = [System.Console]::Error
        $Writer = [System.IO.StringWriter]::new()
        [System.Console]::SetError($Writer)
        try {
            Remove-CurrencyEntity -Name 'Kogi Skrzynka Targowa' -ValidFrom '2026-02' `
                -EntitiesFile $script:EntFile -Confirm:$false
            $StderrOutput = $Writer.ToString()
        } finally {
            [System.Console]::SetError($OldErr)
            $Writer.Dispose()
        }

        $StderrOutput | Should -Not -Match 'non-zero balance'
    }

    It 'defaults ValidFrom to current month' {
        Remove-CurrencyEntity -Name 'Kogi Skrzynka Targowa' `
            -EntitiesFile $script:EntFile -Confirm:$false

        $Expected = (Get-Date).ToString('yyyy-MM')
        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match "@status:\s*Usunięty\s*\($Expected`:\)"
    }

    It 'throws when entity not found' {
        { Remove-CurrencyEntity -Name 'Nonexistent' -EntitiesFile $script:EntFile -Confirm:$false } |
            Should -Throw '*not found*'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        Remove-CurrencyEntity -Name 'Korony Erdamon' -ValidFrom '2026-02' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }
}

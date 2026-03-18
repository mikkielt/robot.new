<#
    .SYNOPSIS
    Pester tests for Set-LocationEntity.

    .DESCRIPTION
    Tests for Set-LocationEntity covering parent update, coordinate update,
    door add/remove operations, validation, and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-set-loc-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Set-LocationEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-location-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'updates parent location' {
        Set-LocationEntity -Name 'Koszary Steadwicku' -Parent 'Droga przez Erathię' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        # Should have the new parent
        $Content | Should -Match 'Koszary Steadwicku[\s\S]*?@lokacja:\s*Droga przez Erathię'
    }

    It 'updates coordinates' {
        Set-LocationEntity -Name 'Ratusz Steadwicku' -Coordinates '30, 40' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Ratusz Steadwicku[\s\S]*?@koordynaty:\s*30, 40'
    }

    It 'updates NerthusName' {
        Set-LocationEntity -Name 'Steadwick' -NerthusName 'Nowy Steadwick' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@nazwa_nerthus:\s*Nowy Steadwick'
    }

    It 'adds door connections' {
        Set-LocationEntity -Name 'Koszary Steadwicku' -AddDoors 'Droga przez Erathię' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Koszary Steadwicku[\s\S]*?@drzwi:\s*Droga przez Erathię'
    }

    It 'removes door connections' {
        Set-LocationEntity -Name 'Steadwick' -RemoveDoors 'Ratusz Steadwicku' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        # Should still have Koszary door
        $Content | Should -Match 'Steadwick[\s\S]*?@drzwi:\s*Koszary Steadwicku'
        # Should NOT have Ratusz door
        $Lines = [System.IO.File]::ReadAllLines($script:EntFile)
        $SteadwickIdx = -1
        $RatuszDoorFound = $false
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^\*\s*Steadwick$') { $SteadwickIdx = $i }
            if ($SteadwickIdx -ge 0 -and $i -gt $SteadwickIdx -and $Lines[$i] -match '^\*\s') { break }
            if ($SteadwickIdx -ge 0 -and $Lines[$i] -match '@drzwi:\s*Ratusz Steadwicku') { $RatuszDoorFound = $true }
        }
        $RatuszDoorFound | Should -BeFalse
    }

    It 'applies ValidFrom temporal suffix to tags' {
        Set-LocationEntity -Name 'Koszary Steadwicku' -Parent 'Droga przez Erathię' `
            -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Droga przez Erathię \(2026-03:\)'
    }

    It 'applies ValidFrom to added door entries' {
        Set-LocationEntity -Name 'Koszary Steadwicku' -AddDoors 'Steadwick' `
            -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@drzwi:\s*Steadwick \(2026-03:\)'
    }

    It 'throws on non-existent parent' {
        { Set-LocationEntity -Name 'Steadwick' -Parent 'NieistniejącaLokacja' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Parent location*not found*'
    }

    It 'throws on invalid coordinate format' {
        { Set-LocationEntity -Name 'Steadwick' -Coordinates 'abc' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Invalid coordinates format*'
    }

    It 'throws on invalid coordinate values' {
        { Set-LocationEntity -Name 'Steadwick' -Coordinates 'abc, def' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*X and Y must be integers*'
    }

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        Set-LocationEntity -Name 'Steadwick' -Parent 'Droga przez Erathię' `
            -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }

    It 'supports Mapa type via -Type parameter' {
        Set-LocationEntity -Name 'Komnata Rady' -Type 'Mapa' `
            -Tags @{ info = 'Zaktualizowano' } -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@info:\s*Zaktualizowano'
    }
}

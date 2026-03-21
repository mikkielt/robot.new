<#
    .SYNOPSIS
    Pester tests for Set-MapEntity.

    .DESCRIPTION
    Tests for Set-MapEntity covering slug update with uniqueness validation,
    dimensions validation, parent validation, URL/info updates, door add/remove
    operations, temporal suffix, custom tags passthrough, and WhatIf support.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-set-map-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Set-MapEntity' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-location-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    # --- Simple tag updates ---

    It 'updates slug on existing map entity' {
        Set-MapEntity -Name 'Komnata Rady' -Slug 'nowy-slug' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@slug:\s*nowy-slug'
    }

    It 'updates parent location' {
        Set-MapEntity -Name 'Komnata Rady' -Parent 'Steadwick' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@lokacja:\s*Steadwick'
    }

    It 'updates URL' {
        Set-MapEntity -Name 'Komnata Rady' -Url 'https://cdn.example.com/new.png' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@url:\s*https://cdn.example.com/new.png'
    }

    It 'updates URL Nerthus' {
        Set-MapEntity -Name 'Komnata Rady' -UrlNerthus 'https://nerthus.example.com/new.png' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@url_nerthus:\s*https://nerthus.example.com/new.png'
    }

    It 'updates dimensions' {
        Set-MapEntity -Name 'Komnata Rady' -Dimensions '50, 40' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@wymiary:\s*50, 40'
    }

    It 'updates info description' {
        Set-MapEntity -Name 'Komnata Rady' -Info 'Nowy opis.' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@info:\s*Nowy opis\.'
    }

    It 'updates multiple properties in one call' {
        Set-MapEntity -Name 'Piwnica Ratusza' -Slug 'nowa-piwnica' `
            -Dimensions '30, 20' -Info 'Mroczna piwnica.' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@slug:\s*nowa-piwnica'
        $Content | Should -Match '@wymiary:\s*30, 20'
        $Content | Should -Match '@info:\s*Mroczna piwnica\.'
    }

    It 'passes custom -Tags through to entity' {
        Set-MapEntity -Name 'Komnata Rady' -Tags @{ custom_tag = 'test-value' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@custom_tag:\s*test-value'
    }

    # --- Slug uniqueness validation ---

    It 'throws on slug collision with another entity' {
        { Set-MapEntity -Name 'Komnata Rady' -Slug 'piwnica-ratusza' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Slug*already exists*'
    }

    It 'throws on slug collision (case-insensitive)' {
        { Set-MapEntity -Name 'Komnata Rady' -Slug 'PIWNICA-RATUSZA' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Slug*already exists*'
    }

    It 'allows updating own slug to same value (no self-collision)' {
        { Set-MapEntity -Name 'Komnata Rady' -Slug 'komnata-rady-ratusz' `
            -EntitiesFile $script:EntFile } |
            Should -Not -Throw
    }

    # --- Dimensions validation ---

    It 'throws on invalid dimensions format — single value' {
        { Set-MapEntity -Name 'Komnata Rady' -Dimensions '20' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Invalid dimensions format*'
    }

    It 'throws on invalid dimensions — non-positive' {
        { Set-MapEntity -Name 'Komnata Rady' -Dimensions '0, 15' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*positive integers*'
    }

    It 'throws on invalid dimensions — non-integer' {
        { Set-MapEntity -Name 'Komnata Rady' -Dimensions 'abc, def' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*positive integers*'
    }

    # --- Parent validation ---

    It 'throws on non-existent parent' {
        { Set-MapEntity -Name 'Komnata Rady' -Parent 'NieistniejącaLokacja' `
            -EntitiesFile $script:EntFile } |
            Should -Throw '*Parent location*not found*'
    }

    # --- Door operations ---

    It 'adds door connections' {
        Set-MapEntity -Name 'Piwnica Ratusza' -AddDoors 'Steadwick' `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Piwnica Ratusza[\s\S]*?@drzwi:\s*Steadwick'
    }

    It 'removes door connections' {
        Set-MapEntity -Name 'Komnata Rady' -RemoveDoors 'Steadwick' `
            -EntitiesFile $script:EntFile

        $Lines = [System.IO.File]::ReadAllLines($script:EntFile)
        $KomnataIdx = -1
        $DoorFound = $false
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^\*\s*Komnata Rady') { $KomnataIdx = $i }
            if ($KomnataIdx -ge 0 -and $i -gt $KomnataIdx -and $Lines[$i] -match '^\*\s') { break }
            if ($KomnataIdx -ge 0 -and $Lines[$i] -match '@drzwi:\s*Steadwick') { $DoorFound = $true }
        }
        $DoorFound | Should -BeFalse
    }

    It 'adds and removes doors in single call' {
        Set-MapEntity -Name 'Komnata Rady' -AddDoors 'Droga przez Erathię' `
            -RemoveDoors 'Steadwick' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match 'Komnata Rady[\s\S]*?@drzwi:\s*Droga przez Erathię'

        $Lines = [System.IO.File]::ReadAllLines($script:EntFile)
        $KomnataIdx = -1
        $OldDoorFound = $false
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^\*\s*Komnata Rady') { $KomnataIdx = $i }
            if ($KomnataIdx -ge 0 -and $i -gt $KomnataIdx -and $Lines[$i] -match '^\*\s') { break }
            if ($KomnataIdx -ge 0 -and $Lines[$i] -match '@drzwi:\s*Steadwick$') { $OldDoorFound = $true }
        }
        $OldDoorFound | Should -BeFalse
    }

    # --- Temporal suffix ---

    It 'applies ValidFrom temporal suffix to tags' {
        Set-MapEntity -Name 'Komnata Rady' -Parent 'Steadwick' `
            -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@lokacja:\s*Steadwick \(2026-03:\)'
    }

    It 'applies ValidFrom to added door entries' {
        Set-MapEntity -Name 'Piwnica Ratusza' -AddDoors 'Steadwick' `
            -ValidFrom '2026-03' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@drzwi:\s*Steadwick \(2026-03:\)'
    }

    # --- WhatIf ---

    It 'supports -WhatIf without modifying file' {
        $OrigContent = [System.IO.File]::ReadAllText($script:EntFile)

        Set-MapEntity -Name 'Komnata Rady' -Slug 'nowy-slug' `
            -Parent 'Steadwick' -EntitiesFile $script:EntFile -WhatIf

        $NewContent = [System.IO.File]::ReadAllText($script:EntFile)
        $NewContent | Should -Be $OrigContent
    }
}

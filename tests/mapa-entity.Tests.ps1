<#
    .SYNOPSIS
    Pester tests for Mapa entity type registration and CRUD.

    .DESCRIPTION
    Tests that "Mapa" is recognized in EntityTypeMap/TypeToHeader,
    and that New-Entity, Set-Entity, Remove-Entity accept Mapa type.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-mapa-entity-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Mapa type registration' {
    It 'EntityTypeMap recognizes "mapa" as Mapa' {
        $script:EntityTypeMap['mapa'] | Should -Be 'Mapa'
    }

    It 'EntityTypeMap recognizes "mapy" as Mapa' {
        $script:EntityTypeMap['mapy'] | Should -Be 'Mapa'
    }

    It 'TypeToHeader maps "Mapa" to "Mapa"' {
        $script:TypeToHeader['Mapa'] | Should -Be 'Mapa'
    }
}

Describe 'Invoke-EnsureEntityFile creates ## Mapa section' {
    It 'new entities file contains ## Mapa section' {
        $EntFile = Join-Path $script:TempRoot 'entities-ensure-mapa.md'
        $Result = Invoke-EnsureEntityFile -Path $EntFile
        $Content = [System.IO.File]::ReadAllText($Result)
        $Content | Should -Match '## Mapa'
    }
}

Describe 'New-Entity -Type Mapa' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-generic-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'creates a Mapa entity' {
        $Result = New-Entity -Type 'Mapa' -Name 'Komnata Rady' `
            -Tags @{ lokacja = 'Ratusz'; url = 'https://cdn.example.com/map.png' } `
            -EntitiesFile $script:EntFile

        $Result.Name | Should -Be 'Komnata Rady'
        $Result.Type | Should -Be 'Mapa'
        $Result.Created | Should -BeTrue

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Komnata Rady'
        $Content | Should -Match '@lokacja:\s*Ratusz'
        $Content | Should -Match '@url:\s*https://cdn\.example\.com/map\.png'
    }

    It 'creates Mapa entity under ## Mapa section' {
        New-Entity -Type 'Mapa' -Name 'Piwnica' -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Lines = $Content.Split("`n")
        $SectionIdx = -1
        $EntityIdx = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^## Mapa') { $SectionIdx = $i }
            if ($Lines[$i] -match '\*\s*Piwnica') { $EntityIdx = $i }
        }
        $SectionIdx | Should -BeGreaterThan -1
        $EntityIdx | Should -BeGreaterThan $SectionIdx
    }

    It 'throws on duplicate Mapa entity' {
        New-Entity -Type 'Mapa' -Name 'TestMap' -EntitiesFile $script:EntFile
        { New-Entity -Type 'Mapa' -Name 'TestMap' -EntitiesFile $script:EntFile } |
            Should -Throw '*already exists*'
    }
}

Describe 'Set-Entity -Type Mapa' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-generic-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'auto-creates Mapa entity when not found' {
        Set-Entity -Name 'Nowa Mapa' -Type 'Mapa' `
            -Tags @{ url = 'https://cdn.example.com/new.png' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '\*\s*Nowa Mapa'
        $Content | Should -Match '@url:\s*https://cdn\.example\.com/new\.png'
    }

    It 'upserts tags on existing Mapa entity' {
        New-Entity -Type 'Mapa' -Name 'MapDoUpdate' `
            -Tags @{ url = 'https://old.com/map.png' } `
            -EntitiesFile $script:EntFile

        Set-Entity -Name 'MapDoUpdate' -Type 'Mapa' `
            -Tags @{ url_nerthus = 'https://nerthus.com/map.png' } `
            -EntitiesFile $script:EntFile

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@url_nerthus:\s*https://nerthus\.com/map\.png'
    }
}

Describe 'Remove-Entity -Type Mapa' {
    BeforeEach {
        $script:EntFile = Join-Path $script:TempRoot 'entities.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-generic-crud.md'
        [System.IO.File]::Copy($FixtureSrc, $script:EntFile, $true)
    }

    It 'soft-deletes a Mapa entity' {
        New-Entity -Type 'Mapa' -Name 'MapDoRemove' -EntitiesFile $script:EntFile

        Remove-Entity -Name 'MapDoRemove' -Type 'Mapa' `
            -ValidFrom '2026-03' -EntitiesFile $script:EntFile -Confirm:$false

        $Content = [System.IO.File]::ReadAllText($script:EntFile)
        $Content | Should -Match '@status:\s*Usunięty \(2026-03:\)'
    }
}

<#
    .SYNOPSIS
    Pester tests for Przedmiot entity handling.

    .DESCRIPTION
    Tests for Przedmiot-specific entity operations covering file creation,
    tag writing (@ilość, @typ, @należy_do, @generyczne_nazwy), section
    manipulation, and Write-EntityFile round-trip for Przedmiot entities.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/private/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-przedmiot-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Przedmiot type mappings in entity-writehelpers' {
    It 'recognizes "Przedmiot" in EntityTypeMap' {
        $script:EntityTypeMap['przedmiot'] | Should -Be 'Przedmiot'
        $script:EntityTypeMap['przedmioty'] | Should -Be 'Przedmiot'
    }

    It 'has Przedmiot in TypeToHeader reverse map' {
        $script:TypeToHeader['Przedmiot'] | Should -Be 'Przedmiot'
    }
}

Describe 'Invoke-EnsureEntityFile includes Przedmiot section' {
    It 'creates entities.md with ## Przedmiot section' {
        $EntFile = Join-Path $script:TempRoot 'new-entities.md'
        if ([System.IO.File]::Exists($EntFile)) { [System.IO.File]::Delete($EntFile) }

        $Result = Invoke-EnsureEntityFile -Path $EntFile
        $Content = [System.IO.File]::ReadAllText($Result, [System.Text.UTF8Encoding]::new($false))

        $Content | Should -Match '## Przedmiot'
        $Content | Should -Match '## Gracz'
        $Content | Should -Match '## Postać'
    }
}

Describe 'Resolve-EntityTarget for Przedmiot' {
    It 'creates a Przedmiot entity with @należy_do tag' {
        $EntFile = Join-Path $script:TempRoot 'przedmiot-ent.md'
        if ([System.IO.File]::Exists($EntFile)) { [System.IO.File]::Delete($EntFile) }

        $Target = Resolve-EntityTarget -FilePath $EntFile `
            -EntityType 'Przedmiot' -EntityName 'Zaklęty miecz' `
            -InitialTags ([ordered]@{ 'należy_do' = 'Erdamon' })

        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL

        $Content = [System.IO.File]::ReadAllText($EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '\*\s*Zaklęty miecz'
        $Content | Should -Match '@należy_do:\s*Erdamon'
        $Target.Created | Should -Be $true
    }

    It 'finds existing Przedmiot entity without creating duplicate' {
        $EntFile = Join-Path $script:TempRoot 'przedmiot-existing.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-przedmiot-existing.md'
        [System.IO.File]::Copy($FixtureSrc, $EntFile, $true)

        $Target = Resolve-EntityTarget -FilePath $EntFile `
            -EntityType 'Przedmiot' -EntityName 'Istniejący Przedmiot'

        $Target.Created | Should -Be $false
        $Target.BulletIdx | Should -BeGreaterOrEqual 0
    }
}

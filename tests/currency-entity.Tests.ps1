<#
    .SYNOPSIS
    Pester tests for currency entity creation and tag updates.

    .DESCRIPTION
    Tests for currency Przedmiot entities via Resolve-EntityTarget and
    Set-EntityTag, covering creation with @ilość/@należy_do/@lokacja tags
    and in-place @ilość value updates.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-currency-" + [System.Guid]::NewGuid().ToString('N'))
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

Describe 'Currency entity creation via Resolve-EntityTarget' {
    It 'creates a currency Przedmiot with @ilość and @należy_do tags' {
        $EntFile = Join-Path $script:TempRoot 'currency-owned.md'
        if ([System.IO.File]::Exists($EntFile)) { [System.IO.File]::Delete($EntFile) }

        $Target = Resolve-EntityTarget -FilePath $EntFile `
            -EntityType 'Przedmiot' -EntityName 'Korony Elanckie' `
            -InitialTags ([ordered]@{ 'ilość' = '50'; 'należy_do' = 'Erdamon' })

        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL

        $Content = [System.IO.File]::ReadAllText($EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '\*\s*Korony Elanckie'
        $Content | Should -Match '@ilość:\s*50'
        $Content | Should -Match '@należy_do:\s*Erdamon'
        $Target.Created | Should -Be $true
    }

    It 'creates a currency Przedmiot with @ilość and @lokacja tags (dropped currency)' {
        $EntFile = Join-Path $script:TempRoot 'currency-dropped.md'
        if ([System.IO.File]::Exists($EntFile)) { [System.IO.File]::Delete($EntFile) }

        $Target = Resolve-EntityTarget -FilePath $EntFile `
            -EntityType 'Przedmiot' -EntityName 'Talary Hirońskie' `
            -InitialTags ([ordered]@{ 'ilość' = '200'; 'lokacja' = 'Erathia' })

        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL

        $Content = [System.IO.File]::ReadAllText($EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '\*\s*Talary Hirońskie'
        $Content | Should -Match '@ilość:\s*200'
        $Content | Should -Match '@lokacja:\s*Erathia'
        $Target.Created | Should -Be $true
    }

    It 'creates Kogi Skeltvorskie currency entity' {
        $EntFile = Join-Path $script:TempRoot 'currency-kogi.md'
        if ([System.IO.File]::Exists($EntFile)) { [System.IO.File]::Delete($EntFile) }

        $Target = Resolve-EntityTarget -FilePath $EntFile `
            -EntityType 'Przedmiot' -EntityName 'Kogi Skeltvorskie' `
            -InitialTags ([ordered]@{ 'ilość' = '1500'; 'należy_do' = 'Kyrre' })

        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL

        $Content = [System.IO.File]::ReadAllText($EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '\*\s*Kogi Skeltvorskie'
        $Content | Should -Match '@ilość:\s*1500'
        $Content | Should -Match '@należy_do:\s*Kyrre'
        $Target.Created | Should -Be $true
    }
}

Describe 'Currency @ilość tag update via Set-EntityTag' {
    It 'updates @ilość value on existing currency entity' {
        $EntFile = Join-Path $script:TempRoot 'currency-update.md'
        $FixtureSrc = Join-Path $PSScriptRoot 'fixtures/entities-currency-update.md'
        [System.IO.File]::Copy($FixtureSrc, $EntFile, $true)

        $Target = Resolve-EntityTarget -FilePath $EntFile `
            -EntityType 'Przedmiot' -EntityName 'Korony Elanckie'

        $Target.Created | Should -Be $false

        $NewEnd = Set-EntityTag -Lines $Target.Lines `
            -BulletIdx $Target.BulletIdx `
            -ChildrenStart $Target.ChildrenStart `
            -ChildrenEnd $Target.ChildrenEnd `
            -TagName 'ilość' -Value '75'

        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL

        $Content = [System.IO.File]::ReadAllText($EntFile, [System.Text.UTF8Encoding]::new($false))
        $Content | Should -Match '@ilość:\s*75'
        $Content | Should -Not -Match '@ilość:\s*50'
    }
}

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'entity-writehelpers.ps1')
}

Describe 'Find-EntitySection' {
    It 'finds NPC section in entities.md' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Result = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Result | Should -Not -BeNullOrEmpty
        $Result.EntityType | Should -Be 'NPC'
        $Result.HeaderIdx | Should -BeGreaterOrEqual 0
    }

    It 'finds Postać (Gracz) section' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Result = Find-EntitySection -Lines $Lines -EntityType 'Postać (Gracz)'
        $Result | Should -Not -BeNullOrEmpty
    }

    It 'returns $null for missing section' {
        $Lines = @('## NPC', '', '* Test')
        $Result = Find-EntitySection -Lines $Lines -EntityType 'Przedmiot'
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Find-EntityBullet' {
    It 'finds entity bullet by name' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Section = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Bullet = Find-EntityBullet -Lines $Lines -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName 'Kupiec Orrin'
        $Bullet | Should -Not -BeNullOrEmpty
        $Bullet.EntityName | Should -Be 'Kupiec Orrin'
    }

    It 'returns $null for non-existent entity' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Section = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Bullet = Find-EntityBullet -Lines $Lines -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName 'NONEXISTENT'
        $Bullet | Should -BeNullOrEmpty
    }

    It 'identifies children range' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Section = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Bullet = Find-EntityBullet -Lines $Lines -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName 'Kupiec Orrin'
        $Bullet.ChildrenStartIdx | Should -BeGreaterThan $Bullet.BulletIdx
        $Bullet.ChildrenEndIdx | Should -BeGreaterThan $Bullet.ChildrenStartIdx
    }
}

Describe 'Find-EntityTag' {
    It 'finds @alias tag in entity children' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Section = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Bullet = Find-EntityBullet -Lines $Lines -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName 'Kupiec Orrin'
        $Tag = Find-EntityTag -Lines $Lines -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'alias'
        $Tag | Should -Not -BeNullOrEmpty
        $Tag.Tag | Should -Be 'alias'
    }

    It 'returns $null for missing tag' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Section = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Bullet = Find-EntityBullet -Lines $Lines -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName 'Kupiec Orrin'
        $Tag = Find-EntityTag -Lines $Lines -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'nonexistent_tag'
        $Tag | Should -BeNullOrEmpty
    }
}

Describe 'Set-EntityTag' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'adds a new tag when it does not exist' {
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@('## Gracz', '', '* Kilgor'))
        $ChildEnd = Set-EntityTag -Lines $Lines -BulletIdx 2 -ChildrenStart 3 -ChildrenEnd 3 -TagName 'margonemid' -Value '12345'
        $ChildEnd | Should -Be 4
        $Lines[3] | Should -BeLike '*@margonemid: 12345*'
    }

    It 'updates existing tag' {
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@('## Gracz', '', '* Kilgor', '    - @margonemid: 12345'))
        $ChildEnd = Set-EntityTag -Lines $Lines -BulletIdx 2 -ChildrenStart 3 -ChildrenEnd 4 -TagName 'margonemid' -Value '99999'
        $Lines[3] | Should -BeLike '*@margonemid: 99999*'
    }
}

Describe 'New-EntityBullet' {
    It 'creates entity bullet with tags' {
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@('## Gracz', ''))
        $End = New-EntityBullet -Lines $Lines -SectionEnd 2 -EntityName 'NewPlayer' -Tags @{ 'margonemid' = '111' }
        $Lines | Should -Contain '* NewPlayer'
        ($Lines -match '@margonemid: 111') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Ensure-EntityFile' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates file with standard sections if missing' {
        $Path = Join-Path $script:TempDir 'new-entities.md'
        $Result = Ensure-EntityFile -Path $Path
        $Result | Should -Be $Path
        [System.IO.File]::Exists($Path) | Should -BeTrue
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*## Gracz*'
        $Content | Should -BeLike '*## Postać (Gracz)*'
    }

    It 'returns existing file path without modification' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md'
        $Before = [System.IO.File]::ReadAllText($Path)
        $Result = Ensure-EntityFile -Path $Path
        $After = [System.IO.File]::ReadAllText($Path)
        $After | Should -Be $Before
    }
}

Describe 'Resolve-EntityTarget' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates new entity in existing file' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md'
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'Gracz' -EntityName 'NewGracz'
        $Result.Created | Should -BeTrue
        $Result.Lines | Should -Not -BeNullOrEmpty
    }

    It 'finds existing entity without creating' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-find.md'
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'NPC' -EntityName 'Kupiec Orrin'
        $Result.Created | Should -BeFalse
    }
}

Describe 'Write-EntityFile and Read-EntityFile' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'round-trips content through write and read' {
        $Path = Join-Path $script:TempDir 'roundtrip.md'
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@('## Test', '', '* Entity', '    - @tag: value'))
        Write-EntityFile -Path $Path -Lines $Lines
        $Read = Read-EntityFile -Path $Path
        $Read.Lines.Count | Should -Be 4
        $Read.Lines[2] | Should -Be '* Entity'
    }
}

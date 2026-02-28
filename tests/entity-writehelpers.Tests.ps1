<#
    .SYNOPSIS
    Pester tests for entity-writehelpers.ps1.

    .DESCRIPTION
    Tests for Find-EntitySection, Find-EntityBullet, Find-EntityTag,
    Set-EntityTag, New-EntityBullet, ConvertFrom-EntityTemplate,
    Invoke-EnsureEntityFile, Resolve-EntityTarget,
    Write-EntityFile, Read-EntityFile, and ConvertTo-EntitiesFromPlayers
    covering entity file manipulation and player-to-entity conversion.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'entity-writehelpers.ps1')
}

Describe 'Find-EntitySection' {
    It 'finds NPC section in entities.md' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Result = Find-EntitySection -Lines $Lines -EntityType 'NPC'
        $Result | Should -Not -BeNullOrEmpty
        $Result.EntityType | Should -Be 'NPC'
        $Result.HeaderIdx | Should -BeGreaterOrEqual 0
    }

    It 'finds Postać section' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'entities.md'))
        $Result = Find-EntitySection -Lines $Lines -EntityType 'Postać'
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
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart 3 -ChildrenEnd 3 -TagName 'margonemid' -Value '12345'
        $ChildEnd | Should -Be 4
        $Lines[3] | Should -BeLike '*@margonemid: 12345*'
    }

    It 'updates existing tag' {
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@('## Gracz', '', '* Kilgor', '    - @margonemid: 12345'))
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart 3 -ChildrenEnd 4 -TagName 'margonemid' -Value '99999'
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

Describe 'ConvertFrom-EntityTemplate' {
    It 'parses entity name and tags from rendered template' {
        $Content = "* TestChar`n    - @należy_do: TestPlayer`n    - @pu_startowe: 20"
        $Result = ConvertFrom-EntityTemplate -Content $Content
        $Result.Name | Should -Be 'TestChar'
        $Result.Tags['należy_do'] | Should -Be 'TestPlayer'
        $Result.Tags['pu_startowe'] | Should -Be '20'
    }

    It 'handles multiple values for same tag' {
        $Content = "* MultiTag`n    - @alias: Foo`n    - @alias: Bar"
        $Result = ConvertFrom-EntityTemplate -Content $Content
        $Result.Name | Should -Be 'MultiTag'
        $Result.Tags['alias'].Count | Should -Be 2
        $Result.Tags['alias'][0] | Should -Be 'Foo'
        $Result.Tags['alias'][1] | Should -Be 'Bar'
    }

    It 'handles template with no tags' {
        $Content = "* NameOnly"
        $Result = ConvertFrom-EntityTemplate -Content $Content
        $Result.Name | Should -Be 'NameOnly'
        $Result.Tags.Count | Should -Be 0
    }

    It 'handles CRLF line endings' {
        $Content = "* CRLFTest`r`n    - @tag1: val1`r`n    - @tag2: val2"
        $Result = ConvertFrom-EntityTemplate -Content $Content
        $Result.Name | Should -Be 'CRLFTest'
        $Result.Tags.Count | Should -Be 2
    }
}

Describe 'Invoke-EnsureEntityFile' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates file with all six standard sections if missing' {
        $Path = Join-Path $script:TempDir 'new-entities.md'
        $Result = Invoke-EnsureEntityFile -Path $Path
        $Result | Should -Be $Path
        [System.IO.File]::Exists($Path) | Should -BeTrue
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*## Gracz*'
        $Content | Should -BeLike '*## Postać*'
        $Content | Should -BeLike '*## Przedmiot*'
        $Content | Should -BeLike '*## NPC*'
        $Content | Should -BeLike '*## Organizacja*'
        $Content | Should -BeLike '*## Lokacja*'
    }

    It 'returns existing file path without modification' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md'
        $Before = [System.IO.File]::ReadAllText($Path)
        $Result = Invoke-EnsureEntityFile -Path $Path
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

Describe 'ConvertTo-EntitiesFromPlayers' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'generates Gracz and Postać sections' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = 'kilgor123'
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @(
                    [PSCustomObject]@{
                        Name           = 'Xeron'
                        Aliases        = @()
                        PUStart        = $null
                        PUExceeded     = $null
                        PUSum          = 10
                        PUTaken        = 5
                        AdditionalInfo = @()
                    }
                )
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-from-players.md'
        $Result = ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Result | Should -Be $OutputPath
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*## Gracz*'
        $Content | Should -BeLike '*Kilgor*'
        $Content | Should -BeLike '*@margonemid: kilgor123*'
        $Content | Should -BeLike '*## Postać*'
        $Content | Should -BeLike '*Xeron*'
        $Content | Should -BeLike '*@należy_do: Kilgor*'
        $Content | Should -BeLike '*@pu_suma: 10*'
        $Content | Should -BeLike '*@pu_zdobyte: 5*'
    }

    It 'writes player PRFWebhook when present' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = 'https://discord.com/api/webhooks/111/abc'
                Triggers     = @()
                Characters   = @()
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-webhook.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*@prfwebhook: https://discord.com/api/webhooks/111/abc*'
    }

    It 'writes triggers when present' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @('trigger1', 'trigger2')
                Characters   = @()
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-triggers.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*@trigger: trigger1*'
        $Content | Should -BeLike '*@trigger: trigger2*'
    }

    It 'writes character aliases' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @(
                    [PSCustomObject]@{
                        Name           = 'Xeron'
                        Aliases        = @('Xe', 'Demon Lord')
                        PUStart        = $null
                        PUExceeded     = $null
                        PUSum          = $null
                        PUTaken        = $null
                        AdditionalInfo = @()
                    }
                )
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-aliases.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*@alias: Xe*'
        $Content | Should -BeLike '*@alias: Demon Lord*'
    }

    It 'writes PU start and exceeded values' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @(
                    [PSCustomObject]@{
                        Name           = 'Xeron'
                        Aliases        = @()
                        PUStart        = 5
                        PUExceeded     = 2
                        PUSum          = $null
                        PUTaken        = $null
                        AdditionalInfo = @()
                    }
                )
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-pu.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*@pu_startowe: 5*'
        $Content | Should -BeLike '*@pu_nadmiar: 2*'
    }

    It 'writes additional info' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @(
                    [PSCustomObject]@{
                        Name           = 'Xeron'
                        Aliases        = @()
                        PUStart        = $null
                        PUExceeded     = $null
                        PUSum          = $null
                        PUTaken        = $null
                        AdditionalInfo = @('Note 1', 'Note 2')
                    }
                )
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-info.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*@info: Note 1*'
        $Content | Should -BeLike '*@info: Note 2*'
    }

    It 'skips players with empty names' {
        $Players = @(
            [PSCustomObject]@{
                Name         = ''
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @()
            }
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @()
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-skip-empty.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*Kilgor*'
        # Only one "* " bullet under Gracz section
        $Matches = [regex]::Matches($Content, '^\* \w', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $Matches.Count | Should -Be 1
    }

    It 'does not write pu_nadmiar when value is 0' {
        $Players = @(
            [PSCustomObject]@{
                Name         = 'Kilgor'
                MargonemID   = $null
                PRFWebhook   = $null
                Triggers     = @()
                Characters   = @(
                    [PSCustomObject]@{
                        Name           = 'Xeron'
                        Aliases        = @()
                        PUStart        = $null
                        PUExceeded     = 0
                        PUSum          = 10
                        PUTaken        = $null
                        AdditionalInfo = @()
                    }
                )
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-no-exceed.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -Not -BeLike '*@pu_nadmiar*'
    }

    It 'handles multiple players with multiple characters' {
        $Players = @(
            [PSCustomObject]@{
                Name = 'Kilgor'; MargonemID = $null; PRFWebhook = $null; Triggers = @()
                Characters = @(
                    [PSCustomObject]@{ Name = 'Xeron'; Aliases = @(); PUStart = $null; PUExceeded = $null; PUSum = 10; PUTaken = 5; AdditionalInfo = @() }
                    [PSCustomObject]@{ Name = 'Erdamon'; Aliases = @(); PUStart = $null; PUExceeded = $null; PUSum = 8; PUTaken = 3; AdditionalInfo = @() }
                )
            }
            [PSCustomObject]@{
                Name = 'Solmyr'; MargonemID = $null; PRFWebhook = $null; Triggers = @()
                Characters = @(
                    [PSCustomObject]@{ Name = 'Dracon'; Aliases = @(); PUStart = $null; PUExceeded = $null; PUSum = 15; PUTaken = 7; AdditionalInfo = @() }
                )
            }
        )
        $OutputPath = Join-Path $script:TempDir 'ent-multi.md'
        ConvertTo-EntitiesFromPlayers -OutputPath $OutputPath -Players $Players
        $Content = [System.IO.File]::ReadAllText($OutputPath)
        $Content | Should -BeLike '*Kilgor*'
        $Content | Should -BeLike '*Solmyr*'
        $Content | Should -BeLike '*Xeron*'
        $Content | Should -BeLike '*Erdamon*'
        $Content | Should -BeLike '*Dracon*'
    }
}

Describe 'Resolve-EntityTarget - additional coverage' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates entity with initial tags' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-tags.md'
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'Gracz' -EntityName 'NewPlayer' `
            -InitialTags @{ 'status' = 'Aktywny' }
        $Result.Created | Should -BeTrue
        $Content = $Result.Lines -join "`n"
        $Content | Should -BeLike '*NewPlayer*'
        $Content | Should -BeLike '*@status: Aktywny*'
    }

    It 'creates file when it does not exist' {
        $Path = Join-Path $script:TempDir 'new-entity-file.md'
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'Gracz' -EntityName 'TestPlayer'
        $Result.Created | Should -BeTrue
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }

    It 'creates section when entity type does not exist in file' {
        $Path = Join-Path $script:TempDir 'ent-nosection.md'
        [System.IO.File]::WriteAllText($Path, "## Gracz`n`n* ExistingPlayer`n")
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'Przedmiot' -EntityName 'NewItem'
        $Result.Created | Should -BeTrue
        $Content = $Result.Lines -join "`n"
        $Content | Should -BeLike '*## Przedmiot*'
        $Content | Should -BeLike '*NewItem*'
    }

    It 'inserts blank line before entity when previous line is not blank' {
        $Path = Join-Path $script:TempDir 'ent-noblank.md'
        [System.IO.File]::WriteAllText($Path, "## Gracz`n* ExistingPlayer`n    - @status: Aktywny")
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'Gracz' -EntityName 'AnotherPlayer' `
            -InitialTags ([ordered]@{ 'status' = 'Aktywny' })
        $Result.Created | Should -BeTrue
        $Content = $Result.Lines -join "`n"
        $Content | Should -BeLike '*AnotherPlayer*'
    }

    It 'uses unknown type as header text when not in TypeToHeader mapping' {
        $Path = Join-Path $script:TempDir 'ent-unknowntype.md'
        [System.IO.File]::WriteAllText($Path, "## Gracz`n`n")
        $Result = Resolve-EntityTarget -FilePath $Path -EntityType 'CustomType' -EntityName 'CustomEntity'
        $Result.Created | Should -BeTrue
        $Content = $Result.Lines -join "`n"
        $Content | Should -BeLike '*## CustomType*'
    }
}

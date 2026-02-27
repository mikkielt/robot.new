BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'get-newplayercharacterpucount.ps1')
    . (Join-Path $script:ModuleRoot 'new-playercharacter.ps1')
}

Describe 'New-PlayerCharacter' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates character entity entry in entities.md' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-newpc.md'
        # Also need templates dir for character file creation
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'templates/player-character-file.md.template'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:TempRoot 'templates')
        }}

        $Result = New-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'NewHero' -InitialPUStart 20 -EntitiesFile $Path -NoCharacterFile
        $Result | Should -Not -BeNullOrEmpty
        $Result.CharacterName | Should -Be 'NewHero'
        $Result.PUStart | Should -Be 20

        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*NewHero*'
        $Content | Should -BeLike '*@należy_do: Kilgor*'
        $Content | Should -BeLike '*@pu_startowe: 20*'
    }

    It 'throws if character already exists' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-dup.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        { New-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' -InitialPUStart 20 -EntitiesFile $Path -NoCharacterFile } |
            Should -Throw '*already exists*'
    }

    It 'creates player entry if player does not exist' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-newplayer-pc.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Result = New-PlayerCharacter -PlayerName 'BrandNewPlayer' -CharacterName 'BrandNewChar' -InitialPUStart 25 -EntitiesFile $Path -NoCharacterFile
        $Result.PlayerCreated | Should -BeTrue
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*BrandNewPlayer*'
    }
}

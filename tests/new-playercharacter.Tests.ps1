<#
    .SYNOPSIS
    Pester tests for new-playercharacter.ps1.

    .DESCRIPTION
    Tests for New-PlayerCharacter covering character entity creation,
    charfile scaffolding, PU computation, player validation, existing
    character detection, and file output correctness.
#>

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

    It 'creates character file from template when NoCharacterFile is not set' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-withfile.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'templates/player-character-file.md.template'
        $CharsDir = Join-Path $script:TempRoot 'Postaci' 'Gracze'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = $CharsDir
            TemplatesDir = (Join-Path $script:TempRoot 'templates')
        }}

        New-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'FileHero' -InitialPUStart 20 -EntitiesFile $Path -CharacterSheetUrl 'https://example.com/sheet'
        $CharFile = Join-Path $CharsDir 'FileHero.md'
        [System.IO.File]::Exists($CharFile) | Should -BeTrue
        $FileContent = [System.IO.File]::ReadAllText($CharFile)
        $FileContent | Should -BeLike '*https://example.com/sheet*'
    }

    It 'defaults PU to 20 when Get-NewPlayerCharacterPUCount fails' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-defaultpu.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}
        Mock Get-NewPlayerCharacterPUCount { throw 'Not available' }

        $Result = New-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'DefaultPUChar' -EntitiesFile $Path -NoCharacterFile
        $Result.PUStart | Should -Be 20
    }

    It 'applies initial Condition to character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-cond.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'templates/player-character-file.md.template'
        $CharsDir = Join-Path $script:TempRoot 'Postaci' 'Gracze'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = $CharsDir
            TemplatesDir = (Join-Path $script:TempRoot 'templates')
        }}

        New-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'CondChar' -InitialPUStart 20 -EntitiesFile $Path -Condition 'Ranny.'
        $CharFile = Join-Path $CharsDir 'CondChar.md'
        $FileContent = [System.IO.File]::ReadAllText($CharFile)
        $FileContent | Should -BeLike '*Ranny.*'
    }

    It 'applies initial SpecialItems to character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-items.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'templates/player-character-file.md.template'
        $CharsDir = Join-Path $script:TempRoot 'Postaci' 'Gracze'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = $CharsDir
            TemplatesDir = (Join-Path $script:TempRoot 'templates')
        }}

        New-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'ItemChar' -InitialPUStart 20 -EntitiesFile $Path -SpecialItems @('Magic Sword', 'Shield')
        $CharFile = Join-Path $CharsDir 'ItemChar.md'
        $FileContent = [System.IO.File]::ReadAllText($CharFile)
        $FileContent | Should -BeLike '*Magic Sword*'
        $FileContent | Should -BeLike '*Shield*'
    }

    It 'applies initial AdditionalNotes to character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-notes.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'templates/player-character-file.md.template'
        $CharsDir = Join-Path $script:TempRoot 'Postaci' 'Gracze'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = $CharsDir
            TemplatesDir = (Join-Path $script:TempRoot 'templates')
        }}

        New-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'NoteChar' -InitialPUStart 20 -EntitiesFile $Path -AdditionalNotes @('Special note')
        $CharFile = Join-Path $CharsDir 'NoteChar.md'
        $FileContent = [System.IO.File]::ReadAllText($CharFile)
        $FileContent | Should -BeLike '*Special note*'
    }
}

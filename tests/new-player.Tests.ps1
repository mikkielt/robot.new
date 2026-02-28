<#
    .SYNOPSIS
    Pester tests for new-player.ps1.

    .DESCRIPTION
    Tests for New-Player covering player directory creation, Gracze.md
    entry generation, existing player detection, entity creation,
    PU defaults, and Discord ID formatting.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-newplayercharacterpucount.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'new-playercharacter.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'new-player.ps1')
}

Describe 'New-Player' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates player entry in entities.md' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Result = New-Player -Name 'FreshPlayer' -MargonemID '77777' -EntitiesFile $Path
        $Result | Should -Not -BeNullOrEmpty
        $Result.PlayerName | Should -Be 'FreshPlayer'

        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*FreshPlayer*'
        $Content | Should -BeLike '*@margonemid: 77777*'
    }

    It 'throws if player already exists' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-dup-np.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        { New-Player -Name 'Solmyr' -EntitiesFile $Path } |
            Should -Throw '*already exists*'
    }

    It 'validates webhook URL format' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-wh.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        { New-Player -Name 'WH-Player' -PRFWebhook 'http://bad-url.com' -EntitiesFile $Path } |
            Should -Throw '*Invalid webhook URL*'
    }

    It 'creates player with valid webhook' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-goodwh.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Webhook = 'https://discord.com/api/webhooks/123/valid-token'
        $Result = New-Player -Name 'WHPlayer' -PRFWebhook $Webhook -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike "*$Webhook*"
    }

    It 'creates player with triggers' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-triggers.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        New-Player -Name 'TriggerPlayer' -Triggers @('violence', 'darkness') -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@trigger: violence*'
        $Content | Should -BeLike '*@trigger: darkness*'
    }

    It 'creates character when CharacterName is provided' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-withchar.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Result = New-Player -Name 'CharPlayer' -CharacterName 'TestHero' -EntitiesFile $Path
        $Result.PlayerName | Should -Be 'CharPlayer'
        $Result.CharacterName | Should -Be 'TestHero'
    }

    It 'creates character with CharacterSheetUrl parameter' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-sheet.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Result = New-Player -Name 'SheetPlayer' -CharacterName 'SheetHero' `
            -CharacterSheetUrl 'https://example.com/sheet' -EntitiesFile $Path
        $Result.CharacterName | Should -Be 'SheetHero'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*SheetHero*'
    }

    It 'creates character with InitialPUStart' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-pu.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Result = New-Player -Name 'PUPlayer' -CharacterName 'PUHero' `
            -InitialPUStart 15 -EntitiesFile $Path
        $Result.CharacterName | Should -Be 'PUHero'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@pu_startowe: 15*'
    }

    It 'creates character with NoCharacterFile flag' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-nofile.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        $Result = New-Player -Name 'NoFilePlayer' -CharacterName 'NoFileHero' `
            -NoCharacterFile -EntitiesFile $Path
        $Result.CharacterName | Should -Be 'NoFileHero'
        # Character file should not be created
        $CharFile = Join-Path $script:TempRoot 'Postaci' 'Gracze' 'NoFileHero.md'
        [System.IO.File]::Exists($CharFile) | Should -BeFalse
    }

    It 'uses config EntitiesFile when not passed as parameter' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-np-configpath.md'
        Mock Get-AdminConfig { return @{
            RepoRoot = $script:TempRoot
            ModuleRoot = $script:ModuleRoot
            EntitiesFile = $Path
            CharactersDir = (Join-Path $script:TempRoot 'Postaci' 'Gracze')
            TemplatesDir = (Join-Path $script:FixturesRoot 'templates')
        }}

        # Don't pass -EntitiesFile; should use config
        $Result = New-Player -Name 'ConfigPathPlayer'
        $Result.PlayerName | Should -Be 'ConfigPathPlayer'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*ConfigPathPlayer*'
    }
}

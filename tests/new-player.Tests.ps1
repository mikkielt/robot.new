BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'get-newplayercharacterpucount.ps1')
    . (Join-Path $script:ModuleRoot 'new-player.ps1')
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
}

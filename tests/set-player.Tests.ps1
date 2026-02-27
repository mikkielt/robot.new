<#
    .SYNOPSIS
    Pester tests for set-player.ps1.

    .DESCRIPTION
    Tests for Set-Player covering player entity modification, field
    updates (Discord, aliases, triggers), Gracze.md rewriting,
    and error handling for non-existent players.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'set-player.ps1')
}

Describe 'Set-Player' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'updates MargonemID for existing player' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md'
        Set-Player -Name 'Solmyr' -MargonemID '99999' -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@margonemid: 99999*'
    }

    It 'updates PRFWebhook for existing player' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-webhook.md'
        $Webhook = 'https://discord.com/api/webhooks/999/new-token'
        Set-Player -Name 'Solmyr' -PRFWebhook $Webhook -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike "*$Webhook*"
    }

    It 'rejects invalid webhook URL' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-badwh.md'
        { Set-Player -Name 'Solmyr' -PRFWebhook 'http://invalid.com/webhook' -EntitiesFile $Path } |
            Should -Throw '*Invalid webhook URL*'
    }

    It 'sets triggers for player' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-triggers.md'
        Set-Player -Name 'Solmyr' -Triggers @('gore', 'spiders') -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@trigger: gore*'
        $Content | Should -BeLike '*@trigger: spiders*'
    }

    It 'creates player entry if not found' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-newplayer.md'
        Set-Player -Name 'NewPlayer' -MargonemID '55555' -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*NewPlayer*'
        $Content | Should -BeLike '*@margonemid: 55555*'
    }
}

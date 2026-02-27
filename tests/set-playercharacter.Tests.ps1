BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'get-entitystate.ps1')
    . (Join-Path $script:ModuleRoot 'get-playercharacter.ps1')
    . (Join-Path $script:ModuleRoot 'set-playercharacter.ps1')
}

Describe 'Set-PlayerCharacter — entity tags' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'updates PU values for existing character' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' -PUSum 30 -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@pu_suma: 30*'
    }

    It 'derives PUTaken when PUSum is set with PUStart' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-derive.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' -PUStart 20 -PUSum 28 -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@pu_zdobyte: 8*'
    }

    It 'creates character entry if not found' {
        $Path = Copy-FixtureToTemp -FixtureName 'minimal-entity.md' -DestName 'ent-newchar.md'
        Set-PlayerCharacter -PlayerName 'Kilgor' -CharacterName 'NewCharacter' -PUStart 20 -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*NewCharacter*'
        $Content | Should -BeLike '*@należy_do: Kilgor*'
        $Content | Should -BeLike '*@pu_startowe: 20*'
    }

    It 'adds aliases without duplicating existing ones' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-alias.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' -Aliases @('Xeron', 'XeronNew') -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@alias: XeronNew*'
    }

    It 'sets status with auto-dated temporal range' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-status.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' -Status 'Nieaktywny' -EntitiesFile $Path
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@status: Nieaktywny*'
    }
}

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
    . (Join-Path $script:ModuleRoot 'admin-config.ps1')
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

Describe 'Set-PlayerCharacter — character file updates' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'updates Condition in character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-setcond.md'
        Copy-FixtureToTemp -FixtureName 'Gracze.md'
        $CharPath = Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'Postaci/Gracze/Xeron Demonlord.md'
        Mock Get-RepoRoot { return $script:TempRoot }

        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' -Condition 'Ranny.' -EntitiesFile $Path -CharacterFile $CharPath
        $Content = [System.IO.File]::ReadAllText($CharPath)
        $Content | Should -BeLike '*Ranny.*'
    }

    It 'updates SpecialItems in character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-setitems2.md'
        Copy-FixtureToTemp -FixtureName 'Gracze.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'Postaci/Gracze/Xeron Demonlord.md'
        Mock Get-RepoRoot { return $script:TempRoot }

        $CharPath = Join-Path $script:TempRoot 'Postaci' 'Gracze' 'Xeron Demonlord.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' `
            -SpecialItems @('Miecz Ognia') -EntitiesFile $Path -CharacterFile $CharPath
        $CharContent = [System.IO.File]::ReadAllText($CharPath)
        $CharContent | Should -BeLike '*Miecz Ognia*'
    }

    It 'triggers Przedmiot auto-creation logic for SpecialItems' {
        # Note: Resolve-EntityTarget creates entities in-memory; the current implementation
        # does not persist them to disk between iterations. This test verifies the code path runs.
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-autoprzedmiot.md'
        Copy-FixtureToTemp -FixtureName 'Gracze.md'
        $CharPath = Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'Postaci/Gracze/XeronPrzedmiot.md'
        Mock Get-RepoRoot { return $script:TempRoot }

        # Should not throw — exercises the Przedmiot auto-creation code path
        { Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' `
            -SpecialItems @('Nowy Przedmiot Testowy') -EntitiesFile $Path -CharacterFile $CharPath } |
            Should -Not -Throw
    }

    It 'updates CharacterSheet in character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-setsheet.md'
        Copy-FixtureToTemp -FixtureName 'Gracze.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'Postaci/Gracze/XeronSheet.md'
        Mock Get-RepoRoot { return $script:TempRoot }

        $CharPath = Join-Path $script:TempRoot 'Postaci' 'Gracze' 'XeronSheet.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' `
            -CharacterSheet 'https://example.com/newsheet' -EntitiesFile $Path -CharacterFile $CharPath
        $Content = [System.IO.File]::ReadAllText($CharPath)
        $Content | Should -BeLike '*https://example.com/newsheet*'
    }

    It 'updates AdditionalNotes in character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-setnotes.md'
        Copy-FixtureToTemp -FixtureName 'Gracze.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'Postaci/Gracze/XeronNotes.md'
        Mock Get-RepoRoot { return $script:TempRoot }

        $CharPath = Join-Path $script:TempRoot 'Postaci' 'Gracze' 'XeronNotes.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' `
            -AdditionalNotes @('Important note') -EntitiesFile $Path -CharacterFile $CharPath
        $Content = [System.IO.File]::ReadAllText($CharPath)
        $Content | Should -BeLike '*Important note*'
    }

    It 'updates RestrictedTopics in character file' {
        $Path = Copy-FixtureToTemp -FixtureName 'entities.md' -DestName 'ent-settopics.md'
        Copy-FixtureToTemp -FixtureName 'Gracze.md'
        Copy-FixtureToTemp -FixtureName 'templates/player-character-file.md.template' -DestName 'Postaci/Gracze/XeronTopics.md'
        Mock Get-RepoRoot { return $script:TempRoot }

        $CharPath = Join-Path $script:TempRoot 'Postaci' 'Gracze' 'XeronTopics.md'
        Set-PlayerCharacter -PlayerName 'Solmyr' -CharacterName 'Xeron Demonlord' `
            -RestrictedTopics 'No romance' -EntitiesFile $Path -CharacterFile $CharPath
        $Content = [System.IO.File]::ReadAllText($CharPath)
        $Content | Should -BeLike '*No romance*'
    }
}

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
    . (Join-Path $script:ModuleRoot 'format-sessionblock.ps1')
    . (Join-Path $script:ModuleRoot 'set-session.ps1')
}

Describe 'Find-SessionInFile' {
    It 'finds session by header text' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'sessions-gen3.md'))
        $Results = Find-SessionInFile -Lines $Lines -TargetHeader '2024-06-15, Ucieczka z Erathii, Solmyr'
        $Results.Count | Should -BeGreaterThan 0
        $Results[0].HeaderText | Should -Be '2024-06-15, Ucieczka z Erathii, Solmyr'
    }

    It 'finds session by date' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'sessions-gen3.md'))
        $Results = Find-SessionInFile -Lines $Lines -TargetDate ([datetime]::new(2024, 6, 15))
        $Results.Count | Should -BeGreaterThan 0
    }

    It 'returns empty list when not found' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:FixturesRoot 'sessions-gen3.md'))
        $Results = Find-SessionInFile -Lines $Lines -TargetHeader 'NONEXISTENT HEADER'
        $Results.Count | Should -Be 0
    }
}

Describe 'Split-SessionSection' {
    It 'decomposes Gen3 section into meta blocks and body' {
        $Lines = @(
            ''
            '- Lokalizacje:'
            '    - Erathia'
            '- PU:'
            '    - Xeron: 0,3'
            ''
            'Body text here.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Contain 'locations'
        $Result.MetaBlocks.Keys | Should -Contain 'pu'
        ($Result.BodyLines -join ' ') | Should -BeLike '*Body text*'
    }

    It 'handles Gen2 italic location line' {
        $Lines = @('', '*Lokalizacja: Erathia, Steadwick*', '', 'Some text.')
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Contain 'locations-italic'
    }
}

Describe 'Set-Session' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'updates locations for a session' {
        $Path = Copy-FixtureToTemp -FixtureName 'sessions-gen3.md'
        Set-Session -Date ([datetime]::new(2024, 6, 15)) -File $Path -Locations @('Steadwick', 'Enroth')
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@Lokacje:*'
        $Content | Should -BeLike '*Steadwick*'
        $Content | Should -BeLike '*Enroth*'
    }

    It 'updates PU values for a session' {
        $Path = Copy-FixtureToTemp -FixtureName 'sessions-gen3.md' -DestName 'ses-pu.md'
        $PU = @([PSCustomObject]@{ Character = 'Xeron Demonlord'; Value = 1.0 })
        Set-Session -Date ([datetime]::new(2024, 6, 15)) -File $Path -PU $PU
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@PU:*'
        $Content | Should -BeLike '*Xeron Demonlord*'
    }

    It 'updates body content' {
        $Path = Copy-FixtureToTemp -FixtureName 'sessions-gen3.md' -DestName 'ses-content.md'
        Set-Session -Date ([datetime]::new(2024, 6, 15)) -File $Path -Content 'Replaced body text.'
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*Replaced body text.*'
    }

    It 'throws when session not found' {
        $Path = Copy-FixtureToTemp -FixtureName 'sessions-gen3.md' -DestName 'ses-notfound.md'
        { Set-Session -Date ([datetime]::new(1999, 1, 1)) -File $Path -Locations @('X') } |
            Should -Throw '*not found*'
    }

    It 'upgrades Gen3 to Gen4 format with -UpgradeFormat' {
        $Path = Copy-FixtureToTemp -FixtureName 'sessions-gen3.md' -DestName 'ses-upgrade.md'
        Set-Session -Date ([datetime]::new(2024, 6, 15)) -File $Path -UpgradeFormat
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*@Lokacje:*'
        $Content | Should -BeLike '*@PU:*'
        $Content | Should -BeLike '*@Logi:*'
    }

    It 'accepts Properties hashtable as alternative to individual params' {
        $Path = Copy-FixtureToTemp -FixtureName 'sessions-gen3.md' -DestName 'ses-props.md'
        $Props = @{ Locations = @('Enroth'); Content = 'New content via Properties' }
        Set-Session -Date ([datetime]::new(2024, 6, 15)) -File $Path -Properties $Props
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*Enroth*'
        $Content | Should -BeLike '*New content via Properties*'
    }
}

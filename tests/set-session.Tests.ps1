<#
    .SYNOPSIS
    Pester tests for set-session.ps1.

    .DESCRIPTION
    Tests for Find-SessionInFile and Set-Session covering session
    lookup by header text, content replacement, multi-file session
    updates, and Gen3/Gen4 format compatibility.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'format-sessionblock.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'set-session.ps1')
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

Describe 'ConvertFrom-ItalicLocation' {
    It 'converts italic location line to Gen4 block' {
        $Result = ConvertFrom-ItalicLocation -Line '*Lokalizacja: Erathia, Steadwick*' -NL "`n"
        $Result | Should -Not -BeNullOrEmpty
        $Result | Should -BeLike '*@Lokacje:*'
        $Result | Should -BeLike '*Erathia*'
        $Result | Should -BeLike '*Steadwick*'
    }

    It 'handles Lokalizacje variant' {
        $Result = ConvertFrom-ItalicLocation -Line '*Lokalizacje: Enroth*' -NL "`n"
        $Result | Should -Not -BeNullOrEmpty
        $Result | Should -BeLike '*Enroth*'
    }

    It 'returns null for non-matching line' {
        $Result = ConvertFrom-ItalicLocation -Line 'Not an italic location line' -NL "`n"
        $Result | Should -BeNullOrEmpty
    }

    It 'returns null for empty location content' {
        $Result = ConvertFrom-ItalicLocation -Line '*Lokalizacja: *' -NL "`n"
        # The regex might not match or returns null items
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-PlainTextLog' {
    It 'extracts URL from plain text log line' {
        $Result = ConvertFrom-PlainTextLog -Lines @('Logi: https://example.com/log1') -NL "`n"
        $Result | Should -Not -BeNullOrEmpty
        $Result | Should -BeLike '*@Logi:*'
        $Result | Should -BeLike '*https://example.com/log1*'
    }

    It 'handles multiple log lines' {
        $Result = ConvertFrom-PlainTextLog -Lines @(
            'Logi: https://example.com/log1'
            'Logi: https://example.com/log2'
        ) -NL "`n"
        $Result | Should -BeLike '*log1*'
        $Result | Should -BeLike '*log2*'
    }

    It 'returns null when no URLs found' {
        $Result = ConvertFrom-PlainTextLog -Lines @('No URL here') -NL "`n"
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-Gen4FromRawBlock' {
    It 'converts Gen3 locations block to Gen4' {
        $Lines = @('- Lokalizacje:', '    - Erathia', '    - Steadwick')
        $Result = ConvertTo-Gen4FromRawBlock -Tag 'locations' -Lines $Lines -NL "`n"
        $Result | Should -BeLike '*@Lokacje:*'
        $Result | Should -BeLike '*Erathia*'
        $Result | Should -BeLike '*Steadwick*'
    }

    It 'converts Gen3 PU block to Gen4' {
        $Lines = @('- PU:', '    - Xeron: 0.3')
        $Result = ConvertTo-Gen4FromRawBlock -Tag 'pu' -Lines $Lines -NL "`n"
        $Result | Should -BeLike '*@PU:*'
        $Result | Should -BeLike '*Xeron: 0.3*'
    }

    It 'converts Gen3 logs block to Gen4' {
        $Lines = @('- Logi:', '    - https://example.com/log')
        $Result = ConvertTo-Gen4FromRawBlock -Tag 'logs' -Lines $Lines -NL "`n"
        $Result | Should -BeLike '*@Logi:*'
        $Result | Should -BeLike '*https://example.com/log*'
    }

    It 'expands inline comma-separated values when no children' {
        $Lines = @('- Lokalizacje: Erathia, Steadwick')
        $Result = ConvertTo-Gen4FromRawBlock -Tag 'locations' -Lines $Lines -NL "`n"
        $Result | Should -BeLike '*@Lokacje:*'
        $Result | Should -BeLike '*Erathia*'
        $Result | Should -BeLike '*Steadwick*'
    }

    It 'converts changes block to Gen4' {
        $Lines = @('- Zmiany:', '    - Xeron: @status: Aktywny')
        $Result = ConvertTo-Gen4FromRawBlock -Tag 'changes' -Lines $Lines -NL "`n"
        $Result | Should -BeLike '*@Zmiany:*'
        $Result | Should -BeLike '*Xeron*'
    }

    It 'converts intel block to Gen4' {
        $Lines = @('- Intel:', '    - Xeron: Secret info')
        $Result = ConvertTo-Gen4FromRawBlock -Tag 'intel' -Lines $Lines -NL "`n"
        $Result | Should -BeLike '*@Intel:*'
        $Result | Should -BeLike '*Xeron*'
    }
}

Describe 'Split-SessionSection - additional coverage' {
    It 'handles Gen1/2 plain text Logi: lines' {
        $Lines = @('', 'Logi: https://example.com/log1', '', 'Body text.')
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Contain 'logs-plain'
        $Result.MetaBlocks['logs-plain'].Count | Should -Be 1
    }

    It 'handles multiple plain text Logi: lines' {
        $Lines = @('', 'Logi: https://example.com/log1', 'Logi: https://example.com/log2', '', 'Body.')
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks['logs-plain'].Count | Should -Be 2
    }

    It 'extracts preserved blocks (Objaśnienia, Efekty)' {
        $Lines = @(
            ''
            '- Objaśnienia:'
            '    - Some explanation'
            '- Efekty:'
            '    - Some effect'
            ''
            'Body text.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.PreservedBlocks.Count | Should -Be 2
        $Tags = $Result.PreservedBlocks | ForEach-Object { $_.Tag }
        $Tags | Should -Contain 'objaśnienia'
        $Tags | Should -Contain 'efekty'
    }

    It 'handles code fences without treating content as metadata' {
        $Lines = @(
            '```'
            '- PU:'
            '    - Xeron: 0.3'
            '```'
            ''
            'Body text.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Not -Contain 'pu'
        ($Result.BodyLines -join ' ') | Should -BeLike '*PU:*'
    }

    It 'handles Gen4 @-prefixed tags' {
        $Lines = @(
            ''
            '- @PU:'
            '    - Xeron: 0.3'
            '- @Lokacje:'
            '    - Erathia'
            ''
            'Body text.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Contain 'pu'
        $Result.MetaBlocks.Keys | Should -Contain 'locations'
    }

    It 'handles Intel metadata block' {
        $Lines = @(
            ''
            '- @Intel:'
            '    - Xeron: Some secret'
            ''
            'Body.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Contain 'intel'
    }

    It 'closes block on blank line' {
        $Lines = @(
            '- PU:'
            '    - Xeron: 0.3'
            ''
            'Body text after blank.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Keys | Should -Contain 'pu'
        ($Result.BodyLines -join ' ') | Should -BeLike '*Body text after blank*'
    }

    It 'treats non-metadata root list items as body' {
        $Lines = @(
            '- Random list item'
            '- Another item'
            ''
            'Body.'
        )
        $Result = Split-SessionSection -Lines $Lines
        $Result.MetaBlocks.Count | Should -Be 0
        ($Result.BodyLines -join ' ') | Should -BeLike '*Random list item*'
    }
}

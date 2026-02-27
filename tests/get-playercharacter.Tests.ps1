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
}

Describe 'Get-PlayerCharacter' {
    BeforeAll {
        $script:Characters = Get-PlayerCharacter
    }

    It 'returns one object per character' {
        $script:Characters.Count | Should -BeGreaterOrEqual 3
    }

    It 'each character has PlayerName backreference' {
        foreach ($Char in $script:Characters) {
            $Char.PlayerName | Should -Not -BeNullOrEmpty
        }
    }

    It 'Xeron Demonlord belongs to Solmyr' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron | Should -Not -BeNullOrEmpty
        $Xeron.PlayerName | Should -Be 'Solmyr'
    }

    It 'Dracon belongs to Crag Hack' {
        $Dracon = $script:Characters | Where-Object { $_.Name -eq 'Dracon' }
        $Dracon | Should -Not -BeNullOrEmpty
        $Dracon.PlayerName | Should -Be 'Crag Hack'
    }

    It 'carries PU data from Get-Player' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.PUStart | Should -Not -BeNullOrEmpty
    }

    It 'carries IsActive flag' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.IsActive | Should -BeTrue
    }

    It 'carries Path' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Path | Should -Not -BeNullOrEmpty
    }

    It 'carries aliases' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Aliases | Should -Contain 'Xeron'
    }

    It 'filters by -PlayerName' {
        $Result = Get-PlayerCharacter -PlayerName 'Solmyr'
        foreach ($Char in $Result) {
            $Char.PlayerName | Should -Be 'Solmyr'
        }
        $Result.Count | Should -BeGreaterOrEqual 2
    }

    It 'filters by -CharacterName' {
        $Result = Get-PlayerCharacter -CharacterName 'Xeron Demonlord'
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron Demonlord'
    }

    It 'state fields are $null when -IncludeState is not set' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.CharacterSheet | Should -BeNullOrEmpty
        $Xeron.Condition | Should -BeNullOrEmpty
        $Xeron.Status | Should -BeNullOrEmpty
    }

    It 'Player backreference carries player object' {
        $Xeron = $script:Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Player | Should -Not -BeNullOrEmpty
        $Xeron.Player.Name | Should -Be 'Solmyr'
    }
}

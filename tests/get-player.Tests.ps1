BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
}

Describe 'Complete-PUData' {
    It 'derives PUTaken from PUSum - PUStart' {
        $Char = [PSCustomObject]@{ PUStart = 20; PUSum = 25; PUTaken = $null }
        Complete-PUData -Character $Char
        $Char.PUTaken | Should -Be 5
    }

    It 'derives PUSum from PUStart + PUTaken' {
        $Char = [PSCustomObject]@{ PUStart = 20; PUSum = $null; PUTaken = 3.5 }
        Complete-PUData -Character $Char
        $Char.PUSum | Should -Be 23.5
    }

    It 'does nothing when both PUSum and PUTaken are set' {
        $Char = [PSCustomObject]@{ PUStart = 20; PUSum = 25; PUTaken = 5 }
        Complete-PUData -Character $Char
        $Char.PUSum | Should -Be 25
        $Char.PUTaken | Should -Be 5
    }

    It 'does nothing when PUStart is $null' {
        $Char = [PSCustomObject]@{ PUStart = $null; PUSum = 25; PUTaken = $null }
        Complete-PUData -Character $Char
        $Char.PUTaken | Should -BeNullOrEmpty
    }
}

Describe 'Get-Player' {
    BeforeAll {
        $script:Players = Get-Player
    }

    It 'parses all players from Gracze.md fixture' {
        $script:Players.Count | Should -Be 3
    }

    It 'parses Solmyr with correct metadata' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Solmyr | Should -Not -BeNullOrEmpty
        $Solmyr.MargonemID | Should -Be '12345'
        $Solmyr.PRFWebhook | Should -Be 'https://discord.com/api/webhooks/111/solmyr-token'
    }

    It 'parses triggers for Solmyr' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Solmyr.Triggers | Should -Contain 'gore'
        $Solmyr.Triggers | Should -Contain 'tortury'
    }

    It 'parses "brak" triggers as empty' {
        $CragHack = $script:Players | Where-Object { $_.Name -eq 'Crag Hack' }
        $CragHack.Triggers.Count | Should -Be 0
    }

    It 'parses Solmyr characters (2 characters)' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Solmyr.Characters.Count | Should -Be 2
    }

    It 'identifies active (bolded) character' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Xeron = $Solmyr.Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.IsActive | Should -BeTrue
    }

    It 'identifies non-active character' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Kyrre = $Solmyr.Characters | Where-Object { $_.Name -eq 'Kyrre' }
        $Kyrre.IsActive | Should -BeFalse
    }

    It 'parses character aliases' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Xeron = $Solmyr.Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Aliases | Should -Contain 'Xeron'
        $Xeron.Aliases | Should -Contain 'XD'
    }

    It 'parses character path' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Xeron = $Solmyr.Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Path | Should -Be 'Postaci/Gracze/Xeron%20Demonlord.md'
    }

    It 'parses PU values with comma decimal separator' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Xeron = $Solmyr.Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.PUExceeded | Should -Be 0.5
        $Xeron.PUStart | Should -Be 20
        $Xeron.PUSum | Should -Be 25.5
        $Xeron.PUTaken | Should -Be 5.5
    }

    It 'parses PU BRAK as $null' {
        $CragHack = $script:Players | Where-Object { $_.Name -eq 'Crag Hack' }
        $Dracon = $CragHack.Characters | Where-Object { $_.Name -eq 'Dracon' }
        $Dracon.PUExceeded | Should -BeNullOrEmpty
        $Dracon.PUSum | Should -BeNullOrEmpty
        $Dracon.PUTaken | Should -BeNullOrEmpty
        $Dracon.PUStart | Should -Be 20
    }

    It 'parses additional info for character' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Xeron = $Solmyr.Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.AdditionalInfo | Should -Contain 'Biegły w walce mieczem.'
    }

    It 'handles player with zero characters (Sandro)' {
        $Sandro = $script:Players | Where-Object { $_.Name -eq 'Sandro' }
        $Sandro | Should -Not -BeNullOrEmpty
        $Sandro.Characters.Count | Should -Be 0
    }

    It 'builds Names index with player + character names + aliases' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Solmyr.Names | Should -Contain 'Solmyr'
        $Solmyr.Names | Should -Contain 'Xeron Demonlord'
        $Solmyr.Names | Should -Contain 'Xeron'
        $Solmyr.Names | Should -Contain 'Kyrre'
    }

    It 'filters by -Name parameter' {
        $Result = Get-Player -Name 'Solmyr'
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Solmyr'
    }

    It 'applies entity overrides for Gracz — PRFWebhook and MargonemID' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Solmyr.PRFWebhook | Should -Not -BeNullOrEmpty
    }

    It 'applies entity overrides for Postać (Gracz) — PU values from entities' {
        $Solmyr = $script:Players | Where-Object { $_.Name -eq 'Solmyr' }
        $Xeron = $Solmyr.Characters | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        # entities-100-ent.md overrides pu_suma to 26
        $Xeron.PUSum | Should -Be 26
    }

    It 'Crag Hack has no PRFWebhook (not in entities)' {
        $CragHack = $script:Players | Where-Object { $_.Name -eq 'Crag Hack' }
        $CragHack.PRFWebhook | Should -BeNullOrEmpty
    }
}

<#
    .SYNOPSIS
    Pester tests for cli-fuzzy.ps1.

    .DESCRIPTION
    Tests for fuzzy candidate filtering and source-based candidate generation.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source CLI layers in dependency order
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-primitives.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-fuzzy.ps1')

    # Create a minimal NavState for color resolution
    $script:NavState = [PSCustomObject]@{
        Theme = 'Dark'
    }
}

# ── Filter-FuzzyCandidates ──────────────────────────────────────────────────

Describe 'Filter-FuzzyCandidates' {
    BeforeAll {
        $script:TestCandidates = @(
            [PSCustomObject]@{ Name = 'Xeron Demonlord'; Type = 'NPC'; DisplayText = 'Xeron Demonlord [NPC]'; Owner = $null }
            [PSCustomObject]@{ Name = 'Solmyra';         Type = 'NPC'; DisplayText = 'Solmyra [NPC]';         Owner = $null }
            [PSCustomObject]@{ Name = 'Tatalia';           Type = 'Lokacja'; DisplayText = 'Tatalia [Lokacja]'; Owner = $null }
            [PSCustomObject]@{ Name = 'Bracada';          Type = 'Lokacja'; DisplayText = 'Bracada [Lokacja]'; Owner = $null }
            [PSCustomObject]@{ Name = 'Lorelei';          Type = 'NPC'; DisplayText = 'Lorelei [NPC]';         Owner = $null }
        )

        $script:TestState = [PSCustomObject]@{
            NameIndex    = $null
            ResolveCache = @{}
        }
    }

    It 'returns all candidates (up to MaxResults) for empty query' {
        $Result = Filter-FuzzyCandidates -Query '' -Candidates $script:TestCandidates -State $script:TestState -MaxResults 10
        $Result.Count | Should -Be 5
    }

    It 'returns limited candidates for MaxResults < total' {
        $Result = Filter-FuzzyCandidates -Query '' -Candidates $script:TestCandidates -State $script:TestState -MaxResults 2
        $Result.Count | Should -Be 2
    }

    It 'finds prefix match: Xer -> Xeron Demonlord' {
        $Result = Filter-FuzzyCandidates -Query 'Xer' -Candidates $script:TestCandidates -State $script:TestState
        $Result.Count | Should -BeGreaterOrEqual 1
        $Result[0].Name | Should -Be 'Xeron Demonlord'
    }

    It 'finds prefix match case-insensitively: xer -> Xeron Demonlord' {
        $Result = Filter-FuzzyCandidates -Query 'xer' -Candidates $script:TestCandidates -State $script:TestState
        $Result.Count | Should -BeGreaterOrEqual 1
        $Result[0].Name | Should -Be 'Xeron Demonlord'
    }

    It 'finds contains match: myr -> Solmyra' {
        $Result = Filter-FuzzyCandidates -Query 'myr' -Candidates $script:TestCandidates -State $script:TestState
        $Result.Count | Should -BeGreaterOrEqual 1
        ($Result | Where-Object { $_.Name -eq 'Solmyra' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'returns empty array for no matches' {
        $Result = Filter-FuzzyCandidates -Query 'zzzzz' -Candidates $script:TestCandidates -State $script:TestState
        $Result.Count | Should -Be 0
    }

    It 'prioritizes prefix over contains matches' {
        $Result = Filter-FuzzyCandidates -Query 'Bra' -Candidates $script:TestCandidates -State $script:TestState
        $Result.Count | Should -BeGreaterOrEqual 1
        $Result[0].Name | Should -Be 'Bracada'
    }
}

# ── Get-FuzzySearchCandidates ───────────────────────────────────────────────

Describe 'Get-FuzzySearchCandidates' {
    BeforeAll {
        $script:TestEntity1 = [PSCustomObject]@{ Name = 'Xeron'; Type = 'NPC'; Tags = @{} }
        $script:TestEntity2 = [PSCustomObject]@{ Name = 'Tatalia'; Type = 'Lokacja'; Tags = @{} }
        $script:TestEntity3 = [PSCustomObject]@{ Name = 'Gildia Magów'; Type = 'Grupa'; Tags = @{} }
        $script:TestEntity4 = [PSCustomObject]@{ Name = 'Sakiewka Xerona'; Type = 'Przedmiot'; Tags = @{ 'ilość' = '100' } }

        $script:TestPlayer1 = [PSCustomObject]@{
            Name = 'Tyris'
            Characters = @(
                [PSCustomObject]@{ Name = 'Lorelei' }
                [PSCustomObject]@{ Name = 'Loynis' }
            )
        }

        $script:FuzzyState = [PSCustomObject]@{
            Players  = @($script:TestPlayer1)
            Entities = @($script:TestEntity1, $script:TestEntity2, $script:TestEntity3, $script:TestEntity4)
        }
    }

    It 'returns players for "players" source' {
        $Result = Get-FuzzySearchCandidates -Source 'players' -State $script:FuzzyState
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Tyris'
        $Result[0].Type | Should -Be 'Gracz'
    }

    It 'returns characters for "characters" source' {
        $Result = Get-FuzzySearchCandidates -Source 'characters' -State $script:FuzzyState
        $Result.Count | Should -Be 2
        $Result[0].Name | Should -Be 'Lorelei'
        $Result[1].Name | Should -Be 'Loynis'
    }

    It 'returns all entities for "entities" source' {
        $Result = Get-FuzzySearchCandidates -Source 'entities' -State $script:FuzzyState
        $Result.Count | Should -Be 4
    }

    It 'returns only locations for "locations" source' {
        $Result = Get-FuzzySearchCandidates -Source 'locations' -State $script:FuzzyState
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Tatalia'
    }

    It 'returns only groups for "groups" source' {
        $Result = Get-FuzzySearchCandidates -Source 'groups' -State $script:FuzzyState
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Gildia Magów'
    }

    It 'returns only NPCs for "npcs" source' {
        $Result = Get-FuzzySearchCandidates -Source 'npcs' -State $script:FuzzyState
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron'
    }

    It 'returns currency entities (Przedmiot with ilość tag) for "currency" source' {
        $Result = Get-FuzzySearchCandidates -Source 'currency' -State $script:FuzzyState
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Sakiewka Xerona'
        $Result[0].Type | Should -Be 'Waluta'
    }

    It 'returns narrators (same as players) for "narrators" source' {
        $Result = Get-FuzzySearchCandidates -Source 'narrators' -State $script:FuzzyState
        $Result.Count | Should -Be 1
        $Result[0].Type | Should -Be 'Narrator'
    }

    It 'returns all entities for unknown source' {
        $Result = Get-FuzzySearchCandidates -Source 'unknown_source' -State $script:FuzzyState
        $Result.Count | Should -Be 4
    }
}

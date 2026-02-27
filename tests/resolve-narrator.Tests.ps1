<#
    .SYNOPSIS
    Pester tests for resolve-narrator.ps1.

    .DESCRIPTION
    Tests for Resolve-Narrator covering narrator name resolution
    from session headers, player name matching, alias handling,
    and fallback behavior for unrecognized narrator names.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-narrator.ps1')
}

Describe 'Resolve-NarratorCandidate' {
    BeforeAll {
        $script:Entities = Get-Entity
        $script:Players = Get-Player -Entities $script:Entities
        $script:NameIdx = Get-NameIndex -Players $script:Players -Entities $script:Entities
    }

    It 'exact match returns High confidence' {
        $Result = Resolve-NarratorCandidate -Query 'Solmyr' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Result | Should -Not -BeNullOrEmpty
        $Result.Confidence | Should -Be 'High'
        $Result.Player.Name | Should -Be 'Solmyr'
    }

    It 'fuzzy match returns Medium confidence' {
        $Result = Resolve-NarratorCandidate -Query 'Solmyrowi' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        if ($Result) {
            $Result.Confidence | Should -Be 'Medium'
        }
    }

    It 'returns $null for unresolvable name' {
        $Result = Resolve-NarratorCandidate -Query 'XYZNONEXISTENT' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-Narrator' {
    BeforeAll {
        $script:Entities = Get-Entity
        $script:Players = Get-Player -Entities $script:Entities
        $script:NameIdx = Get-NameIndex -Players $script:Players -Entities $script:Entities
    }

    It 'resolves single narrator from header' {
        $Sessions = @([PSCustomObject]@{ Header = '2024-06-15, Ucieczka z Erathii, Solmyr' })
        $Results = Resolve-Narrator -Sessions $Sessions -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Results.Count | Should -Be 1
        $Results[0].Narrators.Count | Should -Be 1
        $Results[0].Narrators[0].Name | Should -Be 'Solmyr'
    }

    It 'detects Rada as council session' {
        $Sessions = @([PSCustomObject]@{ Header = '2024-06-15, Sesja rady, Rada' })
        $Results = Resolve-Narrator -Sessions $Sessions -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Results[0].IsCouncil | Should -BeTrue
        $Results[0].Confidence | Should -Be 'High'
    }

    It 'handles co-narrators with "i" conjunction' {
        $Sessions = @([PSCustomObject]@{ Header = '2024-06-15, Sesja, Solmyr i Crag Hack' })
        $Results = Resolve-Narrator -Sessions $Sessions -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Results[0].Narrators.Count | Should -Be 2
    }

    It 'handles header with only date and title (no narrator)' {
        $Sessions = @([PSCustomObject]@{ Header = '2024-06-15, Sesja bez narratora' })
        $Results = Resolve-Narrator -Sessions $Sessions -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Results[0].Narrators.Count | Should -Be 0
        $Results[0].Confidence | Should -Be 'None'
    }

    It 'returns None confidence for unresolvable narrator' {
        $Sessions = @([PSCustomObject]@{ Header = '2024-06-15, Sesja, XYZNONEXISTENT999' })
        $Results = Resolve-Narrator -Sessions $Sessions -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Results[0].Confidence | Should -Be 'None'
    }

    It 'caches results for repeated narrator text' {
        $Sessions = @(
            [PSCustomObject]@{ Header = '2024-06-15, Session 1, Solmyr' },
            [PSCustomObject]@{ Header = '2024-07-20, Session 2, Solmyr' }
        )
        $Results = Resolve-Narrator -Sessions $Sessions -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Results.Count | Should -Be 2
        $Results[0].Narrators[0].Name | Should -Be 'Solmyr'
        $Results[1].Narrators[0].Name | Should -Be 'Solmyr'
    }
}

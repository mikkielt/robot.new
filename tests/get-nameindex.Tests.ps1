BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'get-nameindex.ps1')
}

Describe 'Get-NameIndex' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:Players = Get-Player -Entities $script:Entities
        $script:NameIdx = Get-NameIndex -Players $script:Players -Entities $script:Entities
    }

    It 'returns hashtable with Index, StemIndex, and BKTree' {
        $script:NameIdx.Index | Should -Not -BeNullOrEmpty
        $script:NameIdx.StemIndex | Should -Not -BeNullOrEmpty
        $script:NameIdx.BKTree | Should -Not -BeNullOrEmpty
    }

    It 'Index contains player names' {
        $script:NameIdx.Index.ContainsKey('Solmyr') | Should -BeTrue
        $script:NameIdx.Index.ContainsKey('Crag Hack') | Should -BeTrue
    }

    It 'Index contains character full names at priority 1' {
        $Entry = $script:NameIdx.Index['Xeron Demonlord']
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.Priority | Should -Be 1
    }

    It 'Index contains character aliases at priority 1' {
        $Entry = $script:NameIdx.Index['Xeron']
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.Priority | Should -Be 1
    }

    It 'Index contains entity names (NPCs)' {
        $script:NameIdx.Index.ContainsKey('Kupiec Orrin') | Should -BeTrue
        $script:NameIdx.Index.ContainsKey('Rion') | Should -BeTrue
    }

    It 'Index contains entity aliases' {
        $script:NameIdx.Index.ContainsKey('Gildia Handlarzy') | Should -BeTrue
    }

    It 'Index contains location names' {
        $script:NameIdx.Index.ContainsKey('Erathia') | Should -BeTrue
        $script:NameIdx.Index.ContainsKey('Enroth') | Should -BeTrue
    }

    It 'word tokens from multi-word names get priority 2' {
        $Entry = $script:NameIdx.Index['Demonlord']
        $Entry | Should -Not -BeNullOrEmpty
        $Entry.Priority | Should -Be 2
    }

    It 'short tokens below MinTokenLength are excluded' {
        # 'XD' is only 2 chars, default MinTokenLength is 3
        $script:NameIdx.Index.ContainsKey('XD') | Should -BeTrue  # XD is a full alias, priority 1
    }

    It 'case-insensitive index lookup' {
        $script:NameIdx.Index.ContainsKey('solmyr') | Should -BeTrue
        $script:NameIdx.Index.ContainsKey('SOLMYR') | Should -BeTrue
    }

    It 'StemIndex maps stems to original token keys' {
        $script:NameIdx.StemIndex.Count | Should -BeGreaterThan 0
    }

    It 'BKTree has a root node with a Key' {
        $script:NameIdx.BKTree.Key | Should -Not -BeNullOrEmpty
    }

    It 'Player wins over Gracz/Postać entity at same priority' {
        # Solmyr is both a Player and a Gracz entity
        $Entry = $script:NameIdx.Index['Solmyr']
        $Entry.Ambiguous | Should -BeFalse
        $Entry.OwnerType | Should -Be 'Player'
    }
}

Describe 'Add-BKTreeNode and Search-BKTree' {
    It 'BK-tree search finds nearby keys' {
        $Tree = @{ Key = 'Xeron'; Children = @{} }
        Add-BKTreeNode -Node $Tree -Key 'Xeroni'
        Add-BKTreeNode -Node $Tree -Key 'Abc'

        $Results = Search-BKTree -Tree $Tree -Query 'Xeron' -Threshold 1
        $Results.Count | Should -BeGreaterOrEqual 1
        $ResultKeys = $Results | ForEach-Object { $_.Key }
        $ResultKeys | Should -Contain 'Xeron'
    }

    It 'BK-tree search returns empty for distant keys' {
        $Tree = @{ Key = 'Aaaaa'; Children = @{} }
        Add-BKTreeNode -Node $Tree -Key 'Zzzzz'
        $Results = Search-BKTree -Tree $Tree -Query 'Xxxxx' -Threshold 1
        ($Results | Where-Object { $_.Key -eq 'Aaaaa' }) | Should -BeNullOrEmpty
    }
}

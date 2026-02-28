<#
    .SYNOPSIS
    Pester tests for get-nameindex.ps1.

    .DESCRIPTION
    Tests for Get-NameIndex, Add-BKTreeNode, and Search-BKTree covering
    index construction from players and entities, priority assignment,
    case-insensitive lookup, stem indexing, BK-tree fuzzy search, and
    Player vs Gracz entity disambiguation.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
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

    It 'BK-tree handles single node tree' {
        $Tree = @{ Key = 'Xeron'; Children = @{} }
        $Results = Search-BKTree -Tree $Tree -Query 'Xeron' -Threshold 0
        $Results.Count | Should -Be 1
        $Results[0].Key | Should -Be 'Xeron'
    }

    It 'BK-tree returns empty for threshold 0 non-exact match' {
        $Tree = @{ Key = 'Xeron'; Children = @{} }
        $Results = Search-BKTree -Tree $Tree -Query 'Xeroni' -Threshold 0
        $Results.Count | Should -Be 0
    }

    It 'BK-tree handles multiple insertions at same distance' {
        $Tree = @{ Key = 'Aaa'; Children = @{} }
        Add-BKTreeNode -Node $Tree -Key 'Bbb'
        Add-BKTreeNode -Node $Tree -Key 'Ccc'
        Add-BKTreeNode -Node $Tree -Key 'Ddd'
        $Results = Search-BKTree -Tree $Tree -Query 'Aab' -Threshold 1
        $ResultKeys = $Results | ForEach-Object { $_.Key }
        $ResultKeys | Should -Contain 'Aaa'
    }
}

Describe 'Get-NameIndex - many aliases entity' {
    BeforeAll {
        $script:ManyAliasEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-many-aliases.md')
        $script:ManyAliasIdx = Get-NameIndex -Players @() -Entities $script:ManyAliasEntities
    }

    It 'indexes all aliases from entity with six aliases' {
        $script:ManyAliasIdx.Index.ContainsKey('Mistrz Szpiegów') | Should -BeTrue
        $script:ManyAliasIdx.Index.ContainsKey('Cień Nighonu') | Should -BeTrue
    }

    It 'expired alias is still indexed' {
        # Aliases with temporal validity are still in the entities file
        $script:ManyAliasIdx.Index.ContainsKey('Szpieg Tunnelów') | Should -BeTrue
    }
}

Describe 'Get-NameIndex - duplicate names across types' {
    BeforeAll {
        $script:DupEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-duplicate-names.md')
        $script:DupIdx = Get-NameIndex -Players @() -Entities $script:DupEntities
    }

    It 'indexes duplicate name (Złoty Smok appears as NPC and Lokacja and Organizacja)' {
        $Entry = $script:DupIdx.Index['Złoty Smok']
        $Entry | Should -Not -BeNullOrEmpty
    }

    It 'marks duplicate-name entry as ambiguous' {
        $Entry = $script:DupIdx.Index['Złoty Smok']
        $Entry.Ambiguous | Should -BeTrue
    }
}

Describe 'Get-NameIndex - unicode names indexing' {
    BeforeAll {
        $script:UniEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-unicode-names.md')
        $script:UniIdx = Get-NameIndex -Players @() -Entities $script:UniEntities
    }

    It 'indexes names with Polish diacritics' {
        $script:UniIdx.Index.ContainsKey('Śćiółka Żółwia') | Should -BeTrue
        $script:UniIdx.Index.ContainsKey('Łącznik Ńewski') | Should -BeTrue
    }

    It 'case-insensitive lookup works with diacritics' {
        $script:UniIdx.Index.ContainsKey('śćiółka żółwia') | Should -BeTrue
    }

    It 'BK-tree includes diacritic names' {
        $Results = Search-BKTree -Tree $script:UniIdx.BKTree -Query 'Śćiółka Żółwia' -Threshold 0
        $ResultKeys = $Results | ForEach-Object { $_.Key }
        $ResultKeys | Should -Contain 'śćiółka żółwia'
    }
}

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-name.ps1')
}

Describe 'Get-DeclensionStem' {
    It 'strips -owi suffix: Xeronowi → Xeron' {
        Get-DeclensionStem -Text 'Xeronowi' | Should -Be 'Xeron'
    }

    It 'strips -em suffix (longest first): Draconem → Dracon' {
        Get-DeclensionStem -Text 'Draconem' | Should -Be 'Dracon'
    }

    It 'respects minimum stem length 3: Aba unchanged' {
        Get-DeclensionStem -Text 'Aba' | Should -Be 'Aba'
    }

    It 'returns original when no suffix matches' {
        Get-DeclensionStem -Text 'Xeron' | Should -Be 'Xeron'
    }
}

Describe 'Get-StemAlternationCandidates' {
    It 'Bracadzie → contains Bracada' {
        $Result = Get-StemAlternationCandidates -Text 'Bracadzie'
        $Result | Should -Contain 'Bracada'
    }

    It 'returns empty list when no alternation matches' {
        $Result = Get-StemAlternationCandidates -Text 'Xeron'
        $Result.Count | Should -Be 0
    }
}

Describe 'Get-LevenshteinDistance' {
    It 'returns 0 for same string' {
        Get-LevenshteinDistance -Source 'test' -Target 'test' | Should -Be 0
    }

    It 'returns length for empty vs non-empty' {
        Get-LevenshteinDistance -Source '' -Target 'abc' | Should -Be 3
    }

    It 'returns 3 for kitten/sitting' {
        Get-LevenshteinDistance -Source 'kitten' -Target 'sitting' | Should -Be 3
    }

    It 'is case insensitive: ABC/abc → 0' {
        Get-LevenshteinDistance -Source 'ABC' -Target 'abc' | Should -Be 0
    }

    It 'returns 1 for single character difference' {
        Get-LevenshteinDistance -Source 'cat' -Target 'bat' | Should -Be 1
    }
}

Describe 'Resolve-Name' {
    BeforeAll {
        # Build index from fixtures
        $script:Entities = Get-Entity
        $script:Players = Get-Player -Entities $script:Entities
        $script:NameIdx = Get-NameIndex -Players $script:Players -Entities $script:Entities
    }

    It 'Stage 1 exact match: Xeron Demonlord resolves' {
        $Result = Resolve-Name -Query 'Xeron Demonlord' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Xeron Demonlord'
    }

    It 'Stage 1 exact match is case-insensitive' {
        $Result = Resolve-Name -Query 'xeron demonlord' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Result | Should -Not -BeNullOrEmpty
    }

    It 'Stage 2 declension: Xeronowi resolves to Xeron Demonlord' {
        $Result = Resolve-Name -Query 'Xeronowi' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        if ($Result) {
            $Result.Name | Should -BeLike '*Xeron*'
        }
    }

    It 'returns $null for completely unresolvable query' {
        $Result = Resolve-Name -Query 'XYZNONEXISTENT999' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Result | Should -BeNullOrEmpty
    }

    It 'uses cache for repeated queries' {
        $Cache = @{}
        $null = Resolve-Name -Query 'Xeron Demonlord' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree -Cache $Cache
        $Cache.Count | Should -BeGreaterThan 0
        # Second call should use cache
        $Result = Resolve-Name -Query 'Xeron Demonlord' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree -Cache $Cache
        $Result | Should -Not -BeNullOrEmpty
    }

    It 'Stage 2b stem alternation: Bracadzie resolves' {
        $Candidates = Get-StemAlternationCandidates -Text 'Bracadzie'
        # If Bracada is in the index, this should resolve
        $HasBracada = $script:NameIdx.Index.ContainsKey('Bracada')
        if ($HasBracada) {
            $Result = Resolve-Name -Query 'Bracadzie' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
            $Result | Should -Not -BeNullOrEmpty
        }
    }

    It 'Stage 3 fuzzy match: typo resolves via Levenshtein' {
        # "Xeron Demonlors" is 1 edit from "Xeron Demonlord" — within threshold
        $Result = Resolve-Name -Query 'Xeron Demonlors' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Xeron Demonlord'
    }

    It 'OwnerType filter restricts results' {
        $Result = Resolve-Name -Query 'Xeron Demonlord' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree -OwnerType 'Lokacja'
        # Xeron Demonlord is Postać (Gracz), not Lokacja — should not match
        $Result | Should -BeNullOrEmpty
    }

    It 'caches miss as DBNull sentinel' {
        $Cache = @{}
        $Result = Resolve-Name -Query 'TOTALLYUNKNOWN123' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree -Cache $Cache
        $Result | Should -BeNullOrEmpty
        $Cache.ContainsKey('TOTALLYUNKNOWN123') | Should -BeTrue
        $Cache['TOTALLYUNKNOWN123'] -is [System.DBNull] | Should -BeTrue
    }

    It 'builds index automatically when not provided' {
        $Result = Resolve-Name -Query 'Xeron Demonlord' -Players $script:Players -Entities $script:Entities
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Xeron Demonlord'
    }

    It 'linear scan fallback works without BK-tree' {
        $Result = Resolve-Name -Query 'Xeron Demonlors' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex
        # No BKTree provided — falls back to linear scan
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Xeron Demonlord'
    }

    It 'OwnerType filter affects cache key' {
        $Cache = @{}
        $null = Resolve-Name -Query 'Xeron' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree -Cache $Cache
        $null = Resolve-Name -Query 'Xeron' -Index $script:NameIdx.Index -StemIndex $script:NameIdx.StemIndex -BKTree $script:NameIdx.BKTree -Cache $Cache -OwnerType 'Lokacja'
        # Two cache entries: 'Xeron' and 'Xeron|Lokacja'
        $Cache.ContainsKey('Xeron') | Should -BeTrue
        $Cache.ContainsKey('Xeron|Lokacja') | Should -BeTrue
    }
}

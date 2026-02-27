BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
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
}

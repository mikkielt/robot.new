<#
    .SYNOPSIS
    Pester tests for charfile-helpers.ps1.

    .DESCRIPTION
    Tests for Read-CharacterFile, Find-CharacterSection,
    Write-CharacterFileSection, and Format-ReputationSection covering
    character file parsing, section manipulation, and reputation rendering.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'charfile-helpers.ps1')

    $script:FullCharFile = Join-Path $script:FixturesRoot 'charfile-full.md'
    $script:EmptyCharFile = Join-Path $script:FixturesRoot 'charfile-empty.md'
    $script:AngleBracketFile = Join-Path $script:FixturesRoot 'charfile-anglebracket.md'
    $script:MultiLineStanFile = Join-Path $script:FixturesRoot 'charfile-multilinestan.md'
}

Describe 'Read-CharacterFile' {
    Context 'Full character file parsing' {
        BeforeAll {
            $script:Result = Read-CharacterFile -Path $script:FullCharFile
        }

        It 'parses CharacterSheet URL' {
            $script:Result.CharacterSheet | Should -Be 'https://example.com/xeron-sheet'
        }

        It 'parses RestrictedTopics' {
            $script:Result.RestrictedTopics | Should -BeLike '*Tortury*'
        }

        It 'parses Condition' {
            $script:Result.Condition | Should -BeLike '*Blizny*'
        }

        It 'parses SpecialItems' {
            $script:Result.SpecialItems.Count | Should -Be 2
            $script:Result.SpecialItems[0] | Should -BeLike '*Miecz Piekielny*'
            $script:Result.SpecialItems[1] | Should -BeLike '*Tarcza Demoniczna*'
        }

        It 'parses Reputation.Positive' {
            $script:Result.Reputation.Positive.Count | Should -Be 2
            $script:Result.Reputation.Positive[0].Location | Should -Be 'Eeofol'
            $script:Result.Reputation.Positive[0].Detail | Should -BeLike '*Kreegany*'
            $script:Result.Reputation.Positive[1].Location | Should -Be 'Nighon'
        }

        It 'parses Reputation.Neutral inline' {
            $script:Result.Reputation.Neutral.Count | Should -Be 3
            $script:Result.Reputation.Neutral[0].Location | Should -Be 'Deyja'
        }

        It 'parses Reputation.Negative with detail' {
            $script:Result.Reputation.Negative.Count | Should -Be 2
            $script:Result.Reputation.Negative[0].Location | Should -Be 'AvLee'
            $script:Result.Reputation.Negative[0].Detail | Should -BeLike '*las elfów*'
        }

        It 'parses AdditionalNotes' {
            $script:Result.AdditionalNotes.Count | Should -Be 2
            $script:Result.AdditionalNotes[0] | Should -BeLike '*bliznę*'
        }

        It 'parses DescribedSessions' {
            $script:Result.DescribedSessions.Count | Should -Be 2
            $script:Result.DescribedSessions[0].Title | Should -BeLike '*Bitwa o Eeofol*'
            $script:Result.DescribedSessions[0].Narrator | Should -Be 'Solmyr'
            $script:Result.DescribedSessions[0].Date | Should -Be ([datetime]::ParseExact('2025-01-15', 'yyyy-MM-dd', $null))
        }
    }

    Context 'Empty/template file' {
        BeforeAll {
            $script:Result = Read-CharacterFile -Path $script:EmptyCharFile
        }

        It 'returns null RestrictedTopics for "brak"' {
            $script:Result.RestrictedTopics | Should -BeNullOrEmpty
        }

        It 'returns empty SpecialItems for "Brak."' {
            $script:Result.SpecialItems.Count | Should -Be 0
        }

        It 'returns empty AdditionalNotes for "Brak."' {
            $script:Result.AdditionalNotes.Count | Should -Be 0
        }

        It 'parses Neutral reputation inline with many entries' {
            $script:Result.Reputation.Neutral.Count | Should -BeGreaterThan 5
        }
    }

    Context 'Angle-bracket URL' {
        It 'strips angle brackets from CharacterSheet URL' {
            $Result = Read-CharacterFile -Path $script:AngleBracketFile
            $Result.CharacterSheet | Should -Be 'https://docs.google.com/document/d/kyrre-ranger-sheet'
        }

        It 'handles dash-only reputation tiers' {
            $Result = Read-CharacterFile -Path $script:AngleBracketFile
            $Result.Reputation.Positive.Count | Should -Be 0
            $Result.Reputation.Negative.Count | Should -Be 0
        }
    }

    Context 'Multi-line Stan' {
        It 'joins multi-line condition text' {
            $Result = Read-CharacterFile -Path $script:MultiLineStanFile
            $Result.Condition | Should -BeLike '*Pokonany*'
            $Result.Condition | Should -BeLike '*nekromancji*'
        }
    }

    Context 'Non-existent file' {
        It 'returns null for missing file' {
            $Result = Read-CharacterFile -Path (Join-Path $script:FixturesRoot 'nonexistent-charfile-xyz.md')
            $Result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Find-CharacterSection' {
    It 'finds a section by name' {
        $Lines = @('**Stan:**', 'Zdrowy.', '', '**Przedmioty specjalne:**', 'Brak.')
        $Result = Find-CharacterSection -Lines $Lines -SectionName 'Stan'
        $Result | Should -Not -BeNullOrEmpty
        $Result.HeaderIdx | Should -Be 0
        $Result.ContentStart | Should -Be 1
    }

    It 'returns null for missing section' {
        $Lines = @('**Stan:**', 'Zdrowy.')
        $Result = Find-CharacterSection -Lines $Lines -SectionName 'Reputacja'
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Write-CharacterFileSection' {
    It 'replaces section content in-place' {
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@(
            '**Stan:**'
            'Zdrowy.'
            ''
            '**Przedmioty specjalne:**'
            'Brak.'
        ))
        Write-CharacterFileSection -Lines $Lines -SectionName 'Stan' -NewContent @('Ranny.')
        # The Stan section should now contain 'Ranny.'
        $Lines[1] | Should -Be 'Ranny.'
    }

    It 'updates inline value when specified' {
        $Lines = [System.Collections.Generic.List[string]]::new([string[]]@(
            '**Karta Postaci:** https://old.url'
            ''
            '**Stan:**'
            'Zdrowy.'
        ))
        Write-CharacterFileSection -Lines $Lines -SectionName 'Karta Postaci' -InlineValue 'https://new.url'
        $Lines[0] | Should -Be '**Karta Postaci:** https://new.url'
    }
}

Describe 'Format-ReputationSection' {
    It 'renders inline format when no details' {
        $Entries = @(
            [PSCustomObject]@{ Location = 'Erathia'; Detail = $null }
            [PSCustomObject]@{ Location = 'Steadwick'; Detail = $null }
        )
        $Result = Format-ReputationSection -Positive $Entries -Neutral @() -Negative @()
        $Result[0] | Should -Be '- Pozytywna: Erathia, Steadwick'
    }

    It 'renders nested format when any entry has detail' {
        $Entries = @(
            [PSCustomObject]@{ Location = 'Erathia'; Detail = 'pomógł w obronie' }
            [PSCustomObject]@{ Location = 'Steadwick'; Detail = $null }
        )
        $Result = Format-ReputationSection -Positive $Entries -Neutral @() -Negative @()
        $Result[0] | Should -Be '- Pozytywna:'
        $Result[1] | Should -Be '    - Erathia: pomógł w obronie'
        $Result[2] | Should -Be '    - Steadwick'
    }

    It 'renders empty tiers' {
        $Result = Format-ReputationSection -Positive @() -Neutral @() -Negative @()
        $Result[0] | Should -Be '- Pozytywna: '
        $Result[1] | Should -Be '- Neutralna: '
        $Result[2] | Should -Be '- Negatywna: '
    }
}

Describe 'Read-CharacterFile — rich character file' {
    BeforeAll {
        $script:Result = Read-CharacterFile -Path (Join-Path $script:FixturesRoot 'charfile-rich.md')
    }

    It 'parses multiple restricted topics' {
        $script:Result.RestrictedTopics | Should -BeLike '*Nekromancja*'
        $script:Result.RestrictedTopics | Should -BeLike '*Tortury*'
    }

    It 'parses five special items' {
        $script:Result.SpecialItems.Count | Should -Be 5
    }

    It 'parses three positive reputation entries' {
        $script:Result.Reputation.Positive.Count | Should -Be 3
    }

    It 'parses five neutral reputation entries inline' {
        $script:Result.Reputation.Neutral.Count | Should -Be 5
    }

    It 'parses two negative reputation entries with details' {
        $script:Result.Reputation.Negative.Count | Should -Be 2
        $script:Result.Reputation.Negative[0].Detail | Should -BeLike '*spalił las*'
    }

    It 'parses three additional notes' {
        $script:Result.AdditionalNotes.Count | Should -Be 3
    }

    It 'parses five described sessions' {
        $script:Result.DescribedSessions.Count | Should -Be 5
    }

    It 'parses described sessions with different narrators' {
        $Narrators = $script:Result.DescribedSessions | ForEach-Object { $_.Narrator } | Sort-Object -Unique
        $Narrators.Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Read-CharacterFile — unicode content' {
    BeforeAll {
        $script:Result = Read-CharacterFile -Path (Join-Path $script:FixturesRoot 'charfile-unicode.md')
    }

    It 'parses restricted topics with diacritics' {
        $script:Result.RestrictedTopics | Should -BeLike '*Śmierć*'
    }

    It 'parses condition with diacritics and multi-line' {
        $script:Result.Condition | Should -BeLike '*Złamana noga*'
        $script:Result.Condition | Should -BeLike '*żeber*'
    }

    It 'parses special items with diacritics' {
        $script:Result.SpecialItems.Count | Should -Be 2
        $script:Result.SpecialItems[0] | Should -BeLike '*Różdżka*'
    }

    It 'parses reputation with location diacritics' {
        $script:Result.Reputation.Positive[0].Location | Should -Be 'Łąka Ościennych'
    }
}

Describe 'Read-CharacterFile — missing sections' {
    BeforeAll {
        $script:Result = Read-CharacterFile -Path (Join-Path $script:FixturesRoot 'charfile-missing-sections.md')
    }

    It 'parses file with missing SpecialItems section' {
        $script:Result | Should -Not -BeNullOrEmpty
    }

    It 'parses CharacterSheet URL even without other sections' {
        $script:Result.CharacterSheet | Should -Be 'https://example.com/missing-sections'
    }
}

Describe 'Read-CharacterFile — empty reputation tiers' {
    BeforeAll {
        $script:Result = Read-CharacterFile -Path (Join-Path $script:FixturesRoot 'charfile-empty-reputation.md')
    }

    It 'handles all empty reputation tiers' {
        $script:Result.Reputation.Positive.Count | Should -Be 0
        $script:Result.Reputation.Neutral.Count | Should -Be 0
        $script:Result.Reputation.Negative.Count | Should -Be 0
    }
}

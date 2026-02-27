BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/charfile-helpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-charfile-" + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    # Full character file fixture
    $script:FullCharFile = Join-Path $script:TempRoot 'FullChar.md'
    Write-TestFile -Path $script:FullCharFile -Content @'
**Karta Postaci:** https://example.com/sheet

**Tematy zastrzeżone:**
- Amputacja kończyn. Nie pod względem gore, co impaktu na późniejsze życie.

**Stan:**
- Dużo blizn po strzałach, poza tym zdrowy.

**Przedmioty specjalne:**
- Magiczny miecz - ostrze ze srebra
- Tarcza ognia - z rubinowym wgłębieniem

**Reputacja:**
- Pozytywna:
    - Erathia (pomógł w obronie)
    - Steadwick
- Neutralna: Deyja, Mythar, Enroth
- Negatywna:
    - Nighon: zabiła Thant
    - Nithal

**Dodatkowe informacje:**
- Ma bliznę na lewym policzku.
- Członek organizacji AV.

**Opisane sesje:**

[[_TOC_]]

### 2025-01-15, Testowa sesja, Narrator
Treść sesji...

### 2025-02-20, Druga sesja, InnyNarrator
Inna treść...
'@

    # Template/empty character file fixture
    $script:EmptyCharFile = Join-Path $script:TempRoot 'EmptyChar.md'
    Write-TestFile -Path $script:EmptyCharFile -Content @'
**Karta Postaci:** <TU_WKLEJAMY_LINK>

**Tematy zastrzeżone:**
brak

**Stan:**
Zdrowy.

**Przedmioty specjalne:**
Brak.

**Reputacja:**
- Pozytywna:
- Neutralna: Deyja, Erathia, Mythar, Mirvenis-Adur, Thuzal, Nithal, Werbin, NH, Steadwick, Enroth
- Negatywna:

**Dodatkowe informacje:**
- Brak.

**Opisane sesje:**

[[_TOC_]]
'@

    # Angle-bracket URL fixture
    $script:AngleBracketFile = Join-Path $script:TempRoot 'AngleBracket.md'
    Write-TestFile -Path $script:AngleBracketFile -Content @'
**Karta Postaci:** <https://docs.google.com/document/d/abc123>

**Tematy zastrzeżone:**
Brak.

**Stan:**
Zdrowy.

**Przedmioty specjalne:**
Brak.

**Reputacja:**
- Pozytywna: -
- Neutralna: Deyja
- Negatywna: -

**Dodatkowe informacje:**
Brak.

**Opisane sesje**

[[_TOC_]]
'@

    # Multi-line Stan fixture (Harume-style)
    $script:MultiLineStanFile = Join-Path $script:TempRoot 'MultiLineStan.md'
    Write-TestFile -Path $script:MultiLineStanFile -Content @'
**Karta Postaci:** https://example.com/sheet

**Tematy zastrzeżone:**
Brak.

**Stan:**
- Zginęła podczas potyczki.
Modlesius walnął ją piorunem i tyle pamięta. Ukradł jej 1/3 duszy.

**Przedmioty specjalne:**
Brak.

**Reputacja:**
- Pozytywna:
- Neutralna: Deyja
- Negatywna:

**Dodatkowe informacje:**
- Brak.

**Opisane sesje:**

[[_TOC_]]
'@
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Read-CharacterFile' {
    Context 'Full character file parsing' {
        BeforeAll {
            $script:Result = Read-CharacterFile -Path $script:FullCharFile
        }

        It 'parses CharacterSheet URL' {
            $script:Result.CharacterSheet | Should -Be 'https://example.com/sheet'
        }

        It 'parses RestrictedTopics' {
            $script:Result.RestrictedTopics | Should -BeLike '*Amputacja*'
        }

        It 'parses Condition' {
            $script:Result.Condition | Should -BeLike '*blizn*'
        }

        It 'parses SpecialItems' {
            $script:Result.SpecialItems.Count | Should -Be 2
            $script:Result.SpecialItems[0] | Should -BeLike '*Magiczny miecz*'
            $script:Result.SpecialItems[1] | Should -BeLike '*Tarcza ognia*'
        }

        It 'parses Reputation.Positive' {
            $script:Result.Reputation.Positive.Count | Should -Be 2
            $script:Result.Reputation.Positive[0].Location | Should -Be 'Erathia'
            $script:Result.Reputation.Positive[0].Detail | Should -BeLike '*obronie*'
            $script:Result.Reputation.Positive[1].Location | Should -Be 'Steadwick'
        }

        It 'parses Reputation.Neutral inline' {
            $script:Result.Reputation.Neutral.Count | Should -Be 3
            $script:Result.Reputation.Neutral[0].Location | Should -Be 'Deyja'
        }

        It 'parses Reputation.Negative with detail' {
            $script:Result.Reputation.Negative.Count | Should -Be 2
            $script:Result.Reputation.Negative[0].Location | Should -Be 'Nighon'
            $script:Result.Reputation.Negative[0].Detail | Should -BeLike '*Thant*'
        }

        It 'parses AdditionalNotes' {
            $script:Result.AdditionalNotes.Count | Should -Be 2
            $script:Result.AdditionalNotes[0] | Should -BeLike '*bliznę*'
        }

        It 'parses DescribedSessions' {
            $script:Result.DescribedSessions.Count | Should -Be 2
            $script:Result.DescribedSessions[0].Title | Should -BeLike '*Testowa sesja*'
            $script:Result.DescribedSessions[0].Narrator | Should -Be 'Narrator'
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
            $Result.CharacterSheet | Should -Be 'https://docs.google.com/document/d/abc123'
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
            $Result.Condition | Should -BeLike '*Zginęła*'
            $Result.Condition | Should -BeLike '*duszy*'
        }
    }

    Context 'Non-existent file' {
        It 'returns null for missing file' {
            $Result = Read-CharacterFile -Path (Join-Path $script:TempRoot 'nonexistent.md')
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
        $Lines = [System.Collections.Generic.List[string]]::new(@(
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
        $Lines = [System.Collections.Generic.List[string]]::new(@(
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

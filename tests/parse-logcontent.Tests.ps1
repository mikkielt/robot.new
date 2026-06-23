<#
    .SYNOPSIS
    Pester tests for parse-logcontent.ps1 (log content parsing).

    .DESCRIPTION
    Unit tests for Get-LogFormat, ConvertFrom-ChatLogContent,
    ConvertFrom-ProseContent, and ConvertFrom-LogContent covering:
    - Format detection (ChatLog vs Prose)
    - ChatLog parsing: timestamps, channels, speakers, pending timestamps
    - Prose parsing: location header heuristic, speaker detection
    - Location segment boundary computation
    - Edge cases: empty content, speaker-only lines, trailing pending timestamps

    Uses loading pattern C (standalone helper — dot-source directly).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'parse-logcontent.ps1')
}

# ── Get-LogFormat ────────────────────────────────────────────────────────────

Describe 'Get-LogFormat' {
    It 'detects ChatLog format when 2+ timestamps are present' {
        $Content = @(
            '[13:22] [Lokalny] Ivor: Proszę!'
            '[13:23] [Lokalny] Cuthbert: Hej.'
        ) -join "`n"
        Get-LogFormat -Content $Content | Should -Be 'ChatLog'
    }

    It 'returns Prose when fewer than 2 timestamps found' {
        $Content = @(
            '[13:22] Single timestamp line'
            'Some other text'
            'More text'
        ) -join "`n"
        Get-LogFormat -Content $Content | Should -Be 'Prose'
    }

    It 'returns Prose for content without any timestamps' {
        $Content = @(
            'Narrator: Some text here.'
            'Jenova: Hello.'
        ) -join "`n"
        Get-LogFormat -Content $Content | Should -Be 'Prose'
    }

    It 'skips empty lines during scan' {
        $Content = @(
            ''
            ''
            '[13:22] [Lokalny] Ivor: First'
            ''
            '[13:23] [Lokalny] Ivor: Second'
        ) -join "`n"
        Get-LogFormat -Content $Content | Should -Be 'ChatLog'
    }

    It 'scans at most 30 non-empty lines' {
        # Build 31 non-timestamp lines + 2 timestamp lines after them
        $Lines = @()
        for ($i = 0; $i -lt 31; $i++) {
            $Lines += "Line number $i with no timestamp"
        }
        $Lines += '[13:22] [Lokalny] Late timestamp 1'
        $Lines += '[13:23] [Lokalny] Late timestamp 2'
        $Content = $Lines -join "`n"
        # Should NOT detect ChatLog because timestamps are beyond the 30-line scan window
        Get-LogFormat -Content $Content | Should -Be 'Prose'
    }

    It 'detects ChatLog from fixture file' {
        $Content = [System.IO.File]::ReadAllText(
            (Join-Path $script:FixturesRoot 'log-chatlog.txt'))
        Get-LogFormat -Content $Content | Should -Be 'ChatLog'
    }

    It 'detects Prose from fixture file' {
        $Content = [System.IO.File]::ReadAllText(
            (Join-Path $script:FixturesRoot 'log-prose.txt'))
        Get-LogFormat -Content $Content | Should -Be 'Prose'
    }
}

# ── ConvertFrom-ChatLogContent ───────────────────────────────────────────────

Describe 'ConvertFrom-ChatLogContent' {
    Context 'basic parsing' {
        BeforeAll {
            $Content = @(
                ' Steadwick'
                '[13:22] [Lokalny] Ivor: Proszę!'
                '[13:23] [Grupowy] Deemer: Cuthbert rozgląda się.'
            ) -join "`n"
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'returns ChatLog format' {
            $script:Result.Format | Should -Be 'ChatLog'
        }

        It 'parses correct number of lines' {
            $script:Result.Lines.Count | Should -Be 2
        }

        It 'extracts timestamp' {
            $script:Result.Lines[0].Time | Should -Be '13:22'
            $script:Result.Lines[1].Time | Should -Be '13:23'
        }

        It 'extracts channel' {
            $script:Result.Lines[0].Channel | Should -Be 'Lokalny'
            $script:Result.Lines[1].Channel | Should -Be 'Grupowy'
        }

        It 'extracts speaker' {
            $script:Result.Lines[0].Speaker | Should -Be 'Ivor'
            $script:Result.Lines[1].Speaker | Should -Be 'Deemer'
        }

        It 'extracts text' {
            $script:Result.Lines[0].Text | Should -Be 'Proszę!'
            $script:Result.Lines[1].Text | Should -Be 'Cuthbert rozgląda się.'
        }

        It 'assigns correct segment index' {
            $script:Result.Lines[0].Segment | Should -Be 0
            $script:Result.Lines[1].Segment | Should -Be 0
        }

        It 'assigns sequential line indices' {
            $script:Result.Lines[0].Index | Should -Be 0
            $script:Result.Lines[1].Index | Should -Be 1
        }
    }

    Context 'location segments' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-chatlog.txt'))
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'detects all location segments' {
            $script:Result.LocationSegments.Count | Should -Be 3
        }

        It 'extracts location names' {
            $script:Result.LocationSegments[0].Raw | Should -Be 'Steadwick'
            $script:Result.LocationSegments[1].Raw | Should -Be 'Domostwo'
            $script:Result.LocationSegments[2].Raw | Should -Be 'Koszary'
        }

        It 'assigns sequential segment indices' {
            $script:Result.LocationSegments[0].Index | Should -Be 0
            $script:Result.LocationSegments[1].Index | Should -Be 1
            $script:Result.LocationSegments[2].Index | Should -Be 2
        }

        It 'computes StartLine for each segment' {
            $script:Result.LocationSegments[0].StartLine | Should -BeGreaterOrEqual 0
            $script:Result.LocationSegments[1].StartLine | Should -BeGreaterThan $script:Result.LocationSegments[0].StartLine
            $script:Result.LocationSegments[2].StartLine | Should -BeGreaterThan $script:Result.LocationSegments[1].StartLine
        }

        It 'computes EndLine for each segment' {
            # Each segment EndLine should be >= StartLine (non-empty segments)
            foreach ($Seg in $script:Result.LocationSegments) {
                $Seg.EndLine | Should -BeGreaterOrEqual $Seg.StartLine
            }
        }

        It 'last segment EndLine equals last line index' {
            $LastSeg = $script:Result.LocationSegments[$script:Result.LocationSegments.Count - 1]
            $LastSeg.EndLine | Should -Be ($script:Result.Lines.Count - 1)
        }
    }

    Context 'pending timestamp (timestamp-only line)' {
        BeforeAll {
            $Content = @(
                ' Lokacja'
                '[13:22] [Lokalny]'
                'Tazar ledwo co usiadł i znowu ktoś zawaraca głowę.'
            ) -join "`n"
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'parses continuation as a line with the pending timestamp' {
            $script:Result.Lines.Count | Should -Be 1
        }

        It 'assigns pending timestamp to continuation line' {
            $script:Result.Lines[0].Time | Should -Be '13:22'
        }

        It 'preserves channel from pending timestamp' {
            $script:Result.Lines[0].Channel | Should -Be 'Lokalny'
        }

        It 'uses continuation text as line text' {
            $script:Result.Lines[0].Text | Should -BeLike '*Tazar*'
        }
    }

    Context 'pending timestamp followed by empty line (no continuation)' {
        BeforeAll {
            $Content = @(
                ' Lokacja'
                '[13:22] [Lokalny]'
                ''
                '[13:25] [Lokalny] Ivor: Dalej.'
            ) -join "`n"
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'emits empty narration for pending timestamp' {
            $script:Result.Lines[0].Time | Should -Be '13:22'
            $script:Result.Lines[0].Speaker | Should -BeNullOrEmpty
            $script:Result.Lines[0].Text | Should -Be ''
        }

        It 'parses subsequent line normally' {
            $script:Result.Lines[1].Time | Should -Be '13:25'
            $script:Result.Lines[1].Speaker | Should -Be 'Ivor'
        }
    }

    Context 'trailing pending timestamp at end of content' {
        BeforeAll {
            $Content = @(
                ' Lokacja'
                '[13:22] [Lokalny] Ivor: Start.'
                '[13:30] [Lokalny]'
            ) -join "`n"
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'finalizes trailing pending timestamp as empty narration' {
            $script:Result.Lines.Count | Should -Be 2
            $script:Result.Lines[1].Time | Should -Be '13:30'
            $script:Result.Lines[1].Speaker | Should -BeNullOrEmpty
            $script:Result.Lines[1].Text | Should -Be ''
        }
    }

    Context 'speaker-only line (no text after colon)' {
        BeforeAll {
            $Content = @(
                ' Lokacja'
                '[13:22] [Lokalny] Ivor:'
            ) -join "`n"
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'extracts speaker with empty text' {
            $script:Result.Lines[0].Speaker | Should -Be 'Ivor'
            $script:Result.Lines[0].Text | Should -Be ''
        }
    }

    Context 'narration line (no speaker pattern)' {
        BeforeAll {
            $Content = @(
                ' Lokacja'
                '[13:22] [Lokalny] Rozległo się pukanie do drzwi.'
            ) -join "`n"
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'has null speaker for narration' {
            $script:Result.Lines[0].Speaker | Should -BeNullOrEmpty
        }

        It 'preserves full narration text' {
            $script:Result.Lines[0].Text | Should -Be 'Rozległo się pukanie do drzwi.'
        }
    }

    Context 'multiple location segments from fixture' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-chatlog-avlee.txt'))
            $script:Result = ConvertFrom-ChatLogContent -Content $Content
        }

        It 'detects all 7 location segments' {
            $script:Result.LocationSegments.Count | Should -Be 7
        }

        It 'handles repeated location names' {
            # AvLee appears multiple times
            $AvLeeSegments = @($script:Result.LocationSegments | Where-Object { $_.Raw -eq 'AvLee' })
            $AvLeeSegments.Count | Should -Be 3
        }
    }

    Context 'whitespace-only content' {
        BeforeAll {
            $script:Result = ConvertFrom-ChatLogContent -Content ' '
        }

        It 'returns empty Lines array' {
            $script:Result.Lines.Count | Should -Be 0
        }

        It 'returns empty LocationSegments array' {
            $script:Result.LocationSegments.Count | Should -Be 0
        }
    }
}

# ── ConvertFrom-ProseContent ─────────────────────────────────────────────────

Describe 'ConvertFrom-ProseContent' {
    Context 'basic parsing' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-prose.txt'))
            $script:Result = ConvertFrom-ProseContent -Content $Content
        }

        It 'returns Prose format' {
            $script:Result.Format | Should -Be 'Prose'
        }

        It 'parses all dialogue/narration lines' {
            $script:Result.Lines.Count | Should -BeGreaterThan 0
        }

        It 'has null Time for all lines' {
            foreach ($L in $script:Result.Lines) {
                $L.Time | Should -BeNullOrEmpty
            }
        }

        It 'has null Channel for all lines' {
            foreach ($L in $script:Result.Lines) {
                $L.Channel | Should -BeNullOrEmpty
            }
        }

        It 'extracts speakers correctly' {
            $Speakers = @($script:Result.Lines | Where-Object { $_.Speaker } |
                Select-Object -ExpandProperty Speaker -Unique)
            $Speakers | Should -Contain 'Narrator'
            $Speakers | Should -Contain 'Jenova'
            $Speakers | Should -Contain 'Ryland'
        }
    }

    Context 'location segments' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-prose.txt'))
            $script:Result = ConvertFrom-ProseContent -Content $Content
        }

        It 'detects both location segments' {
            $script:Result.LocationSegments.Count | Should -Be 2
        }

        It 'extracts location names' {
            $script:Result.LocationSegments[0].Raw | Should -Be 'Karczma pod Liściem Dębu'
            $script:Result.LocationSegments[1].Raw | Should -Be 'Trakt do Ithanu'
        }

        It 'computes EndLine correctly' {
            $LastSeg = $script:Result.LocationSegments[$script:Result.LocationSegments.Count - 1]
            $LastSeg.EndLine | Should -Be ($script:Result.Lines.Count - 1)
        }
    }

    Context 'location header heuristic' {
        It 'requires empty line before location header' {
            # No empty line before second location → not treated as location
            $Content = @(
                'Lokacja Pierwsza'
                ''
                'Narrator: Tekst.'
                'Lokacja Druga'
                ''
                'Narrator: Tekst.'
            ) -join "`n"
            $Result = ConvertFrom-ProseContent -Content $Content
            # "Lokacja Druga" is NOT preceded by empty line (preceded by Speaker line)
            # so it should NOT be a location header
            $Result.LocationSegments.Count | Should -Be 1
        }

        It 'rejects lines longer than 60 characters as locations' {
            $LongName = 'A' * 61
            $Content = @(
                $LongName
                ''
                'Narrator: Tekst.'
            ) -join "`n"
            $Result = ConvertFrom-ProseContent -Content $Content
            # 61-char line should not be a location
            $Result.LocationSegments.Count | Should -Be 0
        }

        It 'rejects Speaker: pattern as location header' {
            $Content = @(
                'Narrator: Opowieść zaczęła się tutaj.'
                ''
                'Narrator: I tak dalej.'
            ) -join "`n"
            $Result = ConvertFrom-ProseContent -Content $Content
            $Result.LocationSegments.Count | Should -Be 0
        }

        It 'treats start of content as "after empty line"' {
            # First line (at start) should be treated as location header
            $Content = @(
                'Moja Lokacja'
                ''
                'Narrator: Tekst.'
            ) -join "`n"
            $Result = ConvertFrom-ProseContent -Content $Content
            $Result.LocationSegments.Count | Should -Be 1
            $Result.LocationSegments[0].Raw | Should -Be 'Moja Lokacja'
        }
    }

    Context 'multiple location segments from dungeon fixture' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-prose-dungeon.txt'))
            $script:Result = ConvertFrom-ProseContent -Content $Content
        }

        It 'detects all 7 location segments' {
            $script:Result.LocationSegments.Count | Should -Be 7
        }

        It 'handles repeated location names' {
            $Repeated = @($script:Result.LocationSegments |
                Where-Object { $_.Raw -eq 'Piekielna Grota p.1' })
            $Repeated.Count | Should -Be 2
        }
    }

    Context 'whitespace-only content' {
        BeforeAll {
            $script:Result = ConvertFrom-ProseContent -Content ' '
        }

        It 'returns empty Lines array' {
            $script:Result.Lines.Count | Should -Be 0
        }

        It 'returns empty LocationSegments array' {
            $script:Result.LocationSegments.Count | Should -Be 0
        }
    }
}

# ── ConvertFrom-LogContent (dispatcher) ──────────────────────────────────────

Describe 'ConvertFrom-LogContent' {
    It 'auto-detects and routes ChatLog format' {
        $Content = [System.IO.File]::ReadAllText(
            (Join-Path $script:FixturesRoot 'log-chatlog.txt'))
        $Result = ConvertFrom-LogContent -Content $Content
        $Result.Format | Should -Be 'ChatLog'
        $Result.Lines.Count | Should -BeGreaterThan 0
        $Result.LocationSegments.Count | Should -BeGreaterThan 0
    }

    It 'auto-detects and routes Prose format' {
        $Content = [System.IO.File]::ReadAllText(
            (Join-Path $script:FixturesRoot 'log-prose.txt'))
        $Result = ConvertFrom-LogContent -Content $Content
        $Result.Format | Should -Be 'Prose'
        $Result.Lines.Count | Should -BeGreaterThan 0
        $Result.LocationSegments.Count | Should -BeGreaterThan 0
    }

    Context 'ChatLog fixture produces same results via dispatcher' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-chatlog.txt'))
            $script:Direct = ConvertFrom-ChatLogContent -Content $Content
            $script:Dispatched = ConvertFrom-LogContent -Content $Content
        }

        It 'matches line count' {
            $script:Dispatched.Lines.Count | Should -Be $script:Direct.Lines.Count
        }

        It 'matches segment count' {
            $script:Dispatched.LocationSegments.Count | Should -Be $script:Direct.LocationSegments.Count
        }
    }

    Context 'Prose fixture produces same results via dispatcher' {
        BeforeAll {
            $Content = [System.IO.File]::ReadAllText(
                (Join-Path $script:FixturesRoot 'log-prose.txt'))
            $script:Direct = ConvertFrom-ProseContent -Content $Content
            $script:Dispatched = ConvertFrom-LogContent -Content $Content
        }

        It 'matches line count' {
            $script:Dispatched.Lines.Count | Should -Be $script:Direct.Lines.Count
        }

        It 'matches segment count' {
            $script:Dispatched.LocationSegments.Count | Should -Be $script:Direct.LocationSegments.Count
        }
    }
}

# ── Resolve-MessageMentions ───────────────────────────────────────────────────

Describe 'Resolve-MessageMentions' {
    BeforeAll {
        Import-RobotModule  # Resolve-Name lives in the module, not the dot-sourced file

        # Mock NameIndex matching the real Get-NameIndex return format.
        # Inner Index is Dictionary[string, object] keyed by lowercase token; each
        # value carries Owner, OwnerType, Source, Priority, Ambiguous.
        $SolmyrEntity   = [PSCustomObject]@{ Name = 'Solmyr';   Type = 'NPC' }
        $HaartEntity    = [PSCustomObject]@{ Name = 'Lord Haart'; Type = 'NPC' }
        $IvorEntity     = [PSCustomObject]@{ Name = 'Ivor';     Type = 'NPC' }
        $SteadwickLoc   = [PSCustomObject]@{ Name = 'Steadwick'; Type = 'Lokacja' }
        $HotelLoc       = [PSCustomObject]@{ Name = 'Alabastrowy Hotel'; Type = 'Lokacja' }

        $InnerIndex = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $InnerIndex['solmyr']    = [PSCustomObject]@{ Owner = $SolmyrEntity;   OwnerType = 'NPC';     Source = 'Solmyr';   Priority = 1; Ambiguous = $false }
        $InnerIndex['lord haart'] = [PSCustomObject]@{ Owner = $HaartEntity;   OwnerType = 'NPC';     Source = 'Lord Haart'; Priority = 1; Ambiguous = $false }
        $InnerIndex['lord']      = [PSCustomObject]@{ Owner = $HaartEntity;   OwnerType = 'NPC';     Source = 'Lord';     Priority = 2; Ambiguous = $false }
        $InnerIndex['ivor']      = [PSCustomObject]@{ Owner = $IvorEntity;    OwnerType = 'NPC';     Source = 'Ivor';     Priority = 1; Ambiguous = $false }
        $InnerIndex['steadwick'] = [PSCustomObject]@{ Owner = $SteadwickLoc;  OwnerType = 'Lokacja'; Source = 'Steadwick'; Priority = 1; Ambiguous = $false }
        $InnerIndex['alabastrowy hotel'] = [PSCustomObject]@{ Owner = $HotelLoc; OwnerType = 'Lokacja'; Source = 'Alabastrowy Hotel'; Priority = 1; Ambiguous = $false }

        # Stem index for declension matching: "solmyra" stems to "solmyr"
        $InnerStemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $List = [System.Collections.Generic.List[string]]::new()
        $List.Add('solmyr')
        $InnerStemIndex['solmyr'] = $List

        $script:MentionIndex = @{
            Index     = $InnerIndex
            StemIndex = $InnerStemIndex
            BKTree    = $null
        }
    }

    It 'returns empty array for empty text' {
        $Result = Resolve-MessageMentions -Text '' -Index $script:MentionIndex
        @($Result).Count | Should -Be 0
    }

    It 'returns empty array for whitespace-only text' {
        $Result = Resolve-MessageMentions -Text "   `t  " -Index $script:MentionIndex
        @($Result).Count | Should -Be 0
    }

    It 'ignores all-lowercase text (Capitalized filter)' {
        $Result = Resolve-MessageMentions -Text 'widziałem solmyra w karczmie' -Index $script:MentionIndex
        @($Result).Count | Should -Be 0
    }

    It 'matches a single Capitalized proper noun' {
        $Result = Resolve-MessageMentions -Text 'Tam stał Solmyr.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 1
        $Result[0].Resolved | Should -Be 'Solmyr'
        $Result[0].Raw | Should -Be 'Solmyr'
    }

    It 'prefers 2-gram over 1-gram (longest-match-wins)' {
        # "Lord" alone resolves, and "Lord Haart" also resolves — the 2-gram MUST win
        $Result = Resolve-MessageMentions -Text 'Wszedł Lord Haart bez pukania.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 1
        $Result[0].Resolved | Should -Be 'Lord Haart'
        $Result[0].Raw | Should -Be 'Lord Haart'
    }

    It 'resolves declension form via Stage 2' {
        # "Solmyra" is genitive of "Solmyr" — must hit via the stem index
        $Result = Resolve-MessageMentions -Text 'Widziałem Solmyra w lesie.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 1
        $Result[0].Resolved | Should -Be 'Solmyr'
        $Result[0].Raw | Should -Be 'Solmyra'
    }

    It 'does not span a 2-gram across a sentence boundary' {
        # Without the boundary, "Solmyr Lord" → 2-gram lookup; with it, two 1-gram lookups
        $Result = Resolve-MessageMentions -Text 'Wszedł Solmyr. Lord Haart spał.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 2
        $Result[0].Resolved | Should -Be 'Solmyr'
        $Result[1].Resolved | Should -Be 'Lord Haart'
    }

    It 'extracts multiple distinct mentions in the same sentence' {
        $Result = Resolve-MessageMentions -Text 'Solmyr i Ivor opuścili Steadwick.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 3
        $Names = @($Result.Resolved | Sort-Object)
        $Names | Should -Be @('Ivor', 'Solmyr', 'Steadwick')
    }

    It 'records correct Offset and Length' {
        $Text = 'Tam stał Solmyr.'
        $Result = Resolve-MessageMentions -Text $Text -Index $script:MentionIndex
        $Result[0].Offset | Should -Be ($Text.IndexOf('Solmyr'))
        $Result[0].Length | Should -Be 'Solmyr'.Length
    }

    It 'uses the shared cache for repeat resolutions' {
        $Cache = @{}
        $Text  = 'Solmyr przyszedł. Solmyr odszedł.'
        $Result = Resolve-MessageMentions -Text $Text -Index $script:MentionIndex -Cache $Cache
        @($Result).Count | Should -Be 2
        # Cache MUST have the resolved entry keyed by query
        $Cache.Keys.Count | Should -BeGreaterThan 0
    }

    It 'matches a 2-gram entity with Polish diacritics' {
        $Result = Resolve-MessageMentions -Text 'Spotkanie w Alabastrowy Hotel jutro.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 1
        $Result[0].Resolved | Should -Be 'Alabastrowy Hotel'
    }

    It 'returns empty for capitalized words that do not resolve (NoFuzzy)' {
        # "Karczmie" is capitalized but not in the index — fuzzy is disabled so no match
        $Result = Resolve-MessageMentions -Text 'Wszedł do Karczmie.' -Index $script:MentionIndex
        @($Result).Count | Should -Be 0
    }
}


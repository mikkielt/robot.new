<#
    .SYNOPSIS
    Pester tests for log fetch helpers, log content parser, and Get-SessionLog.

    .DESCRIPTION
    Tests URL normalization, filename generation, format detection, ChatLog/Prose
    parsing, cross-referenced output schema, and the Get-SessionLog pipeline.
    All HTTP calls are avoided by using fixture files and mocking.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source private helpers directly for unit testing
    . (Join-Path $script:ModuleRoot 'private' 'log-fetchhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'parse-logcontent.ps1')

    # Load fixture content
    $script:ChatLogContent = [System.IO.File]::ReadAllText(
        (Join-Path $script:FixturesRoot 'log-chatlog.txt'))
    $script:ProseContent = [System.IO.File]::ReadAllText(
        (Join-Path $script:FixturesRoot 'log-prose.txt'))
}

# ── URL Normalization ──────────────────────────────────────────────────────────

Describe 'Normalize-LogUrl' {
    It 'converts non-raw pastebin URL to raw' {
        Normalize-LogUrl -Url 'https://pastebin.com/wqhtQ5Wq' |
            Should -Be 'https://pastebin.com/raw/wqhtQ5Wq'
    }

    It 'preserves already-raw pastebin URL' {
        Normalize-LogUrl -Url 'https://pastebin.com/raw/wqhtQ5Wq' |
            Should -Be 'https://pastebin.com/raw/wqhtQ5Wq'
    }

    It 'handles http protocol' {
        Normalize-LogUrl -Url 'http://pastebin.com/ABC123' |
            Should -Be 'https://pastebin.com/raw/ABC123'
    }

    It 'strips trailing slash' {
        Normalize-LogUrl -Url 'https://pastebin.com/wqhtQ5Wq/' |
            Should -Be 'https://pastebin.com/raw/wqhtQ5Wq'
    }

    It 'strips whitespace' {
        Normalize-LogUrl -Url '  https://pastebin.com/raw/ABC  ' |
            Should -Be 'https://pastebin.com/raw/ABC'
    }

    It 'passes through non-pastebin URLs with https' {
        Normalize-LogUrl -Url 'http://example.com/log.txt' |
            Should -Be 'https://example.com/log.txt'
    }
}

# ── Filename Generation ────────────────────────────────────────────────────────

Describe 'ConvertTo-LogFileName' {
    It 'strips protocol and non-alphanumeric chars' {
        ConvertTo-LogFileName -NormalizedUrl 'https://pastebin.com/raw/wqhtQ5Wq' |
            Should -Be 'pastebincomrawwqhtQ5Wq'
    }

    It 'handles URL with query parameters' {
        ConvertTo-LogFileName -NormalizedUrl 'https://example.com/log?id=123&v=2' |
            Should -Be 'examplecomlogid123v2'
    }
}

# ── Format Detection ──────────────────────────────────────────────────────────

Describe 'Get-LogFormat' {
    It 'detects ChatLog format' {
        Get-LogFormat -Content $script:ChatLogContent | Should -Be 'ChatLog'
    }

    It 'detects Prose format' {
        Get-LogFormat -Content $script:ProseContent | Should -Be 'Prose'
    }

    It 'returns Prose for content with only whitespace' {
        Get-LogFormat -Content ' ' | Should -Be 'Prose'
    }

    It 'returns Prose for plain text without timestamps' {
        Get-LogFormat -Content "Line one`nLine two`nLine three" | Should -Be 'Prose'
    }
}

# ── ChatLog Parser ─────────────────────────────────────────────────────────────

Describe 'ConvertFrom-ChatLogContent' {
    BeforeAll {
        $script:ChatResult = ConvertFrom-ChatLogContent -Content $script:ChatLogContent
    }

    It 'sets Format to ChatLog' {
        $script:ChatResult.Format | Should -Be 'ChatLog'
    }

    It 'detects three location segments' {
        $script:ChatResult.LocationSegments.Count | Should -Be 3
    }

    It 'extracts location names correctly' {
        $script:ChatResult.LocationSegments[0].Raw | Should -Be 'Steadwick'
        $script:ChatResult.LocationSegments[1].Raw | Should -Be 'Domostwo'
        $script:ChatResult.LocationSegments[2].Raw | Should -Be 'Koszary'
    }

    It 'assigns sequential segment indices' {
        $script:ChatResult.LocationSegments[0].Index | Should -Be 0
        $script:ChatResult.LocationSegments[1].Index | Should -Be 1
        $script:ChatResult.LocationSegments[2].Index | Should -Be 2
    }

    It 'parses chat lines with time and channel' {
        $FirstLine = $script:ChatResult.Lines[0]
        $FirstLine.Time | Should -Be '13:22'
        $FirstLine.Channel | Should -Be 'Lokalny'
    }

    It 'extracts speaker from Speaker: text pattern' {
        $SpeakerLine = $script:ChatResult.Lines | Where-Object { $_.Speaker -eq 'Ivor' } | Select-Object -First 1
        $SpeakerLine | Should -Not -BeNullOrEmpty
        $SpeakerLine.Text | Should -Be 'Proszę!'
    }

    It 'returns null speaker for narration lines' {
        $NarrationLine = $script:ChatResult.Lines[0]
        $NarrationLine.Speaker | Should -BeNullOrEmpty
        $NarrationLine.Text | Should -Match 'pukanie'
    }

    It 'handles continuation lines (timestamp with no inline text)' {
        $ContinuationLine = $script:ChatResult.Lines | Where-Object { $_.Text -match 'ledwo co usiadł' } | Select-Object -First 1
        $ContinuationLine | Should -Not -BeNullOrEmpty
        $ContinuationLine.Time | Should -Be '13:22'
        $ContinuationLine.Channel | Should -Be 'Lokalny'
    }

    It 'links lines to their location segment' {
        # Lines in the first segment should have Segment = 0
        $FirstSegLines = $script:ChatResult.Lines | Where-Object { $_.Segment -eq 0 }
        $FirstSegLines.Count | Should -BeGreaterThan 0

        # Lines in the second segment should have Segment = 1
        $SecondSegLines = $script:ChatResult.Lines | Where-Object { $_.Segment -eq 1 }
        $SecondSegLines.Count | Should -BeGreaterThan 0
    }

    It 'computes StartLine and EndLine for segments' {
        $Seg0 = $script:ChatResult.LocationSegments[0]
        $Seg0.StartLine | Should -BeGreaterOrEqual 0
        $Seg0.EndLine | Should -BeGreaterOrEqual $Seg0.StartLine

        $Seg1 = $script:ChatResult.LocationSegments[1]
        $Seg1.StartLine | Should -Be ($Seg0.EndLine + 1)
    }

    It 'detects Grupowy channel' {
        $GrupowyLine = $script:ChatResult.Lines | Where-Object { $_.Channel -eq 'Grupowy' } | Select-Object -First 1
        $GrupowyLine | Should -Not -BeNullOrEmpty
        $GrupowyLine.Speaker | Should -Be 'Deemer'
    }
}

# ── Prose Parser ───────────────────────────────────────────────────────────────

Describe 'ConvertFrom-ProseContent' {
    BeforeAll {
        $script:ProseResult = ConvertFrom-ProseContent -Content $script:ProseContent
    }

    It 'sets Format to Prose' {
        $script:ProseResult.Format | Should -Be 'Prose'
    }

    It 'detects two location segments' {
        $script:ProseResult.LocationSegments.Count | Should -Be 2
    }

    It 'extracts location names' {
        $script:ProseResult.LocationSegments[0].Raw | Should -Match 'Karczma'
        $script:ProseResult.LocationSegments[1].Raw | Should -Match 'Trakt'
    }

    It 'parses Speaker: text lines' {
        $JenovaLine = $script:ProseResult.Lines | Where-Object { $_.Speaker -eq 'Jenova' } | Select-Object -First 1
        $JenovaLine | Should -Not -BeNullOrEmpty
        $JenovaLine.Text | Should -Match 'bandytach'
    }

    It 'sets Time and Channel to null for prose lines' {
        $AnyLine = $script:ProseResult.Lines[0]
        $AnyLine.Time | Should -BeNullOrEmpty
        $AnyLine.Channel | Should -BeNullOrEmpty
    }
}

# ── ConvertFrom-LogContent dispatcher ──────────────────────────────────────────

Describe 'ConvertFrom-LogContent' {
    It 'dispatches ChatLog content correctly' {
        $Result = ConvertFrom-LogContent -Content $script:ChatLogContent
        $Result.Format | Should -Be 'ChatLog'
    }

    It 'dispatches Prose content correctly' {
        $Result = ConvertFrom-LogContent -Content $script:ProseContent
        $Result.Format | Should -Be 'Prose'
    }
}

# ── Get-SessionLog ─────────────────────────────────────────────────────────────

Describe 'Get-SessionLog' {
    BeforeAll {
        # Create a temp directory to simulate res/logs/
        $script:TempLogDir = New-TestTempDir

        # Write fixture content as if it was fetched
        $ChatFileName = ConvertTo-LogFileName -NormalizedUrl 'https://pastebin.com/raw/TestChat'
        $ProseFileName = ConvertTo-LogFileName -NormalizedUrl 'https://pastebin.com/raw/TestProse'
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($script:TempLogDir, $ChatFileName),
            $script:ChatLogContent)
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($script:TempLogDir, $ProseFileName),
            $script:ProseContent)

        # Build mock session objects
        $script:MockSession1 = [PSCustomObject]@{
            Title     = 'Test Session 1'
            Date      = [datetime]::Parse('2024-06-15')
            Locations = @('Steadwick', 'Koszary')
            Logs      = @('https://pastebin.com/raw/TestChat')
        }
        $script:MockSession2 = [PSCustomObject]@{
            Title     = 'Test Session 2'
            Date      = [datetime]::Parse('2024-06-16')
            Locations = @('Ithan')
            Logs      = @('https://pastebin.com/raw/TestProse')
        }
        $script:MockSessionNoLogs = [PSCustomObject]@{
            Title     = 'No Logs'
            Date      = [datetime]::Parse('2024-06-17')
            Locations = @()
            Logs      = @()
        }
    }

    AfterAll {
        Remove-TestTempDir
    }

    It 'returns parsed log for a single session with -SkipFetch' {
        $Result = Get-SessionLog -Session $script:MockSession1 `
            -LogDirectory $script:TempLogDir -SkipFetch
        $Result | Should -Not -BeNullOrEmpty
        $Result.Logs.Count | Should -Be 1
        $Result.Logs[0].Format | Should -Be 'ChatLog'
    }

    It 'returns Logs array with cross-referenced properties' {
        $Result = Get-SessionLog -Session $script:MockSession1 `
            -LogDirectory $script:TempLogDir -SkipFetch
        $Log = $Result.Logs[0]
        $Log.Lines | Should -Not -BeNullOrEmpty
        $Log.LocationSegments | Should -Not -BeNullOrEmpty
        $Log.Speakers | Should -Not -BeNullOrEmpty
    }

    It 'aggregates speakers with line counts' {
        $Result = Get-SessionLog -Session $script:MockSession1 `
            -LogDirectory $script:TempLogDir -SkipFetch
        $Speakers = $Result.Logs[0].Speakers
        $Ivor = $Speakers | Where-Object { $_.Raw -eq 'Ivor' }
        $Ivor | Should -Not -BeNullOrEmpty
        $Ivor.LineCount | Should -BeGreaterThan 0
        $Ivor.Lines.Count | Should -Be $Ivor.LineCount
    }

    It 'aggregates channels for ChatLog' {
        $Result = Get-SessionLog -Session $script:MockSession1 `
            -LogDirectory $script:TempLogDir -SkipFetch
        $Channels = $Result.Logs[0].Channels
        $Channels | Should -Not -BeNullOrEmpty
        $Lokalny = $Channels | Where-Object { $_.Name -eq 'Lokalny' }
        $Lokalny | Should -Not -BeNullOrEmpty
    }

    It 'sets Channels to null for Prose format' {
        $Result = Get-SessionLog -Session $script:MockSession2 `
            -LogDirectory $script:TempLogDir -SkipFetch
        $Result.Logs[0].Channels | Should -BeNullOrEmpty
    }

    It 'handles pipeline input from multiple sessions' {
        $Results = @($script:MockSession1, $script:MockSession2) |
            Get-SessionLog -LogDirectory $script:TempLogDir -SkipFetch
        @($Results).Count | Should -Be 2
    }

    It 'skips sessions with no log URLs' {
        $Results = @($script:MockSessionNoLogs, $script:MockSession1) |
            Get-SessionLog -LogDirectory $script:TempLogDir -SkipFetch
        @($Results).Count | Should -Be 1
    }

    It 'deduplicates URLs across sessions sharing the same log' {
        $DupSession = [PSCustomObject]@{
            Title = 'Dup Session'
            Date  = [datetime]::Parse('2024-06-18')
            Logs  = @('https://pastebin.com/raw/TestChat')  # same as MockSession1
        }
        $Results = @($script:MockSession1, $DupSession) |
            Get-SessionLog -LogDirectory $script:TempLogDir -SkipFetch
        @($Results).Count | Should -Be 2
        $Results[0].Logs[0].Url | Should -Be $Results[1].Logs[0].Url
    }
}

# ── Get-SessionLog mention extraction ──────────────────────────────────────────

Describe 'Get-SessionLog mention extraction' {
    BeforeAll {
        $script:MentionDir = New-TestTempDir

        # Inline ChatLog fixture: Ivor speaks of Solmyr (and a declension form) in two
        # separate lines so the aggregation can be verified.
        $MentionContent = @(
            ' Domostwo'
            '[13:00] [Lokalny] Ivor: Widziałem Solmyra w lesie.'
            '[13:01] [Lokalny] Cuthbert: A Lord Haart? Słyszałem, że przybył.'
            '[13:02] [Lokalny] Ivor: Solmyr odszedł rano.'
        ) -join "`n"
        $script:MentionUrl = 'https://pastebin.com/raw/MentionChat'
        $MentionFile = ConvertTo-LogFileName -NormalizedUrl $script:MentionUrl
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($script:MentionDir, $MentionFile),
            $MentionContent)

        $script:MentionSession = [PSCustomObject]@{
            Title = 'Mention Test'
            Date  = [datetime]::Parse('2024-07-01')
            Logs  = @($script:MentionUrl)
        }

        # Mock index containing only the entities we expect to be mentioned
        $SolmyrEntity = [PSCustomObject]@{ Name = 'Solmyr';     Type = 'NPC' }
        $HaartEntity  = [PSCustomObject]@{ Name = 'Lord Haart'; Type = 'NPC' }
        $IvorEntity   = [PSCustomObject]@{ Name = 'Ivor';       Type = 'NPC' }
        $CuthEntity   = [PSCustomObject]@{ Name = 'Cuthbert';   Type = 'NPC' }
        $DomoLoc      = [PSCustomObject]@{ Name = 'Domostwo';   Type = 'Lokacja' }

        $InnerIndex = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $InnerIndex['solmyr']     = [PSCustomObject]@{ Owner = $SolmyrEntity; OwnerType = 'NPC';     Source = 'Solmyr';     Priority = 1; Ambiguous = $false }
        $InnerIndex['lord haart'] = [PSCustomObject]@{ Owner = $HaartEntity;  OwnerType = 'NPC';     Source = 'Lord Haart'; Priority = 1; Ambiguous = $false }
        $InnerIndex['ivor']       = [PSCustomObject]@{ Owner = $IvorEntity;   OwnerType = 'NPC';     Source = 'Ivor';       Priority = 1; Ambiguous = $false }
        $InnerIndex['cuthbert']   = [PSCustomObject]@{ Owner = $CuthEntity;   OwnerType = 'NPC';     Source = 'Cuthbert';   Priority = 1; Ambiguous = $false }
        $InnerIndex['domostwo']   = [PSCustomObject]@{ Owner = $DomoLoc;      OwnerType = 'Lokacja'; Source = 'Domostwo';   Priority = 1; Ambiguous = $false }

        $StemList = [System.Collections.Generic.List[string]]::new()
        $StemList.Add('solmyr')
        $InnerStemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $InnerStemIndex['solmyr'] = $StemList

        $script:MentionIndex = @{
            Index     = $InnerIndex
            StemIndex = $InnerStemIndex
            BKTree    = $null
        }
    }

    AfterAll {
        Remove-TestTempDir
    }

    It 'omits Mentions/MentionsByLine when -Index is not provided' {
        $Result = Get-SessionLog -Session $script:MentionSession `
            -LogDirectory $script:MentionDir -SkipFetch
        $Log = $Result.Logs[0]
        $Log.Mentions       | Should -BeNullOrEmpty
        $Log.MentionsByLine | Should -BeNullOrEmpty
    }

    It 'populates aggregated Mentions[] when -Index is provided' {
        $Result = Get-SessionLog -Session $script:MentionSession `
            -LogDirectory $script:MentionDir -SkipFetch `
            -Index $script:MentionIndex
        $Log = $Result.Logs[0]
        $Log.Mentions | Should -Not -BeNullOrEmpty
        $Solmyr = $Log.Mentions | Where-Object { $_.Resolved -eq 'Solmyr' }
        $Solmyr | Should -Not -BeNullOrEmpty
        # Solmyr appears on two lines (one declension form, one nominative)
        $Solmyr.LineCount | Should -Be 2
    }

    It 'records the resolved entity Type in aggregated Mentions' {
        $Result = Get-SessionLog -Session $script:MentionSession `
            -LogDirectory $script:MentionDir -SkipFetch `
            -Index $script:MentionIndex
        $Solmyr = $Result.Logs[0].Mentions | Where-Object { $_.Resolved -eq 'Solmyr' }
        $Solmyr.Type | Should -Be 'NPC'
    }

    It 'builds MentionsByLine keyed by Line.Index' {
        $Result = Get-SessionLog -Session $script:MentionSession `
            -LogDirectory $script:MentionDir -SkipFetch `
            -Index $script:MentionIndex
        $MByL = $Result.Logs[0].MentionsByLine
        $MByL | Should -Not -BeNullOrEmpty
        # At least one line MUST carry a Solmyr mention
        $SolmyrLines = $MByL.Keys | Where-Object { @($MByL[$_]) | Where-Object { $_.Resolved -eq 'Solmyr' } }
        @($SolmyrLines).Count | Should -BeGreaterOrEqual 1
    }

    It 'matches Lord Haart as a 2-gram mention' {
        $Result = Get-SessionLog -Session $script:MentionSession `
            -LogDirectory $script:MentionDir -SkipFetch `
            -Index $script:MentionIndex
        $Haart = $Result.Logs[0].Mentions | Where-Object { $_.Resolved -eq 'Lord Haart' }
        $Haart | Should -Not -BeNullOrEmpty
        $Haart.LineCount | Should -Be 1
    }

    It 'honors -SkipMentions to suppress extraction while keeping speaker resolution' {
        $Result = Get-SessionLog -Session $script:MentionSession `
            -LogDirectory $script:MentionDir -SkipFetch `
            -Index $script:MentionIndex -SkipMentions
        $Log = $Result.Logs[0]
        $Log.Mentions       | Should -BeNullOrEmpty
        $Log.MentionsByLine | Should -BeNullOrEmpty
        # Speakers are still aggregated as usual
        $Log.Speakers | Should -Not -BeNullOrEmpty
    }
}

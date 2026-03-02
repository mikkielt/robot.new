<#
    .SYNOPSIS
    Pester tests for Get-NamedLogLocationReport.

    .DESCRIPTION
    Tests location resolution reporting from parsed session log data.
    Uses pre-built mock data instead of actual log fetching.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    . (Join-Path $script:ModuleRoot 'private' 'parse-logcontent.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'string-helpers.ps1')

    # Load fixture content and parse it
    $ChatLogContent = [System.IO.File]::ReadAllText(
        (Join-Path $script:FixturesRoot 'log-chatlog.txt'))
    $script:ParsedChat = ConvertFrom-ChatLogContent -Content $ChatLogContent

    # Build a mock NameIndex matching the real Get-NameIndex return format
    # Inner Index uses Dictionary<string, object> as Resolve-Name expects
    # Each entry has Owner (entity object), OwnerType, Source, Priority, Ambiguous
    $SteadwickEntity = [PSCustomObject]@{ Name = 'Steadwick' }
    $KoszaryEntity   = [PSCustomObject]@{ Name = 'Koszary' }

    $InnerIndex = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $InnerIndex['steadwick'] = [PSCustomObject]@{
        Owner = $SteadwickEntity; OwnerType = 'Lokacja'; Source = 'Steadwick'; Priority = 1; Ambiguous = $false
    }
    $InnerIndex['koszary'] = [PSCustomObject]@{
        Owner = $KoszaryEntity; OwnerType = 'Lokacja'; Source = 'Koszary'; Priority = 1; Ambiguous = $false
    }

    $InnerStemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $script:MockIndex = @{
        Index     = $InnerIndex
        StemIndex = $InnerStemIndex
        BKTree    = $null
    }

    # Build mock SessionLog output (as Get-SessionLog would produce)
    $script:MockSessionLog = [PSCustomObject]@{
        Logs = @(
            [PSCustomObject]@{
                Url              = 'https://pastebin.com/raw/TestChat'
                Format           = 'ChatLog'
                Lines            = $script:ParsedChat.Lines
                LocationSegments = $script:ParsedChat.LocationSegments
                Speakers         = @()
                Channels         = @()
            }
        )
    }

    # Build mock session for cross-referencing
    $script:MockSession = [PSCustomObject]@{
        Title     = 'Test Session'
        Date      = [datetime]::Parse('2024-06-15')
        Locations = @('Steadwick/Domostwo', 'Steadwick', 'Koszary')
        Logs      = @('https://pastebin.com/raw/TestChat')
    }
}

Describe 'Get-NamedLogLocationReport' {
    BeforeAll {
        $script:Report = Get-NamedLogLocationReport `
            -SessionLog $script:MockSessionLog `
            -Session $script:MockSession `
            -Index $script:MockIndex
    }

    It 'returns report entries' {
        $script:Report | Should -Not -BeNullOrEmpty
        @($script:Report).Count | Should -Be 1
    }

    It 'includes SessionTitle and SessionDate' {
        $Entry = @($script:Report)[0]
        $Entry.SessionTitle | Should -Be 'Test Session'
        $Entry.SessionDate | Should -Not -BeNullOrEmpty
    }

    It 'reports all three location segments' {
        $Entry = @($script:Report)[0]
        $Entry.Locations.Count | Should -Be 3
    }

    It 'resolves Steadwick as Exact match' {
        $Entry = @($script:Report)[0]
        $SteadwickLoc = $Entry.Locations | Where-Object { $_.Raw -eq 'Steadwick' }
        $SteadwickLoc | Should -Not -BeNullOrEmpty
        $SteadwickLoc.Resolved | Should -Be 'Steadwick'
    }

    It 'resolves Koszary' {
        $Entry = @($script:Report)[0]
        $KoszaryLoc = $Entry.Locations | Where-Object { $_.Raw -eq 'Koszary' }
        $KoszaryLoc | Should -Not -BeNullOrEmpty
        $KoszaryLoc.Resolved | Should -Be 'Koszary'
    }

    It 'marks Domostwo as unresolved' {
        $Entry = @($script:Report)[0]
        $DomostwoLoc = $Entry.Locations | Where-Object { $_.Raw -eq 'Domostwo' }
        $DomostwoLoc | Should -Not -BeNullOrEmpty
        $DomostwoLoc.Resolved | Should -BeNullOrEmpty
    }

    It 'marks Steadwick as InSessionMeta true' {
        $Entry = @($script:Report)[0]
        $SteadwickLoc = $Entry.Locations | Where-Object { $_.Raw -eq 'Steadwick' }
        $SteadwickLoc.InSessionMeta | Should -Be $true
    }

    It 'provides summary counts' {
        $Entry = @($script:Report)[0]
        $Entry.Summary.Total | Should -Be 3
        $Entry.Summary.Resolved | Should -Be 2
        $Entry.Summary.Unresolved | Should -Be 1
    }

    It 'accepts pipeline input' {
        $Results = @($script:MockSessionLog) |
            Get-NamedLogLocationReport -Session $script:MockSession -Index $script:MockIndex
        @($Results).Count | Should -Be 1
    }
}

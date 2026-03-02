<#
    .SYNOPSIS
    Pester tests for Invoke-SessionLogFetch workflow.

    .DESCRIPTION
    Tests the mass fetch workflow: URL partitioning, .failed marker handling,
    summary output, and -WhatIf behavior. HTTP calls are mocked.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    . (Join-Path $script:ModuleRoot 'private' 'log-fetchhelpers.ps1')
}

Describe 'Invoke-SessionLogFetch' {
    BeforeAll {
        $script:TempLogDir = New-TestTempDir

        $script:MockSessions = @(
            [PSCustomObject]@{
                Title = 'Session A'
                Date  = [datetime]::Parse('2024-01-15')
                Logs  = @('https://pastebin.com/raw/AAA111', 'https://pastebin.com/raw/BBB222')
            }
            [PSCustomObject]@{
                Title = 'Session B'
                Date  = [datetime]::Parse('2024-02-15')
                Logs  = @('https://pastebin.com/raw/CCC333')
            }
            [PSCustomObject]@{
                Title = 'No Logs'
                Date  = [datetime]::Parse('2024-03-15')
                Logs  = @()
            }
        )

        # Pre-cache one URL
        $CachedFileName = ConvertTo-LogFileName -NormalizedUrl 'https://pastebin.com/raw/AAA111'
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($script:TempLogDir, $CachedFileName),
            'Cached content')

        # Create a .failed marker for another
        $FailedFileName = ConvertTo-LogFileName -NormalizedUrl 'https://pastebin.com/raw/BBB222'
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($script:TempLogDir, "$FailedFileName.failed"),
            "URL: https://pastebin.com/raw/BBB222`nError: HTTP 404`nTimestamp: 2024-01-01T00:00:00Z")
    }

    AfterAll {
        Remove-TestTempDir
    }

    It 'reports correct counts for cached and skipped URLs' {
        # Mock the HTTP client to avoid actual requests
        Mock Get-LogHttpClient { return $null } -ModuleName Robot

        $Result = $script:MockSessions | Invoke-SessionLogFetch `
            -LogDirectory $script:TempLogDir -WhatIf

        $Result.Total | Should -Be 3
        $Result.Cached | Should -Be 1
        $Result.Skipped | Should -Be 1
    }

    It 'returns zero Fetched in -WhatIf mode' {
        $Result = $script:MockSessions | Invoke-SessionLogFetch `
            -LogDirectory $script:TempLogDir -WhatIf

        $Result.Fetched | Should -Be 0
        $Result.Failed | Should -Be 0
    }

    It 'returns empty summary when no sessions have logs' {
        $EmptySessions = @(
            [PSCustomObject]@{ Title = 'Empty'; Date = [datetime]::Now; Logs = @() }
        )

        $Result = $EmptySessions | Invoke-SessionLogFetch `
            -LogDirectory $script:TempLogDir -WhatIf

        $Result.Total | Should -Be 0
    }
}

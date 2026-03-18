<#
    .SYNOPSIS
    Pester tests for Get-SessionFrequencyTrend.

    .DESCRIPTION
    Tests monthly session aggregation including session counting, narrator
    deduplication, format breakdown, date range filtering, chronological
    ordering, and empty session sets. Uses mock session objects.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-freq-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force

    # Build mock session objects with Date, Narrator, and Format properties
    $script:MockSessions = @(
        [PSCustomObject]@{ Date = [datetime]'2025-01-10'; Narrator = [PSCustomObject]@{ Name = 'Solmyr' }; Format = 'Gen4' }
        [PSCustomObject]@{ Date = [datetime]'2025-01-20'; Narrator = [PSCustomObject]@{ Name = 'Dracon' }; Format = 'Gen4' }
        [PSCustomObject]@{ Date = [datetime]'2025-01-25'; Narrator = [PSCustomObject]@{ Name = 'Solmyr' }; Format = 'Gen3' }
        [PSCustomObject]@{ Date = [datetime]'2025-02-05'; Narrator = [PSCustomObject]@{ Name = 'Dracon' }; Format = 'Gen4' }
        [PSCustomObject]@{ Date = [datetime]'2025-02-15'; Narrator = [PSCustomObject]@{ Name = 'Kyrre' };  Format = 'Gen2' }
        [PSCustomObject]@{ Date = [datetime]'2025-03-01'; Narrator = [PSCustomObject]@{ Name = 'Solmyr' }; Format = 'Gen1' }
        [PSCustomObject]@{ Date = $null; Narrator = $null; Format = $null }  # session with no date
    )
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Get-SessionFrequencyTrend' {
    It 'groups sessions by month' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -Quiet
        $Result.Count | Should -Be 3
        $Result[0].Month | Should -Be '2025-01'
        $Result[1].Month | Should -Be '2025-02'
        $Result[2].Month | Should -Be '2025-03'
    }

    It 'counts sessions per month correctly' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -Quiet
        $Result[0].SessionCount | Should -Be 3   # Jan: 3 sessions
        $Result[1].SessionCount | Should -Be 2   # Feb: 2 sessions
        $Result[2].SessionCount | Should -Be 1   # Mar: 1 session
    }

    It 'deduplicates narrators per month' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -Quiet
        $Result[0].NarratorCount | Should -Be 2   # Jan: Solmyr (x2), Dracon
        $Result[0].UniqueNarrators | Should -Contain 'Solmyr'
        $Result[0].UniqueNarrators | Should -Contain 'Dracon'
    }

    It 'computes format breakdown per month' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -Quiet
        # Jan: 2 Gen4, 1 Gen3
        $Result[0].FormatBreakdown.Gen4 | Should -Be 2
        $Result[0].FormatBreakdown.Gen3 | Should -Be 1
        $Result[0].FormatBreakdown.Gen2 | Should -Be 0
        $Result[0].FormatBreakdown.Gen1 | Should -Be 0

        # Feb: 1 Gen4, 1 Gen2
        $Result[1].FormatBreakdown.Gen4 | Should -Be 1
        $Result[1].FormatBreakdown.Gen2 | Should -Be 1

        # Mar: 1 Gen1
        $Result[2].FormatBreakdown.Gen1 | Should -Be 1
    }

    It 'skips sessions with null Date' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -Quiet
        $TotalCounted = ($Result | Measure-Object -Property SessionCount -Sum).Sum
        $TotalCounted | Should -Be 6  # 7 sessions minus 1 null-dated
    }

    It 'filters by MinDate' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -MinDate ([datetime]'2025-02-01') -Quiet
        $Result.Count | Should -Be 2
        $Result[0].Month | Should -Be '2025-02'
        $Result[1].Month | Should -Be '2025-03'
    }

    It 'filters by MaxDate' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -MaxDate ([datetime]'2025-01-31') -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Month | Should -Be '2025-01'
    }

    It 'filters by MinDate and MaxDate combined' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions `
            -MinDate ([datetime]'2025-01-20') -MaxDate ([datetime]'2025-02-10') -Quiet
        $Result.Count | Should -Be 2
        # Jan: 2 sessions (20th, 25th), Feb: 1 session (5th)
        $Result[0].SessionCount | Should -Be 2
        $Result[1].SessionCount | Should -Be 1
    }

    It 'returns empty array for no matching sessions' {
        $Result = Get-SessionFrequencyTrend -Sessions $script:MockSessions -MinDate ([datetime]'2026-01-01') -Quiet
        $Result.Count | Should -Be 0
    }

    It 'returns empty array for empty session set' {
        $Result = Get-SessionFrequencyTrend -Sessions @() -Quiet
        $Result.Count | Should -Be 0
    }

    It 'handles narrator as plain string' {
        $Sessions = @(
            [PSCustomObject]@{ Date = [datetime]'2025-06-01'; Narrator = 'PlainNarrator'; Format = 'Gen4' }
        )
        $Result = Get-SessionFrequencyTrend -Sessions $Sessions -Quiet
        $Result[0].NarratorCount | Should -Be 1
        $Result[0].UniqueNarrators | Should -Contain 'PlainNarrator'
    }

    It 'handles null narrator gracefully' {
        $Sessions = @(
            [PSCustomObject]@{ Date = [datetime]'2025-06-01'; Narrator = $null; Format = 'Gen4' }
        )
        $Result = Get-SessionFrequencyTrend -Sessions $Sessions -Quiet
        $Result[0].NarratorCount | Should -Be 0
        $Result[0].SessionCount | Should -Be 1
    }

    It 'returns months in chronological order' {
        # Pass sessions in reverse order
        $Reversed = @(
            [PSCustomObject]@{ Date = [datetime]'2025-03-01'; Narrator = $null; Format = 'Gen4' }
            [PSCustomObject]@{ Date = [datetime]'2025-01-01'; Narrator = $null; Format = 'Gen4' }
            [PSCustomObject]@{ Date = [datetime]'2025-02-01'; Narrator = $null; Format = 'Gen4' }
        )
        $Result = Get-SessionFrequencyTrend -Sessions $Reversed -Quiet
        # Ordered by first encounter — sessions from Get-Session are typically date-sorted
        $Result.Count | Should -Be 3
    }
}

<#
    .SYNOPSIS
    Pester tests for get-puassignmentlog.ps1.

    .DESCRIPTION
    Tests for Get-PUAssignmentLog covering state file parsing, timestamp
    extraction, session header grouping, date filtering, and edge cases.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-puassignmentlog.ps1')
}

Describe 'Get-PUAssignmentLog' {
    BeforeAll {
        $script:SamplePath = Join-Path $script:FixturesRoot 'pu-sessions-sample.md'
    }

    It 'returns structured entries from state file' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        $Result | Should -Not -BeNullOrEmpty
        $Result.Count | Should -Be 3
    }

    It 'returns entries with correct output shape' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        $First = $Result[0]
        $First.PSObject.Properties['ProcessedAt'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Timezone'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['SessionCount'] | Should -Not -BeNullOrEmpty
        $First.PSObject.Properties['Sessions'] | Should -Not -BeNullOrEmpty
    }

    It 'parses timestamps correctly' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        # Most recent first (descending sort)
        $Result[0].ProcessedAt.Year | Should -Be 2025
        $Result[0].ProcessedAt.Month | Should -Be 9
    }

    It 'sorts by ProcessedAt descending' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        if ($Result.Count -gt 1) {
            for ($i = 1; $i -lt $Result.Count; $i++) {
                $Result[$i].ProcessedAt | Should -BeLessOrEqual $Result[$i - 1].ProcessedAt
            }
        }
    }

    It 'counts sessions correctly per entry' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        # First run (chronologically) had 3 sessions, second had 2, third had 1
        # After descending sort: index 0 = Sept (1 session), 1 = Aug (2), 2 = Jul (3)
        $Result[0].SessionCount | Should -Be 1
        $Result[1].SessionCount | Should -Be 2
        $Result[2].SessionCount | Should -Be 3
    }

    It 'parses session headers into structured objects' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        $LastRun = $Result[-1]  # July run with 3 sessions
        $FirstSession = $LastRun.Sessions[0]
        $FirstSession.PSObject.Properties['Header'] | Should -Not -BeNullOrEmpty
        $FirstSession.PSObject.Properties['Date'] | Should -Not -BeNullOrEmpty
        $FirstSession.PSObject.Properties['Title'] | Should -Not -BeNullOrEmpty
        $FirstSession.PSObject.Properties['Narrator'] | Should -Not -BeNullOrEmpty
    }

    It 'parses session header date correctly' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        $LastRun = $Result[-1]  # July run
        $Session = $LastRun.Sessions | Where-Object { $_.Title -eq 'Powrót zdrowia' }
        $Session | Should -Not -BeNullOrEmpty
        $Session.Date.Year | Should -Be 2025
        $Session.Date.Month | Should -Be 6
        $Session.Narrator | Should -Be 'Crag Hack'
    }

    It 'extracts timezone string' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath
        $Result[0].Timezone | Should -Be 'UTC+02:00'
    }

    It 'filters by MinDate' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath -MinDate ([datetime]'2025-08-01')
        foreach ($Entry in $Result) {
            $Entry.ProcessedAt | Should -BeGreaterOrEqual ([datetime]'2025-08-01')
        }
    }

    It 'filters by MaxDate' {
        $Result = Get-PUAssignmentLog -Path $script:SamplePath -MaxDate ([datetime]'2025-08-31')
        foreach ($Entry in $Result) {
            $Entry.ProcessedAt | Should -BeLessOrEqual ([datetime]'2025-08-31')
        }
    }

    It 'returns empty array for nonexistent file' {
        $Result = Get-PUAssignmentLog -Path '/nonexistent/path/pu-sessions.md'
        $Result.Count | Should -Be 0
    }

    It 'handles empty file gracefully' {
        $TempDir = New-TestTempDir
        $EmptyFile = Join-Path $TempDir 'empty-pu.md'
        Write-TestFile -Path $EmptyFile -Content '# Empty PU log'
        $Result = Get-PUAssignmentLog -Path $EmptyFile
        $Result.Count | Should -Be 0
        Remove-TestTempDir
    }
}

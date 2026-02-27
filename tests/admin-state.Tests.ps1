<#
    .SYNOPSIS
    Pester tests for admin-state.ps1.

    .DESCRIPTION
    Tests for Get-AdminHistoryEntries and Add-AdminHistoryEntry functions
    covering state file reading, header normalization, entry appending,
    and chronological sorting.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'admin-state.ps1')
}

Describe 'Get-AdminHistoryEntries' {
    It 'reads processed session headers from state file' {
        $Path = Join-Path $script:FixturesRoot 'pu-sessions.md'
        $Result = Get-AdminHistoryEntries -Path $Path
        $Result.GetType().Name | Should -BeLike 'HashSet*'
        $Result.Count | Should -BeGreaterThan 0
    }

    It 'normalizes headers (collapse whitespace, strip ### prefix)' {
        $Path = Join-Path $script:FixturesRoot 'pu-sessions.md'
        $Result = Get-AdminHistoryEntries -Path $Path
        # Should contain "2024-06-15, Ucieczka z Erathii, Solmyr" from fixtures
        $Result | Should -Contain '2024-06-15, Ucieczka z Erathii, Solmyr'
    }

    It 'returns empty HashSet for non-existent file' {
        $Result = Get-AdminHistoryEntries -Path '/nonexistent/path/file.md'
        $Result.Count | Should -Be 0
    }
}

Describe 'Add-AdminHistoryEntry' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'creates state file with preamble when missing' {
        $Path = Join-Path $script:TempDir 'new-state.md'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-01-01, Test Session, Narrator')
        [System.IO.File]::Exists($Path) | Should -BeTrue
        $Content = [System.IO.File]::ReadAllText($Path)
        $Content | Should -BeLike '*Historia*'
        $Content | Should -BeLike '*### 2025-01-01*'
    }

    It 'appends entries with timestamp to existing file' {
        $Path = Copy-FixtureToTemp -FixtureName 'pu-sessions.md'
        $Before = [System.IO.File]::ReadAllText($Path)
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-12-01, New Session, Author')
        $After = [System.IO.File]::ReadAllText($Path)
        $After.Length | Should -BeGreaterThan $Before.Length
        $After | Should -BeLike '*### 2025-12-01, New Session, Author*'
    }

    It 'added entries are readable by Get-AdminHistoryEntries' {
        $Path = Join-Path $script:TempDir 'roundtrip-state.md'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-06-01, RT Session, Narrator')
        $Result = Get-AdminHistoryEntries -Path $Path
        $Result | Should -Contain '2025-06-01, RT Session, Narrator'
    }

    It 'does nothing when Headers is empty' {
        $Path = Join-Path $script:TempDir 'empty-headers.md'
        Add-AdminHistoryEntry -Path $Path -Headers @()
        [System.IO.File]::Exists($Path) | Should -BeFalse
    }

    It 'sorts headers chronologically' {
        $Path = Join-Path $script:TempDir 'sorted-state.md'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-12-01, Later, N', '2025-01-01, Earlier, N')
        $Content = [System.IO.File]::ReadAllText($Path)
        $EarlierIdx = $Content.IndexOf('2025-01-01')
        $LaterIdx = $Content.IndexOf('2025-12-01')
        $EarlierIdx | Should -BeLessThan $LaterIdx
    }
}

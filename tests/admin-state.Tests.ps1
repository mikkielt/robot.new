<#
    .SYNOPSIS
    Pester tests for admin-state.ps1.

    .DESCRIPTION
    Tests for Save-JsonStateFile, Read-JsonStateFile, Get-AdminHistoryEntries,
    Add-AdminHistoryEntry, and Convert-PUHistoryToJson covering JSON state file
    operations, header normalization, round-trip fidelity, and migration conversion.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
}

Describe 'Save-JsonStateFile and Read-JsonStateFile' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'round-trips a hashtable through write and read' {
        $Path = Join-Path $script:TempDir 'roundtrip.json'
        $Data = [ordered]@{ version = 1; items = @('a', 'b') }
        Save-JsonStateFile -Path $Path -Data $Data
        $Result = Read-JsonStateFile -Path $Path
        $Result.version | Should -Be 1
        @($Result.items).Count | Should -Be 2
    }

    It 'creates parent directory automatically' {
        $Path = Join-Path $script:TempDir 'sub' 'dir' 'state.json'
        $Data = [ordered]@{ version = 1 }
        Save-JsonStateFile -Path $Path -Data $Data
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }

    It 'creates .bak backup and removes .tmp after write' {
        $Path = Join-Path $script:TempDir 'backup-test.json'
        Save-JsonStateFile -Path $Path -Data ([ordered]@{ v = 1 })
        Save-JsonStateFile -Path $Path -Data ([ordered]@{ v = 2 })
        [System.IO.File]::Exists("$Path.bak") | Should -BeTrue
        [System.IO.File]::Exists("$Path.tmp") | Should -BeFalse
        $Result = Read-JsonStateFile -Path $Path
        $Result.v | Should -Be 2
    }

    It 'recovers from corrupted primary using backup' {
        $Path = Join-Path $script:TempDir 'corrupt-test.json'
        Save-JsonStateFile -Path $Path -Data ([ordered]@{ v = 1 })
        Save-JsonStateFile -Path $Path -Data ([ordered]@{ v = 2 })
        # Corrupt primary
        [System.IO.File]::WriteAllText($Path, 'NOT VALID JSON')
        $Result = Read-JsonStateFile -Path $Path
        $Result.v | Should -Be 1  # recovered from .bak
    }

    It 'returns null for non-existent file' {
        $Result = Read-JsonStateFile -Path '/nonexistent/path/file.json'
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Get-AdminHistoryEntries' {
    It 'reads processed session headers from JSON state file' {
        $Path = Join-Path $script:FixturesRoot 'pu-sessions.json'
        $Result = Get-AdminHistoryEntries -Path $Path
        $Result.GetType().Name | Should -BeLike 'HashSet*'
        $Result.Count | Should -BeGreaterThan 0
    }

    It 'normalizes headers (collapse whitespace)' {
        $Path = Join-Path $script:FixturesRoot 'pu-sessions.json'
        $Result = Get-AdminHistoryEntries -Path $Path
        $Result | Should -Contain '2024-06-15, Ucieczka z Erathii, Solmyr'
    }

    It 'returns empty HashSet for non-existent file' {
        $Result = Get-AdminHistoryEntries -Path '/nonexistent/path/file.json'
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

    It 'creates JSON state file when missing' {
        $Path = Join-Path $script:TempDir 'new-state.json'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-01-01, Test Session, Narrator')
        [System.IO.File]::Exists($Path) | Should -BeTrue
        $Content = [System.IO.File]::ReadAllText($Path)
        $Parsed = $Content | ConvertFrom-Json
        $Parsed.version | Should -Be 2
        @($Parsed.runs).Count | Should -Be 1
    }

    It 'appends run to existing state file' {
        $Path = Join-Path $script:TempDir 'append-state.json'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-01-01, First, N')
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-06-01, Second, N')
        $Parsed = (Read-JsonStateFile -Path $Path)
        @($Parsed.runs).Count | Should -Be 2
    }

    It 'added entries are readable by Get-AdminHistoryEntries' {
        $Path = Join-Path $script:TempDir 'roundtrip-state.json'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-06-01, RT Session, Narrator')
        $Result = Get-AdminHistoryEntries -Path $Path
        $Result | Should -Contain '2025-06-01, RT Session, Narrator'
    }

    It 'does nothing when Headers is empty' {
        $Path = Join-Path $script:TempDir 'empty-headers.json'
        Add-AdminHistoryEntry -Path $Path -Headers @()
        [System.IO.File]::Exists($Path) | Should -BeFalse
    }

    It 'sorts headers chronologically' {
        $Path = Join-Path $script:TempDir 'sorted-state.json'
        Add-AdminHistoryEntry -Path $Path -Headers @('2025-12-01, Later, N', '2025-01-01, Earlier, N')
        $Parsed = Read-JsonStateFile -Path $Path
        $Sessions = @($Parsed.runs[0].sessions)
        $Sessions[0] | Should -BeLike '2025-01-01*'
        $Sessions[1] | Should -BeLike '2025-12-01*'
    }

    It 'strips ### prefix from headers at write time' {
        $Path = Join-Path $script:TempDir 'prefix-state.json'
        Add-AdminHistoryEntry -Path $Path -Headers @('### 2025-01-01, Test, N')
        $Parsed = Read-JsonStateFile -Path $Path
        $Sessions = @($Parsed.runs[0].sessions)
        $Sessions[0] | Should -Be '2025-01-01, Test, N'
    }
}

Describe 'Convert-PUHistoryToJson' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }

    It 'converts pu-sessions.md fixture to JSON with correct run count' {
        $SourcePath = Join-Path $script:FixturesRoot 'pu-sessions.md'
        $TargetPath = Join-Path $script:TempDir 'converted-pu.json'
        $Result = Convert-PUHistoryToJson -SourcePath $SourcePath -TargetPath $TargetPath
        $Result | Should -BeTrue
        $Parsed = Read-JsonStateFile -Path $TargetPath
        $Parsed.version | Should -Be 2
        @($Parsed.runs).Count | Should -Be 1
        @($Parsed.runs[0].sessions).Count | Should -Be 2
    }

    It 'converts pu-sessions-sample.md fixture to JSON with 3 runs' {
        $SourcePath = Join-Path $script:FixturesRoot 'pu-sessions-sample.md'
        $TargetPath = Join-Path $script:TempDir 'converted-pu-sample.json'
        $Result = Convert-PUHistoryToJson -SourcePath $SourcePath -TargetPath $TargetPath
        $Result | Should -BeTrue
        $Parsed = Read-JsonStateFile -Path $TargetPath
        @($Parsed.runs).Count | Should -Be 3
        @($Parsed.runs[0].sessions).Count | Should -Be 3
        @($Parsed.runs[1].sessions).Count | Should -Be 2
        @($Parsed.runs[2].sessions).Count | Should -Be 1
    }

    It 'returns false when target exists without -Force' {
        $SourcePath = Join-Path $script:FixturesRoot 'pu-sessions.md'
        $TargetPath = Join-Path $script:TempDir 'existing-target.json'
        Save-JsonStateFile -Path $TargetPath -Data ([ordered]@{ version = 2; runs = @() })
        $Result = Convert-PUHistoryToJson -SourcePath $SourcePath -TargetPath $TargetPath
        $Result | Should -BeFalse
    }

    It 'overwrites target with -Force' {
        $SourcePath = Join-Path $script:FixturesRoot 'pu-sessions.md'
        $TargetPath = Join-Path $script:TempDir 'force-target.json'
        Save-JsonStateFile -Path $TargetPath -Data ([ordered]@{ version = 2; runs = @() })
        $Result = Convert-PUHistoryToJson -SourcePath $SourcePath -TargetPath $TargetPath -Force
        $Result | Should -BeTrue
        $Parsed = Read-JsonStateFile -Path $TargetPath
        @($Parsed.runs).Count | Should -Be 1
    }

    It 'round-trip: converted JSON produces same headers as MD parse' {
        $SourcePath = Join-Path $script:FixturesRoot 'pu-sessions-sample.md'
        $TargetPath = Join-Path $script:TempDir 'roundtrip-convert.json'
        Convert-PUHistoryToJson -SourcePath $SourcePath -TargetPath $TargetPath
        $JsonHeaders = Get-AdminHistoryEntries -Path $TargetPath
        $JsonHeaders.Count | Should -Be 6
        $JsonHeaders | Should -Contain '2025-06-01, Powrót zdrowia, Crag Hack'
        $JsonHeaders | Should -Contain '2025-08-05, Tajemna rada, Solmyr'
    }
}

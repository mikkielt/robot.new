<#
    .SYNOPSIS
    Pester tests for phase4-log-download.ps1.

    .DESCRIPTION
    Tests for Invoke-MigrationPhase4 covering:
    - Calls Invoke-SessionLogFetch with -RetryFailed and -Quiet
    - Handles sessions with no log URLs gracefully (marks complete)
    - Skips already-localized local paths (res/logs/...) when counting URLs

    Interactive UI functions (Request-YesNo, Write-PhaseHeader, etc.) are mocked
    as no-op stubs since they require a live terminal.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source migration infrastructure (same order as migration-phases.ps1)
    . (Join-Path $script:ModuleRoot 'migration' 'migration-ui.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'migration-state.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'migration-shared.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'phase4-log-download.ps1')

    $script:TempDir = New-TestTempDir

    # ── Universal mocks ──────────────────────────────────────────────────
    Mock Get-RepoRoot { return $script:TempDir }
    Mock Get-AdminConfig {
        return @{
            RepoRoot = $script:TempDir
            ResDir   = $script:TempDir
        }
    }

    # Migration UI mocks (no-op stubs for console output)
    Mock Write-PhaseHeader {}
    Mock Write-Step {}
    Mock Write-StepOK {}
    Mock Write-StepWarning {}
    Mock Write-StepError {}
    Mock Write-PhaseSummary {}
    Mock Write-MigrationLog {}
    Mock Write-Host {}
    Mock Resolve-MigrationColor { return 'White' }

    # Migration state mocks
    Mock Save-MigrationState {}
    Mock Set-PhaseCompleted {}
    Mock Set-PhaseInProgress {}
    Mock Update-PhaseChecklist {}
    Mock Test-PhasePredecessor { return $true }
    Mock Get-PhaseStatus { return 'NotStarted' }

    # Interactive prompt mocks
    Mock Request-YesNo { return $true }
}

AfterAll {
    Remove-TestTempDir
}

Describe 'Invoke-MigrationPhase4' {
    Context 'sessions with log URLs' {
        It 'calls Invoke-SessionLogFetch with -RetryFailed and -Quiet' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-01-15, Sesja Testowa, Narrator'
                        Title  = 'Sesja Testowa'
                        Date   = [datetime]::Parse('2024-01-15')
                        Logs   = @('https://pastebin.com/raw/AAA111', 'https://pastebin.com/raw/BBB222')
                    }
                    [PSCustomObject]@{
                        Header = '### 2024-02-15, Druga Sesja, Narrator'
                        Title  = 'Druga Sesja'
                        Date   = [datetime]::Parse('2024-02-15')
                        Logs   = @('https://pastebin.com/raw/CCC333')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {
                return [PSCustomObject]@{
                    Total      = 3
                    Fetched    = 2
                    Cached     = 1
                    Failed     = 0
                    Skipped    = 0
                    FailedUrls = @()
                }
            }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Invoke-SessionLogFetch -Times 1 -ParameterFilter {
                $RetryFailed -eq $true -and $Quiet -eq $true
            }
        }

        It 'marks phase as completed after successful fetch' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-01-15, Sesja, Narrator'
                        Title  = 'Sesja'
                        Date   = [datetime]::Parse('2024-01-15')
                        Logs   = @('https://pastebin.com/raw/DDD444')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {
                return [PSCustomObject]@{
                    Total      = 1
                    Fetched    = 1
                    Cached     = 0
                    Failed     = 0
                    Skipped    = 0
                    FailedUrls = @()
                }
            }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Set-PhaseCompleted -Times 1 -ParameterFilter {
                $Phase -eq 4
            }
        }

        It 'updates UrlsCounted checklist item' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-01-15, Sesja, Narrator'
                        Title  = 'Sesja'
                        Date   = [datetime]::Parse('2024-01-15')
                        Logs   = @('https://pastebin.com/raw/EEE555')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {
                return [PSCustomObject]@{
                    Total = 1; Fetched = 1; Cached = 0; Failed = 0; Skipped = 0; FailedUrls = @()
                }
            }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Update-PhaseChecklist -ParameterFilter {
                $Phase -eq 4 -and $Item -eq 'UrlsCounted'
            }
        }
    }

    Context 'sessions with no log URLs' {
        It 'marks phase as completed with zero URLs' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-03-15, Sesja Bez Logów, Narrator'
                        Title  = 'Sesja Bez Logów'
                        Date   = [datetime]::Parse('2024-03-15')
                        Logs   = @()
                    }
                    [PSCustomObject]@{
                        Header = '### 2024-04-15, Inna Sesja, Narrator'
                        Title  = 'Inna Sesja'
                        Date   = [datetime]::Parse('2024-04-15')
                        Logs   = $null
                    }
                )
            }

            Mock Invoke-SessionLogFetch {}

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Set-PhaseCompleted -Times 1 -ParameterFilter {
                $Phase -eq 4
            }
        }

        It 'does not call Invoke-SessionLogFetch when no URLs exist' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-03-15, Brak Logów, Narrator'
                        Title  = 'Brak Logów'
                        Date   = [datetime]::Parse('2024-03-15')
                        Logs   = @()
                    }
                )
            }

            Mock Invoke-SessionLogFetch {}

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Invoke-SessionLogFetch -Times 0
        }
    }

    Context 'sessions with localized paths (res/logs/...)' {
        It 'skips local paths and counts only HTTP URLs' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-05-01, Sesja Lokalna, Narrator'
                        Title  = 'Sesja Lokalna'
                        Date   = [datetime]::Parse('2024-05-01')
                        Logs   = @('res/logs/pastebincomrawXXX111')
                    }
                    [PSCustomObject]@{
                        Header = '### 2024-05-15, Sesja Mieszana, Narrator'
                        Title  = 'Sesja Mieszana'
                        Date   = [datetime]::Parse('2024-05-15')
                        Logs   = @('res/logs/pastebincomrawYYY222', 'https://pastebin.com/raw/ZZZ333')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {
                return [PSCustomObject]@{
                    Total = 1; Fetched = 1; Cached = 0; Failed = 0; Skipped = 0; FailedUrls = @()
                }
            }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            # Only ZZZ333 should be counted as a URL; the res/logs/ paths are skipped
            Should -Invoke Write-StepOK -ParameterFilter {
                $Text -match '1 unikalnych URL'
            }
        }

        It 'marks phase as completed with mixed paths' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-05-01, Test, Narrator'
                        Title  = 'Test'
                        Date   = [datetime]::Parse('2024-05-01')
                        Logs   = @('res/logs/pastebincomrawLOCAL', 'https://pastebin.com/raw/REMOTE1')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {
                return [PSCustomObject]@{
                    Total = 1; Fetched = 1; Cached = 0; Failed = 0; Skipped = 0; FailedUrls = @()
                }
            }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Set-PhaseCompleted -Times 1 -ParameterFilter {
                $Phase -eq 4
            }
        }

        It 'completes immediately when all entries are local paths' {
            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-05-01, Wszystko Lokalne, Narrator'
                        Title  = 'Wszystko Lokalne'
                        Date   = [datetime]::Parse('2024-05-01')
                        Logs   = @('res/logs/file1', 'res/logs/file2')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {}

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Invoke-SessionLogFetch -Times 0
            Should -Invoke Set-PhaseCompleted -Times 1 -ParameterFilter {
                $Phase -eq 4
            }
        }
    }

    Context 'all logs already cached' {
        It 'does not call Invoke-SessionLogFetch when all URLs are cached' {
            # Pre-create the cached file so the function sees it as already fetched
            $LogDir = [System.IO.Path]::Combine($script:TempDir, 'logs')
            if (-not [System.IO.Directory]::Exists($LogDir)) {
                [void][System.IO.Directory]::CreateDirectory($LogDir)
            }
            # ConvertTo-LogFileName strips protocol and non-alnum
            $FileName = 'pastebincomrawCACHED01'
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($LogDir, $FileName),
                'Cached log content')

            Mock Get-Session {
                return @(
                    [PSCustomObject]@{
                        Header = '### 2024-06-01, Sesja Cache, Narrator'
                        Title  = 'Sesja Cache'
                        Date   = [datetime]::Parse('2024-06-01')
                        Logs   = @('https://pastebin.com/raw/CACHED01')
                    }
                )
            }

            Mock Invoke-SessionLogFetch {}

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Invoke-SessionLogFetch -Times 0
        }
    }

    Context 'predecessor phase not completed' {
        It 'warns about incomplete predecessor' {
            Mock Test-PhasePredecessor { return $false }
            Mock Request-YesNo { return $false }
            Mock Get-Session { return @() }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Write-StepWarning -Times 1 -ParameterFilter {
                $Text -match 'Faza 3'
            }
        }

        It 'does not proceed when user declines to continue' {
            Mock Test-PhasePredecessor { return $false }
            Mock Request-YesNo { return $false }
            Mock Get-Session { return @() }

            $State = New-DefaultMigrationState
            Invoke-MigrationPhase4 -State $State

            Should -Invoke Get-Session -Times 0
        }
    }
}

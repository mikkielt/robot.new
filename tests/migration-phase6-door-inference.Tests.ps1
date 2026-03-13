<#
    .SYNOPSIS
    Pester tests for phase6-door-inference.ps1.

    .DESCRIPTION
    Tests for Invoke-MigrationPhase6 covering the core @drzwi candidate
    inference logic: movement edge aggregation, existing door/containment
    filtering, self-transition exclusion, and confidence-based action
    assignment (ADD vs REVIEW).

    Interactive UI functions (Write-PhaseHeader, Write-Step, etc.) and
    file I/O (Read-EntityFile, Write-EntityFile) are mocked. Only the
    candidate computation pipeline is exercised.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Load migration framework (same order as migration-phases.ps1)
    . (Join-Path $script:ModuleRoot 'migration' 'migration-ui.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'migration-state.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'migration-shared.ps1')
    . (Join-Path $script:ModuleRoot 'migration' 'phase6-door-inference.ps1')

    $script:TempDir = New-TestTempDir

    # ── Mock: migration state helpers ──────────────────────────────────────
    Mock Get-RepoRoot { return $script:TempRoot }
    Mock Get-AdminConfig {
        return @{
            RepoRoot = $script:TempRoot
            ResDir   = $script:TempRoot
        }
    }
    Mock Save-MigrationState {}
    Mock Initialize-MigrationLog {}
    Mock Write-MigrationLog {}
    Mock Flush-MigrationLog {}

    # ── Mock: migration UI helpers ──────────────────────────────────────────
    Mock Write-PhaseHeader {}
    Mock Write-Step {}
    Mock Write-StepOK {}
    Mock Write-StepWarning {}
    Mock Write-StepError {}
    Mock Write-PhaseSummary {}
    Mock Write-SectionHeader {}
    Mock Write-Host {}

    # Request-UserChoice returns 'Z' (apply) to trigger candidate acceptance
    Mock Request-UserChoice { return 'Z' }
    Mock Request-YesNo { return $false }

    # ── Mock: entity read/write (avoid file system) ────────────────────────
    Mock Read-EntityFile {
        return @{
            Lines = [System.Collections.Generic.List[string]]::new(@('# Entities'))
            NL    = "`n"
        }
    }
    Mock Write-EntityFile {}

    # ── Mock: data providers ───────────────────────────────────────────────
    # Entities: locations with and without existing @drzwi tags
    $script:MockEntities = @(
        [PSCustomObject]@{
            Name     = 'Steadwick'
            Type     = 'Lokacja'
            FilePath = (Join-Path $script:TempRoot 'entities.md')
            Doors    = @()
            Tags     = @{}
        }
        [PSCustomObject]@{
            Name     = 'Bracada'
            Type     = 'Lokacja'
            FilePath = (Join-Path $script:TempRoot 'entities.md')
            Doors    = @()
            Tags     = @{}
        }
        [PSCustomObject]@{
            Name     = 'Twierdza Kreeganu'
            Type     = 'Lokacja'
            FilePath = (Join-Path $script:TempRoot 'entities.md')
            Doors    = @('Steadwick')  # existing door to Steadwick
            Tags     = @{}
        }
        [PSCustomObject]@{
            Name     = 'Port Bracada'
            Type     = 'Lokacja'
            FilePath = (Join-Path $script:TempRoot 'entities.md')
            Doors    = @()
            Tags     = @{}
        }
    )

    Mock Get-Entity { return $script:MockEntities }

    # Sessions (minimal)
    $script:MockSessions = @(
        [PSCustomObject]@{
            Header   = '### 2025-01-10, Podróż do Bracady, Solmyr'
            Date     = [datetime]::new(2025, 1, 10)
            Logs     = @('https://example.com/log1')
            FilePath = 'sessions.md'
        }
    )
    Mock Get-Session { return $script:MockSessions }

    # Name index (minimal)
    Mock Get-NameIndex {
        $Idx = [System.Collections.Generic.Dictionary[string,object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($E in $script:MockEntities) {
            $Idx[$E.Name] = $E
        }
        return $Idx
    }

    # Session log (minimal)
    Mock Get-SessionLog { return @([PSCustomObject]@{ Session = $script:MockSessions[0]; Transitions = @() }) }

    # Named location report (minimal)
    Mock Get-NamedLogLocationReport { return @() }

    # Location graph mock — the core test data
    # Edges: Movement edges + existing Door + Containment
    $script:MockGraph = @{
        Edges   = @(
            # Movement: Steadwick → Bracada (weight 3, high confidence → ADD)
            [PSCustomObject]@{
                Source        = 'Steadwick'
                Target        = 'Bracada'
                Type          = 'Movement'
                Weight        = 3
                FirstSeen     = [datetime]::new(2024, 6, 1)
                LastSeen      = [datetime]::new(2025, 1, 10)
                PossiblyStale = $false
            }
            # Movement: Bracada → Port Bracada (weight 1, low confidence → REVIEW)
            [PSCustomObject]@{
                Source        = 'Bracada'
                Target        = 'Port Bracada'
                Type          = 'Movement'
                Weight        = 1
                FirstSeen     = [datetime]::new(2025, 1, 10)
                LastSeen      = [datetime]::new(2025, 1, 10)
                PossiblyStale = $false
            }
            # Movement: Steadwick → Twierdza Kreeganu (weight 2 → ADD, but ALREADY has a Door)
            [PSCustomObject]@{
                Source        = 'Steadwick'
                Target        = 'Twierdza Kreeganu'
                Type          = 'Movement'
                Weight        = 2
                FirstSeen     = [datetime]::new(2024, 3, 1)
                LastSeen      = [datetime]::new(2024, 12, 1)
                PossiblyStale = $false
            }
            # Existing Door: Steadwick ↔ Twierdza Kreeganu
            [PSCustomObject]@{
                Source = 'Steadwick'
                Target = 'Twierdza Kreeganu'
                Type   = 'Door'
                Weight = 1
            }
            # Containment: Bracada contains Port Bracada (parent/child)
            [PSCustomObject]@{
                Source = 'Bracada'
                Target = 'Port Bracada'
                Type   = 'Containment'
                Weight = 1
            }
            # Movement: self-transition (should be skipped)
            [PSCustomObject]@{
                Source        = 'Steadwick'
                Target        = 'Steadwick'
                Type          = 'Movement'
                Weight        = 1
                FirstSeen     = [datetime]::new(2025, 1, 1)
                LastSeen      = [datetime]::new(2025, 1, 1)
                PossiblyStale = $false
            }
        )
        Summary = @{ EdgeCount = 6 }
    }

    Mock Get-LocationGraph { return $script:MockGraph }
}

AfterAll {
    Remove-TestTempDir
}

Describe 'Invoke-MigrationPhase6' {
    BeforeAll {
        # Build a valid migration state with phase 5 completed
        $script:State = @{
            Version = '2.0'
            Phases  = @{
                '5' = @{ Status = 'Completed'; Checklist = @{} }
                '6' = @{ Status = 'NotStarted'; Checklist = @{} }
            }
        }

        # Create fake entities.md so Read-EntityFile path checks pass
        [System.IO.File]::WriteAllText(
            (Join-Path $script:TempRoot 'entities.md'),
            '# Entities')

        # Create a fake review file that the function writes and re-reads
        # (We let the function write it, then it re-reads with 'Z' choice)
    }

    It 'produces correct candidates from movement edges' {
        # Act
        Invoke-MigrationPhase6 -State $script:State -WhatIf

        # The review file should have been written
        $ReviewPath = Join-Path $script:TempRoot 'drzwi-candidates.txt'
        [System.IO.File]::Exists($ReviewPath) | Should -BeTrue

        $ReviewContent = [System.IO.File]::ReadAllText($ReviewPath)

        # Bracada ↔ Steadwick should appear (canonical key: alphabetical order)
        $ReviewContent | Should -BeLike '*Bracada*Steadwick*'
    }

    It 'skips existing doors (Steadwick ↔ Twierdza Kreeganu)' {
        Invoke-MigrationPhase6 -State $script:State -WhatIf

        $ReviewPath = Join-Path $script:TempRoot 'drzwi-candidates.txt'
        $ReviewLines = [System.IO.File]::ReadAllLines($ReviewPath)

        # Filter non-comment data lines
        $DataLines = @($ReviewLines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#')
        })

        # Should NOT contain Twierdza Kreeganu as a candidate (existing door)
        $TwierdzaLines = @($DataLines | Where-Object { $_ -match 'Twierdza Kreeganu' })
        $TwierdzaLines.Count | Should -Be 0
    }

    It 'skips containment pairs (Bracada → Port Bracada)' {
        Invoke-MigrationPhase6 -State $script:State -WhatIf

        $ReviewPath = Join-Path $script:TempRoot 'drzwi-candidates.txt'
        $ReviewLines = [System.IO.File]::ReadAllLines($ReviewPath)

        $DataLines = @($ReviewLines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#')
        })

        # Port Bracada should not appear (containment pair with Bracada)
        $PortLines = @($DataLines | Where-Object { $_ -match 'Port Bracada' })
        $PortLines.Count | Should -Be 0
    }

    It 'skips self-transitions' {
        Invoke-MigrationPhase6 -State $script:State -WhatIf

        $ReviewPath = Join-Path $script:TempRoot 'drzwi-candidates.txt'
        $ReviewLines = [System.IO.File]::ReadAllLines($ReviewPath)

        $DataLines = @($ReviewLines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#')
        })

        # Only one valid candidate should remain: Steadwick ↔ Bracada
        $DataLines.Count | Should -Be 1
    }

    It 'assigns ADD action when weight >= 2' {
        Invoke-MigrationPhase6 -State $script:State -WhatIf

        $ReviewPath = Join-Path $script:TempRoot 'drzwi-candidates.txt'
        $ReviewLines = [System.IO.File]::ReadAllLines($ReviewPath)

        $DataLines = @($ReviewLines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#')
        })

        # Steadwick ↔ Bracada has weight 3 → ADD
        $DataLines[0] | Should -BeLike '*ADD*'
    }

    It 'marks phase completed after WhatIf run' {
        Invoke-MigrationPhase6 -State $script:State -WhatIf

        $script:State.Phases['6'].Status | Should -Be 'Completed'
    }
}

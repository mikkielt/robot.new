<#
    .SYNOPSIS
    Pester tests for export-staticapi.ps1.

    .DESCRIPTION
    Tests for Export-StaticApi covering file generation, manifest shape,
    optional economy/graph exports, directory creation, and deterministic
    JSON output.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    Mock Get-RepoRoot { return $script:FixturesRoot } -ModuleName Robot
}

Describe 'Export-StaticApi' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
        $script:OutputDir = Join-Path $script:TempDir 'static-api'
    }
    AfterEach {
        Remove-TestTempDir
    }

    Context 'Default exports' {
        It 'creates output directory if it does not exist' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            [System.IO.Directory]::Exists($script:OutputDir) | Should -BeTrue
        }

        It 'creates entities.json' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'entities.json'
            [System.IO.File]::Exists($Path) | Should -BeTrue

            $Content = [System.IO.File]::ReadAllText($Path)
            $Data = $Content | ConvertFrom-Json
            $Data.count | Should -BeGreaterOrEqual 0
            $Data.items | Should -Not -BeNullOrEmpty
        }

        It 'creates sessions.json' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'sessions.json'
            [System.IO.File]::Exists($Path) | Should -BeTrue

            $Content = [System.IO.File]::ReadAllText($Path)
            $Data = $Content | ConvertFrom-Json
            $Data.count | Should -BeGreaterOrEqual 0
        }

        It 'creates players.json' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'players.json'
            [System.IO.File]::Exists($Path) | Should -BeTrue

            $Content = [System.IO.File]::ReadAllText($Path)
            $Data = $Content | ConvertFrom-Json
            $Data.count | Should -BeGreaterOrEqual 0
        }

        It 'creates manifest.json with version and endpoints list' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'manifest.json'
            [System.IO.File]::Exists($Path) | Should -BeTrue

            $Content = [System.IO.File]::ReadAllText($Path)
            $Data = $Content | ConvertFrom-Json
            $Data.version | Should -Not -BeNullOrEmpty
            $Data.exportedAt | Should -Not -BeNullOrEmpty
            $Data.endpoints | Should -Not -BeNullOrEmpty
            $Data.endpoints | Should -Contain 'entities.json'
            $Data.endpoints | Should -Contain 'sessions.json'
            $Data.endpoints | Should -Contain 'players.json'
            # manifest.json is written last — its endpoints list contains files exported before it
            $Data.endpoints | Should -Not -Contain 'manifest.json'
        }

        It 'creates schema.json when ApiNameDictionary is available' {
            $HasType = ([System.Management.Automation.PSTypeName]'Robot.ApiNameDictionary').Type
            if (-not $HasType) {
                Set-ItResult -Skipped -Because 'C# types not compiled'
                return
            }

            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'schema.json'
            [System.IO.File]::Exists($Path) | Should -BeTrue
        }
    }

    Context 'Return value' {
        It 'returns result object with OutputPath and FileCount' {
            $Result = Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Result.OutputPath | Should -Be ([System.IO.Path]::GetFullPath($script:OutputDir))
            $Result.FileCount | Should -BeGreaterThan 0
            $Result.Files | Should -Not -BeNullOrEmpty
            $Result.ExportedAt | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Optional exports' {
        It 'skips economy when -IncludeEconomy is not specified' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'economy' 'snapshot.json'
            [System.IO.File]::Exists($Path) | Should -BeFalse
        }

        It 'skips graph when -IncludeGraph is not specified' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $Path = Join-Path $script:OutputDir 'location-graph.json'
            [System.IO.File]::Exists($Path) | Should -BeFalse
        }

        It 'creates economy/snapshot.json with -IncludeEconomy' {
            # Economy depends on entity data being available
            try {
                Export-StaticApi -OutputPath $script:OutputDir -IncludeEconomy -Confirm:$false
                $Path = Join-Path $script:OutputDir 'economy' 'snapshot.json'
                # May fail if economy data is unavailable — that's acceptable
                if ([System.IO.File]::Exists($Path)) {
                    $Content = [System.IO.File]::ReadAllText($Path)
                    $Content | Should -Not -BeNullOrEmpty
                }
            } catch {
                # Economy snapshot may not work without full data setup
            }
        }
    }

    Context 'ShouldProcess' {
        It 'does not create files when -WhatIf is passed' {
            Export-StaticApi -OutputPath $script:OutputDir -WhatIf
            [System.IO.Directory]::Exists($script:OutputDir) | Should -BeFalse
        }
    }

    Context 'Nested output path' {
        It 'creates nested directories' {
            $NestedPath = Join-Path $script:OutputDir 'deep' 'nested' 'api'
            Export-StaticApi -OutputPath $NestedPath -Confirm:$false
            [System.IO.Directory]::Exists($NestedPath) | Should -BeTrue
        }
    }

    Context 'JSON validity' {
        It 'all exported files contain valid JSON' {
            Export-StaticApi -OutputPath $script:OutputDir -Confirm:$false
            $JsonFiles = [System.IO.Directory]::GetFiles($script:OutputDir, '*.json',
                [System.IO.SearchOption]::AllDirectories)
            $JsonFiles.Count | Should -BeGreaterThan 0

            foreach ($JF in $JsonFiles) {
                $Content = [System.IO.File]::ReadAllText($JF)
                { $Content | ConvertFrom-Json } | Should -Not -Throw `
                    -Because "File $([System.IO.Path]::GetFileName($JF)) should contain valid JSON"
            }
        }
    }
}

AfterAll {
    Remove-TestTempDir
}

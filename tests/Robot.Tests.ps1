BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path $script:ModuleRoot 'robot.psd1'
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
}

Describe 'robot.psm1 - module loader' {
    Context 'Module loading and export verification' {
        It 'imports robot.psd1 without errors' {
            { Import-Module $script:ManifestPath -Force -ErrorAction Stop } | Should -Not -Throw
        }

        It 'exports all expected Verb-Noun functions' {
            Import-Module $script:ManifestPath -Force -ErrorAction Stop

            $Expected = @(
                'Get-RepoRoot',
                'Get-Markdown',
                'Get-GitChangeLog',
                'Get-Player',
                'Get-Entity',
                'Get-EntityState',
                'Get-PlayerCharacter',
                'Get-Session',
                'Get-NameIndex',
                'Get-NewPlayerCharacterPUCount',
                'Get-CurrencyReport',
                'New-Player',
                'New-PlayerCharacter',
                'New-Session',
                'Remove-PlayerCharacter',
                'Resolve-Name',
                'Resolve-Narrator',
                'Set-Player',
                'Set-PlayerCharacter',
                'Set-Session',
                'Send-DiscordMessage',
                'Invoke-PlayerCharacterPUAssignment',
                'Test-PlayerCharacterPUAssignment',
                'Test-CurrencyReconciliation'
            )

            $Actual = Get-Command -Module robot | Select-Object -ExpandProperty Name

            $Missing = $Expected | Where-Object { $_ -notin $Actual }
            $Unexpected = $Actual | Where-Object { $_ -notin $Expected }

            $Missing | Should -BeNullOrEmpty
            $Unexpected | Should -BeNullOrEmpty
            $Actual.Count | Should -Be $Expected.Count
        }

        It 'does not export helper script files' {
            Import-Module $script:ManifestPath -Force -ErrorAction Stop

            $NotExported = @(
                'entity-writehelpers',
                'admin-state',
                'admin-config',
                'format-sessionblock',
                'parse-markdownfile'
            )

            foreach ($Name in $NotExported) {
                (Get-Command -Module robot -Name $Name -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
            }
        }

        It 're-imports cleanly with -Force' {
            Import-Module $script:ManifestPath -Force -ErrorAction Stop
            { Import-Module $script:ManifestPath -Force -ErrorAction Stop } | Should -Not -Throw

            $Loaded = @(Get-Module -Name robot -All)
            $Loaded.Count | Should -Be 1

            $GetRepoRoot = Get-Command -Module robot -Name 'Get-RepoRoot' -ErrorAction Stop
            $GetRepoRoot | Should -Not -BeNullOrEmpty
        }
    }
}

AfterAll {
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
}

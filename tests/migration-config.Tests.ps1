<#
    .SYNOPSIS
    Pester tests for the ConfigSchema parser, defaults merger, and validator (WP-A1).

    .DESCRIPTION
    Covers Resolve-MigrationConfigSchema (Manifest → normalized schema),
    Merge-MigrationConfigDefaults (Schema + Supplied → Merged), Test-MigrationConfig
    (validation), and ConvertFromMigrationConfigValue (REST-side coercion).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-config.ps1')
}

Describe 'Resolve-MigrationConfigSchema' {
    It 'returns empty hashtable for manifest without ConfigSchema' {
        $Manifest = @{ Version = '0.1.0'; Slug = 'foo' }
        $Schema = Resolve-MigrationConfigSchema -Manifest $Manifest
        $Schema | Should -BeOfType [hashtable]
        $Schema.Keys.Count | Should -Be 0
    }

    It 'normalises omitted Type / Required / Description with defaults' {
        $Manifest = @{
            ConfigSchema = @{
                Name = @{ Default = 'X' }
            }
        }
        $Schema = Resolve-MigrationConfigSchema -Manifest $Manifest
        $Schema['Name']['Type'] | Should -Be 'String'
        $Schema['Name']['Required'] | Should -BeFalse
        $Schema['Name']['Description'] | Should -Be ''
        $Schema['Name']['Default'] | Should -Be 'X'
    }

    It 'preserves explicit Type / Required / Description / Default' {
        $Manifest = @{
            ConfigSchema = @{
                Force = @{
                    Type        = 'Switch'
                    Default     = $false
                    Required    = $true
                    Description = 'override safety'
                }
            }
        }
        $Schema = Resolve-MigrationConfigSchema -Manifest $Manifest
        $Schema['Force']['Type'] | Should -Be 'Switch'
        $Schema['Force']['Required'] | Should -BeTrue
        $Schema['Force']['Description'] | Should -Be 'override safety'
    }

    It 'rejects ConfigSchema that is not a hashtable' {
        $Manifest = @{ ConfigSchema = 'not-a-hashtable' }
        { Resolve-MigrationConfigSchema -Manifest $Manifest } | Should -Throw
    }

    It 'rejects field that is not a hashtable' {
        $Manifest = @{ ConfigSchema = @{ X = 'oops' } }
        { Resolve-MigrationConfigSchema -Manifest $Manifest } | Should -Throw
    }

    It 'rejects unsupported Type' {
        $Manifest = @{ ConfigSchema = @{ X = @{ Type = 'Date' } } }
        { Resolve-MigrationConfigSchema -Manifest $Manifest } | Should -Throw
    }
}

Describe 'Merge-MigrationConfigDefaults' {
    It 'fills missing fields with declared defaults' {
        $Schema = Resolve-MigrationConfigSchema -Manifest @{
            ConfigSchema = @{
                A = @{ Default = 1 }
                B = @{ Default = 'two' }
            }
        }
        $M = Merge-MigrationConfigDefaults -Schema $Schema -Supplied @{}
        $M['A'] | Should -Be 1
        $M['B'] | Should -Be 'two'
    }

    It 'supplied values win over defaults' {
        $Schema = Resolve-MigrationConfigSchema -Manifest @{
            ConfigSchema = @{ A = @{ Default = 1 } }
        }
        $M = Merge-MigrationConfigDefaults -Schema $Schema -Supplied @{ A = 99 }
        $M['A'] | Should -Be 99
    }

    It 'ignores supplied keys that are not in the schema' {
        $Schema = Resolve-MigrationConfigSchema -Manifest @{ ConfigSchema = @{ A = @{ Default = 1 } } }
        $M = Merge-MigrationConfigDefaults -Schema $Schema -Supplied @{ A = 2; Extra = 'x' }
        $M.ContainsKey('Extra') | Should -BeFalse
    }
}

Describe 'Test-MigrationConfig' {
    BeforeAll {
        $script:S = Resolve-MigrationConfigSchema -Manifest @{
            ConfigSchema = @{
                Force = @{ Type = 'Switch'; Default = $false }
                Name  = @{ Type = 'String'; Required = $true }
                Count = @{ Type = 'Int';    Default = 0 }
            }
        }
    }

    It 'returns OK for valid config' {
        $R = Test-MigrationConfig -Schema $script:S -Config @{ Force = $true; Name = 'x' }
        $R.OK | Should -BeTrue
        $R.Errors.Count | Should -Be 0
    }

    It 'flags missing Required field' {
        $R = Test-MigrationConfig -Schema $script:S -Config @{ Force = $true }
        $R.OK | Should -BeFalse
        ($R.Errors | Where-Object { $_ -match "'Name' is Required" }).Count | Should -BeGreaterThan 0
    }

    It 'flags unknown field' {
        $R = Test-MigrationConfig -Schema $script:S -Config @{ Name = 'x'; What = 1 }
        $R.OK | Should -BeFalse
        ($R.Errors | Where-Object { $_ -match "'What'" }).Count | Should -BeGreaterThan 0
    }

    It 'flags wrong type' {
        $R = Test-MigrationConfig -Schema $script:S -Config @{ Name = 'x'; Force = 'true' }
        $R.OK | Should -BeFalse
        ($R.Errors | Where-Object { $_ -match "Switch.*string" }).Count | Should -BeGreaterThan 0
    }
}

Describe 'ConvertFromMigrationConfigValue' {
    It 'coerces string "true" to Switch' {
        ConvertFromMigrationConfigValue -Type 'Switch' -Value 'true' | Should -BeTrue
    }
    It 'coerces "0" to Switch false' {
        ConvertFromMigrationConfigValue -Type 'Switch' -Value '0' | Should -BeFalse
    }
    It 'coerces numeric string to Int' {
        ConvertFromMigrationConfigValue -Type 'Int' -Value '42' | Should -Be 42
    }
    It 'wraps scalar value in single-item Array' {
        $R = ConvertFromMigrationConfigValue -Type 'Array' -Value 'x'
        $R.Count | Should -Be 1
        $R[0] | Should -Be 'x'
    }
    It 'throws on unparseable Int' {
        { ConvertFromMigrationConfigValue -Type 'Int' -Value 'abc' } | Should -Throw
    }
    It 'returns existing hashtable unchanged for Hashtable type' {
        $H = @{ a = 1 }
        $R = ConvertFromMigrationConfigValue -Type 'Hashtable' -Value $H
        $R['a'] | Should -Be 1
    }
}

Describe 'Get-MigrationConfigSchema (public cmdlet)' -Tag 'Integration' {
    It 'is exported by the module' {
        $Cmd = Get-Command -Module Robot.PowerShell -Name 'Get-MigrationConfigSchema' -ErrorAction SilentlyContinue
        $Cmd | Should -Not -BeNullOrEmpty
    }
}

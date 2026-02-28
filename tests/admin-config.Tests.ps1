<#
    .SYNOPSIS
    Pester tests for admin-config.ps1.

    .DESCRIPTION
    Tests for Resolve-ConfigValue, Find-DataManifest, Get-AdminConfig,
    and Get-AdminTemplate functions covering value resolution priority,
    manifest discovery, template substitution, and configuration loading.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
}

Describe 'Resolve-ConfigValue' {
    It 'returns explicit value when provided' {
        $Result = Resolve-ConfigValue -ExplicitValue 'MyValue' -EnvVarName 'NERTHUS_TEST_UNUSED' -ConfigKey 'unused'
        $Result | Should -Be 'MyValue'
    }

    It 'returns env var when explicit is empty' {
        $env:NERTHUS_TEST_CFG = 'FromEnv'
        try {
            $Result = Resolve-ConfigValue -ExplicitValue '' -EnvVarName 'NERTHUS_TEST_CFG' -ConfigKey 'unused'
            $Result | Should -Be 'FromEnv'
        } finally {
            Remove-Item Env:\NERTHUS_TEST_CFG -ErrorAction SilentlyContinue
        }
    }

    It 'returns config file value when explicit and env are empty' {
        $Config = @{ TestKey = 'FromConfig' }
        $Result = Resolve-ConfigValue -ExplicitValue '' -EnvVarName 'NERTHUS_NONEXISTENT_VAR' -ConfigKey 'TestKey' -LocalConfig $Config
        $Result | Should -Be 'FromConfig'
    }

    It 'returns null when all sources are empty' {
        $Result = Resolve-ConfigValue -ExplicitValue '' -EnvVarName 'NERTHUS_NONEXISTENT_VAR' -ConfigKey 'missing' -LocalConfig @{}
        $Result | Should -BeNullOrEmpty
    }

    It 'treats whitespace-only values as absent' {
        $Result = Resolve-ConfigValue -ExplicitValue '   ' -EnvVarName 'NERTHUS_NONEXISTENT_VAR' -ConfigKey 'missing' -LocalConfig @{}
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Find-DataManifest' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
    }
    AfterAll {
        Remove-TestTempDir
    }
    BeforeEach {
        # Clear cache between tests
        $script:CachedManifest = $null
        $script:CachedManifestDir = $null
    }

    It 'returns null when no manifest exists' {
        $Result = Find-DataManifest -RepoRoot $script:TempDir -ParentRepoRoot $script:TempDir -Force
        $Result | Should -BeNullOrEmpty
    }

    It 'finds manifest in repo root' {
        $ManifestContent = "@{ EntitiesFile = 'data/entities.md' }"
        Write-TestFile -Path (Join-Path $script:TempDir '.robot-data.psd1') -Content $ManifestContent

        $Result = Find-DataManifest -RepoRoot $script:TempDir -ParentRepoRoot $script:TempDir -Force
        $Result | Should -Not -BeNullOrEmpty
        $Result.Manifest.EntitiesFile | Should -Be 'data/entities.md'
        $Result.ManifestDir | Should -Be $script:TempDir
    }

    It 'caches result across calls' {
        $ManifestContent = "@{ PlayersFile = 'Gracze.md' }"
        Write-TestFile -Path (Join-Path $script:TempDir '.robot-data.psd1') -Content $ManifestContent

        $Result1 = Find-DataManifest -RepoRoot $script:TempDir -ParentRepoRoot $script:TempDir -Force
        # Remove the file - cached result should still be returned
        [System.IO.File]::Delete((Join-Path $script:TempDir '.robot-data.psd1'))
        $Result2 = Find-DataManifest -RepoRoot $script:TempDir -ParentRepoRoot $script:TempDir
        $Result2.Manifest.PlayersFile | Should -Be 'Gracze.md'
    }
}

Describe 'Get-AdminConfig' {
    It 'returns hashtable with resolved paths' {
        $Config = Get-AdminConfig
        $Config | Should -Not -BeNullOrEmpty
        $Config.RepoRoot | Should -Not -BeNullOrEmpty
        $Config.ModuleRoot | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-AdminTemplate' {
    It 'loads template and performs placeholder substitution' {
        $Result = Get-AdminTemplate -Name 'player-entry.md.template' `
            -Variables @{ CharacterName = 'TestChar'; PlayerName = 'Kilgor'; PUStart = '20' } `
            -TemplatesDir (Join-Path $script:FixturesRoot 'templates')
        $Result | Should -BeLike '*TestChar*'
        $Result | Should -BeLike '*Kilgor*'
        $Result | Should -BeLike '*20*'
    }

    It 'throws for missing template file' {
        { Get-AdminTemplate -Name 'nonexistent.template' -TemplatesDir (Join-Path $script:FixturesRoot 'templates') } |
            Should -Throw '*not found*'
    }

    It 'leaves unmatched placeholders in output' {
        $Result = Get-AdminTemplate -Name 'player-character-file.md.template' `
            -Variables @{ CharacterSheetUrl = 'https://test.com' } `
            -TemplatesDir (Join-Path $script:FixturesRoot 'templates')
        $Result | Should -BeLike '*https://test.com*'
        $Result | Should -BeLike '*{Triggers}*'
    }
}

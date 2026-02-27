<#
    .SYNOPSIS
    Configuration resolution and template rendering for admin workflows.

    .DESCRIPTION
    Non-exported helper functions consumed by New-PlayerCharacter and other
    admin commands via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Get-AdminConfig:    resolves config values from parameter/env/config file
    - Get-AdminTemplate:  loads and renders template files with variable substitution
    - Resolve-ConfigValue: priority-chain resolution for a single config key

    Config resolution priority:
    1. Explicit parameter value (caller passes directly)
    2. Environment variable (e.g. $env:NERTHUS_REPO_WEBHOOK)
    3. Local config file (.robot.new/local.config.psd1, git-ignored)
    4. Fail with clear error message

    Templates live in .robot.new/templates/ as standalone .md.template files.
    Rendering uses simple {VariableName} placeholder substitution.
#>

# Resolve a single config value through the priority chain
function Resolve-ConfigValue {
    param(
        [string]$ExplicitValue,
        [string]$EnvVarName,
        [string]$ConfigKey,
        [hashtable]$LocalConfig
    )

    # 1. Explicit parameter
    if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
        return $ExplicitValue
    }

    # 2. Environment variable
    if (-not [string]::IsNullOrWhiteSpace($EnvVarName)) {
        $EnvVal = [System.Environment]::GetEnvironmentVariable($EnvVarName)
        if (-not [string]::IsNullOrWhiteSpace($EnvVal)) {
            return $EnvVal
        }
    }

    # 3. Local config file
    if ($LocalConfig -and $ConfigKey -and $LocalConfig.ContainsKey($ConfigKey)) {
        $Val = $LocalConfig[$ConfigKey]
        if (-not [string]::IsNullOrWhiteSpace($Val)) {
            return $Val
        }
    }

    return $null
}

# Returns a hashtable with all resolved admin config values
function Get-AdminConfig {
    param(
        [Parameter(HelpMessage = "Explicit overrides hashtable (key → value)")]
        [hashtable]$Overrides = @{}
    )

    $ModuleRoot = $PSScriptRoot

    # Load local config file if it exists
    $LocalConfigPath = [System.IO.Path]::Combine($ModuleRoot, 'local.config.psd1')
    $LocalConfig = if ([System.IO.File]::Exists($LocalConfigPath)) {
        try { Import-PowerShellDataFile -Path $LocalConfigPath } catch { @{} }
    } else { @{} }

    $RepoRoot = Get-RepoRoot

    $Config = @{
        RepoRoot       = $RepoRoot
        ModuleRoot     = $ModuleRoot
        EntitiesFile   = [System.IO.Path]::Combine($ModuleRoot, 'entities.md')
        TemplatesDir   = [System.IO.Path]::Combine($ModuleRoot, 'templates')
        ResDir         = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res')
        CharactersDir  = [System.IO.Path]::Combine($RepoRoot, 'Postaci', 'Gracze')
        PlayersFile    = [System.IO.Path]::Combine($RepoRoot, 'Gracze.md')

        RepoWebhook    = Resolve-ConfigValue `
            -ExplicitValue ($Overrides['RepoWebhook']) `
            -EnvVarName 'NERTHUS_REPO_WEBHOOK' `
            -ConfigKey 'RepoWebhook' `
            -LocalConfig $LocalConfig

        BotUsername     = Resolve-ConfigValue `
            -ExplicitValue ($Overrides['BotUsername']) `
            -EnvVarName 'NERTHUS_BOT_USERNAME' `
            -ConfigKey 'BotUsername' `
            -LocalConfig $LocalConfig
    }

    # Merge any additional overrides
    foreach ($Key in $Overrides.Keys) {
        if (-not $Config.ContainsKey($Key)) {
            $Config[$Key] = $Overrides[$Key]
        }
    }

    return $Config
}

# Loads a template file and renders it by replacing {Placeholder} tokens
function Get-AdminTemplate {
    param(
        [Parameter(Mandatory, HelpMessage = "Template filename (e.g. 'player-character-file.md.template')")]
        [string]$Name,

        [Parameter(HelpMessage = "Hashtable of placeholder → value substitutions")]
        [hashtable]$Variables = @{},

        [Parameter(HelpMessage = "Templates directory path override")]
        [string]$TemplatesDir
    )

    if (-not $TemplatesDir) {
        $TemplatesDir = [System.IO.Path]::Combine($PSScriptRoot, 'templates')
    }

    $TemplatePath = [System.IO.Path]::Combine($TemplatesDir, $Name)
    if (-not [System.IO.File]::Exists($TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }

    $Content = [System.IO.File]::ReadAllText($TemplatePath)

    foreach ($Key in $Variables.Keys) {
        $Content = $Content.Replace("{$Key}", $Variables[$Key])
    }

    return $Content
}

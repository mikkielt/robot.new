<#
    .SYNOPSIS
    Configuration resolution and template rendering for admin workflows.

    .DESCRIPTION
    Non-exported helper functions consumed by New-PlayerCharacter and other
    admin commands via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Resolve-ConfigValue:   priority-chain resolution for a single config key
    - Test-PathUnderRoot:    validates a resolved path stays within the repository root (prevents traversal)
    - Find-DataManifest:     checks for .robot/robot-data.psd1 at a fixed path within the repo root
    - Get-AdminConfig:       resolves config values from parameter/env/config file/manifest
    - Get-AdminTemplate:     loads and renders template files with variable substitution

    Module-level data:
    - $script:CachedManifest:    session-scoped cache for the parsed data manifest hashtable
    - $script:CachedManifestDir: directory path corresponding to the cached manifest

    Config resolution priority:
    1. Explicit parameter value (caller passes directly)
    2. Environment variable (e.g. $env:NERTHUS_REPO_WEBHOOK)
    3. Local config file (.robot.new/local.config.psd1, git-ignored)
    4. Fail with clear error message

    Data manifest (.robot/robot-data.psd1) provides path overrides relative to its location.
    Located at a fixed path {RepoRoot}/.robot/robot-data.psd1, cached per session.

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

# Validates that a resolved path is under the repository root (prevents path traversal)
function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $FullRoot = [System.IO.Path]::GetFullPath($Root)
    # Ensure root ends with separator for prefix matching
    if (-not $FullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $FullRoot = $FullRoot + [System.IO.Path]::DirectorySeparatorChar
    }
    return $FullPath.StartsWith($FullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

# Session-scoped cache for data manifest
$script:CachedManifest = $null
$script:CachedManifestDir = $null

# Checks for .robot/robot-data.psd1 at a fixed path within RepoRoot.
# Returns @{ Manifest = hashtable; ManifestDir = string } or $null.
# Result is cached per session.
function Find-DataManifest {
    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override the repo root for testing")]
        [string]$RepoRoot,

        [Parameter(HelpMessage = "Skip cache and rescan")]
        [switch]$Force
    )

    if ($script:CachedManifest -and -not $Force) {
        return @{ Manifest = $script:CachedManifest; ManifestDir = $script:CachedManifestDir }
    }

    if (-not $RepoRoot) {
        $RepoRoot = Get-RepoRoot
    }

    $ManifestDir  = [System.IO.Path]::Combine($RepoRoot, '.robot')
    $ManifestPath = [System.IO.Path]::Combine($ManifestDir, 'robot-data.psd1')

    if (-not [System.IO.File]::Exists($ManifestPath)) {
        return $null
    }

    try {
        $Data = Import-PowerShellDataFile -Path $ManifestPath
        $script:CachedManifest    = $Data
        $script:CachedManifestDir = $ManifestDir
        return @{ Manifest = $Data; ManifestDir = $ManifestDir }
    } catch {
        [System.Console]::Error.WriteLine("[WARN Find-DataManifest] Failed to parse $ManifestPath : $_")
        return $null
    }
}

# Returns a hashtable with all resolved admin config values
function Get-AdminConfig {
    param(
        [Parameter(HelpMessage = "Explicit overrides hashtable (key -> value)")]
        [hashtable]$Overrides = @{}
    )

    $ModuleRoot = [System.IO.Path]::GetDirectoryName($PSScriptRoot)

    # Load local config file if it exists
    $LocalConfigPath = [System.IO.Path]::Combine($ModuleRoot, 'local.config.psd1')
    $LocalConfig = if ([System.IO.File]::Exists($LocalConfigPath)) {
        try { Import-PowerShellDataFile -Path $LocalConfigPath } catch { @{} }
    } else { @{} }

    $RepoRoot = Get-RepoRoot

    # Try to load data manifest for path overrides
    $ManifestResult = Find-DataManifest
    $ManifestPaths = @{}
    if ($ManifestResult) {
        $ManifestDir = $ManifestResult.ManifestDir
        $Manifest = $ManifestResult.Manifest
        foreach ($Key in $Manifest.Keys) {
            $RelPath = $Manifest[$Key]
            if ($RelPath -is [string]) {
                $Resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($ManifestDir, $RelPath))
                # Security: prevent path traversal outside repository root
                if (-not (Test-PathUnderRoot -Path $Resolved -Root $RepoRoot)) {
                    [System.Console]::Error.WriteLine(
                        "[WARN Get-AdminConfig] Manifest path '$Key' resolves to '$Resolved' outside repository root - skipping")
                    continue
                }
                $ManifestPaths[$Key] = $Resolved
            }
        }
    }

    $Config = @{
        RepoRoot       = $RepoRoot
        ModuleRoot     = $ModuleRoot
        EntitiesFile   = if ($ManifestPaths.ContainsKey('EntitiesFile')) { $ManifestPaths['EntitiesFile'] } else { [System.IO.Path]::Combine($RepoRoot, '.robot.new', 'entities.md') }
        TemplatesDir   = [System.IO.Path]::Combine($ModuleRoot, 'templates')
        ResDir         = if ($ManifestPaths.ContainsKey('ResDir')) { $ManifestPaths['ResDir'] } else { [System.IO.Path]::Combine($RepoRoot, '.robot', 'res') }
        CharactersDir  = if ($ManifestPaths.ContainsKey('CharactersDir')) { $ManifestPaths['CharactersDir'] } else { [System.IO.Path]::Combine($RepoRoot, 'Postaci', 'Gracze') }
        PlayersFile    = if ($ManifestPaths.ContainsKey('PlayersFile')) { $ManifestPaths['PlayersFile'] } else { [System.IO.Path]::Combine($RepoRoot, 'Gracze.md') }

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

        [Parameter(HelpMessage = "Hashtable of placeholder -> value substitutions")]
        [hashtable]$Variables = @{},

        [Parameter(HelpMessage = "Templates directory path override")]
        [string]$TemplatesDir
    )

    if (-not $TemplatesDir) {
        $TemplatesDir = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'templates')
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

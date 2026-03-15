<#
    .SYNOPSIS
    Module loader for Robot - PowerShell functions for Nerthus repository lore and metadata processing.

    .DESCRIPTION
    Auto-discovers and dot-sources all Verb-Noun .ps1 files in the module directory, exporting them
    as module functions. Non-Verb-Noun scripts (e.g. parse-markdownfile.ps1) are left unloaded -
    they are consumed on demand by the functions that need them.

    After loading core functions, discovers and loads plugins from the plugins/ directory.
    Each plugin is an independent directory containing a plugin.psd1 manifest.
    Plugin functions are exported alongside core functions.

    Assumes the working directory is inside the Nerthus Git repository containing Markdown files
    with structured information about players, characters, sessions, and entities.

    Core design principles:
    - No external modules or dependencies - only Git and PowerShell
    - Compatible with PowerShell 5.1 (Windows) and 7.0+ (Core)
    - .NET methods for file I/O, string manipulation, and process execution (performance + cross-platform)
    - No tools beyond Git and PowerShell
#>

$ModuleRoot = $PSScriptRoot

# ── Warning Suppression ────────────────────────────────────────────────────
# Module-scoped flag checked by Write-RobotWarning/Write-RobotInfo.
# Set to $true by CLI dispatch or public functions called with -Quiet.

$script:SuppressWarnings = $false

# ── Season Mapping ────────────────────────────────────────────────────────
# Loaded from local.config.psd1 SeasonMapping key. Used by Resolve-SeasonForDate
# in temporal-helpers.ps1. Null means use default meteorological mapping.

$script:CachedSeasonMapping = $null

$LocalConfigPath = [System.IO.Path]::Combine($ModuleRoot, 'local.config.psd1')
if ([System.IO.File]::Exists($LocalConfigPath)) {
    try {
        $LocalCfg = Import-PowerShellDataFile -Path $LocalConfigPath
        if ($LocalCfg.SeasonMapping) {
            $script:CachedSeasonMapping = $LocalCfg.SeasonMapping
        }
    } catch {
        # Non-fatal: local config is optional
    }
}

function Write-RobotWarning {
    param([Parameter(Mandatory)] [string]$Message)
    if (-not $script:SuppressWarnings) {
        [System.Console]::Error.WriteLine($Message)
    }
    if (Get-Command 'Add-OperationWarning' -ErrorAction SilentlyContinue) {
        Add-OperationWarning -Message $Message -Severity 'Warn'
    }
}

function Write-RobotInfo {
    param([Parameter(Mandatory)] [string]$Message)
    if (-not $script:SuppressWarnings) {
        [System.Console]::Error.WriteLine($Message)
    }
}

# ── PHASE 1: Core Function Loading ──────────────────────────────────────────

# .NET I/O avoids Get-ChildItem overhead (~3x faster on large trees).
# AllDirectories finds files in subfolders (public/session/, public/workflow/, etc.).
$FunctionFiles = [System.IO.Directory]::GetFiles($ModuleRoot, '*.ps1', [System.IO.SearchOption]::AllDirectories)

# Only Verb-Noun files are auto-loaded; helpers are dot-sourced on demand by the functions that need them
$VerbNounPattern = [regex]::new('^(Get|Set|New|Remove|Resolve|Test|Invoke|Send|Export)-\w+$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$ExportedFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Plugin files are loaded in Phase 2 with dependency ordering; skip them here
$PluginsDirSep = [System.IO.Path]::DirectorySeparatorChar + 'plugins' + [System.IO.Path]::DirectorySeparatorChar

foreach ($FilePath in $FunctionFiles) {
    $FileName = [System.IO.Path]::GetFileName($FilePath)

    # Skip the module file itself and core.ps1 (case-insensitive)
    if ($FileName -ieq 'robot.psm1' -or $FileName -ieq 'core.ps1') { continue }

    # Skip files inside plugins/ (loaded separately by plugin loader)
    $RelPath = $FilePath.Substring($ModuleRoot.Length)
    if ($RelPath.Contains($PluginsDirSep) -or $RelPath.Contains('/plugins/')) { continue }

    # Derive function name directly from filename (cheaper than Get-ChildItem Function: diff)
    $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

    # Non-Verb-Noun files (parse-markdownfile.ps1, etc.) are loaded on demand
    # by the functions that need them, keeping module import time minimal.
    if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }

    try {
        . "$FilePath"
    }
    catch {
        [System.Console]::Error.WriteLine("[WARN robot.psm1] Failed to load function file '$FileName': $_")
        continue
    }

    [void]$ExportedFunctions.Add($FuncName)
}

# ── PHASE 2: Plugin Loading ─────────────────────────────────────────────────

# Module-scoped plugin state
$script:LoadedPlugins        = @{}             # Name -> manifest hashtable
$script:HookRegistry         = @{}             # "Operation:Phase" -> sorted list of handlers
$script:PluginConfigs        = @{}             # Name -> resolved config hashtable
$script:PluginMenuItems      = [System.Collections.Generic.List[hashtable]]::new()  # CLI menu entries from plugins
$script:PluginMenuCategories = [System.Collections.Generic.List[string]]::new()     # New CLI categories from plugins
$script:PluginHelpContent    = @{}             # Category -> List[hashtable] of help entries from plugins
$script:ModuleRoot           = $ModuleRoot     # Expose to plugin helpers

$PluginsDir = [System.IO.Path]::Combine($ModuleRoot, 'plugins')

if ([System.IO.Directory]::Exists($PluginsDir)) {
    # Load plugin helper functions
    $PluginLoaderPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'plugin-loader.ps1')
    if ([System.IO.File]::Exists($PluginLoaderPath)) {
        . $PluginLoaderPath
    }

    $PluginHooksPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'plugin-hooks.ps1')
    if ([System.IO.File]::Exists($PluginHooksPath)) {
        . $PluginHooksPath
    }

    # VERSION file gates plugin loading via MinCoreVersion in manifests
    $CoreVersion = $null
    $VersionPath = [System.IO.Path]::Combine($ModuleRoot, 'VERSION')
    if ([System.IO.File]::Exists($VersionPath)) {
        $CoreVersion = [System.IO.File]::ReadAllText($VersionPath).Trim()
    }

    # Phase 2a: Discover all plugin manifests
    $PluginCandidates = [System.Collections.Generic.List[object]]::new()
    $PluginDirs = [System.IO.Directory]::GetDirectories($PluginsDir)

    foreach ($PluginDir in $PluginDirs) {
        $ManifestPath = [System.IO.Path]::Combine($PluginDir, 'plugin.psd1')
        if (-not [System.IO.File]::Exists($ManifestPath)) { continue }

        try {
            $Manifest = Import-PowerShellDataFile -Path $ManifestPath
        }
        catch {
            [System.Console]::Error.WriteLine(
                "[WARN robot.psm1] Failed to parse plugin manifest '$ManifestPath': $_")
            continue
        }

        # Name + Version are mandatory per plugin contract
        if (-not $Manifest.Name -or -not $Manifest.Version) {
            [System.Console]::Error.WriteLine(
                "[WARN robot.psm1] Plugin at '$PluginDir' missing Name or Version - skipped")
            continue
        }

        # Reject plugins that require a newer core than what's running
        if ($Manifest.MinCoreVersion -and $CoreVersion) {
            if ([version]$Manifest.MinCoreVersion -gt [version]$CoreVersion) {
                [System.Console]::Error.WriteLine(
                    "[WARN robot.psm1] Plugin '$($Manifest.Name)' requires core v$($Manifest.MinCoreVersion)" +
                    " but current is v$CoreVersion - skipped")
                continue
            }
        }

        $PluginCandidates.Add(@{
            Dir      = $PluginDir
            Manifest = $Manifest
            Path     = $ManifestPath
        })
    }

    # Phase 2b: Topological sort by DependsOn
    $SortedPlugins = if (Get-Command 'Resolve-PluginLoadOrder' -ErrorAction SilentlyContinue) {
        Resolve-PluginLoadOrder -Candidates $PluginCandidates
    } else {
        $PluginCandidates
    }

    # Phase 2c: Load each plugin in dependency order
    foreach ($Plugin in $SortedPlugins) {
        $Manifest   = $Plugin.Manifest
        $PluginDir  = $Plugin.Dir
        $PluginName = $Manifest.Name

        # Resolve plugin config
        if (Get-Command 'Resolve-PluginConfig' -ErrorAction SilentlyContinue) {
            $PluginConfig = Resolve-PluginConfig -Manifest $Manifest -PluginDir $PluginDir -ModuleRoot $ModuleRoot
            $script:PluginConfigs[$PluginName] = $PluginConfig
        }

        # Load plugin functions using the same Verb-Noun convention as core
        $PluginPublicDir = [System.IO.Path]::Combine($PluginDir, 'public')
        if ([System.IO.Directory]::Exists($PluginPublicDir)) {
            $PluginFiles = [System.IO.Directory]::GetFiles(
                $PluginPublicDir, '*.ps1', [System.IO.SearchOption]::AllDirectories)

            foreach ($FilePath in $PluginFiles) {
                $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
                if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }

                # Prevent plugins from shadowing core functions
                if ($ExportedFunctions.Contains($FuncName)) {
                    [System.Console]::Error.WriteLine(
                        "[WARN robot.psm1] Plugin '$PluginName' function '$FuncName'" +
                        " collides with existing function - skipped")
                    continue
                }

                try {
                    . "$FilePath"
                }
                catch {
                    [System.Console]::Error.WriteLine(
                        "[WARN robot.psm1] Plugin '$PluginName' failed to load '$FuncName': $_")
                    continue
                }

                [void]$ExportedFunctions.Add($FuncName)
            }
        }

        # Wire up plugin hooks into the "Operation:Phase" registry for Invoke-PluginHook
        if ($Manifest.Hooks) {
            foreach ($HookDef in $Manifest.Hooks) {
                $HookKey = "$($HookDef.Operation):$($HookDef.Phase)"
                if (-not $script:HookRegistry.ContainsKey($HookKey)) {
                    $script:HookRegistry[$HookKey] = [System.Collections.Generic.List[object]]::new()
                }
                $script:HookRegistry[$HookKey].Add([PSCustomObject]@{
                    Plugin   = $PluginName
                    Handler  = $HookDef.Handler
                    Priority = if ($HookDef.Priority) { $HookDef.Priority } else { 100 }
                })
            }
        }

        # Collect menu entries for Phase 2c merge into CLI navigation
        if ($Manifest.MenuItems) {
            foreach ($MenuItem in $Manifest.MenuItems) {
                $MenuItem['_PluginName'] = $PluginName
                [void]$script:PluginMenuItems.Add($MenuItem)
            }
        }

        # New categories appear as top-level menu groups in the CLI
        if ($Manifest.MenuCategories) {
            foreach ($Cat in $Manifest.MenuCategories) {
                if (-not $script:PluginMenuCategories.Contains($Cat)) {
                    [void]$script:PluginMenuCategories.Add($Cat)
                }
            }
        }

        # Plugin help entries are merged into the CLI help system by category
        if ($Manifest.HelpContent) {
            foreach ($HelpKey in $Manifest.HelpContent.Keys) {
                if (-not $script:PluginHelpContent.ContainsKey($HelpKey)) {
                    $script:PluginHelpContent[$HelpKey] = [System.Collections.Generic.List[hashtable]]::new()
                }
                $HelpEntry = $Manifest.HelpContent[$HelpKey].Clone()
                $HelpEntry['_PluginName'] = $PluginName
                [void]$script:PluginHelpContent[$HelpKey].Add($HelpEntry)
            }
        }

        $script:LoadedPlugins[$PluginName] = $Manifest

        Write-Verbose "Loaded plugin: $PluginName v$($Manifest.Version)"
    }

    # Lower priority values execute first (e.g. validation before logging)
    foreach ($HookKey in @($script:HookRegistry.Keys)) {
        $Handlers = $script:HookRegistry[$HookKey]
        $Sorted = $Handlers | Sort-Object { $_.Priority }
        $script:HookRegistry[$HookKey] = [System.Collections.Generic.List[object]]::new(
            [object[]]@($Sorted))
    }
}

# ── PHASE 3: Plugin Management Functions ────────────────────────────────────

# Defined inline because they need access to $script: variables.

function Get-PluginConfig {
    <#
        .SYNOPSIS
        Returns the resolved configuration hashtable for a named plugin.

        .PARAMETER PluginName
        The plugin name as declared in its plugin.psd1 manifest.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]
        [string]$PluginName
    )

    if ($script:PluginConfigs -and $script:PluginConfigs.ContainsKey($PluginName)) {
        return $script:PluginConfigs[$PluginName]
    }

    return @{}
}

function Get-LoadedPlugins {
    <#
        .SYNOPSIS
        Returns information about all currently loaded plugins.
    #>
    [CmdletBinding()] param()

    $Results = [System.Collections.Generic.List[object]]::new()

    if ($script:LoadedPlugins) {
        foreach ($Entry in $script:LoadedPlugins.GetEnumerator()) {
            $Manifest = $Entry.Value
            $Config = if ($script:PluginConfigs.ContainsKey($Entry.Key)) {
                $script:PluginConfigs[$Entry.Key]
            } else { @{} }

            $MenuItemCount = ($script:PluginMenuItems | Where-Object { $_['_PluginName'] -eq $Entry.Key }).Count

            $Results.Add([PSCustomObject]@{
                Name          = $Entry.Key
                Version       = $Manifest.Version
                Description   = $Manifest.Description
                Author        = $Manifest.Author
                Functions     = if ($Manifest.ExportedFunctions) { $Manifest.ExportedFunctions } else { @() }
                HookCount     = if ($Manifest.Hooks) { $Manifest.Hooks.Count } else { 0 }
                MenuItemCount = $MenuItemCount
                ConfigKeys    = @($Config.Keys)
            })
        }
    }

    return $Results
}

[void]$ExportedFunctions.Add('Get-PluginConfig')
[void]$ExportedFunctions.Add('Get-LoadedPlugins')

# ── PHASE 4: Export ─────────────────────────────────────────────────────────

if ($ExportedFunctions.Count -gt 0) {
    Export-ModuleMember -Function @($ExportedFunctions)
}

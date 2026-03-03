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

# ── PHASE 1: Core Function Loading ──────────────────────────────────────────

# Discover all .ps1 files using .NET I/O - avoid Get-ChildItem for performance
# Use AllDirectories so function files living in subfolders are found as well.
$FunctionFiles = [System.IO.Directory]::GetFiles($ModuleRoot, '*.ps1', [System.IO.SearchOption]::AllDirectories)

# Verb-Noun pattern regex for exported functions (case-insensitive)
$VerbNounPattern = [regex]::new('^(Get|Set|New|Remove|Resolve|Test|Invoke|Send|Export)-\w+$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$ExportedFunctions = [System.Collections.Generic.List[string]]::new()

# Path fragment used to detect files inside plugins/ (platform-aware)
$PluginsDirSep = [System.IO.Path]::DirectorySeparatorChar + 'plugins' + [System.IO.Path]::DirectorySeparatorChar

foreach ($FilePath in $FunctionFiles) {
    $FileName = [System.IO.Path]::GetFileName($FilePath)

    # Skip the module file itself and core.ps1 (case-insensitive)
    if ($FileName -ieq 'robot.psm1' -or $FileName -ieq 'core.ps1') { continue }

    # Skip files inside plugins/ (loaded separately by plugin loader)
    $RelPath = $FilePath.Substring($ModuleRoot.Length)
    if ($RelPath.Contains($PluginsDirSep) -or $RelPath.Contains('/plugins/')) { continue }

    # Derive function name from filename - avoids expensive Get-ChildItem Function: diffing
    $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

    # Only dot-source files whose name matches the Verb-Noun convention;
    # other .ps1 files (e.g. helper scripts) are loaded on demand, not at import.
    if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }

    try {
        . "$FilePath"
    }
    catch {
        [System.Console]::Error.WriteLine("Failed to load function file '$FileName': $_")
        continue
    }

    $ExportedFunctions.Add($FuncName)
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

    # Read core module version for compatibility checks
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

        # Validate required fields
        if (-not $Manifest.Name -or -not $Manifest.Version) {
            [System.Console]::Error.WriteLine(
                "[WARN robot.psm1] Plugin at '$PluginDir' missing Name or Version - skipped")
            continue
        }

        # Version gate: check MinCoreVersion against module version
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

        # Discover and dot-source Verb-Noun .ps1 files from plugin's public/
        $PluginPublicDir = [System.IO.Path]::Combine($PluginDir, 'public')
        if ([System.IO.Directory]::Exists($PluginPublicDir)) {
            $PluginFiles = [System.IO.Directory]::GetFiles(
                $PluginPublicDir, '*.ps1', [System.IO.SearchOption]::AllDirectories)

            foreach ($FilePath in $PluginFiles) {
                $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
                if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }

                # Collision detection
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

                $ExportedFunctions.Add($FuncName)
            }
        }

        # Register hooks
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

        # Register CLI menu items
        if ($Manifest.MenuItems) {
            foreach ($MenuItem in $Manifest.MenuItems) {
                $MenuItem['_PluginName'] = $PluginName
                [void]$script:PluginMenuItems.Add($MenuItem)
            }
        }

        # Register CLI menu categories
        if ($Manifest.MenuCategories) {
            foreach ($Cat in $Manifest.MenuCategories) {
                if (-not $script:PluginMenuCategories.Contains($Cat)) {
                    [void]$script:PluginMenuCategories.Add($Cat)
                }
            }
        }

        # Collect CLI help content
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

    # Sort all hook lists by priority (lower = first)
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

$ExportedFunctions.Add('Get-PluginConfig')
$ExportedFunctions.Add('Get-LoadedPlugins')

# ── PHASE 4: Export ─────────────────────────────────────────────────────────

if ($ExportedFunctions.Count -gt 0) {
    Export-ModuleMember -Function $ExportedFunctions
}

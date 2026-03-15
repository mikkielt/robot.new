<#
    .SYNOPSIS
    Module loader for Robot — PowerShell functions for Nerthus repository
    lore and metadata processing.

    .DESCRIPTION
    Auto-discovers and dot-sources all Verb-Noun .ps1 files in the module
    directory, exporting them as module functions. Non-Verb-Noun scripts
    (e.g. parse-markdownfile.ps1) are left unloaded — they are consumed
    on demand by the functions that need them, keeping import time minimal.

    Loading proceeds in four phases:
    Phase 1 (Core Functions): .NET Directory.GetFiles with AllDirectories
      enumerates all .ps1 files, filters to Verb-Noun names via compiled
      regex, dot-sources each, and collects names for Export-ModuleMember.
      Plugin files are skipped (loaded separately in Phase 2).
    Phase 2 (Plugin Loading):
      2a. Discover plugin.psd1 manifests in plugins/ subdirectories.
          Validate Name/Version presence, reject plugins requiring a
          newer core version than the current VERSION file.
      2b. Topological sort by DependsOn via Resolve-PluginLoadOrder.
      2c. Load each plugin's public/ Verb-Noun files, wire hooks into
          the "Operation:Phase" registry, collect menu items, categories,
          and help content for CLI integration.
    Phase 3 (Plugin Management): Define Get-PluginConfig and
      Get-LoadedPlugins inline (they need $script: variable access).
    Phase 4 (Export): Export-ModuleMember with the collected function names.

    Module-level data:
    - $script:SuppressWarnings: warning suppression flag for -Quiet switches
    - $script:CachedSeasonMapping: season mapping from local.config.psd1
    - $script:LoadedPlugins: Name -> manifest hashtable
    - $script:HookRegistry: "Operation:Phase" -> sorted handler list
    - $script:PluginConfigs: Name -> resolved config hashtable
    - $script:PluginMenuItems: CLI menu entries contributed by plugins
    - $script:PluginMenuCategories: new CLI categories from plugins
    - $script:PluginHelpContent: Category -> help entries from plugins
    - $script:ModuleRoot: absolute path to the module directory

    Core design principles:
    - No external modules or dependencies — only Git and PowerShell
    - Compatible with PowerShell 5.1 (Windows) and 7.0+ (Core)
    - .NET methods for file I/O, string manipulation, and process execution
    - No tools beyond Git and PowerShell
#>

$ModuleRoot = $PSScriptRoot

# ── Warning Suppression ────────────────────────────────────────────────────
# Checked by Write-RobotWarning/Write-RobotInfo before emitting to stderr.
# Set to $true by CLI dispatch or public functions called with -Quiet.

$script:SuppressWarnings = $false

# ── Compiled C# Library ───────────────────────────────────────────────────
# Consumer files check PSTypeName before using C# types and fall back to
# PowerShell when unavailable, so a compilation failure is non-fatal.

$LibDir = [System.IO.Path]::Combine($ModuleRoot, 'lib')
if ([System.IO.Directory]::Exists($LibDir)) {
    $CsFiles = [System.IO.Directory]::GetFiles($LibDir, '*.cs')
    if ($CsFiles.Length -gt 0) {
        # Guard: skip if types already loaded (e.g. module reimport in same session)
        if (-not ([System.Management.Automation.PSTypeName]'Robot.MarkdownScanner').Type) {
            # Hoist all 'using' directives above namespace blocks to avoid CS1529
            # when concatenating multiple .cs files with independent using sets.
            $Usings = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal)
            $Body = [System.Text.StringBuilder]::new()
            foreach ($CsFile in $CsFiles) {
                foreach ($Line in [System.IO.File]::ReadAllLines($CsFile)) {
                    if ($Line -match '^\s*using\s+[A-Z][\w.]*\s*;') {
                        [void]$Usings.Add($Line)
                    } else {
                        [void]$Body.AppendLine($Line)
                    }
                }
            }
            $AllSource = [System.Text.StringBuilder]::new()
            foreach ($U in $Usings) {
                [void]$AllSource.AppendLine($U)
            }
            [void]$AllSource.Append($Body)
            try {
                Add-Type -TypeDefinition $AllSource.ToString() -Language CSharp
            }
            catch {
                [System.Console]::Error.WriteLine("[WARN robot.psm1] Failed to compile lib/*.cs: $_")
            }
        }
    }
}

# ── Season Mapping ────────────────────────────────────────────────────────
# Optional override from local.config.psd1; null = default meteorological
# mapping (Mar-May=wiosna, Jun-Aug=lato, Sep-Nov=jesien, Dec-Feb=zima).

$script:CachedSeasonMapping = $null

$LocalConfigPath = [System.IO.Path]::Combine($ModuleRoot, 'local.config.psd1')
if ([System.IO.File]::Exists($LocalConfigPath)) {
    try {
        $LocalCfg = Import-PowerShellDataFile -Path $LocalConfigPath
        if ($LocalCfg.SeasonMapping) {
            $script:CachedSeasonMapping = $LocalCfg.SeasonMapping
        }
    } catch {
        # Non-fatal: local config is optional, absence = use defaults
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

# .NET I/O avoids Get-ChildItem overhead (~3x faster on large trees);
# AllDirectories reaches subfolders (public/session/, public/workflow/, etc.).
$FunctionFiles = [System.IO.Directory]::GetFiles($ModuleRoot, '*.ps1', [System.IO.SearchOption]::AllDirectories)

# Only Verb-Noun files are auto-loaded; helpers are dot-sourced on demand
$VerbNounPattern = [regex]::new('^(Get|Set|New|Remove|Resolve|Test|Invoke|Send|Export)-\w+$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$ExportedFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Plugin files use dependency ordering in Phase 2; skip them in Phase 1
$PluginsDirSep = [System.IO.Path]::DirectorySeparatorChar + 'plugins' + [System.IO.Path]::DirectorySeparatorChar

foreach ($FilePath in $FunctionFiles) {
    $FileName = [System.IO.Path]::GetFileName($FilePath)

    # Skip the module file itself and core.ps1 (loaded separately)
    if ($FileName -ieq 'robot.psm1' -or $FileName -ieq 'core.ps1') { continue }

    # Skip files inside plugins/ — loaded in Phase 2 with dependency ordering
    $RelPath = $FilePath.Substring($ModuleRoot.Length)
    if ($RelPath.Contains($PluginsDirSep) -or $RelPath.Contains('/plugins/')) { continue }

    # Derive function name from filename — cheaper than inspecting AST or Function: drive
    $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

    # Non-Verb-Noun files (parse-markdownfile.ps1, etc.) are loaded on demand,
    # keeping module import time minimal.
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

# Module-scoped plugin state — populated during Phase 2, queried by CLI and hooks
$script:LoadedPlugins        = @{}
$script:HookRegistry         = @{}
$script:PluginConfigs        = @{}
$script:PluginMenuItems      = [System.Collections.Generic.List[hashtable]]::new()
$script:PluginMenuCategories = [System.Collections.Generic.List[string]]::new()
$script:PluginHelpContent    = @{}
$script:ModuleRoot           = $ModuleRoot

$PluginsDir = [System.IO.Path]::Combine($ModuleRoot, 'plugins')

if ([System.IO.Directory]::Exists($PluginsDir)) {
    # Plugin infrastructure: loader (discovery/validation) and hooks (dispatch)
    $PluginLoaderPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'plugin-loader.ps1')
    if ([System.IO.File]::Exists($PluginLoaderPath)) {
        . $PluginLoaderPath
    }

    $PluginHooksPath = [System.IO.Path]::Combine($ModuleRoot, 'private', 'plugin-hooks.ps1')
    if ([System.IO.File]::Exists($PluginHooksPath)) {
        . $PluginHooksPath
    }

    # VERSION file gates plugin compatibility via MinCoreVersion in manifests
    $CoreVersion = $null
    $VersionPath = [System.IO.Path]::Combine($ModuleRoot, 'VERSION')
    if ([System.IO.File]::Exists($VersionPath)) {
        $CoreVersion = [System.IO.File]::ReadAllText($VersionPath).Trim()
    }

    # Phase 2a: discover and validate plugin manifests
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

        # Name + Version are mandatory — reject malformed manifests early
        if (-not $Manifest.Name -or -not $Manifest.Version) {
            [System.Console]::Error.WriteLine(
                "[WARN robot.psm1] Plugin at '$PluginDir' missing Name or Version - skipped")
            continue
        }

        # Version gate: reject plugins requiring a newer core
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

    # Phase 2b: topological sort ensures dependencies load before dependents
    $SortedPlugins = if (Get-Command 'Resolve-PluginLoadOrder' -ErrorAction SilentlyContinue) {
        Resolve-PluginLoadOrder -Candidates $PluginCandidates
    } else {
        $PluginCandidates
    }

    # Phase 2c: load each plugin in dependency order
    foreach ($Plugin in $SortedPlugins) {
        $Manifest   = $Plugin.Manifest
        $PluginDir  = $Plugin.Dir
        $PluginName = $Manifest.Name

        # Merge plugin's default config with any local overrides
        if (Get-Command 'Resolve-PluginConfig' -ErrorAction SilentlyContinue) {
            $PluginConfig = Resolve-PluginConfig -Manifest $Manifest -PluginDir $PluginDir -ModuleRoot $ModuleRoot
            $script:PluginConfigs[$PluginName] = $PluginConfig
        }

        # Load plugin's public functions using the same Verb-Noun convention as core
        $PluginPublicDir = [System.IO.Path]::Combine($PluginDir, 'public')
        if ([System.IO.Directory]::Exists($PluginPublicDir)) {
            $PluginFiles = [System.IO.Directory]::GetFiles(
                $PluginPublicDir, '*.ps1', [System.IO.SearchOption]::AllDirectories)

            foreach ($FilePath in $PluginFiles) {
                $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
                if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }

                # Prevent plugin functions from shadowing core — would cause silent behavior changes
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

        # Wire plugin hooks into "Operation:Phase" registry for Invoke-PluginHook dispatch
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

        # Collect menu entries for CLI navigation integration
        if ($Manifest.MenuItems) {
            foreach ($MenuItem in $Manifest.MenuItems) {
                $MenuItem['_PluginName'] = $PluginName
                [void]$script:PluginMenuItems.Add($MenuItem)
            }
        }

        # New categories appear as top-level groups in the CLI menu
        if ($Manifest.MenuCategories) {
            foreach ($Cat in $Manifest.MenuCategories) {
                if (-not $script:PluginMenuCategories.Contains($Cat)) {
                    [void]$script:PluginMenuCategories.Add($Cat)
                }
            }
        }

        # Plugin help entries merge into the CLI help system keyed by category
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

    # Sort hooks by priority: lower values execute first (e.g. validation before logging)
    foreach ($HookKey in @($script:HookRegistry.Keys)) {
        $Handlers = $script:HookRegistry[$HookKey]
        $Sorted = $Handlers | Sort-Object { $_.Priority }
        $script:HookRegistry[$HookKey] = [System.Collections.Generic.List[object]]::new(
            [object[]]@($Sorted))
    }
}

# ── PHASE 3: Plugin Management Functions ────────────────────────────────────

# Defined inline because they need direct access to $script: plugin state.

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

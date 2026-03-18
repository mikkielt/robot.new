# Plugin System - Technical Reference

---

## Scope

This document covers the plugin system for extending Robot module functionality without modifying core code: `private/plugin-loader.ps1` (discovery, manifest validation, dependency resolution, function loading), `private/plugin-hooks.ps1` (hook registry, invocation, handler contract), the plugin loading phase in `Robot.PowerShell.psm1`, and the exported management functions `Get-PluginConfig` and `Get-LoadedPlugins` (defined inline in `Robot.PowerShell.psm1`).

Individual plugin implementations are documented separately. Core entity write operations are in [ENTITY-WRITES.md](ENTITY-WRITES.md). Configuration resolution for the core module is in [CONFIG-STATE.md](CONFIG-STATE.md).

---

## Architecture Overview

```
Robot.PowerShell.psm1 (module entry point)
    |
    +-- Core functions loaded (public/, private/)
    |
    +-- Plugin Discovery & Loading (private/plugin-loader.ps1)
    |       |
    |       +-- Scan plugins/ for plugin.psd1 manifests
    |       +-- Validate manifests, version-gate
    |       +-- Topological sort by DependsOn
    |       +-- Per plugin:
    |           +-- Resolve config (env -> local -> core -> manifest default)
    |           +-- Load public/ functions (collision detection)
    |           +-- Load private/ helpers
    |           +-- Register hooks (private/plugin-hooks.ps1)
    |
    +-- Sort hooks by priority
    |
    +-- Single Export-ModuleMember (core + all plugin functions)

Hook Registry (private/plugin-hooks.ps1)
    |
    +-- Write-EntityFile --> BeforeWrite / AfterWrite
    +-- Set-Session ------> BeforeWrite / AfterWrite
    +-- New-Entity -------> AfterCreate
    +-- New-PlayerCharacter -> AfterCreate
```

Core functions are loaded first. Plugins are discovered, validated, and loaded in dependency order. Plugin public functions are exported alongside core functions via a single `Export-ModuleMember` call at the end of `Robot.PowerShell.psm1`. The hook registry connects plugin handlers to core write operations.

---

## Plugin Structure

Directory layout:

```
plugins/
+-- my-plugin/
    +-- plugin.psd1              # Mandatory: plugin manifest
    +-- public/                  # Optional: exported functions
    |   +-- Export-MyData.ps1
    |   +-- Get-MyReport.ps1
    +-- private/                 # Optional: internal helpers (not exported)
    |   +-- Format-MyOutput.ps1
    +-- cli/                     # Optional: CLI workflow files (dot-sourced at Layer 6.5)
    |   +-- cli-wf-myplugin.ps1
    +-- templates/               # Optional: template files
    |   +-- my-report.md.template
    +-- tests/                   # Optional: Pester test files
    |   +-- my-plugin.Tests.ps1
    +-- local.config.psd1        # Optional: plugin-specific config (git-ignored)
```

Plugins are git submodules under `plugins/`. This enables independent versioning and clean separation from the core module. Each plugin directory must contain a `plugin.psd1` manifest. Directories without a manifest are silently skipped. Public functions in `public/` follow the same `Verb-Noun` naming convention as core functions. Private helpers in `private/` are dot-sourced into the module scope but not exported.

Installed plugins:

| Plugin | Description | DependsOn | Exported Functions |
|---|---|---|---|
| `robot-api` | REST API with compiled C# server engine | -- | `Start-RobotApi`, `Stop-RobotApi`, `Get-RobotApiStatus`, `New-RobotApiToken`, `Remove-RobotApiToken`, `Get-RobotApiToken` |
| `robot-dashboard` | Web dashboard for session creation and data browsing | `robot-api` | `Invoke-RobotDashboard` |
| `margoworld-datasource` | Pulls canonical map data from MargoWorld.pl | -- | `Invoke-MargoWorldMapCheckup`, `Get-MargoWorldMapList`, `Get-MargoWorldLocationReport`, `ConvertTo-MapsJsonFromMarkdown`, `Invoke-MargoWorldMapCoordinates`, `Set-MargoWorldMapTileData`, `Export-MargoWorldAsciiMap` |
| `nerthusaddon-integration` | Cross-references entities with nerthusaddon map data | -- | `Import-NerthusAddonMaps`, `Get-NerthusLocationReport`, `Export-NerthusLocationData` |

---

## Plugin Manifest Schema (`plugin.psd1`)

Required fields:

| Field | Type | Description |
|---|---|---|
| `Name` | string | Unique plugin identifier (must match directory name) |
| `Version` | string | Semantic version (e.g., `'1.0.0'`) |
| `Description` | string | Human-readable summary |
| `Author` | string | Plugin author |

Optional fields:

| Field | Type | Default | Description |
|---|---|---|---|
| `MinCoreVersion` | string | `$null` | Minimum Robot module version required |
| `ExportedFunctions` | string[] | All `public/*.ps1` | Explicit list of functions to export |
| `Hooks` | hashtable[] | `@()` | Hook registrations with `Operation`, `Phase`, `Handler`, `Priority` (see the Lifecycle Hook System section) |
| `Config` | hashtable | `@{}` | Declared configuration keys (see the Plugin Config System section) |
| `Scopes` | string[] | `@()` | RBAC scopes required by this plugin (see the RBAC section) |
| `DependsOn` | string[] | `@()` | Plugin names that must load first |
| `MenuItems` | hashtable[] | `@()` | CLI menu entries to register (see the CLI Menu Items section under Creating a Plugin) |
| `MenuCategories` | string[] | `@()` | New CLI top-level categories to add to `MenuOrder` |
| `HelpContent` | hashtable | `@{}` | CLI help entries keyed by category name (see the CLI Menu Items section under Creating a Plugin) |

Complete example:

```powershell
@{
    Name              = 'llm-validator'
    Version           = '1.2.0'
    Description       = 'Validates entity writes against LLM-based consistency checks'
    Author            = 'Nerthus Team'
    MinCoreVersion    = '2.0.0'
    ExportedFunctions = @('Test-EntityConsistency', 'Get-ValidationReport')
    DependsOn         = @()
    Hooks             = @(
        @{
            Operation = 'Write-EntityFile'
            Phase     = 'BeforeWrite'
            Handler   = 'Invoke-LLMValidation'
            Priority  = 100
        }
    )
    Config            = @{
        ApiEndpoint = @{
            Description = 'LLM API endpoint URL'
            EnvVar      = 'ROBOT_LLM_ENDPOINT'
            Default     = 'http://localhost:11434/api/generate'
            Required    = $false
        }
        ModelName   = @{
            Description = 'LLM model name'
            EnvVar      = 'ROBOT_LLM_MODEL'
            Default     = 'mistral'
            Required    = $false
        }
        MaxTokens   = @{
            Description = 'Maximum token count for validation requests'
            EnvVar      = $null
            Default     = 512
            Required    = $false
        }
    }
    Scopes            = @('entity:write')
    MenuCategories    = @()
    MenuItems         = @(
        @{
            ID       = 'llm-validator:report'
            Label    = 'Raport walidacji LLM'
            Menu     = 'Encje'
            Mode     = 'Workflow'
            WorkflowFunction = 'Invoke-LLMReportWorkflow'
        }
    )
    HelpContent       = @{
        'Encje' = @{
            Body = @('Raport walidacji LLM - pokazuje wyniki walidacji encji przez LLM.')
        }
    }
}
```

---

## Plugin Discovery and Loading

Step-by-step sequence executed during module import in `Robot.PowerShell.psm1`:

1. Scan `plugins/` directory for subdirectories containing `plugin.psd1`
2. Parse each manifest via `Import-PowerShellDataFile` with error handling
3. Validate required fields (`Name`, `Version`, `Description`, `Author`)
4. Version-gate -- skip plugin if `MinCoreVersion` exceeds current module version (warn to stderr)
5. Topological sort by `DependsOn` via `Resolve-PluginLoadOrder` (detect circular dependencies)
6. Per plugin (in dependency order): resolve config via `Resolve-PluginConfig` (see the Plugin Config System section); dot-source `public/*.ps1` Verb-Noun functions into module scope (private helpers are loaded on-demand by plugin functions, same as core); collision detection skips conflicting function names with a warning to stderr; register hooks from manifest `Hooks` array (see the Lifecycle Hook System section); extract CLI metadata into `$script:PluginMenuItems`, `$script:PluginMenuCategories`, `$script:PluginHelpContent` (each item tagged with `_PluginName`)
7. Sort all registered hooks by priority (ascending, lower = earlier)
8. Single `Export-ModuleMember` at end of `Robot.PowerShell.psm1` exports core functions + all plugin public functions

CLI metadata is stored in module-scoped lists and merged later by `Merge-PluginMenuItems` when `Invoke-RobotCLI` starts (see [CLI.md](CLI.md)).

Functions:

| Function | Purpose |
|---|---|
| `Resolve-PluginLoadOrder` | Topological sort of plugins by `DependsOn`. Returns ordered list. Warns and skips plugins with missing or circular dependencies. |
| `Resolve-PluginConfig` | Resolves all config keys for a plugin through the priority chain (see the Plugin Config System section). Returns hashtable. |

`Resolve-PluginLoadOrder` takes an array of parsed manifests and returns manifests sorted so that dependencies load before dependents. Algorithm: Kahn's topological sort. If a cycle is detected, warns to stderr and skips the cycled plugins. If a dependency references an undiscovered plugin, warns to stderr and skips the dependent plugin. Independent plugins always load regardless of other plugins' dependency issues.

`Resolve-PluginConfig` resolves all declared config keys for a single plugin through the priority chain.

Parameters:

| Parameter | Type | Description |
|---|---|---|
| `Manifest` | hashtable | Parsed `plugin.psd1` manifest (must have `Name` and `Config` keys) |
| `PluginDir` | string | Absolute path to the plugin's directory |
| `ModuleRoot` | string | Absolute path to the `.robot.powershell/` module root |

Algorithm:
1. Return empty `@{}` if manifest has no `Config` section
2. Load plugin-level `local.config.psd1` (if exists)
3. Load core `local.config.psd1` (if exists)
4. For each declared config key: Priority 1 is the environment variable (`$Def.EnvVar`), Priority 2 is the plugin's own `local.config.psd1` (direct key match), Priority 3 is the core `local.config.psd1` with namespaced key (`PluginName.Key`), Priority 4 is the manifest default value (`$Def.Default`), Priority 5 warns to stderr if `Required = $true` and no value resolved
5. Return resolved hashtable mapping config keys to their values

Return value: `[hashtable]` -- keys are config key names, values are resolved config values (or `$null` if unresolved).

---

## Lifecycle Hook System

Hook points:

| Operation | Phase | Can Reject? | Data Passed | Use Case |
|---|---|---|---|---|
| `Write-EntityFile` | `BeforeWrite` | Yes | `Path`, `Lines`, `NL` | Validate or enrich content before write |
| `Write-EntityFile` | `AfterWrite` | No | `Path`, `Lines`, `NL` | Side-effects: logging, sync, notifications |
| `Set-Session` | `BeforeWrite` | Yes | `FilePath`, `HeaderText`, `NewContent` | Validate session modifications |
| `Set-Session` | `AfterWrite` | No | `FilePath`, `HeaderText`, `NewContent` | Side-effects: logging, notifications |
| `New-Entity` | `AfterCreate` | No | `Name`, `Type`, `Tags`, `FilePath` | Side-effects: logging, external sync |
| `New-PlayerCharacter` | `AfterCreate` | No | `PlayerName`, `CharacterName`, `FilePath`, `CharacterFile` | Side-effects: logging, external sync |

`Invoke-PluginHook` invocation:

```powershell
Invoke-PluginHook -Operation 'Write-EntityFile' -Phase 'BeforeWrite' -Context @{
    Operation = 'Write-EntityFile'
    Path      = $Path
    Lines     = $Lines
    NL        = $NL
}
```

When no handlers are registered for a hook point, `Invoke-PluginHook` returns immediately with zero overhead. The hook registry is a `Dictionary[string, List[handler]]` -- a missing key means no work.

Handler function names are resolved via `Get-Command` on first invocation and cached in `$script:HookCommandCache` (keyed by function name). Subsequent invocations of the same handler skip the `Get-Command` call entirely. Failed lookups are cached as `[DBNull]::Value` to avoid repeated resolution attempts for missing handlers. The cache also validates that the command is a user-defined `Function` (not a `Cmdlet`, `Alias`, or `Application`) before caching.

Handlers execute in ascending priority order (lower number = earlier). Default priority is `100`. Handlers from different plugins at the same priority execute in plugin load order.

Error handling by phase:

| Phase | On error |
|---|---|
| `BeforeWrite` | Handler throws -> operation is rejected. Exception propagates to caller. Subsequent handlers are not invoked. |
| `AfterWrite` / `AfterCreate` | Handler throws -> error is logged to stderr (`Write-Warning`). Subsequent handlers continue. The core operation has already completed. |

Handler contract -- function signature:

```powershell
function Invoke-LLMValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$HookContext
    )

    # BeforeWrite: throw to reject
    if ($SomethingInvalid) {
        throw "Validation failed: $Reason"
    }

    # BeforeWrite: modify Lines in-place to enrich
    $HookContext.Lines.Add('- @validated: true')

    # AfterWrite/AfterCreate: side-effects only (Lines not available)
    Write-Verbose "Entity created: $($HookContext.Name)"
}
```

`HookContext` contents by operation and phase:

| Operation | Phase | Keys |
|---|---|---|
| `Write-EntityFile` | `BeforeWrite` | `Operation`, `Path`, `Lines` (`List[string]`, mutable), `NL` |
| `Write-EntityFile` | `AfterWrite` | `Operation`, `Path`, `Lines` (`List[string]`), `NL` |
| `Set-Session` | `BeforeWrite` | `Operation`, `FilePath`, `HeaderText`, `NewContent` |
| `Set-Session` | `AfterWrite` | `Operation`, `FilePath`, `HeaderText`, `NewContent` |
| `New-Entity` | `AfterCreate` | `Operation`, `Name`, `Type`, `Tags`, `FilePath` |
| `New-PlayerCharacter` | `AfterCreate` | `Operation`, `PlayerName`, `CharacterName`, `FilePath`, `CharacterFile` |

Handler behaviors:

| Pattern | Phase | Mechanism |
|---|---|---|
| Reject an operation | `BeforeWrite` | `throw` with descriptive message |
| Enrich content | `BeforeWrite` | Modify `$HookContext.Lines` in-place (it is a `List[string]` reference) |
| Side-effect only | `AfterWrite` / `AfterCreate` | Log, sync, notify. Data modification is not applicable. |

---

## Plugin Config System

For each declared config key, values are resolved in priority order:

| Priority | Source | Example |
|---|---|---|
| 1 | Environment variable | `$env:ROBOT_LLM_ENDPOINT` (from `EnvVar` field) |
| 2 | Plugin `local.config.psd1` | `plugins/llm-validator/local.config.psd1` |
| 3 | Core `local.config.psd1` (namespaced) | `.robot.powershell/local.config.psd1` with key `llm-validator.ApiEndpoint` |
| 4 | Manifest default | `Default` field in `Config` declaration |
| 5 | Warning if required | `Write-Warning` if `Required = $true` and no value resolved |

Plugin `local.config.psd1` files are git-ignored. The core `local.config.psd1` namespace uses the plugin `Name` as key to avoid collisions between plugins.

Declaring config keys in the manifest `Config` section -- each key is a hashtable:

```powershell
Config = @{
    ApiEndpoint = @{
        Description = 'LLM API endpoint URL'
        EnvVar      = 'ROBOT_LLM_ENDPOINT'     # Environment variable name (or $null)
        Default     = 'http://localhost:11434'   # Fallback value (or $null)
        Required    = $false                     # Warn if unresolved
    }
    Timeout     = @{
        Description = 'Request timeout in seconds'
        EnvVar      = $null
        Default     = 30
        Required    = $false
    }
    ApiKey      = @{
        Description = 'API authentication key'
        EnvVar      = 'ROBOT_LLM_API_KEY'
        Default     = $null
        Required    = $true                      # Warning emitted if missing
    }
}
```

Accessing config at runtime:

```powershell
$Config = Get-PluginConfig -PluginName 'llm-validator'
$Endpoint = $Config.ApiEndpoint
$Timeout  = $Config.Timeout
```

`Get-PluginConfig` returns the resolved hashtable for the named plugin. Config is resolved once during plugin loading and cached for the session. Returns an empty hashtable `@{}` if the plugin is not loaded.

---

## RBAC (Advisory)

The RBAC system is advisory -- it logs warnings but does not block operations by default. This allows gradual adoption without breaking existing workflows.

Roles and scope assignments are declared in `local.config.psd1`:

```powershell
@{
    # Map usernames (lowercase) to role names
    Roles = @{
        'anward'     = 'coordinator'
        'narrator1'  = 'narrator'
        'player1'    = 'player'
    }
    # Map role names to scope arrays
    RoleScopes = @{
        'coordinator' = @('admin:all')
        'narrator'    = @('session:read', 'session:write', 'entity:read', 'entity:write')
        'player'      = @('player:read:own', 'entity:read', 'session:read')
    }
}
```

User identity is resolved from `$env:ROBOT_USER` or `git config user.name`, then lowercased for lookup in the `Roles` table.

`Test-PluginScope -RequiredScope 'entity:write'` resolves the current user identity and checks whether the user's role grants the requested scope.

User identity resolution (priority order):
1. `$env:ROBOT_USER` environment variable
2. `git config user.name`
3. Fallback: `$null` (permissive -- all scopes granted)

If no `Roles` / `RoleScopes` configuration exists, or if user identity cannot be resolved, `Test-PluginScope` returns `$true`. This ensures the plugin system works out of the box without RBAC configuration.

Scope conventions:

| Scope | Grants |
|---|---|
| `entity:read` | Read entity data |
| `entity:write` | Create/modify/delete entities |
| `session:read` | Read session data |
| `session:write` | Create/modify sessions |
| `player:read` | Read all player data |
| `player:write` | Create/modify player data |
| `player:read:own` | Read own player data only |
| `admin:all` | All scopes (superuser) |

`admin:all` grants every scope. `player:read` grants `player:read:own`. A scope `a:b` implicitly grants `a:b:*` (any sub-scope).

---

## Plugin Management Functions

| Function | Signature | Output |
|---|---|---|
| `Get-LoadedPlugins` | `Get-LoadedPlugins` | Array of `@{ Name; Version; Description; Author; Functions; HookCount; MenuItemCount; ConfigKeys }` |
| `Get-PluginConfig` | `Get-PluginConfig -PluginName <string>` | Resolved config hashtable for the named plugin, or empty hashtable `@{}` if not loaded |

`Get-LoadedPlugins` returns metadata for all successfully loaded plugins in load order. Useful for diagnostics and tooling.

---

## Creating a Plugin (Step-by-Step)

Create the directory structure:

```powershell
mkdir plugins/my-plugin
mkdir plugins/my-plugin/public
mkdir plugins/my-plugin/private
mkdir plugins/my-plugin/cli        # Optional: CLI workflow files
mkdir plugins/my-plugin/tests
```

Write the manifest as `plugins/my-plugin/plugin.psd1`:

```powershell
@{
    Name        = 'my-plugin'
    Version     = '0.1.0'
    Description = 'Does something useful'
    Author      = 'Your Name'
}
```

Add public functions in `plugins/my-plugin/public/Get-MyData.ps1`:

```powershell
function Get-MyData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    # Implementation
}
```

Add private helpers in `plugins/my-plugin/private/Format-MyOutput.ps1`:

```powershell
function Format-MyOutput {
    param([object]$Data)
    # Internal helper - not exported
}
```

Add tests in `plugins/my-plugin/tests/my-plugin.Tests.ps1`:

```powershell
Describe 'my-plugin' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../../Robot.PowerShell.psm1" -Force
    }
    It 'Get-MyData returns expected output' {
        $Result = Get-MyData -Name 'test'
        $Result | Should -Not -BeNullOrEmpty
    }
}
```

Plugins can register menu items, categories, and help content for the interactive CLI. These are declared in the manifest and merged into the CLI at startup by `Merge-PluginMenuItems` (see [CLI.md](CLI.md)).

Menu items -- each item is a hashtable following the same schema as core registry entries (see [CLI.md](CLI.md)):

```powershell
MenuItems = @(
    @{
        ID       = 'my-plugin:my-action'    # Use plugin-name: prefix to avoid collisions
        Label    = 'Moja akcja'
        Menu     = 'Encje'                  # Must be in MenuOrder (core or plugin-added)
        Mode     = 'Wizard'                 # Wizard (default), Query, or Workflow
        Function = 'Invoke-MyAction'        # Required for Wizard/Query mode
    }
    @{
        ID               = 'my-plugin:my-workflow'
        Label            = 'Moje zadanie'
        Menu             = 'My Tools'       # Plugin-added category
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-MyWorkflow'  # Required for Workflow mode
    }
)
```

Categories -- declare new top-level categories before referencing them in menu items:

```powershell
MenuCategories = @('My Tools')
```

Help content -- provide help text for categories. For existing categories, only `Body` is needed (appended). For new categories, both `Title` and `Body` are required:

```powershell
HelpContent = @{
    'My Tools' = @{
        Title = 'My Tools - Pomoc'
        Body  = @('Line 1 of help text', 'Line 2 of help text')
    }
    'Encje' = @{
        Body = @('Additional help from my plugin.')  # Appended to existing help
    }
}
```

Workflow files -- if a menu item uses `Mode = 'Workflow'`, the workflow function must be available at CLI runtime. Place workflow functions in `cli/*.ps1` files inside the plugin directory -- these are dot-sourced at Layer 6.5 during CLI startup:

```
plugins/my-plugin/cli/cli-wf-myplugin.ps1
```

Configure as git submodule:

```bash
cd plugins/
git submodule add https://github.com/org/my-plugin.git my-plugin
git commit -m "Add my-plugin submodule"
```

---

## Example Plugin Sketches

Standalone plugin (`custom-export`) -- no hooks, purely adds new exported functions.

Manifest (`plugins/custom-export/plugin.psd1`):

```powershell
@{
    Name              = 'custom-export'
    Version           = '1.0.0'
    Description       = 'Export entity data to CSV format'
    Author            = 'Nerthus Team'
    ExportedFunctions = @('Export-EntityCSV')
}
```

Function (`plugins/custom-export/public/Export-EntityCSV.ps1`):

```powershell
function Export-EntityCSV {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Type,
        [string]$OutputPath = './entities.csv'
    )
    $Entities = Get-Entity -Type $Type
    $Entities | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "Exported $($Entities.Count) entities to $OutputPath"
}
```

Hook plugin (`llm-validator`) -- registers a `BeforeWrite` hook to validate entity file content.

Manifest (`plugins/llm-validator/plugin.psd1`):

```powershell
@{
    Name           = 'llm-validator'
    Version        = '1.2.0'
    Description    = 'Validates entity writes against LLM-based consistency checks'
    Author         = 'Nerthus Team'
    MinCoreVersion = '2.0.0'
    Hooks          = @(
        @{
            Operation = 'Write-EntityFile'
            Phase     = 'BeforeWrite'
            Handler   = 'Invoke-LLMValidation'
            Priority  = 100
        }
    )
    Config         = @{
        ApiEndpoint = @{
            Description = 'LLM API endpoint URL'
            EnvVar      = 'ROBOT_LLM_ENDPOINT'
            Default     = 'http://localhost:11434/api/generate'
            Required    = $false
        }
    }
}
```

Handler (`plugins/llm-validator/private/Invoke-LLMValidation.ps1`):

```powershell
function Invoke-LLMValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$HookContext
    )
    $Config = Get-PluginConfig -PluginName 'llm-validator'
    $Content = $HookContext.Lines -join "`n"

    $Result = Invoke-RestMethod -Uri $Config.ApiEndpoint -Method Post -Body @{
        prompt = "Validate this entity file for consistency: $Content"
    }

    if ($Result.valid -eq $false) {
        throw "LLM validation failed: $($Result.reason)"
    }

    Write-Verbose "LLM validation passed for $($HookContext.FilePath)"
}
```

Data source plugin (`homebrew-datasource`) -- adds a function that imports data from an external source.

Manifest (`plugins/homebrew-datasource/plugin.psd1`):

```powershell
@{
    Name              = 'homebrew-datasource'
    Version           = '0.5.0'
    Description       = 'Import entity data from D&D Beyond Homebrew collections'
    Author            = 'Nerthus Team'
    ExportedFunctions = @('Import-HomebrewData')
    Config            = @{
        CollectionUrl = @{
            Description = 'Homebrew collection URL'
            EnvVar      = 'ROBOT_HOMEBREW_URL'
            Default     = $null
            Required    = $true
        }
    }
}
```

Function (`plugins/homebrew-datasource/public/Import-HomebrewData.ps1`):

```powershell
function Import-HomebrewData {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Type = 'Przedmiot'
    )
    $Config = Get-PluginConfig -PluginName 'homebrew-datasource'
    if (-not $Config.CollectionUrl) {
        Write-Warning 'homebrew-datasource: CollectionUrl not configured'
        return
    }

    $Data = Invoke-RestMethod -Uri $Config.CollectionUrl
    foreach ($Item in $Data.items) {
        if ($PSCmdlet.ShouldProcess($Item.name, 'Import as entity')) {
            New-Entity -Name $Item.name -Type $Type -Tags @{
                source = 'homebrew'
                url    = $Item.url
            }
        }
    }
}
```

---

## Git Submodule Setup

Adding a plugin as submodule:

```bash
cd /path/to/lore-repo/.robot.powershell
git submodule add https://github.com/org/my-plugin.git plugins/my-plugin
git commit -m "Add my-plugin plugin submodule"
```

The Robot module is itself a submodule inside a parent lore repository. Plugins as submodules create a nested structure:

```
lore-repo/                          # Parent repository
+-- .robot.powershell/                     # Submodule: Robot module
    +-- plugins/
        +-- my-plugin/              # Submodule: plugin
```

This means `.gitmodules` entries exist at two levels: `lore-repo/.gitmodules` references `.robot.powershell`, and `.robot.powershell/.gitmodules` references `plugins/my-plugin`.

To clone a lore repository with all nested submodules:

```bash
git clone --recursive https://github.com/org/lore-repo.git
```

If already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

Bumping plugin versions:

```bash
cd .robot.powershell/plugins/my-plugin
git fetch origin
git checkout v1.3.0
cd ../..
git add plugins/my-plugin
git commit -m "Bump my-plugin to v1.3.0"
```

The parent module tracks a specific commit of each plugin submodule. Bumping requires checking out the desired version inside the plugin directory and committing the updated submodule reference.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| No `plugins/` directory | No plugins loaded. Module functions normally. |
| Empty `plugins/` directory | No plugins loaded. |
| Directory without `plugin.psd1` | Silently skipped during discovery. |
| Invalid manifest (parse error) | Warns to stderr with plugin path and error. Plugin skipped. |
| `MinCoreVersion` exceeds current | Warns to stderr with version mismatch details. Plugin skipped. |
| Missing dependency (`DependsOn`) | Warns to stderr with missing plugin name. Dependent plugin skipped; independent plugins still load. |
| Circular dependency | Warns to stderr with cycle participant names. Cycled plugins skipped; non-cycled plugins still load. |
| Function name collision | Warns to stderr with conflicting function name and plugin name. Conflicting function skipped; other functions in the plugin still load. |
| Hook handler function not found | Warns to stderr at invocation time. Cached as `[DBNull]::Value` to skip on future invocations. Subsequent hooks still run. |
| Hook handler is not a Function (Cmdlet/Alias/Application) | Warns to stderr. Cached as `[DBNull]::Value`. Hook skipped; subsequent hooks still run. |
| Missing required config (no value resolved) | Warns to stderr with config key name and plugin name. Plugin loads but config key is `$null`. |
| No RBAC config (`Roles`/`RoleScopes` absent) | `Test-PluginScope` returns `$true` for all scopes. Fully permissive. |
| Menu item missing `ID`, `Label`, or `Menu` | Warns to stderr with plugin name. Item skipped; other items still merge. |
| Menu item ID collides with existing entry | Warns to stderr. Item skipped; existing entry preserved. |
| Menu item references unknown category | Warns to stderr. Item skipped. Declare the category in `MenuCategories` first. |
| Wizard item missing `Function` | Warns to stderr. Item skipped. |
| Workflow item missing `WorkflowFunction` | Warns to stderr. Item skipped. |
| Query item `Columns`/`Headers` count mismatch | Warns to stderr. Item skipped. |
| Help entry for new category missing `Title` or `Body` | Warns to stderr. Entry skipped. |
| Plugin `cli/` directory does not exist | No plugin CLI files loaded for that plugin. |
| Plugin `cli/*.ps1` file fails to load | Warns to stderr with file path and error. Other CLI files still load. |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/plugin-system.Tests.ps1` | Resolve-PluginLoadOrder (ordering, missing deps, circular deps), Resolve-PluginConfig (env var, local config, namespaced, defaults, priority), Invoke-PluginHook (fast path, priority ordering, BeforeWrite rejection, AfterWrite error logging, missing handlers), Test-PluginScope (permissive default, role matching, scope hierarchy), Get-LoadedPlugins, Get-PluginConfig, Plugin CLI metadata extraction (MenuItems, MenuCategories, HelpContent) |
| `tests/cli-registry.Tests.ps1` | Merge-PluginMenuItems (valid merge, collision detection, mode validation, category merge, help merge) |

Plugin-specific tests reside in each plugin's `tests/` directory. Run plugin tests separately:

```powershell
Invoke-Pester -Path plugins/my-plugin/tests/
```

Run all plugin tests:

```powershell
Invoke-Pester -Path plugins/*/tests/
```

---

## Related Documents

- [CONFIG-STATE.md](CONFIG-STATE.md) - Core configuration resolution (priority chain pattern reused by plugin config)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Write operations that invoke `BeforeWrite`/`AfterWrite` hooks
- [SESSIONS.md](SESSIONS.md) - Session pipeline that invokes `Set-Session` hooks
- [REST-API.md](REST-API.md) - REST API plugin (robot-api): C# engine, RunspacePool workers, hook-driven SSE

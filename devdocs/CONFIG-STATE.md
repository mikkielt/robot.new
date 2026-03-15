# Configuration & State - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers `private/admin-config.ps1` (configuration resolution, path management, template rendering), `private/admin-state.ps1` (append-only history file management for PU processing), `private/operation-context.ps1` (accumulator-based operation tracking for write commands), and `public/set-datadirectory.ps1` (data directory override for testing and non-standard layouts).

---

## 2. Configuration Resolution (`private/admin-config.ps1`)

### 2.1 Functions

| Function | Purpose |
|---|---|
| `Get-AdminConfig` | Returns a hashtable with all resolved paths and config values |
| `Resolve-ConfigValue` | Priority-chain resolver for a single config key |
| `Get-AdminTemplate` | Loads and renders template files with placeholder substitution |
| `Find-DataManifest` | Checks for `.robot/robot-data.psd1` at a fixed path within the repo root |
| `Test-PathUnderRoot` | Validates that a resolved path is under a given root directory (prevents path traversal) |
| `Set-DataDirectory` | Overrides or resets the lore repository root (in `public/set-datadirectory.ps1`) |

### 2.2 Priority Chain (`Resolve-ConfigValue`)

Resolution order for each config value:

| Priority | Source | Example |
|---|---|---|
| 1 | Explicit parameter | `-PRFWebhook "https://..."` |
| 2 | Environment variable | `$env:NERTHUS_REPO_WEBHOOK` |
| 3 | Local config file | `.robot.new/local.config.psd1` (git-ignored) |
| 4 | Fail with error | Throws if mandatory value missing |

The local config file is loaded via `Import-PowerShellDataFile` with try-catch protection. It is git-ignored to keep environment-specific values (webhooks, paths) out of version control.

### 2.3 Resolved Paths (`Get-AdminConfig`)

| Key | Value | Description |
|---|---|---|
| `RepoRoot` | Repository root | From `Get-RepoRoot` |
| `ModuleRoot` | `.robot.new/` | Module directory |
| `EntitiesFile` | `entities.md` | Base entity registry |
| `TemplatesDir` | `.robot.new/templates/` | Template directory |
| `ResDir` | `.robot/res/` | State/resource directory |
| `CharactersDir` | `Postaci/Gracze/` | Character files directory |
| `PlayersFile` | `Gracze.md` | Legacy player database |

Paths are resolved from `.robot/robot-data.psd1` manifest when available (see §2.5), falling back to the hardcoded values above. This ensures backward compatibility when no manifest exists.

Additional config values:
- `BotUsername` - Discord bot display name (resolved but not used by PU assignment, which hardcodes `"Bothen"`)
- Webhook URLs - resolved via priority chain

### 2.4 Template Rendering (`Get-AdminTemplate`)

Loads template files from `.robot.new/templates/` and performs simple `{Placeholder}` substitution:

```powershell
$Template = Get-AdminTemplate -Name "player-character-file.md.template"
$Result = $Template.Replace("{CharacterSheetUrl}", $Url)
```

No advanced template engine - pure string `.Replace()` calls by the consumer.

**File existence check**: Validates template file exists before reading. Throws on missing file.

### 2.5 Manifest-Based Data Discovery (`Find-DataManifest`)

The module is a git submodule inside a parent lore repository. Coordinators may place data files in non-default locations. `Find-DataManifest` enables this flexibility by checking for a `.robot/robot-data.psd1` manifest file at a fixed path inside the repo root.

**Manifest format** (PowerShell data file):

```powershell
@{
    PlayersFile    = 'Gracze.md'
    CharactersDir  = 'Postaci/Gracze'
    EntitiesDir    = '.robot.new'
    StateDir       = '.robot/res'
}
```

Paths in the manifest are relative to the manifest file's directory. The module resolves them to absolute paths at discovery time.

**Discovery algorithm**:

1. Resolve `RepoRoot` via `Get-RepoRoot` (or accept override for testing)
2. Construct the fixed path: `{RepoRoot}/.robot/robot-data.psd1`
3. If the file exists, parse it and cache the result
4. If not found, fall back to hardcoded paths (backward compatible)
5. Cache the resolved manifest and its directory in `$script:CachedManifest` / `$script:CachedManifestDir`

**Caching**: Per-session. Once discovered, the manifest is not re-scanned. This avoids repeated directory traversal.

**`Get-ParentRepoRoot`**: Companion function in `public/get-reporoot.ps1`. Walks upward from `Get-RepoRoot` past the submodule `.git` to find the enclosing repository root. No longer used by `Find-DataManifest` (which uses a fixed path), but remains available for callers that need the parent repo boundary.

**`Get-AdminConfig` integration**: When `Find-DataManifest` returns a manifest, `Get-AdminConfig` uses its paths. When no manifest exists, all paths resolve identically to the hardcoded defaults. Zero breaking changes.

**Path traversal protection**: `Get-AdminConfig` validates each manifest-resolved path via `Test-PathUnderRoot` before accepting it. Paths that resolve outside the repository root are skipped with a warning to stderr. This prevents a malicious or misconfigured manifest from directing the module to read/write files outside the repository.

### 2.6 Path Validation (`Test-PathUnderRoot`)

Validates that a resolved path is under a given root directory. Used by `Get-AdminConfig` to prevent path traversal attacks from manifest entries.

| Parameter | Type | Description |
|---|---|---|
| `Path` | string | **Mandatory**. The path to validate. |
| `Root` | string | **Mandatory**. The root directory the path must be under. |

**Algorithm**:
1. Resolve both `Path` and `Root` to absolute form via `[System.IO.Path]::GetFullPath()`
2. Ensure `Root` ends with `DirectorySeparatorChar` for correct prefix matching
3. Return `$Path.StartsWith($Root, OrdinalIgnoreCase)`

Returns `$true` if the path is under the root, `$false` otherwise.

---

## 3. State Management (`private/admin-state.ps1`)

### 3.1 Functions

| Function | Purpose |
|---|---|
| `Get-AdminHistoryEntries` | Reads processed session headers from a state file |
| `Add-AdminHistoryEntry` | Appends new entries with timestamp |

### 3.2 State File Format

Append-only Markdown files in `.robot/res/`:

```markdown
W tym pliku znajduje się lista sesji przetworzonych przez system.

## Historia

- 2025-06-15 14:30 (UTC+02:00):
    - ### 2025-06-01, Session Title, Narrator
    - ### 2025-06-08, Another Session, Narrator
- 2025-07-15 10:00 (UTC+02:00):
    - ### 2025-07-01, July Session, Narrator
```

### 3.3 Reading History (`Get-AdminHistoryEntries`)

Parses entry lines matching the precompiled pattern `^\s+-\s+###\s+(.+)$`.

**Normalization pipeline**:
1. Trim leading/trailing whitespace
2. Collapse multiple spaces to single space (via precompiled `\s{2,}` regex)
3. Strip leading `### ` prefix

**Output**: `HashSet[string]` with `OrdinalIgnoreCase` comparer for O(1) membership testing.

Both stripped and unstripped forms are available for comparison. The hash set provides efficient deduplication lookups when filtering sessions in the PU pipeline.

### 3.4 Writing History (`Add-AdminHistoryEntry`)

Appends new entries with a timestamped header:

```markdown
- YYYY-MM-dd HH:mm (UTC±HH:MM):
    - ### session header 1
    - ### session header 2
```

**Timestamp format**: Uses `DateTimeOffset.Now` for timezone-aware timestamps. Handles negative UTC offsets.

**Header sorting**: Session headers sorted chronologically using `[StringComparer]::Ordinal` (works because headers start with `YYYY-MM-DD`).

**`### ` prefix**: Added automatically if not already present.

**File creation**: If the state file doesn't exist, it is created with the preamble:
```
W tym pliku znajduje się lista sesji przetworzonych przez system.

## Historia

```

**Directory creation**: Parent directory created if missing.

### 3.5 State File Location

`$Config.ResDir` -> `<RepoRoot>/.robot/res/pu-sessions.md`

This is separate from the module directory (`.robot.new/`) and lives in `.robot/res/` for historical compatibility with the legacy system.

---

## 4. Operation Context (`private/operation-context.ps1`)

### 4.1 Purpose

Accumulator-based operation tracking for write commands. Provides a structured way to collect changes, warnings, and touched files during a write operation, then drain them into a single `Robot.OperationResult` object at completion.

Dot-sourced by `private/entity-writehelpers.ps1` (non-fatal if missing) and checked by `private/charfile-helpers.ps1`. Not auto-loaded by `robot.psm1`.

### 4.2 Accumulators

| Variable | Type | Purpose |
|---|---|---|
| `$script:OpChanges` | `List[PSCustomObject]` | Property change records `{ Property, OldValue, NewValue }` |
| `$script:OpWarnings` | `List[PSCustomObject]` | Warning records `{ Message, Severity, ActionHint }` |
| `$script:OpFiles` | `HashSet[string]` | Touched file paths (case-insensitive deduplication) |

### 4.3 Functions

| Function | Purpose |
|---|---|
| `Clear-OperationContext` | Resets all three accumulators. No-op if accumulators are `$null`. |
| `Add-OperationChange` | Pushes a property change record. Called by `Set-EntityTag` on each tag upsert. |
| `Add-OperationWarning` | Pushes a warning record with severity (`Info`, `Warning`, `Error`) and optional `ActionHint`. |
| `Add-OperationFile` | Registers a touched file path (deduplicated via `HashSet`). Called by `Write-EntityFile` and `Write-CharacterFile`. |
| `New-OperationResult` | Drains all accumulators into a `Robot.OperationResult` object and resets them via `Clear-OperationContext`. |

### 4.4 `Add-OperationChange`

| Parameter | Type | Description |
|---|---|---|
| `Property` | string | **Mandatory**. The property or tag that changed (e.g. `@status`). |
| `OldValue` | any | Previous value (`$null` for new tags). |
| `NewValue` | any | New value being set. |

### 4.5 `Add-OperationWarning`

| Parameter | Type | Description |
|---|---|---|
| `Message` | string | **Mandatory**. Warning message text. |
| `Severity` | string | Severity level, defaults to `'Info'`. |
| `ActionHint` | string | Optional suggested remediation action. |

### 4.6 `New-OperationResult`

| Parameter | Type | Description |
|---|---|---|
| `Success` | bool | **Mandatory**. Whether the operation succeeded. |
| `Action` | string | **Mandatory**. The action performed (e.g. `'Set'`, `'New'`, `'Remove'`). |
| `TargetType` | string | **Mandatory**. Entity type targeted (e.g. `'Postać'`, `'NPC'`). |
| `TargetName` | string | **Mandatory**. Entity name targeted. |
| `UndoHint` | string | Optional undo guidance text. |

**Return object** (`Robot.OperationResult`):

| Property | Type | Description |
|---|---|---|
| `Success` | bool | Operation outcome |
| `Action` | string | Action performed |
| `TargetType` | string | Entity type |
| `TargetName` | string | Entity name |
| `FilePath` | string or string[] or `$null` | Touched file(s): scalar when 1, array when multiple, `$null` when none |
| `Changes` | object[] | Drained change records |
| `Warnings` | object[] | Drained warning records |
| `UndoHint` | string | Undo guidance |
| `Timestamp` | datetime | Time of result creation |

**Context cleanup**: `Clear-OperationContext` is called in a `finally` block within `New-OperationResult`, ensuring accumulators are always reset even if result construction throws. The return statement is inside the `try` block so the result object is built before cleanup occurs.

**Note**: Has `SuppressMessageAttribute` for `PSUseShouldProcessForStateChangingFunctions` — drains in-memory accumulators, not system state.

### 4.7 Integration Points

Write helpers push records as side effects:
- `Set-EntityTag` -> `Add-OperationChange` (tag name, old value, new value)
- `Write-EntityFile` -> `Add-OperationFile` (file path)
- `Write-CharacterFile` -> `Add-OperationFile` (file path)

Availability is checked via `$script:HasOpCtx` flag, set at dot-source time by probing for `Add-OperationChange` (in entity-writehelpers.ps1) or `Add-OperationFile` (in charfile-helpers.ps1).

---

## 5. `Set-DataDirectory` (`public/set-datadirectory.ps1`)

### 5.1 Purpose

Overrides or resets the data directory used as the lore repository root. Useful for testing and non-standard layouts where the lore repository is not the git ancestor of the module.

### 5.2 Parameters

| Parameter | Type | ParameterSet | Description |
|---|---|---|---|
| `Path` | string | `Path` | **Mandatory**. Absolute path to the directory to use as the data root. Must exist. |
| `Reset` | switch | `Reset` | **Mandatory**. Clears the override and reverts to git-based detection. |

### 5.3 Behavior

- **Path mode**: Validates directory existence, stores `[System.IO.Path]::GetFullPath($Path)` in `$script:DataDirectoryOverride`. Subsequent `Get-RepoRoot` calls return this path instead of performing git traversal.
- **Reset mode**: Sets `$script:DataDirectoryOverride` to `$null`.
- **Both modes**: Clears `$script:CachedManifest` and `$script:CachedManifestDir` so that `Find-DataManifest` re-scans from the new root on next use.

---

## 6. Warning Suppression (`robot.psm1`)

### 6.1 Overview

Module-scoped warning suppression prevents `[System.Console]::Error.WriteLine` output from corrupting interactive CLI menus. All warning/info emission routes through centralized helpers that check a boolean flag before writing.

### 6.2 Components

| Component | Location | Purpose |
|---|---|---|
| `$script:SuppressWarnings` | `robot.psm1` | Module-scoped boolean flag, defaults to `$false` |
| `Write-RobotWarning` | `robot.psm1` | Emits `[WARN ...]` to stderr if flag is `$false` |
| `Write-RobotInfo` | `robot.psm1` | Emits `[INFO ...]` to stderr if flag is `$false` |

Both helpers are module-internal (not exported). Available to all dot-sourced functions via module scope.

### 6.3 `-Quiet` Parameter Pattern

Public functions that emit warnings expose a `[switch]$Quiet` parameter. When set, the function saves the current flag, sets it to `$true`, and restores in `finally`:

```powershell
$PrevSuppress = $script:SuppressWarnings
if ($Quiet) { $script:SuppressWarnings = $true }
try {
    # function body using Write-RobotWarning / Write-RobotInfo
}
finally {
    $script:SuppressWarnings = $PrevSuppress
}
```

Nested calls inherit the suppressed state automatically — inner functions do not need `-Quiet` threading.

### 6.4 CLI Integration

The CLI suppresses warnings at two levels:

1. **Startup** (`Invoke-RobotCLI`): `Get-Entity -Quiet` for pre-loading
2. **Dispatch** (`Invoke-MenuAction` in `cli-routing.ps1`): wraps all Wizard/Query/Workflow dispatch with `$script:SuppressWarnings = $true` / `finally { $false }`

CLI-internal warnings (plugin validation in `Merge-PluginMenuItems`, plugin load errors) are **not** suppressed — they fire before the menu loop starts and are unaffected by overlay rendering.

### 6.5 Scope of Conversion

| Category | Converted | Reason |
|---|---|---|
| Public data-access functions (16) | Yes | CLI-reachable, `-Quiet` parameter added |
| Private helpers (4 files) | Yes | Inherit flag from callers |
| CLI startup warnings | No | Fire before menu loop |
| Infrastructure (`plugin-hooks`, `plugin-loader`, `admin-config`) | No | Module import time |
| Migration (`migration-state`) | No | Not CLI-reachable |

---

## 7. Environment Variables

| Variable | Purpose |
|---|---|
| `NERTHUS_REPO_WEBHOOK` | Default Discord webhook URL |
| `NERTHUS_BOT_USERNAME` | Default bot display name |

---

## 8. Local Config File

Path: `.robot.new/local.config.psd1` (git-ignored)

PowerShell data file format:

```powershell
@{
    PRFWebhook  = 'https://discord.com/api/webhooks/...'
    BotUsername  = 'Bothen'
}
```

Loaded via `Import-PowerShellDataFile` with error handling. Missing file is not an error - the priority chain falls through to the next source.

---

## 9. Edge Cases

| Scenario | Behavior |
|---|---|
| Missing `local.config.psd1` | Not an error; priority chain continues |
| Missing template file | Throws error |
| Missing `.robot/robot-data.psd1` manifest | Not an error; falls back to hardcoded paths |
| Manifest found at fixed path | Paths resolved relative to `.robot/` directory, cached per session |
| Negative UTC offset | Formatted correctly (e.g., `UTC-05:00`) |
| Missing `.robot/res/` directory | Created automatically by `Add-AdminHistoryEntry` |
| Duplicate session headers in history | Deduplicated by `HashSet` on read |
| Whitespace variations in headers | Normalized (collapsed to single space) before comparison |
| `operation-context.ps1` not loaded | `$script:HasOpCtx` is `$false`; write helpers skip accumulator calls |
| `$script:OpChanges` is `$null` | `Add-OperationChange` is no-op (guard at function entry) |
| Multiple files in operation | `New-OperationResult` returns `FilePath` as array |
| Single file in operation | `New-OperationResult` returns `FilePath` as scalar string |
| No files in operation | `New-OperationResult` returns `FilePath` as `$null` |
| Manifest path resolves outside repo root | Skipped with warning to stderr; `Test-PathUnderRoot` returns `$false` |
| `Set-DataDirectory` with non-existent path | Throws `"Directory not found: '$Path'"` |
| `Set-DataDirectory -Reset` | Clears override and manifest cache; `Get-RepoRoot` reverts to git traversal |

---

## 10. Testing

| Test file | Coverage |
|---|---|
| `tests/admin-config.Tests.ps1` | Priority chain, path resolution, template loading, manifest discovery, caching |
| `tests/admin-state.Tests.ps1` | History reading, normalization, appending, file creation |
| `tests/get-reporoot.Tests.ps1` | `Get-ParentRepoRoot` (submodule boundary traversal) |
| `tests/operation-context.Tests.ps1` | Accumulator lifecycle, change/warning/file tracking, `New-OperationResult` drain |

Fixtures: `local.config.psd1`, `pu-sessions.md`, template files in `tests/fixtures/templates/`.

---

## 11. Related Documents

- [PU.md](PU.md) - PU pipeline uses history entries for deduplication
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Write commands consume `Get-AdminConfig` and operation context
- [CHARFILE.md](CHARFILE.md) - Character file writing uses operation context (`Write-CharacterFile`)
- [DISCORD.md](DISCORD.md) - Webhook config resolution

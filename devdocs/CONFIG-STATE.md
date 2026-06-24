# Configuration & State - Technical Reference

## Scope

The configuration and state subsystem comprises `private/admin-config.ps1` (configuration resolution, path management, template rendering), `private/admin-state.ps1` (atomic JSON persistence with crash-safe writes and backup recovery, plus append-only history file management for PU processing), `private/operation-context.ps1` (accumulator-based operation tracking for write commands), and `public/set-reporoot.ps1` (repository root override for testing and non-standard layouts).

## Configuration Resolution

Source: `private/admin-config.ps1`.

Functions:

| Function | Purpose |
|---|---|
| `Get-AdminConfig` | Returns a hashtable with all resolved paths and config values |
| `Resolve-ConfigValue` | Priority-chain resolver for a single config key |
| `Get-AdminTemplate` | Loads and renders template files with placeholder substitution |
| `Find-DataManifest` | Checks for `.robot.local/robot-data.psd1` at a fixed path within the repo root |
| `Test-PathUnderRoot` | Validates that a resolved path is under a given root directory (prevents path traversal) |
| `Set-RepoRoot` | Overrides or resets the lore repository root (in `public/set-reporoot.ps1`) |

Resolution order for each config value (`Resolve-ConfigValue`):

| Priority | Source | Example |
|---|---|---|
| 1 | Explicit parameter | `-PRFWebhook "https://..."` |
| 2 | Environment variable | `$env:NERTHUS_REPO_WEBHOOK` |
| 3 | Local config file | `.robot.powershell/local.config.psd1` (git-ignored) |
| 4 | Fail with error | Throws if mandatory value missing |

The local config file is loaded via `Import-PowerShellDataFile` with try-catch protection. It is git-ignored to keep environment-specific values (webhooks, paths) out of version control.

Resolved paths (`Get-AdminConfig`):

| Key | Value | Description |
|---|---|---|
| `RepoRoot` | Repository root | From `Get-RepoRoot` |
| `ModuleRoot` | `.robot.powershell/` | Module directory |
| `EntitiesFile` | `{RepoRoot}/entities.md` | Base entity registry |
| `TemplatesDir` | `{ModuleRoot}/templates/` | Template directory |
| `ResDir` | `{RepoRoot}/.robot.local/res/` | State/resource directory |
| `CharactersDir` | `{RepoRoot}/Postaci/Gracze/` | Character files directory |
| `PlayersFile` | `{RepoRoot}/Gracze.md` | Legacy player database |
| `CacheDir` | `{RepoRoot}/.robot.local/.cache/` | Disk cache directory for parsed data |
| `SeasonMapping` | `$null` | Custom season mapping from `local.config.psd1`, or `$null` for default meteorological |

`CacheDir` resolves to `{RepoRoot}/.robot.local/.cache` (not inside the module directory). It is used by `Clear-ParseCaches` (via `Robot.ParseCacheHelper`) for disk cache persistence and invalidation.

`SeasonMapping` is read from the `SeasonMapping` key in `local.config.psd1`. When present, it overrides the default meteorological season boundaries used by `Resolve-SeasonForDate`. When absent (or when `local.config.psd1` does not exist), the value is `$null` and the default mapping applies.

Paths are resolved from `.robot.local/robot-data.psd1` manifest when available (see Manifest-Based Data Discovery below), falling back to the hardcoded values above. This ensures backward compatibility when no manifest exists.

Additional config values: `BotUsername` is the Discord bot display name (resolved but not used by PU assignment, which hardcodes `"Bothen"`). Webhook URLs are resolved via the priority chain.

Template rendering (`Get-AdminTemplate`) loads template files from `.robot.powershell/templates/` and performs simple `{Placeholder}` substitution:

```powershell
$Template = Get-AdminTemplate -Name "player-character-file.md.template"
$Result = $Template.Replace("{CharacterSheetUrl}", $Url)
```

No advanced template engine -- pure string `.Replace()` calls by the consumer. The function validates template file existence before reading and throws on missing file.

`Find-DataManifest` enables flexible data file placement. The module is a git submodule inside a parent lore repository. Coordinators may place data files in non-default locations. `Find-DataManifest` checks for a `.robot.local/robot-data.psd1` manifest file at a fixed path inside the repo root.

Manifest format (PowerShell data file):

```powershell
@{
    PlayersFile    = 'Gracze.md'
    CharactersDir  = 'Postaci/Gracze'
    EntitiesDir    = '.robot.powershell'
    StateDir       = '.robot.local/res'
}
```

Paths in the manifest are relative to the manifest file's directory. The module resolves them to absolute paths at discovery time.

Discovery algorithm: (1) Resolve `RepoRoot` via `Get-RepoRoot` (or accept override for testing). (2) Construct the fixed path: `{RepoRoot}/.robot.local/robot-data.psd1`. (3) If the file exists, parse it and cache the result. (4) If not found, fall back to hardcoded paths (backward compatible). (5) Cache the resolved manifest and its directory in `$script:CachedManifest` / `$script:CachedManifestDir`.

Caching is per-session. Once discovered, the manifest is not re-scanned. This avoids repeated directory traversal.

`Get-ParentRepoRoot` is a companion function in `public/get-reporoot.ps1`. Walks upward from `Get-RepoRoot` past the submodule `.git` to find the enclosing repository root. No longer used by `Find-DataManifest` (which uses a fixed path), but remains available for callers that need the parent repo boundary.

When `Find-DataManifest` returns a manifest, `Get-AdminConfig` uses its paths. When no manifest exists, all paths resolve identically to the hardcoded defaults. Zero breaking changes. `Get-AdminConfig` validates each manifest-resolved path via `Test-PathUnderRoot` before accepting it. Paths that resolve outside the repository root are skipped with a warning to stderr. This prevents a misconfigured manifest from directing the module to read/write files outside the repository.

`Test-PathUnderRoot` validates that a resolved path is under a given root directory:

| Parameter | Type | Description |
|---|---|---|
| `Path` | string | Mandatory. The path to validate. |
| `Root` | string | Mandatory. The root directory the path must be under. |

Algorithm: (1) Resolve both `Path` and `Root` to absolute form via `[System.IO.Path]::GetFullPath()`. (2) Ensure `Root` ends with `DirectorySeparatorChar` for correct prefix matching. (3) Return `$Path.StartsWith($Root, OrdinalIgnoreCase)`.

Returns `$true` if the path is under the root, `$false` otherwise.

## State Management

Source: `private/admin-state.ps1`.

Functions:

| Function | Purpose |
|---|---|
| `Save-JsonStateFile` | Atomic JSON write with temp-file swap and `.bak` backup |
| `Read-JsonStateFile` | Reads JSON state file with backup recovery on corruption |
| `Get-AdminHistoryEntries` | Reads processed session headers from a state file |
| `ConvertTo-MutableStateObject` | Generic JSON state file reader that returns a mutable ordered hashtable with a `List[object]` collection |
| `Get-TimezoneOffsetString` | Returns a formatted UTC offset string (e.g. `UTC+02:00`) for the local timezone |
| `Add-AdminHistoryEntry` | Appends new entries with timestamp |

## Schema Version Pointer

The repository schema version lives in `.robot.local/schema.json`, written atomically via `Save-JsonStateFile` from the migration framework. The module's WP-5 load gate reads this on import to decide the operating mode (Normal, ReadOnly, Refused, Unknown).

| Field | Type | Purpose |
|---|---|---|
| `schemaFileVersion` | int | Format version of this file (currently 1) |
| `current` | string | Current SemVer schema version (e.g. `0.3.0` or `21.3.7+plugin-foo.1`) |
| `majorName` | string | Informational name tied to MAJOR (e.g. `Yellow Threat`) |
| `appliedAt` | ISO-8601 UTC | When `current` was last set |
| `appliedBy` | string | User who applied the current migration |
| `appliedMigrationId` | string | ID of the migration that produced `current` |
| `lockedBy` | string \| null | Owner of the active migration lock (`user@host/PID`) |
| `lockedAt` | ISO-8601 UTC \| null | When the lock was acquired (stale TTL default 60 min, override via `MigrationLockTtlMinutes` in `local.config.psd1`) |
| `history` | array | Prior `current` entries, appended on each `Set-SchemaVersion` |

`Lock-Schema` fabricates an initial `0.0.0` placeholder on first acquisition for a fresh repo; the placeholder is NOT pushed to history when the first real migration applies (only entries with `appliedMigrationId` are recorded).

## Per-Migration Record File

`Get-MigrationStateFile` reads `.robot.local/res/migration-state.json`. The new shape uses a `migrations` dictionary keyed by migration ID:

```json
{
  "schemaFileVersion": 3,
  "migrations": {
    "0.1.0-bootstrap-entities": {
      "status": "Completed",
      "startedAt": "2026-06-24T14:00:00Z",
      "completedAt": "2026-06-24T14:00:15Z",
      "checklist": { "entitiesParsed": true },
      "sourceHash": "sha256:..."
    }
  }
}
```

The legacy shape used a `Phases` dict keyed by `"0".."8"` integers. `Get-MigrationStateFile` auto-converts on read via a permanent shim that maps each legacy phase to its framework migration ID (e.g. `"0" → "0.1.0-bootstrap-entities"`, `"5" → "0.6.0-upgrade-session-formats"`). The shim emits a one-shot `Write-RobotInfo` per process suggesting `Save-MigrationStateFile` to make the conversion durable.

State files are JSON files in `.robot.local/res/`:

```json
{
  "version": 2,
  "runs": [
    {
      "processedAt": "2025-06-15T14:30:00",
      "timezone": "UTC+02:00",
      "sessions": [
        "2025-06-01, Session Title, Narrator",
        "2025-06-08, Another Session, Narrator"
      ]
    },
    {
      "processedAt": "2025-07-15T10:00:00",
      "timezone": "UTC+02:00",
      "sessions": [
        "2025-07-01, July Session, Narrator"
      ]
    }
  ]
}
```

`Save-JsonStateFile` implements crash-safe writes via a three-step temp-file swap:

| Parameter | Type | Description |
|---|---|---|
| `Path` | string | Mandatory. Absolute path to the JSON state file. |
| `Data` | object | Mandatory. The data object to serialize via `ConvertTo-Json`. |
| `Depth` | int | JSON serialization depth, defaults to `10`. |

Algorithm: (1) Create parent directory if missing. (2) Serialize `$Data` to JSON. (3) Write to `$Path.tmp` (UTF-8 no BOM). (4) If `$Path` already exists, rotate current file to `$Path.bak` (deleting prior backup). (5) Move `.tmp` into place. This guarantees the file is never in a half-written state even if the process is killed mid-write.

`Read-JsonStateFile` reads and deserializes a JSON state file with backup recovery:

| Parameter | Type | Description |
|---|---|---|
| `Path` | string | Mandatory. Absolute path to the JSON state file. |

Algorithm: (1) Return `$null` if file does not exist. (2) Read and parse via `ConvertFrom-Json`. (3) On parse failure (truncation, corruption), try `$Path.bak` left by the last successful `Save-JsonStateFile` write. (4) If backup parses successfully, copy it over the corrupted primary file and return the recovered data. (5) If backup also fails, return `$null`. Warnings are emitted via `Write-RobotWarning` at each fallback step.

Both functions are shared by `admin-state.ps1` and `discord-state.ps1`.

`Get-AdminHistoryEntries` reads the JSON runs array via `Read-JsonStateFile` and extracts all session header strings. The normalization pipeline: (1) Trim leading/trailing whitespace. (2) Collapse multiple spaces to single space (via precompiled `\s{2,}` regex). Output is a `HashSet[string]` with `OrdinalIgnoreCase` comparer for O(1) membership testing. The hash set provides efficient deduplication lookups when filtering sessions in the PU pipeline.

`Add-AdminHistoryEntry` appends a new run object with a timestamped entry:

```json
{
  "processedAt": "YYYY-MM-ddTHH:mm:ss",
  "timezone": "UTC±HH:MM",
  "sessions": [
    "session header 1",
    "session header 2"
  ]
}
```

`ConvertTo-MutableStateObject` is a shared helper that reads a JSON state file via `Read-JsonStateFile` and returns an `[ordered]@{}` hashtable with a mutable `List[object]` for the named collection key. Used by both `Add-AdminHistoryEntry` (collection key `runs`, default version `2`) and `Add-DiscordDeliveryEntry` in `discord-state.ps1` (collection key `entries`, default version `1`). When `Read-JsonStateFile` returns `$null` (file missing or unrecoverable corruption), it returns a fresh hashtable with the default version and an empty list. When the file exists, it rebuilds the collection from `ConvertFrom-Json` output (which yields immutable PSCustomObjects) into a mutable `List[object]`.

`Get-TimezoneOffsetString` returns the local timezone offset formatted as `UTC+HH:MM` or `UTC-HH:MM`. Accepts an optional `ReferenceTime` parameter (defaults to `[datetime]::Now`) to compute the offset via `[System.TimeZoneInfo]::Local.GetUtcOffset()`. Used by both `Add-AdminHistoryEntry` and `Add-DiscordDeliveryEntry` to produce timezone-aware timestamps.

Timestamp format uses timezone-aware timestamps via `Get-TimezoneOffsetString`. Handles negative UTC offsets. Session headers are sorted chronologically using `[StringComparer]::Ordinal` (works because headers start with `YYYY-MM-DD`). The `### ` prefix is stripped before storage. If the state file doesn't exist, it is created with an empty `runs` array. Parent directory is created by `Save-JsonStateFile`.

State file location: `$Config.ResDir` resolves to `<RepoRoot>/.robot.local/res/pu-sessions.json`. This is separate from the module directory (`.robot.powershell/`) and lives in `.robot.local/res/` for historical compatibility with the legacy system.

## Operation Context

Source: `private/operation-context.ps1`.

Accumulator-based operation tracking for write commands. Provides a structured way to collect changes, warnings, and touched files during a write operation, then drain them into a single `Robot.OperationResult` object at completion.

Dot-sourced by `private/entity-writehelpers.ps1` (non-fatal if missing) and checked by `private/charfile-helpers.ps1`. Not auto-loaded by `Robot.PowerShell.psm1`.

Accumulators:

| Variable | Type | Purpose |
|---|---|---|
| `$script:OpChanges` | `List[PSCustomObject]` | Property change records `{ Property, OldValue, NewValue }` |
| `$script:OpWarnings` | `List[PSCustomObject]` | Warning records `{ Message, Severity, ActionHint }` |
| `$script:OpFiles` | `HashSet[string]` | Touched file paths (case-insensitive deduplication) |

Functions:

| Function | Purpose |
|---|---|
| `Clear-OperationContext` | Resets all three accumulators. No-op if accumulators are `$null`. |
| `Add-OperationChange` | Pushes a property change record. Called by `Set-EntityTag` on each tag upsert. |
| `Add-OperationWarning` | Pushes a warning record with severity (`Info`, `Warning`, `Error`) and optional `ActionHint`. |
| `Add-OperationFile` | Registers a touched file path (deduplicated via `HashSet`). Called by `Write-EntityFile` and `Write-CharacterFile`. |
| `New-OperationResult` | Drains all accumulators into a `Robot.OperationResult` object and resets them via `Clear-OperationContext`. |

`Add-OperationChange` parameters:

| Parameter | Type | Description |
|---|---|---|
| `Property` | string | Mandatory. The property or tag that changed (e.g. `@status`). |
| `OldValue` | any | Previous value (`$null` for new tags). |
| `NewValue` | any | New value being set. |

`Add-OperationWarning` parameters:

| Parameter | Type | Description |
|---|---|---|
| `Message` | string | Mandatory. Warning message text. |
| `Severity` | string | Severity level, defaults to `'Info'`. |
| `ActionHint` | string | Optional suggested remediation action. |

`New-OperationResult` parameters:

| Parameter | Type | Description |
|---|---|---|
| `Success` | bool | Mandatory. Whether the operation succeeded. |
| `Action` | string | Mandatory. The action performed (e.g. `'Set'`, `'New'`, `'Remove'`). |
| `TargetType` | string | Mandatory. Entity type targeted (e.g. `'Postać'`, `'NPC'`). |
| `TargetName` | string | Mandatory. Entity name targeted. |
| `UndoHint` | string | Optional undo guidance text. |

Return object (`Robot.OperationResult`):

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

`Clear-OperationContext` is called in a `finally` block within `New-OperationResult`, ensuring accumulators are always reset even if result construction throws. The return statement is inside the `try` block so the result object is built before cleanup occurs.

Has `SuppressMessageAttribute` for `PSUseShouldProcessForStateChangingFunctions` -- drains in-memory accumulators, not system state.

Write helpers push records as side effects: `Set-EntityTag` calls `Add-OperationChange` (tag name, old value, new value); `Write-EntityFile` calls `Add-OperationFile` (file path); `Write-CharacterFile` calls `Add-OperationFile` (file path). Availability is checked via `$script:HasOpCtx` flag, set at dot-source time by probing for `Add-OperationChange` (in entity-writehelpers.ps1) or `Add-OperationFile` (in charfile-helpers.ps1).

## Set-RepoRoot

Source: `public/set-reporoot.ps1`.

Overrides or resets the data directory used as the lore repository root. Useful for testing and non-standard layouts where the lore repository is not the git ancestor of the module.

| Parameter | Type | ParameterSet | Description |
|---|---|---|---|
| `Path` | string | `Path` | Mandatory. Absolute path to the directory to use as the data root. Must exist. |
| `Reset` | switch | `Reset` | Mandatory. Clears the override and reverts to git-based detection. |

Path mode validates directory existence, stores `[System.IO.Path]::GetFullPath($Path)` in `$script:RepoRootOverride`. Subsequent `Get-RepoRoot` calls return this path instead of performing git traversal. Reset mode sets `$script:RepoRootOverride` to `$null`. Both modes clear `$script:CachedManifest` and `$script:CachedManifestDir` so that `Find-DataManifest` re-scans from the new root on next use.

## Warning Suppression

Source: `Robot.PowerShell.psm1`.

Module-scoped warning suppression prevents `[System.Console]::Error.WriteLine` output from corrupting interactive CLI menus. All warning/info emission routes through centralized helpers that check a boolean flag before writing.

| Component | Location | Purpose |
|---|---|---|
| `$script:SuppressWarnings` | `Robot.PowerShell.psm1` | Module-scoped boolean flag, defaults to `$false` |
| `Write-RobotWarning` | `Robot.PowerShell.psm1` | Emits `[WARN ...]` to stderr if flag is `$false` |
| `Write-RobotInfo` | `Robot.PowerShell.psm1` | Emits `[INFO ...]` to stderr if flag is `$false` |

Both helpers are module-internal (not exported). Available to all dot-sourced functions via module scope.

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

Nested calls inherit the suppressed state automatically -- inner functions do not need `-Quiet` threading.

The CLI suppresses warnings at two levels: (1) Startup (`Invoke-RobotCLI`) uses `Get-Entity -Quiet` for pre-loading. (2) Dispatch (`Invoke-MenuAction` in `cli-routing.ps1`) wraps all Wizard/Query/Workflow dispatch with `$script:SuppressWarnings = $true` / `finally { $false }`. CLI-internal warnings (plugin validation in `Merge-PluginMenuItems`, plugin load errors) fire before the menu loop starts and are unaffected by overlay rendering.

Scope of conversion:

| Category | Converted | Reason |
|---|---|---|
| Public data-access functions (16) | Yes | CLI-reachable, `-Quiet` parameter added |
| Private helpers (4 files) | Yes | Inherit flag from callers |
| CLI startup warnings | No | Fire before menu loop |
| Infrastructure (`plugin-hooks`, `plugin-loader`, `admin-config`) | No | Module import time |
| Migration (`migration-state`) | No | Not CLI-reachable |

## Environment Variables

| Variable | Purpose |
|---|---|
| `NERTHUS_REPO_WEBHOOK` | Default Discord webhook URL |
| `NERTHUS_BOT_USERNAME` | Default bot display name |

## Local Config File

Path: `.robot.powershell/local.config.psd1` (git-ignored)

PowerShell data file format:

```powershell
@{
    PRFWebhook  = 'https://discord.com/api/webhooks/...'
    BotUsername  = 'Bothen'
}
```

Loaded via `Import-PowerShellDataFile` with error handling. Missing file is not an error -- the priority chain falls through to the next source.

## Edge Cases

| Scenario | Behavior |
|---|---|
| Missing `local.config.psd1` | Not an error; priority chain continues |
| Missing template file | Throws error |
| Missing `.robot.local/robot-data.psd1` manifest | Not an error; falls back to hardcoded paths |
| Manifest found at fixed path | Paths resolved relative to `.robot.local/` directory, cached per session |
| Negative UTC offset | Formatted correctly (e.g., `UTC-05:00`) |
| Missing `.robot.local/res/` directory | Created automatically by `Save-JsonStateFile` |
| Corrupted JSON state file | `Read-JsonStateFile` falls back to `.bak` copy; restores backup as primary on success |
| Both primary and backup corrupted | `Read-JsonStateFile` returns `$null`; consumers start with empty state |
| Process killed during `Save-JsonStateFile` | At worst `.tmp` is orphaned; primary or `.bak` is intact |
| Duplicate session headers in history | Deduplicated by `HashSet` on read |
| Whitespace variations in headers | Normalized (collapsed to single space) before comparison |
| `operation-context.ps1` not loaded | `$script:HasOpCtx` is `$false`; write helpers skip accumulator calls |
| `$script:OpChanges` is `$null` | `Add-OperationChange` is no-op (guard at function entry) |
| Multiple files in operation | `New-OperationResult` returns `FilePath` as array |
| Single file in operation | `New-OperationResult` returns `FilePath` as scalar string |
| No files in operation | `New-OperationResult` returns `FilePath` as `$null` |
| Manifest path resolves outside repo root | Skipped with warning to stderr; `Test-PathUnderRoot` returns `$false` |
| `Set-RepoRoot` with non-existent path | Throws `"Directory not found: '$Path'"` |
| `Set-RepoRoot -Reset` | Clears override and manifest cache; `Get-RepoRoot` reverts to git traversal |

## Testing

| Test file | Coverage |
|---|---|
| `tests/admin-config.Tests.ps1` | Priority chain, path resolution, template loading, manifest discovery, caching (12 tests) |
| `tests/admin-state.Tests.ps1` | `Save-JsonStateFile`/`Read-JsonStateFile` atomic writes, backup recovery, history reading, normalization, appending (19 tests) |
| `tests/discord-state.Tests.ps1` | `Add-DiscordDeliveryEntry`, `Get-DiscordDeliveryEntries`, shared JSON state utilities (24 tests) |
| `tests/get-reporoot.Tests.ps1` | `Get-ParentRepoRoot` (submodule boundary traversal) (11 tests) |
| `tests/operation-context.Tests.ps1` | Accumulator lifecycle, change/warning/file tracking, `New-OperationResult` drain (14 tests) |

Fixtures: `local.config.psd1`, `pu-sessions.json`, template files in `tests/fixtures/templates/`.

## Related Documents

- [PU.md](PU.md) -- PU pipeline uses history entries for deduplication
- [ENTITY-WRITES.md](ENTITY-WRITES.md) -- Write commands consume `Get-AdminConfig` and operation context
- [CHARFILE.md](CHARFILE.md) -- Character file writing uses operation context (`Write-CharacterFile`)
- [DISCORD.md](DISCORD.md) -- Webhook config resolution; `discord-state.ps1` consumes `Save-JsonStateFile`/`Read-JsonStateFile`

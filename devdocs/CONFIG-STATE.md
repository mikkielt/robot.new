# Configuration & State - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers `private/admin-config.ps1` (configuration resolution, path management, template rendering) and `private/admin-state.ps1` (append-only history file management for PU processing).

---

## 2. Configuration Resolution (`private/admin-config.ps1`)

### 2.1 Functions

| Function | Purpose |
|---|---|
| `Get-AdminConfig` | Returns a hashtable with all resolved paths and config values |
| `Resolve-ConfigValue` | Priority-chain resolver for a single config key |
| `Get-AdminTemplate` | Loads and renders template files with placeholder substitution |
| `Find-DataManifest` | Scans upward from module root to find `.robot-data.psd1` manifest |

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

Paths are resolved from `.robot-data.psd1` manifest when available (see §2.5), falling back to the hardcoded values above. This ensures backward compatibility when no manifest exists.

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

The module is a git submodule inside a parent lore repository. Coordinators may place data files anywhere in the parent repository. `Find-DataManifest` enables this flexibility by scanning for a `.robot-data.psd1` manifest file.

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

1. Start at the module root (`$PSScriptRoot` parent)
2. Walk upward using `Get-ParentRepoRoot` (from `public/get-reporoot.ps1`) to find the parent repository root — the first `.git` directory above the submodule boundary
3. Scan from RepoRoot upward to the parent repo root for `.robot-data.psd1`
4. If not found, fall back to hardcoded paths (backward compatible)
5. Cache the resolved manifest and its directory in `$script:CachedManifest` / `$script:CachedManifestDir`

**Caching**: Per-session. Once discovered, the manifest is not re-scanned. This avoids repeated directory traversal.

**`Get-ParentRepoRoot`**: Companion function in `public/get-reporoot.ps1`. Walks upward from `Get-RepoRoot` past the submodule `.git` to find the enclosing repository root. Uses `Get-Command` guard to handle cases where the function is not yet loaded.

**`Get-AdminConfig` integration**: When `Find-DataManifest` returns a manifest, `Get-AdminConfig` uses its paths. When no manifest exists, all paths resolve identically to the hardcoded defaults. Zero breaking changes.

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

## 4. Environment Variables

| Variable | Purpose |
|---|---|
| `NERTHUS_REPO_WEBHOOK` | Default Discord webhook URL |
| `NERTHUS_BOT_USERNAME` | Default bot display name |

---

## 5. Local Config File

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

## 6. Edge Cases

| Scenario | Behavior |
|---|---|
| Missing `local.config.psd1` | Not an error; priority chain continues |
| Missing template file | Throws error |
| Missing `.robot-data.psd1` manifest | Not an error; falls back to hardcoded paths |
| Manifest found in parent repo | Paths resolved relative to manifest directory, cached per session |
| Negative UTC offset | Formatted correctly (e.g., `UTC-05:00`) |
| Missing `.robot/res/` directory | Created automatically by `Add-AdminHistoryEntry` |
| Duplicate session headers in history | Deduplicated by `HashSet` on read |
| Whitespace variations in headers | Normalized (collapsed to single space) before comparison |

---

## 7. Testing

| Test file | Coverage |
|---|---|
| `tests/admin-config.Tests.ps1` | Priority chain, path resolution, template loading, manifest discovery, caching |
| `tests/admin-state.Tests.ps1` | History reading, normalization, appending, file creation |
| `tests/get-reporoot.Tests.ps1` | `Get-ParentRepoRoot` (submodule boundary traversal) |

Fixtures: `local.config.psd1`, `pu-sessions.md`, template files in `tests/fixtures/templates/`.

---

## 8. Related Documents

- [PU.md](PU.md) - PU pipeline uses history entries for deduplication
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Write commands consume `Get-AdminConfig`
- [DISCORD.md](DISCORD.md) - Webhook config resolution

# Migration Framework - Technical Reference

## Scope

This document describes the discovery-based versioned migration framework that owns repository schema evolution. The framework's control surface lives under `Robot.PowerShell/public/migration/`, its internals under `Robot.PowerShell/private/migration/`, and its shipped migrations under `Robot.PowerShell/migrations/`. The repository's schema version pointer lives at `<repo>/.robot.local/schema.json`. The primary control plane is the REST API; the CLI cmdlets are equivalent consumers.

For state-file shapes and the schema gate's effect on writes, see [CONFIG-STATE.md](CONFIG-STATE.md). For the REST endpoint table and scopes, see [REST-API.md](REST-API.md). For plugin-contributed migrations, see [PLUGINS.md](PLUGINS.md).

## Architecture Overview

```
Robot.PowerShell/
├── migrations/                     shipped migrations (Module origin)
│   ├── 0.0.0-initialize-schema/
│   ├── 0.1.0-bootstrap-entities/
│   ├── ...
│   └── 1.0.0-cutover-yellow-threat/
├── private/migration/              framework internals (dot-sourced at module init)
│   ├── migration-version.ps1       SemVer pointer + exclusive lock + comparator
│   ├── migration-loader.ps1        discovery, AST-only manifest validation, DAG chain
│   ├── migration-runtime.ps1       lock + hook + checklist + apply
│   ├── migration-branch.ps1        InPlace / Branch / BranchAndMerge
│   ├── migration-cache.ps1         cache-category fast path (auto on module load)
│   └── migration-log.ps1           structured per-run log
└── public/migration/               public cmdlets
    ├── get-schemaversion.ps1
    ├── get-migration.ps1
    ├── get-migrationpreview.ps1
    ├── invoke-migration.ps1
    ├── invoke-migrationchain.ps1
    ├── reset-migrationlock.ps1
    ├── reset-schemaversion.ps1
    └── get-migrationjob.ps1

<lore-repo>/
└── .robot.local/
    ├── schema.json                 version pointer (canonical)
    ├── migrations/                 operator-local extension dir (optional)
    ├── res/migration-state.json    per-migration record (checklist, sourceHash)
    ├── res/migration-log.txt       per-run structured log (overwritten each run)
    └── .cache/migrations.json      per-machine cache-format applied log
```

## Schema Version Pointer

`.robot.local/schema.json` is the canonical version pointer. It is written atomically via `Save-JsonStateFile` (temp + bak swap, crash-safe).

```json
{
  "schemaFileVersion": 1,
  "current": "0.1.0",
  "majorName": "",
  "appliedAt": "2026-06-25T14:30:00+00:00",
  "appliedBy": "anward",
  "appliedMigrationId": "0.1.0-bootstrap-entities",
  "lockedBy": null,
  "lockedAt": null,
  "history": [ /* prior current entries */ ]
}
```

`Lock-Schema` fabricates an initial `0.0.0` placeholder on first acquisition for a fresh repo; the placeholder is NOT pushed to history when the first real migration applies (only entries with `appliedMigrationId` are recorded).

## Manifest Schema

Each migration directory contains a `migration.psd1`:

```powershell
@{
    Version              = '21.3.7'              # SemVer; plugins inherit composite
    MajorName            = 'Yellow Threat'        # informational; tied to MAJOR
    Slug                 = 'add-currency-tag'     # kebab-case, ≤ 64 chars
    Description          = 'Adds @waluta tag'
    Requires             = '21.3.6'               # predecessor (optional for first)
    Author               = 'mikolaj.kielt'
    AffectsCategories    = @('EntitySchema')      # see enum below
    EstimatedDurationSec = 30                     # > 10 forces async dispatch
    OnlyIfSourceChanged  = $false                 # external-import idempotency
    SourceHashScript     = $null                  # relative .ps1 returning a SHA256
    RequiresNetwork      = $false                 # preview degradation flag
    PluginSequence       = 1                      # per-plugin ordering (plugin origin)
    Archetype            = 'Transform'            # Transform | Inspect | Commit (CC-N1)
    ConfigSchema         = @{                     # operator-supplied form (CC-N2)
        Force = @{
            Type        = 'Switch'                # Switch | String | Int | Decimal | Hashtable | Array
            Default     = $false
            Required    = $false
            Description = 'Force re-apply.'
        }
    }
    AllowsGraczeWrite    = $false                 # only freeze-gracze migration sets $true
}
```

Category enum: `EntitySchema | DataRewrite | SessionFormat | StateFile | RepoLayout | Cache | ExternalImport | Fixture`.

## Migration Archetypes (CC-N1)

Every migration belongs to one of three archetypes. Validator rejects manifests missing `Archetype`.

| Archetype | Default for | Reads | Writes | Schema bump | Typical config |
|---|---|---|---|---|---|
| **Transform** | most migrations | repo data | repo data files | yes | Config fields drive behavior; preview emits ChangeRecords (CC-N9) for dashboard diff rendering |
| **Inspect** | expensive analysis only | repo data | `.robot.local/migration-artifacts/<id>/*` only | yes (records inspection ran) | no Config typically; emits artifacts the next Transform sibling consumes |
| **Commit** | post-Transform groups | git index | git working tree (commit) | yes | Config sets commit message; idempotent (no-op when no diff) |

Inspect is opt-in. Most migrations are Transform with rich preview output (the operator inspects via `Get-MigrationPreview`'s `ChangeRecords[]` and applies). Inspect-archetype is chosen only when the analysis cost is high enough to justify caching results between dashboard sessions.

## ConfigSchema Contract (CC-N2)

Every manifest may declare `ConfigSchema = @{ <FieldName> = @{ Type; Default; Required; Description } }`. The framework:

1. Discovers the schema via `Get-MigrationConfigSchema -Version <v>` and surfaces it at `GET /migrations/<v>/config-schema`.
2. Validates operator-supplied Config against the schema before applying — types must match, Required fields must be present, unknown fields are rejected.
3. Merges supplied Config with declared defaults; the migration body reads the merged hashtable under `$Config.Migration`.

`Test-MigrationConfig -Schema <hashtable> -Config <hashtable>` returns `@{ OK; Errors[]; Warnings[] }`. `Resolve-MigrationConfigSchema -Manifest <hashtable>` normalises omitted Type / Required / Description with defaults (`'String'`, `$false`, `''`). `ConvertFromMigrationConfigValue -Type <string> -Value <object>` coerces a single value to the declared type — used by the REST layer when a query string delivers `"true"` for a Switch field.

`Invoke-Migration -Version <v> -Config <hashtable>` and `Invoke-MigrationChain -To <v> -Config <hashtable>` accept Config; chain config is keyed by migration version or full id.

## ChangeRecord Preview Contract (CC-N9)

`Get-MigrationPreview` returns a `ChangeRecords` array alongside the existing flat file lists. Each entry is a structured before/after diff that the dashboard renders side-by-side (left = before, right = after).

```powershell
[PSCustomObject]@{
    Id          = 'entities.md:NPC:Janusz-Strzelec'        # stable handle for override targeting
    ObjectType  = 'EntityBullet'                            # EntityBullet | EntityFile | Session | Charfile | StateFile | FilePath
    FilePath    = 'entities.md'                             # path that holds the object; or rename's source path
    NewFilePath = $null                                     # only set on Rename; otherwise $null
    ChangeKind  = 'Modify'                                  # Create | Modify | Delete | Rename
    Before      = '* [Janusz Strzelec] @lokacja: Bagienko'  # current text; $null for Create
    After       = '* [Janusz Strzelec] @lokacja: Bagna'     # proposed text; $null for Delete
    OverrideKey = 'EntityLocation:Janusz-Strzelec'          # form-field key the operator edits; $null if non-overridable
    Notes       = @('Suggested by location-name normalization (0.4.0).')
}
```

Helpers (private/migration/migration-changerecord.ps1):
- `New-MigrationChangeRecord -Id -ObjectType -ChangeKind -FilePath [-NewFilePath] [-Before] [-After] [-OverrideKey] [-Notes]` — factory with enum validation.
- `Test-MigrationChangeRecord -Record <object>` — shape validator.
- `Test-MigrationChangeRecordSet -Records <object[]>` — collection validator enforcing Id and OverrideKey uniqueness.

Operator overrides flow through `Invoke-Migration -Overrides <hashtable>` (keyed by `OverrideKey`). The framework caches `OverrideKeys` from the most recent preview at `.robot.local/migration-artifacts/<id>/.preview-cache.json` so Apply-time validation rejects keys the migration did not advertise.

## Artifact Handoff (CC-N4)

Inspect-archetype migrations write to `<repo>/.robot.local/migration-artifacts/<source-id>/<artifact-name>.json` via `Set-MigrationArtifact`. Transform-archetype siblings consume via `Get-MigrationArtifact -SourceMigration <id> -Name <name>`. Artifacts are operator-editable between Inspect and Apply runs — REST exposes them at `GET/PUT /migrations/<id>/artifacts/<name>`. Atomic writes via `Save-JsonStateFile` (temp + bak).

`Save-MigrationPreviewCache -MigrationId <id> -ChangeRecords <object[]>` writes `.preview-cache.json` with `MigrationId`, `Generated`, `ChangeRecordCount`, and the `OverrideKeys` array — consumed by WP-A3's Override validation.

## Idempotency Contract (CC-N3)

Every `Invoke-Migration` SHALL be safe to re-run after a successful prior run, after a partial run, and after no run:

1. Re-running an applied migration returns `OK = $true; Skipped = $true; Reason = 'AlreadyApplied'` and writes nothing.
2. Re-running a partially-applied migration resumes from the per-item checklist — items whose checklist entry is `$true` are skipped, missing items run; the resulting checklist is monotonically true-only.
3. `Test-MigrationApplied -Checklist <hashtable>` is the canonical idempotency probe.

## Standardized Commit Helper (CC-N5)

Commit-archetype migrations and any Transform migration that wants to commit its writes SHALL call `Invoke-MigrationCommit -Message <string> [-Files <string[]>] [-AllowsGraczeWrite]` (private/migration/migration-commit.ps1). It:

- No-ops if no diff (returns `Skipped = $true; Reason = 'NoDiff'`).
- Respects framework `BranchMode` implicitly (HEAD is where BranchMode put it).
- Refuses to add `Gracze.md` unless `-AllowsGraczeWrite` (only `1.0.2-freeze-gracze` opts in).
- Returns `{ OK; Skipped; Reason; Sha; Message; FilesAdded }`.

Direct `git add` / `git commit` from migration bodies is refused on review.

## `migrate.ps1` Contract

Each migration directory contains a `migrate.ps1` that defines:

| Function | Required | Purpose |
|---|---|---|
| `Get-MigrationPreview -Config <hashtable>` | yes | Returns a structured preview (FilesToModify/Create/Delete, EntityCountsBefore/After, SampleDiffs, Warnings, NetworkRequired, SourceUnchanged, **ChangeRecords**). Must be side-effect-free. ChangeRecords drive the dashboard's left/right diff (CC-N9). |
| `Invoke-Migration -Config <hashtable> -ProgressCallback <scriptblock> -Checklist <hashtable>` | yes | Performs the migration. Must support `SupportsShouldProcess`. The runtime injects `$Config.Migration` (merged ConfigSchema values) and `$Config.Overrides` (operator edits keyed by `OverrideKey`); the body reads them to drive behavior. |
| `Test-MigrationApplied -Checklist <hashtable>` | no | Returns `$true` to skip if the checklist indicates prior completion. Default behavior: treat any truthy checklist value as applied (CC-N3 idempotency contract). |
| `Invoke-CacheMigration` | no | Cache-category fast-path entry point; invoked by `Invoke-CacheMigrations` on module load instead of `Invoke-Migration`. |

Manifest validation is AST-only: `Test-MigrationManifest` parses `migrate.ps1` via `[System.Management.Automation.Language.Parser]::ParseFile` and walks for the required function definitions without executing the file. Top-level scope is restricted to `FunctionDefinitionAst`, `UsingStatementAst`, or comments — top-level commands, assignments, or `Set-Location` are rejected so a malformed migration cannot execute writes during validation.

## Discovery Roots

| Order | Root | Origin tag |
|---|---|---|
| 1 | `<module>/migrations/` | `Module` |
| 2 | `<lore-repo>/.robot.local/migrations/` | `OperatorLocal` |
| 3 | `<plugin>/migrations/` for each loaded plugin | `Plugin:<name>` |

Later roots override earlier ones at the same effective version, with a warning logged via `Write-RobotWarning`. `Get-MigrationCatalog` caches the scan keyed by per-root `LastWriteTimeUtc.Ticks`; pass `-Force` to bypass the cache.

## Plugin Composite Versioning

Plugin migrations targeting module version X are auto-rewritten by `Get-EffectiveVersion` to `X+<plugin-name>.<PluginSequence>`. Examples: `21.3.7+plugin-foo.1`, `21.3.7+plugin-foo.2`. `Compare-SchemaVersion` is hand-rolled (not `[System.Version]`, which silently drops the build tag) and orders composite versions as strictly greater than the bare core at the same major.minor.patch but strictly less than the next bare core (`21.3.7 < 21.3.7+foo.1 < 21.3.8`).

`Resolve-MigrationChain` emits ready-set migrations in this tiebreak order:

1. Origin priority: Module (1) < Plugin:* (2) < OperatorLocal (3)
2. Version sort key (numeric padding so `10.0.0 > 9.99.99` lex-sorts correctly)
3. `PluginLoadIndex` from `$script:LoadedPlugins` enumeration order
4. Ascending `PluginSequence`
5. `Slug` ordinal (final tiebreak)

## Operator-Local Migrations

Migrations under `<repo>/.robot.local/migrations/` are tagged `Origin = OperatorLocal`. They produce a `Warnings[]` entry "Unsigned operator-local migration; review migrate.ps1 before applying." on preview, and refuse to apply without `-AllowUnsigned` (or `allowUnsigned: true` in the REST body), throwing the terminating error `UnsignedMigrationBlocked`. Module-origin and plugin-origin migrations are considered signed and apply without the flag.

## Module Load Gate

`Robot.PowerShell.psd1:PrivateData.SchemaVersionRange = @{ Min = '0.0.0'; Max = '1.99.99' }` controls the gate. On module load:

| Condition | Mode | Effect |
|---|---|---|
| Repo schema in `[Min, Max]` | `Normal` | Writes permitted; pending migration count logged as a warning |
| Repo schema `< Min` | `ReadOnly` | `Assert-WriteAllowed` throws `SchemaTooOld` for every public mutating cmdlet |
| Repo schema `> Max` | `Refused` | Module load aborts (older module + newer repo is a corruption risk) |
| No repo / schema check failed | `Unknown` | Writes permitted (test harness, CI lint) |

`Get-SchemaState` surfaces the cached state. `Assert-WriteAllowed` is the single funnel called from every top-level public mutating cmdlet; the migration runtime passes `-BypassSchemaGate` so its own writes are permitted during a schema bump.

### Authoring rule

Schema version (`.robot.local/schema.json:current`) and module version (`Robot.PowerShell.psd1:ModuleVersion`) are orthogonal — the only coupling between them is the `SchemaVersionRange` gate above. A migration whose effective version exceeds the current `Max` SHALL bump `Max` in the same change; otherwise the module that ships the new migration will refuse to load on a repo that just ran it (`Mode = Refused`). Bumping `Min` is reserved for the deliberate retirement of code paths that handle older schemas — operators on the old schema land in `Mode = ReadOnly` and MUST run the chain before writes are permitted again. Plugin migrations follow the same rule against the plugin's own version range; the framework auto-rewrites their effective version to `X+<plugin-name>.<PluginSequence>` so they never exceed the host module's `Max` independently.

## Lock Acquisition

`Lock-Schema -LockOwner "$user@$host/$PID"` writes `lockedBy` + `lockedAt` (UTC ISO-8601) into `schema.json`. A second acquisition while a lock is held throws `SchemaLocked`. `Test-SchemaLockStale` returns `$true` when `lockedAt` exceeds the configured TTL (default 60 min, override via `local.config.psd1:MigrationLockTtlMinutes`); the acquire path still refuses but additionally warns "likely stale" so operators see the wedge without auto-takeover risk.

Clock-skew handling: `lockedAt` is written UTC and parsed via `[DateTimeOffset]::Parse(...).UtcDateTime` to honor the trailing `Z`. The 60-minute default absorbs ~10 min of clock skew comfortably; multi-host workflows with looser clocks should raise `MigrationLockTtlMinutes`.

Stale locks are cleared via `Reset-MigrationLock -Force` (CLI) or `DELETE /schema/lock` (REST, requires `migration:admin` scope).

## Runtime Lifecycle

`Invoke-MigrationInternal` is the per-migration apply engine. The caller (`Invoke-Migration` or `Invoke-MigrationChain`) acquires the lock once for the whole run and releases it in `finally`; chains do not rotate the lock per-migration.

For each migration in the chain:

1. Load or initialize the per-migration record in `<repo>/.robot.local/res/migration-state.json`.
2. Fire `Invoke-PluginHook -Operation Migration -Phase BeforeMigration -Context @{ Migration, Record, Config, Phase }`. Throwing aborts the migration.
3. If the manifest declares `OnlyIfSourceChanged` and the `SourceHashScript` produces a SHA256 equal to the recorded value, skip with `Reason = 'source-unchanged'`.
4. Dot-source `migrate.ps1` in a child scope (already AST-validated, safe). If the migration defines `Test-MigrationApplied -Checklist $rec.checklist` and it returns `$true`, skip with `Reason = 'already-applied'`.
5. Call `Invoke-Migration -Config $cfg -ProgressCallback $cb -Checklist $rec.checklist`.
6. Drain `OperationContext` accumulators via `New-OperationResult`.
7. `Set-SchemaVersion -Version $m.Version -MajorName $m.MajorName -MigrationId $m.Id` to advance the pointer.
8. Fire `AfterMigration` hook (errors logged, do not abort).

The runtime returns a `MigrationRunResult` with `OK`, `MigrationId`, `Skipped`, `Reason`, `Duration`, `FilesWritten`, `OperationResult`, `Warnings`, `Errors`.

## Per-Migration Record

`.robot.local/res/migration-state.json` keys per-migration records by ID:

```json
{
  "schemaFileVersion": 3,
  "migrations": {
    "0.1.0-bootstrap-entities": {
      "status": "Completed",
      "startedAt": "2026-06-25T14:00:00Z",
      "completedAt": "2026-06-25T14:00:15Z",
      "checklist": { "entitiesParsed": true },
      "sourceHash": "sha256:..."
    }
  }
}
```

`Set-MigrationChecklistItem -MigrationId <id> -Item <key> -Value $true` is called from inside `Invoke-Migration` via the `ProgressCallback` so resumption after a crash picks up at the next unchecked item.

## Branching Modes

| Mode | Behavior | CLI default | REST default |
|---|---|---|---|
| `InPlace` | Apply to working tree; refuse when `git status --porcelain` is non-empty. | — | ✓ |
| `Branch` | Create `migration/<slug>-<version>` (single) or `migration/<from>-to-<to>` (chain), apply, commit with structured message, leave checked out. | ✓ | — |
| `BranchAndMerge` | `Branch` + `--ff-only` merge back into the original branch on success. Non-ff is refused so the operator resolves manually. | opt-in | opt-in |

Commit message format:

```
migrate: <migration-id>

Migration-Id: <id>
Schema-From: <prev>
Schema-To: <new>
Files-Modified: <count>
Applied-By: <user>
```

## REST API

Full endpoint table and scope mapping in [REST-API.md](REST-API.md). Summary:

| Method | Path | Scope |
|---|---|---|
| GET | `/schema/version` | `migration:read` |
| GET | `/migrations`, `/migrations/pending`, `/migrations/:id`, `/migrations/jobs/:jobId` | `migration:read` |
| GET | `/migrations/:id/preview` (form-ready: ConfigSchema + ChangeRecords + merged config) | `migration:read` |
| GET | `/migrations/:id/config-schema` | `migration:read` |
| GET | `/migrations/:id/artifacts/:name` | `migration:read` |
| PUT | `/migrations/:id/artifacts/:name` (operator-edit) | `migration:write` |
| POST | `/migrations/apply` (accepts `config` + `overrides`) | `migration:write` |
| DELETE | `/schema/lock` | `migration:admin` |
| POST | `/schema/restore` | `migration:restore` |

The migration endpoints live under `/schema/version`, `/schema/lock`, `/schema/restore` because the static `/schema` C# route is owned by the domain name dictionary.

### Form-driven dashboard flow

The dashboard pipeline:

```
GET /migrations/<v>/preview?config=<base64-json>
  → { preview: {...}, config: { schema, supplied, merged }, changeRecords: [...] }
operator edits form (a Config field or a ChangeRecord OverrideKey)
POST /migrations/apply
  body: { target: {...}, config: {...}, overrides: { <OverrideKey>: <value>, ... } }
  → MigrationRunResult { OK, MigrationId, Skipped, FilesWritten, Warnings, Errors }
```

Apply validates `config` against the migration's ConfigSchema (rejects unknown fields, missing Required, type mismatches → 400 `config-invalid`). Apply validates `overrides` against the OverrideKeys captured by the last preview (cached at `.preview-cache.json`); unknown keys return 400 `override-unknown`.

`POST /migrations/apply` body:

```json
{
  "target":        { "id": "0.1.0-bootstrap-entities" },
  "mode":          "sync",
  "branchMode":    "InPlace",
  "allowUnsigned": false,
  "allowNetwork":  false,
  "config":        { "RegenerateEntities": false, "AutoAddMissingSections": true },
  "overrides":     { "EntityLocation:Janusz-Strzelec": "Bagienko" }
}
```

For chain apply (`target.version`), `config` and `overrides` are keyed by migration id (or version) and partitioned across the chain.

`mode: sync` with `EstimatedDurationSec > 10` returns 409 with `hint: "Re-submit with mode=async"` — refusal, not a 307 redirect, so a `curl -L` cannot accidentally flip an explicit sync call into a job. `mode: async` returns 202 with `jobId` + `statusUrl`. Schema lock contention returns 409 with `lockedBy`, `lockedAt`, `lockStale`. Unsigned operator-local without `allowUnsigned: true` returns 422 `unsigned-migration-blocked`.

## Background Jobs

`api-jobs-migration.ps1` provides `Start-ApiMigrationJob`, `Get-ApiMigrationJob`, `Stop-ApiMigrationJob`. Jobs live in a `ConcurrentDictionary[string,object]` keyed by GUID. `Start-ThreadJob` is used when available (PS7+); otherwise execution falls back to inline. Job retention is per-process; the durable per-run log is `.robot.local/res/migration-log.txt`.

## Cache-Format Fast Path

`Invoke-CacheMigrations` is called from `Robot.PowerShell.psm1` after the schema gate when `Mode != 'Unknown'`. It iterates the catalog for migrations whose `AffectsCategories` contains `'Cache'`, filters out OperatorLocal origin (auto-applying unvetted operator-local PowerShell on every module load is rejected), checks `.robot.local/.cache/migrations.json` for prior application, and invokes `Invoke-CacheMigration` (preferred) or `Invoke-Migration` (fallback). Failure of any single cache migration falls back to `Clear-ParseCaches`.

## External-Import Idempotency

A migration that declares `OnlyIfSourceChanged = $true` and `SourceHashScript = 'source-hash.ps1'` (relative path) is skipped when the script's output equals the recorded `sourceHash` in the per-migration record. The runtime invokes the hash script via `& $ScriptPath -Config $Config 2>&1 | Select-Object -Last 1` (executes once, captures last emitted value). On a real apply the new hash is written into the record alongside `status = 'Completed'`.

Example `source-hash.ps1`:

```powershell
param([hashtable]$Config)
$MapsJson = Join-Path $Config.ResDir 'maps.json'
if (-not (Test-Path $MapsJson)) { return $null }
return (Get-FileHash $MapsJson -Algorithm SHA256).Hash
```

## Preview Contract

`Get-MigrationPreview -Version <v>` dispatches to the migration's `Get-MigrationPreview` function and renders to one of three formats:

| `-Format` | Use |
|---|---|
| `Object` (default) | PSCustomObject for CLI piping |
| `Json` | Raw JSON string for REST |
| `Markdown` | Table layout for the Polish CLI adapter |

When the manifest declares `RequiresNetwork = $true` and the call did NOT pass `-AllowNetworkInPreview` (or `?allowNetwork=true`), the file-list fields are blanked and a `Warnings[]` entry "Network required for accurate preview; pass -AllowNetworkInPreview to enable." is prepended. This guarantees previews never hit the network unintentionally.

## Schema Restore (Pointer-Only Downgrade)

`Reset-SchemaVersion -To <version>` (CLI) and `POST /schema/restore` (REST) advance the pointer to a version that already exists in `history[]`. No migration script runs — this is recovery after a `git revert`, not a real downgrade. The operation refuses if the target is not in history (returns 422 `version-not-in-history` with the list of available history versions) and records itself as a new history entry tagged `schema-restore:<previous>-><target>`.

The `migration:restore` scope is held independently of `migration:admin` so a token can be granted downgrade rights without lock-clearing rights.

## Fixture Migration Mode

`Invoke-FixtureMigrations -FixturePath <dir> [-TargetVersion latest]` in `tests/TestHelpers.ps1` swaps `Get-RepoRoot` to the fixture directory via `Set-RepoRoot`, runs `Invoke-MigrationChain`, and restores the original repo root in `finally`. Migrations must use `$Config.RepoRoot` (never hardcoded paths) to work in fixture mode. CI can use this to keep `tests/fixtures/<scenario>/` at HEAD as schema evolves.

## Edge Cases

| Scenario | Behavior |
|---|---|
| `schema.json` missing | `Get-SchemaVersion` returns fabricated 0.0.0 record with `Exists=$false`; gate enters Normal mode if `Min=0.0.0` |
| `schema.json` corrupt past `.bak` recovery | `Get-SchemaState.Mode='Refused'` after the parse error surfaces |
| Module imported outside any repo (`Get-RepoRoot` throws) | `Get-SchemaState.Mode='Unknown'`; `Assert-WriteAllowed` permits writes (no repo = no writes happen) |
| Migration dot-source raises | Runtime catches, records `status='Failed'` on the record, releases lock, returns error in `MigrationRunResult.Errors` |
| Stale lock past TTL | `Lock-Schema` still refuses but warns "likely stale"; `GET /schema/version` exposes `lockStale: true` |
| Crash between `.tmp` write and rename | `Read-JsonStateFile` falls back to `.bak` on next read |
| Two plugins target same module version | Composite versions disambiguate (`X+foo.1`, `X+bar.1`); resolver tiebreak by `PluginLoadIndex` |
| Plugin and OperatorLocal contribute same effective version | OperatorLocal wins with a warning; the Module/Plugin entry is removed from the catalog |
| `EstimatedDurationSec > 10` with `mode: sync` | 409 with `Re-submit with mode=async` hint; no execution |
| Preview accidentally writes | Tests assert filesystem mod-time unchanged before/after the preview call |

## Output Object — `MigrationRunResult`

| Property | Type | Notes |
|---|---|---|
| `OK` | bool | `$true` unless `Errors` is non-empty |
| `MigrationId` | string | e.g. `0.3.0-validate-parity` |
| `Skipped` | bool | `$true` when source-unchanged or already-applied |
| `Reason` | string \| null | `source-unchanged`, `already-applied`, `whatif`, or null |
| `Duration` | TimeSpan | wall-clock |
| `FilesWritten` | string[] | files touched by the migration |
| `OperationResult` | object \| null | drained `OperationContext` accumulators |
| `Warnings` | string[] | hook warnings, runtime warnings |
| `Errors` | string[] | populated when `OK=$false` |

`Invoke-MigrationChain` returns `{ OK, Applied[], Skipped[], Failed, FromVersion, ToVersion }` where `Failed` is null on success or `{ MigrationId, Error }` when the chain stopped.

## Testing

| Test file | Coverage |
|---|---|
| `tests/migration-version.Tests.ps1` | `Get/Set-SchemaVersion`, `Lock-Schema`, `Unlock-Schema`, `Test-SchemaLockStale`, `Compare-SchemaVersion` (incl. composite), `Test-MajorNameDrift` |
| `tests/migration-loader.Tests.ps1` | Discovery, AST-only manifest validation, `Resolve-MigrationChain` DAG + tiebreak, override warnings |
| `tests/migration-runtime.Tests.ps1` | Single + chain apply, lock release in `finally`, prerequisite check, hook firing, state-file shape |
| `tests/migration-preview.Tests.ps1` | Dispatch, Object/Json/Markdown formats, network degradation, side-effect-free assertion |
| `tests/migration-plugin-namespace.Tests.ps1` | Composite version ordering, plugin tiebreak, `Get-EffectiveVersion` rewriting |
| `tests/migration-operator-local.Tests.ps1` | Origin tagging, unsigned warning, `UnsignedMigrationBlocked` |
| `tests/migration-branch.Tests.ps1` | `Test-WorkingTreeDirty`, branch create/commit/ff-merge in throwaway git repos |
| `tests/migration-cache.Tests.ps1` | Fast-path apply, OperatorLocal origin filter, idempotency |
| `tests/migration-external-import.Tests.ps1` | `OnlyIfSourceChanged` skip/apply, hash recording, re-apply on hash change |
| `tests/migration-fixture-mode.Tests.ps1` | `Invoke-FixtureMigrations` advances schema against a fixture dir |
| `tests/module-load-gate.Tests.ps1` | Mode matrix (Normal/ReadOnly/Refused/Unknown), `Assert-WriteAllowed` semantics |
| `tests/write-gate-coverage.Tests.ps1` | AST scan asserting every public mutating cmdlet calls `Assert-WriteAllowed` |
| `plugins/robot-api/tests/api-migration.Tests.ps1` | Route registration, scope naming, per-handler status codes |
| `plugins/robot-api/tests/api-migration-jobs.Tests.ps1` | Job lifecycle, async dispatch, 202 + statusUrl |

Fixtures: `tests/fixtures/migrations/{0.1.0-foo,0.2.0-bar,0.3.0-baz,0.4.0-broken,0.5.0-sideeffect}/`.

## Related Documents

- [CONFIG-STATE.md](CONFIG-STATE.md) — schema.json + per-migration record shape, the load gate
- [REST-API.md](REST-API.md) — migration endpoints, scope reference
- [PLUGINS.md](PLUGINS.md) — `BeforeMigration` / `AfterMigration` hooks, plugin migration contribution
- [TESTING.md](TESTING.md) — Pester patterns, fixture migration mode

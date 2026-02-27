# Migration Guide — Technical Reference

This document describes the migration from the legacy `.robot/robot.ps1` system to the `.robot.new` module. It covers the data model transition, session format upgrade, and operational workflow migration.

---

## 1. Data Model Transition

### 1.1 Two-Store Architecture

The module operates on two data stores simultaneously:

| Store | File(s) | Access | Role |
|---|---|---|---|
| **Legacy** | `Gracze.md` | Read-only | Historical player database. Parsed by `Get-Player` for backward compatibility. Never written to by any module command. |
| **Entity registry** | `entities.md`, `*-NNN-ent.md` | Read + Write | Canonical write target for all player, character, and world entity data. All mutating commands (`Set-Player`, `Set-PlayerCharacter`, `New-Player`, `New-PlayerCharacter`, `Remove-PlayerCharacter`) write exclusively here. |

### 1.2 Read-Time Overlay

`Get-Player` merges both stores at read time:

1. **Base layer** — parse `Gracze.md` under `## Lista` → level-3 `### PlayerName` sections → characters from `Postaci:` bullets with `[Name](Path)` links, PU from `NADMIAR`/`STARTOWE`/`SUMA`/`ZDOBYTE` sub-keys, player metadata (`ID Margonem`, `PRFWebhook`, `Tematy zastrzeżone`).
2. **Override layer** — call `Get-Entity` → filter to `Gracz`, `Postać (Gracz)`, or entities with `@należy_do` → match to players by name (case-insensitive) → apply overrides.
3. **Stub creation** — if an entity references a player or character not in `Gracze.md`, an in-memory stub is created (not persisted to disk).

Override application rules:

| Entity type | Field | Behavior |
|---|---|---|
| `Gracz` | Aliases | Added to player `Names` HashSet |
| `Gracz` | `@margonemid` | Last value wins (replaces) |
| `Gracz` | `@prfwebhook` | Last value wins, validated against `https://discord.com/api/webhooks/*` |
| `Gracz` | `@trigger` | Full array replacement |
| `Postać (Gracz)` | Aliases | Appended to character `Aliases` and player `Names` |
| `Postać (Gracz)` | `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte` | Last value wins, `[math]::Round(_, 2)` |
| `Postać (Gracz)` | `@info` | Appended to `AdditionalInfo` (newline-joined) |

PU derivation (`Complete-PUData`): if SUMA given but ZDOBYTE missing → `ZDOBYTE = SUMA − STARTOWE`; converse applies.

### 1.3 Entity Registry Format

Entity files use structured Markdown:

```markdown
## Gracz

* PlayerName
    - @margonemid: 12345
    - @prfwebhook: https://discord.com/api/webhooks/...
    - @trigger: topic1

## Postać (Gracz)

* CharacterName
    - @należy_do: PlayerName
    - @pu_startowe: 20
    - @pu_suma: 45.5
    - @alias: AltName (2024-01:)

## Przedmiot

* ItemName
    - @należy_do: CharacterName
```

**Multi-file merge**: files are sorted by numeric key (extracted from `*-NNN-ent.md` filenames). `entities.md` has sort key `MaxValue` (processed first, lowest primacy). Lower numbers are processed last and have highest override primacy. Same-name entities across files have their histories concatenated, not replaced.

**Temporal scoping**: tags support `(YYYY-MM:YYYY-MM)`, `(YYYY-MM:)`, `(:YYYY-MM)` validity ranges. Partial dates resolve via `Resolve-PartialDate` (start → first day, end → last day). Missing ranges mean always-active.

### 1.4 Recognized @Tags

| Tag | Type | Description |
|---|---|---|
| `@alias` | Temporal | Alternative name |
| `@lokacja` | Temporal | Location assignment / containment hierarchy |
| `@drzwi` | Temporal | Physical access connection |
| `@typ` | Temporal | Entity type override |
| `@należy_do` | Temporal | Ownership (character → player) |
| `@grupa` | Temporal | Group/faction membership |
| `@status` | Temporal | Entity status (`Aktywny`, `Nieaktywny`, `Usunięty`) |
| `@zawiera` | Non-temporal | Child containment declaration |
| Any other `@tag` | Temporal | Generic override stored in `Overrides` dictionary |

### 1.5 Entity State Pipeline (Two-Pass)

**Pass 1** (`Get-Entity`): parses entity registry files. Produces entity objects with scalar properties resolved via `Get-LastActiveValue` (latest active history entry wins) and array properties via `Get-AllActiveValues`. Post-parse: canonical names resolved via `Resolve-EntityCN` — locations get hierarchical `Lokacja/Parent/.../Name` paths; others get flat `Type/Name`.

**Pass 2** (`Get-EntityState`): merges session `Zmiany` (changes) into entity objects:
- Filters to sessions with `Changes` and valid dates, sorted chronologically.
- Resolves entity names via case-insensitive dictionary lookup, falling back to `Resolve-Name` pipeline (declension stripping, stem alternation, Levenshtein BK-tree).
- Auto-dating: tags without explicit temporal ranges receive `ValidFrom = Session.Date`, open-ended.
- After all sessions processed: histories sorted by `ValidFrom` (null sorts first), active values recomputed.

**Three-layer merge** (`Get-PlayerCharacter -IncludeState`):

| Layer | Source | Temporal behavior |
|---|---|---|
| 1 (Baseline) | Character `.md` file (`Read-CharacterFile`) | Undated — always active, sorts before dated entries |
| 2+3 (Overrides) | `Get-EntityState` result (entities.md + session Zmiany, already merged) | Temporal ranges parsed via `ConvertFrom-ValidityString` |

Scalar properties: last active value wins. Multi-valued properties: all active values collected. Characters with `Status = 'Usunięty'` are excluded unless `-IncludeDeleted`.

---

## 2. Entity Write Operations

### 2.1 Write Helpers (`entity-writehelpers.ps1`)

All mutating functions operate on `List[string]` line arrays with in-place index manipulation:

| Function | Purpose |
|---|---|
| `Find-EntitySection` | Locates `## Type` section boundaries. Returns `{ HeaderIdx, StartIdx, EndIdx, HeaderText, EntityType }`. |
| `Find-EntityBullet` | Locates `* EntityName` bullet within a section range. Returns `{ BulletIdx, ChildrenStartIdx, ChildrenEndIdx, EntityName }`. |
| `Find-EntityTag` | Finds last occurrence of `- @tag: value` within a bullet's children. Returns `{ TagIdx, Tag, Value }` or `$null`. |
| `Set-EntityTag` | Upserts a tag line: replaces if found, inserts at children end if not. Returns updated `ChildrenEnd`. |
| `New-EntityBullet` | Inserts `* EntityName` with sorted `@tag` children at section end. |
| `Resolve-EntityTarget` | High-level orchestrator: `Ensure-EntityFile` → find/create section → find/create bullet. Returns `{ Lines, NL, BulletIdx, ChildrenStart, ChildrenEnd, FilePath, Created }`. |
| `Read-EntityFile` | Reads file into `List[string]` with newline detection. |
| `Write-EntityFile` | Writes `List[string]` back to file (UTF-8 no BOM, preserves newline style). |
| `Ensure-EntityFile` | Creates `entities.md` with skeleton sections (`## Gracz`, `## Postać (Gracz)`, `## Przedmiot`) if missing. |

### 2.2 Mutating Commands

| Command | Target(s) | Key behaviors |
|---|---|---|
| `Set-Player` | `entities.md` `## Gracz` | Upserts `@margonemid`, `@prfwebhook`, `@trigger`. Creates player entity if missing. Validates webhook URL format. Trigger update is remove-all-then-insert (full replacement). `SupportsShouldProcess`. |
| `Set-PlayerCharacter` | `entities.md` `## Postać (Gracz)` + character `.md` file | Dual-target: entity-level PU/alias/status tags → `entities.md`; character file properties (CharacterSheet, RestrictedTopics, Condition, SpecialItems, Reputation, AdditionalNotes) → `Postaci/Gracze/<Name>.md` via `charfile-helpers.ps1`. Auto-creates `## Przedmiot` entities for unknown special items. Status writes include temporal `(YYYY-MM:)` suffix. `SupportsShouldProcess`. |
| `New-Player` | `entities.md` `## Gracz` | Creates player entity with initial tags. Validates uniqueness (throws if exists). Validates webhook URL. Optionally delegates to `New-PlayerCharacter` for first character. `SupportsShouldProcess`. |
| `New-PlayerCharacter` | `entities.md` `## Postać (Gracz)` + `## Gracz` + character file | Creates character entity with `@należy_do` and `@pu_startowe`. Ensures player entity exists (creates if missing). Creates character file from `player-character-file.md.template`. Optionally applies initial character file properties. `SupportsShouldProcess`. |
| `Remove-PlayerCharacter` | `entities.md` `## Postać (Gracz)` | Soft-delete: writes `@status: Usunięty (YYYY-MM:)`. Does not delete the entity bullet or character file. `ConfirmImpact = 'High'`. |

### 2.3 Bootstrap Migration (`ConvertTo-EntitiesFromPlayers`)

One-time function that generates a complete `entities.md` from `Get-Player` output:
- Reads all players (optionally pre-fetched, or calls `Get-Player -Entities @()` to avoid circular dependency).
- Generates `## Gracz` section: `* PlayerName` with `@margonemid`, `@prfwebhook`, `@trigger`.
- Generates `## Postać (Gracz)` section: `* CharacterName` with `@należy_do`, `@alias`, `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`, `@info`.
- PU values formatted with `([decimal]).ToString('G', InvariantCulture)`.
- Output: UTF-8 no BOM.

---

## 3. Session Format Transition

### 3.1 Format Generations

| Gen | Era | Location format | Log format | Metadata blocks | Detection |
|---|---|---|---|---|---|
| **Gen1** | START–2022 | None | `Logi: https://…` plain text | None | Fallback (no other match) |
| **Gen2** | 2022–2023 | `*Lokalizacja: A, B*` (italic) | `Logi: https://…` plain text | None | First non-empty line starts with `*Lokalizacj` |
| **Gen3** | 2024–2026 | `- Lokalizacje:` list item | `- Logi:` list item | `- PU:`, `- Zmiany:`, `- Efekty:`, `- Objaśnienia:` | Root list item with `pu` prefix (no `@`) |
| **Gen4** | 2026+ | `- @Lokacje:` list item | `- @Logi:` list item | `- @PU:`, `- @Zmiany:`, `- @Intel:` | Root list item starting with `@` + letter |

### 3.2 Format Detection (`Get-SessionFormat`)

Detection order (per-section heuristic):
1. `$FirstNonEmptyLine` starts with `*Lokalizacj` → **Gen2**
2. Root list items (`$LI.Indent -eq 0`):
   - Text starts with `@` + letter → **Gen4**
   - Text starts with `pu` followed by `:` or space → **Gen3**
3. Fallback → **Gen1**

### 3.3 Backward-Compatible Reading

`Get-Session` normalizes all four formats transparently:

- **Location extraction** (`Get-SessionLocations`): Gen2 uses italic regex. Gen3/Gen4 use entity-resolution strategy first (all children resolve to `Lokacja` entities), then tag-based fallback (`Lokalizacj*` or `Lokacj*`). Leading `@` stripped via `$TestText`.
- **List metadata** (`Get-SessionListMetadata`): Leading `@` stripped via `$MatchText = if ($LowerText.StartsWith('@')) { $LowerText.Substring(1) } else { $LowerText }` — enabling unified parsing for both `- PU:` and `- @PU:`.
- **Plain-text log fallback** (`Get-SessionPlainTextLogs`): Applied when list-based `$Logs.Count -eq 0`, scanning for `Logi: <url>` patterns (Gen1/Gen2).

### 3.4 Gen4 Output

New sessions are always Gen4 (`New-Session` → `ConvertTo-SessionMetadata` → `ConvertTo-Gen4MetadataBlock`).

Canonical block order: `@Lokacje` → `@Logi` → `@PU` → `@Zmiany` → `@Intel`.

Zmiany rendering: entity names at 4-space indent, `@tag: value` at 8-space indent.

### 3.5 In-Place Upgrade (`Set-Session -UpgradeFormat`)

Section decomposition (`Split-SessionSection`) classifies content into:

| Category | Tags | Handling |
|---|---|---|
| **Meta blocks** | `pu`, `logi`, `lokalizacje`, `lokacje`, `zmiany`, `intel` (with or without `@` prefix) | Replaceable by parameters or upgradeable to Gen4 |
| **Preserved blocks** | `objaśnienia`, `efekty`, `komunikaty`, `straty`, `nagrody` | Written back unchanged |
| **Body lines** | Everything else | Replaceable via `-Content` |
| **Legacy formats** | Gen2 italic locations (`*Lokalizacj…*`), Gen1/2 plain `Logi: ...` | Captured separately, converted during upgrade |

Upgrade conversions:

| Source | Converter | Output |
|---|---|---|
| Gen3 list blocks | `ConvertTo-Gen4FromRawBlock` | Renames root tag, normalizes indent to 4-space multiples |
| Gen2 italic locations | `ConvertFrom-ItalicLocation` | `- @Lokacje:` with expanded children |
| Gen1/2 plain text logs | `ConvertFrom-PlainTextLog` | `- @Logi:` with child URLs |

### 3.6 Cross-File Session Deduplication (`Merge-SessionGroup`)

Sessions with identical headers across files are grouped by exact `Header` text (Ordinal comparison). The metadata-richest instance is selected as primary. Array fields are unioned via `HashSet` (locations, logs) or deduped by composite key (PU: `Character|Value`, Intel: `RawTarget|Message`). Merged sessions carry `IsMerged = $true`, `DuplicateCount`, and `FilePaths[]`.

---

## 4. PU Assignment Workflow

### 4.1 Pipeline (`Invoke-PlayerCharacterPUAssignment`)

1. **Date range**: `Year`/`Month` → first/last day of month. Default: 2-month lookback.
2. **Git optimization**: `Get-GitChangeLog -NoPatch` pre-filters to `.md` files changed in range, passed to `Get-Session -File`. Falls back to full scan on failure.
3. **Session filtering**: select sessions with PU entries, exclude already-processed headers from `.robot/res/pu-sessions.md` via `Get-AdminHistoryEntries`.
4. **Character resolution**: `Get-PlayerCharacter` (merges Gracze.md + entities.md). Fail-early: throws `UnresolvedPUCharacters` error (with structured `TargetObject`) if any PU character name doesn't resolve.
5. **PU computation** (per character):
   ```
   BasePU       = 1 + Sum(session PU for this character)
   UsedExceeded = min(5 - BasePU, PUExceeded) when BasePU <= 5 and PUExceeded > 0
   OverflowPU   = BasePU - 5 when BasePU > 5
   GrantedPU    = min(BasePU + UsedExceeded, 5)
   Remaining    = (PUExceeded - UsedExceeded) + OverflowPU
   ```
6. **Side effects** (switch-gated):
   - `-UpdatePlayerCharacters`: `Set-PlayerCharacter` with PUSum, PUTaken, PUExceeded.
   - `-SendToDiscord`: grouped per player, sent via `Send-DiscordMessage` (username: `Bothen`).
   - `-AppendToLog`: `Add-AdminHistoryEntry` to `pu-sessions.md`.

### 4.2 Diagnostics (`Test-PlayerCharacterPUAssignment`)

Runs the PU pipeline in compute-only mode (`-WhatIf`). Catches `UnresolvedPUCharacters` errors and extracts `TargetObject`. Reports:

- Unresolved character names
- Malformed (null) PU values
- Duplicate PU entries (same character, same session)
- Failed sessions with PU content (silently dropped by normal pipeline)
- Stale history entries (headers in `pu-sessions.md` not matching any repository session)

Returns structured `[PSCustomObject]@{ OK; UnresolvedCharacters; MalformedPU; DuplicateEntries; FailedSessionsWithPU; StaleHistoryEntries; AssignmentResults }`.

### 4.3 New Character PU Estimate (`Get-NewPlayerCharacterPUCount`)

```
Include only characters with PUStart > 0
PU = Floor((Sum(PUTaken) / 2) + 20)
```

Minimum result is 20 (new players). Used by `New-PlayerCharacter` as fallback when `InitialPUStart` is not specified.

---

## 5. Character File Operations (`charfile-helpers.ps1`)

Parses and writes `Postaci/Gracze/*.md` files. Sections identified by `**Header:**` bold-header pattern.

Parsed properties: `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (three-tier: Pozytywna/Neutralna/Negatywna with Location/Detail objects), `AdditionalNotes`, `DescribedSessions` (read-only).

`Write-CharacterFileSection` replaces section content in-place on `List[string]` lines.

`Format-ReputationSection` renders reputation tiers — inline format when no details, nested bullets when details present.

---

## 6. Configuration and State

### 6.1 Config Resolution (`admin-config.ps1`)

Priority chain:
1. Explicit parameter
2. Environment variable (`$env:NERTHUS_REPO_WEBHOOK`, `$env:NERTHUS_BOT_USERNAME`)
3. Local config file (`.robot.new/local.config.psd1`, git-ignored)
4. Fail with error

Resolved paths: `RepoRoot`, `ModuleRoot`, `EntitiesFile`, `TemplatesDir`, `ResDir` (`.robot/res`), `CharactersDir` (`Postaci/Gracze`), `PlayersFile` (`Gracze.md`).

### 6.2 State Files (`admin-state.ps1`)

Append-only files in `.robot/res/`:
```
- YYYY-MM-dd HH:mm (UTC+HH:MM):
    - ### session header 1
    - ### session header 2
```

`Get-AdminHistoryEntries` returns `HashSet[string]` (OrdinalIgnoreCase, whitespace-normalized, `### ` prefix stripped). `Add-AdminHistoryEntry` appends with timestamp, sorts headers chronologically.

### 6.3 Templates

Located in `.robot.new/templates/`. Files: `player-character-file.md.template`, `player-entry.md.template`. Rendering via `Get-AdminTemplate` with `{Placeholder}` substitution.

---

## 7. Intel Resolution

`@Intel` entries in sessions use targeting directives:

| Directive | Syntax | Fan-out |
|---|---|---|
| `Grupa/` | `Grupa/OrgName` | Target org + all entities with `@grupa` membership matching the org |
| `Lokacja/` | `Lokacja/LocName` | Target location + sub-locations (BFS via `@lokacja`) + non-location entities within the tree |
| Direct | `Name` or `Name1, Name2` | Comma-split, resolved individually |

Resolution uses stages 1/2/2b of name resolution (exact → declension → stem alternation, no fuzzy). Webhook URLs resolved via `Resolve-EntityWebhook` (entity `@prfwebhook` override → owning Player's `PRFWebhook`).

---

## 8. Discord Messaging (`Send-DiscordMessage`)

Low-level webhook sender. POSTs JSON payload (`content`, optional `username`) to Discord webhook URL via `HttpClient`. Validates URL format. No retry logic (delegated to future queue system). `SupportsShouldProcess`.

---

## 9. Migration Steps

### 9.1 Bootstrap Entity Store

```powershell
Import-Module ./.robot.new/robot.psd1
. ./.robot.new/entity-writehelpers.ps1
ConvertTo-EntitiesFromPlayers -OutputPath ./.robot.new/entities.md
```

### 9.2 Switch to Entity-Based Writes

All CRUD operations now use `Set-Player`, `Set-PlayerCharacter`, `New-Player`, `New-PlayerCharacter`, `Remove-PlayerCharacter`. These write to `entities.md` exclusively.

### 9.3 Upgrade Session Formats

```powershell
Get-Session | Where-Object { $_.Format -ne 'Gen4' } | Set-Session -UpgradeFormat
```

Or per-file:
```powershell
Get-Session -File 'Wątki/some-thread.md' | Set-Session -UpgradeFormat
```

Non-metadata blocks (`Objaśnienia`, `Efekty`, etc.) and body text are preserved.

### 9.4 Validate Parity

Compare pre/post outputs of:
- `Get-Player` (merged data from both sources)
- `Get-Session` (auto-detects all formats)
- `Get-PlayerCharacter -IncludeState` (three-layer merge)

### 9.5 Monitor Warnings

Unresolved names in `Get-EntityState` / narrator resolution should be cleaned up by adding missing `Gracz` / entity entries.

---

## 10. Transition Invariants

1. **`Gracze.md` is never mutated** by any module command.
2. **All new mutable state** persists in `entities.md` (and `*-NNN-ent.md`).
3. **Gen1/2/3 sessions remain parseable** after migration — `Get-Session` auto-detects transparently.
4. **Gen4 is the canonical write format** for all new/upgraded session metadata.
5. **Soft-delete via `@status`** — no physical removal of entity bullets or character files.
6. **Read path is always merged** — `Get-Player` overlays both stores, `Get-EntityState` merges entity + session data.
7. **All write commands support `SupportsShouldProcess`** (`-WhatIf`, `-Confirm`).

---

## 11. Module Structure

### Exported Commands (Verb-Noun, auto-loaded by `robot.psm1`)

| File | Function | Purpose |
|---|---|---|
| `get-player.ps1` | `Get-Player` | Parse Gracze.md + entity overlays |
| `get-playercharacter.ps1` | `Get-PlayerCharacter` | Typed projection with optional three-layer state merge |
| `get-entity.ps1` | `Get-Entity` | Parse entity registry files |
| `get-entitystate.ps1` | `Get-EntityState` | Merge entity data with session Zmiany |
| `get-session.ps1` | `Get-Session` | Parse session metadata (Gen1–Gen4) |
| `get-reporoot.ps1` | `Get-RepoRoot` | Locate git repository root |
| `get-nameindex.ps1` | `Get-NameIndex` | Token-based reverse lookup with BK-tree |
| `get-gitchangelog.ps1` | `Get-GitChangeLog` | Stream-parse git log into structured objects |
| `get-newplayercharacterpucount.ps1` | `Get-NewPlayerCharacterPUCount` | New character PU estimate |
| `set-player.ps1` | `Set-Player` | Update player metadata in entities.md |
| `set-playercharacter.ps1` | `Set-PlayerCharacter` | Update character PU/metadata/file |
| `set-session.ps1` | `Set-Session` | Modify session metadata, format upgrade |
| `new-player.ps1` | `New-Player` | Create player entry |
| `new-playercharacter.ps1` | `New-PlayerCharacter` | Create character entry + file |
| `new-session.ps1` | `New-Session` | Generate Gen4 session markdown |
| `Remove-PlayerCharacter.ps1` | `Remove-PlayerCharacter` | Soft-delete character |
| `resolve-name.ps1` | `Resolve-Name` | Multi-stage name resolution |
| `resolve-narrator.ps1` | `Resolve-Narrator` | Resolve narrator names from session headers |
| `invoke-playercharacterpuassignment.ps1` | `Invoke-PlayerCharacterPUAssignment` | Monthly PU workflow |
| `test-playercharacterpuassignment.ps1` | `Test-PlayerCharacterPUAssignment` | PU diagnostics |
| `send-discordmessage.ps1` | `Send-DiscordMessage` | Discord webhook sender |

### Non-Exported Helpers (dot-sourced on demand)

| File | Purpose |
|---|---|
| `entity-writehelpers.ps1` | Entity file read/write primitives, bootstrap migration |
| `charfile-helpers.ps1` | Character file parse/write for `Postaci/Gracze/*.md` |
| `format-sessionblock.ps1` | Shared Gen4 metadata block rendering |
| `admin-config.ps1` | Config resolution, template rendering |
| `admin-state.ps1` | Append-only history file read/write |
| `parse-markdownfile.ps1` | Single-file Markdown parser |

### Data Files

| File | Purpose |
|---|---|
| `entities.md` | Base entity registry (lowest override primacy) |
| `entities-100-ent.md` | Override shard with primacy 100 |
| `robot.psd1` | Module manifest |
| `robot.psm1` | Module loader (auto-discovers Verb-Noun `.ps1` files) |
| `templates/*.md.template` | Character file and player entry templates |
| `local.config.psd1` | Local config (git-ignored) |

# Migration Guide

The migration from the legacy `.robot/robot.ps1` system to the `.robot.new` module covers the data model transition, session format upgrade, and operational workflow migration.

---

## Data Model Transition

The module operates on two data stores simultaneously:

| Store | File(s) | Access | Role |
|---|---|---|---|
| Legacy | `Gracze.md` | Read-only | Historical player database. Parsed by `Get-Player` for backward compatibility. Never written to by any module command. |
| Entity registry | `entities.md`, `*-NNN-ent.md` | Read + Write | Canonical write target for all player, character, and world entity data. All mutating commands (`Set-Player`, `Set-PlayerCharacter`, `New-Player`, `New-PlayerCharacter`, `Remove-PlayerCharacter`) write exclusively here. |

`Get-Player` merges both stores at read time:

1. Base layer — parse `Gracze.md` under `## Lista` -> level-3 `### PlayerName` sections -> characters from `Postaci:` bullets with `[Name](Path)` links, PU from `NADMIAR`/`STARTOWE`/`SUMA`/`ZDOBYTE` sub-keys, player metadata (`ID Margonem`, `PRFWebhook`, `Tematy zastrzezone`).
2. Override layer — call `Get-Entity` -> filter to `Gracz`, `Postac`, or entities with `@nalezy_do` -> match to players by name (case-insensitive) -> apply overrides.
3. Stub creation — if an entity references a player or character not in `Gracze.md`, an in-memory stub is created (not persisted to disk).

Override application rules:

| Entity type | Field | Behavior |
|---|---|---|
| `Gracz` | Aliases | Added to player `Names` HashSet |
| `Gracz` | `@margonemid` | Last value wins (replaces) |
| `Gracz` | `@prfwebhook` | Last value wins, validated against `https://discord.com/api/webhooks/*` |
| `Gracz` | `@trigger` | Full array replacement |
| `Postac` | Aliases | Appended to character `Aliases` and player `Names` |
| `Postac` | `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte` | Last value wins, `[math]::Round(_, 2)` |
| `Postac` | `@info` | Appended to `AdditionalInfo` (newline-joined) |

PU derivation (`Complete-PUData`): if SUMA given but ZDOBYTE missing -> `ZDOBYTE = SUMA - STARTOWE`; converse applies.

Entity files use structured Markdown:

```markdown
## Gracz

* Roland Ironfist
    - @margonemid: 12345
    - @prfwebhook: https://discord.com/api/webhooks/...
    - @trigger: topic1

## Postac

* Crag Hack
    - @nalezy_do: Roland Ironfist
    - @pu_startowe: 20
    - @pu_suma: 45.5
    - @alias: Crag (2024-01:)

## Przedmiot

* Miecz Sadu
    - @nalezy_do: Crag Hack
```

Multi-file merge: files are sorted by numeric key (extracted from `*-NNN-ent.md` filenames). `entities.md` has sort key `MaxValue` (processed first, lowest primacy). Lower numbers are processed last and have highest override primacy. Same-name entities across files have their histories concatenated.

Temporal scoping: tags support `(YYYY-MM:YYYY-MM)`, `(YYYY-MM:)`, `(:YYYY-MM)` validity ranges. Partial dates resolve via `Resolve-PartialDate` (start -> first day, end -> last day). Missing ranges mean always-active.

Recognized @Tags:

| Tag | Type | Description |
|---|---|---|
| `@alias` | Temporal | Alternative name |
| `@lokacja` | Temporal | Location assignment / containment hierarchy |
| `@drzwi` | Temporal | Physical access connection |
| `@typ` | Temporal | Entity type override |
| `@nalezy_do` | Temporal | Ownership (character -> player) |
| `@grupa` | Temporal | Group/faction membership |
| `@status` | Temporal | Entity status (`Aktywny`, `Nieaktywny`, `Usuniety`) |
| `@zawiera` | Non-temporal | Child containment declaration |
| Any other `@tag` | Temporal | Generic override stored in `Overrides` dictionary |

Pass 1 (`Get-Entity`) parses entity registry files. Produces entity objects with scalar properties resolved via `Get-LastActiveValue` (latest active history entry wins) and array properties via `Get-AllActiveValues`. Post-parse: canonical names resolved via `Resolve-EntityCN` — locations get hierarchical `Lokacja/Parent/.../Name` paths; others get flat `Type/Name`.

Pass 2 (`Get-EntityState`) merges session `Zmiany` (changes) into entity objects: filters to sessions with `Changes` and valid dates sorted chronologically, resolves entity names via case-insensitive dictionary lookup falling back to `Resolve-Name` pipeline (declension stripping, stem alternation, Levenshtein BK-tree), auto-dates tags without explicit temporal ranges with `ValidFrom = Session.Date` (open-ended), and after all sessions are processed sorts histories by `ValidFrom` (null sorts first) and recomputes active values.

Three-layer merge (`Get-PlayerCharacter -IncludeState`):

| Layer | Source | Temporal behavior |
|---|---|---|
| 1 (Baseline) | Character `.md` file (`Read-CharacterFile`) | Undated - always active, sorts before dated entries |
| 2+3 (Overrides) | `Get-EntityState` result (entities.md + session Zmiany, already merged) | Temporal ranges parsed via `ConvertFrom-ValidityString` |

Scalar properties: last active value wins. Multi-valued properties: all active values collected. Characters with `Status = 'Usuniety'` are excluded unless `-IncludeDeleted`.

---

## Entity Write Operations

All mutating functions operate on `List[string]` line arrays with in-place index manipulation. Write helpers live in `private/entity-writehelpers.ps1` and `private/entity-findhelpers.ps1`:

| Function | Source | Purpose |
|---|---|---|
| `Find-EntitySection` | `private/entity-findhelpers.ps1` | Locates `## Type` section boundaries. Returns `{ HeaderIdx, StartIdx, EndIdx, HeaderText, EntityType }`. |
| `Find-EntityBullet` | `private/entity-findhelpers.ps1` | Locates `* EntityName` bullet within a section range. Returns `{ BulletIdx, ChildrenStartIdx, ChildrenEndIdx, EntityName }`. |
| `Find-EntityTag` | `private/entity-findhelpers.ps1` | Finds last occurrence of `- @tag: value` within a bullet's children. Returns `{ TagIdx, Tag, Value }` or `$null`. |
| `Set-EntityTag` | `private/entity-writehelpers.ps1` | Upserts a tag line: replaces if found, inserts at children end if not. Returns updated `ChildrenEnd`. |
| `New-EntityBullet` | `private/entity-writehelpers.ps1` | Inserts `* EntityName` with sorted `@tag` children at section end. |
| `Resolve-EntityTarget` | `private/entity-writehelpers.ps1` | High-level orchestrator: `Invoke-EnsureEntityFile` -> find/create section -> find/create bullet. Returns `{ Lines, NL, BulletIdx, ChildrenStart, ChildrenEnd, FilePath, Created }`. |
| `Read-EntityFile` | `private/entity-writehelpers.ps1` | Reads file into `List[string]` with newline detection. |
| `Write-EntityFile` | `private/entity-writehelpers.ps1` | Writes `List[string]` back to file (UTF-8 no BOM, preserves newline style). |
| `Invoke-EnsureEntityFile` | `private/entity-writehelpers.ps1` | Creates `entities.md` with skeleton sections (`## Gracz`, `## Postac`, `## Przedmiot`) if missing. |

Mutating commands:

| Command | Target(s) | Key behaviors |
|---|---|---|
| `Set-Player` | `entities.md` `## Gracz` | Upserts `@margonemid`, `@prfwebhook`, `@trigger`. Creates player entity if missing. Validates webhook URL format. Trigger update is remove-all-then-insert (full replacement). `SupportsShouldProcess`. |
| `Set-PlayerCharacter` | `entities.md` `## Postac` + character `.md` file | Dual-target: entity-level PU/alias/status tags -> `entities.md`; character file properties (CharacterSheet, RestrictedTopics, Condition, SpecialItems, Reputation, AdditionalNotes) -> `Postaci/Gracze/<Name>.md` via `private/charfile-helpers.ps1`. Auto-creates `## Przedmiot` entities for unknown special items. Status writes include temporal `(YYYY-MM:)` suffix. `SupportsShouldProcess`. |
| `New-Player` | `entities.md` `## Gracz` | Creates player entity with initial tags. Validates uniqueness (throws if exists). Validates webhook URL. Optionally delegates to `New-PlayerCharacter` for first character. `SupportsShouldProcess`. |
| `New-PlayerCharacter` | `entities.md` `## Postac` + `## Gracz` + character file | Creates character entity with `@nalezy_do` and `@pu_startowe`. Ensures player entity exists (creates if missing). Creates character file from `player-character-file.md.template`. Optionally applies initial character file properties. `SupportsShouldProcess`. |
| `Remove-PlayerCharacter` | `entities.md` `## Postac` | Soft-delete: writes `@status: Usuniety (YYYY-MM:)`. Entity bullet and character file remain. `ConfirmImpact = 'High'`. |

`ConvertTo-EntitiesFromPlayers` (`private/entity-migrationhelpers.ps1`) is a one-time bootstrap function that generates a complete `entities.md` from `Get-Player` output. Reads all players (optionally pre-fetched, or calls `Get-Player -Entities @()` to avoid circular dependency), generates `## Gracz` section with `@margonemid`/`@prfwebhook`/`@trigger` and `## Postac` section with `@nalezy_do`/`@alias`/PU tags/`@info`. PU values formatted with `([decimal]).ToString('G', InvariantCulture)`. Output: UTF-8 no BOM.

---

## Session Format Transition

Four format generations:

| Gen | Era | Location format | Log format | Metadata blocks | Detection |
|---|---|---|---|---|---|
| Gen1 | START-2022 | None | `Logi: https://...` plain text | None | Fallback (no other match) |
| Gen2 | 2022-2023 | `*Lokalizacja: A, B*` (italic) | `Logi: https://...` plain text | None | First non-empty line starts with `*Lokalizacj` |
| Gen3 | 2024-2026 | `- Lokalizacje:` list item | `- Logi:` list item | `- PU:`, `- Zmiany:`, `- Efekty:`, `- Objasnienia:` | Root list item with `pu` prefix (no `@`) |
| Gen4 | 2026+ | `- @Lokacje:` list item | `- @Logi:` list item | `- @PU:`, `- @Zmiany:`, `- @Intel:` | Root list item starting with `@` + letter |

Format detection (`Get-SessionFormat`) order (per-section heuristic):
1. `$FirstNonEmptyLine` starts with `*Lokalizacj` -> Gen2
2. Root list items (`$LI.Indent -eq 0`): text starts with `@` + letter -> Gen4; text starts with `pu` followed by `:` or space -> Gen3
3. Fallback -> Gen1

`Get-Session` normalizes all four formats transparently:
- Location extraction (`Get-SessionLocations`) — Gen2 uses italic regex. Gen3/Gen4 use entity-resolution strategy first (all children resolve to `Lokacja` entities), then tag-based fallback (`Lokalizacj*` or `Lokacj*`). Leading `@` stripped via `$TestText`.
- List metadata (`Get-SessionListMetadata`) — Leading `@` stripped via `$MatchText = if ($LowerText.StartsWith('@')) { $LowerText.Substring(1) } else { $LowerText }`, enabling unified parsing for both `- PU:` and `- @PU:`. Also extracts `@Data` date override (YYYY-MM-DD) and `@Narrator` canonical names.
- Plain-text log fallback (`Get-SessionPlainTextLogs`) — Applied when list-based `$Logs.Count -eq 0`, scanning for `Logi: <url>` patterns (Gen1/Gen2).

New sessions are always Gen4 (`New-Session` -> `ConvertTo-SessionMetadata` -> `ConvertTo-Gen4MetadataBlock`). Canonical block order: `@Narrator` -> `@Data` -> `@Lokacje` -> `@Logi` -> `@PU` -> `@Zmiany` -> `@Intel`. Zmiany rendering: entity names at 4-space indent, `@tag: value` at 8-space indent.

In-place upgrade (`Set-Session -UpgradeFormat`) — section decomposition (`Split-SessionSection`) classifies content into:

| Category | Tags | Handling |
|---|---|---|
| Meta blocks | `pu`, `logi`, `lokalizacje`, `lokacje`, `zmiany`, `intel` (with or without `@` prefix) | Replaceable by parameters or upgradeable to Gen4 |
| Preserved blocks | `objasnienia`, `efekty`, `komunikaty`, `straty`, `nagrody` | Written back unchanged |
| Body lines | Everything else | Replaceable via `-Content` |
| Legacy formats | Gen2 italic locations (`*Lokalizacj...*`), Gen1/2 plain `Logi: ...` | Captured separately, converted during upgrade |

Upgrade conversions:

| Source | Converter | Output |
|---|---|---|
| Gen3 list blocks | `ConvertTo-Gen4FromRawBlock` | Renames root tag, normalizes indent to 4-space multiples |
| Gen2 italic locations | `ConvertFrom-ItalicLocation` | `- @Lokacje:` with expanded children |
| Gen1/2 plain text logs | `ConvertFrom-PlainTextLog` | `- @Logi:` with child URLs |

Sessions with identical headers across files are grouped by exact `Header` text (Ordinal comparison). The metadata-richest instance is selected as primary. Array fields are unioned via `HashSet` (locations, logs) or deduped by composite key (PU: `Character|Value`, Intel: `RawTarget|Message`). Merged sessions carry `IsMerged = $true`, `DuplicateCount`, and `FilePaths[]`.

Session headers contain a narrator name segment (after the last comma), but these raw names may be inconsistent (abbreviations, nicknames, varying forms). Narrator normalization maps raw names to canonical forms using a mappings file at `.robot/res/narrator-mappings.txt`. Format (one mapping per line): `raw -> Canonical1, Canonical2`. Each line maps a raw narrator string (left side) to one or more canonical narrator names (right side), matched case-insensitively.

Phase 2 workflow: The coordinator runs `Get-NarratorReport` to identify raw narrator names that do not resolve to known players. Unresolved names are added to `narrator-mappings.txt` with their canonical equivalents. The process is iterative: run report, add mappings, re-run until all names resolve.

Phase 5 workflow: During session format upgrade, resolved narrator mappings can be persisted as `- @Narrator:` blocks in Gen4 metadata. When present, the `@Narrator` block overrides header-based narrator resolution while preserving the original `RawText`.

Sessions with malformed dates in headers (e.g., `2024-07-014`) cannot have their headers changed because headers are unique identifiers shared across multiple files. The `@Data` tag allows overriding the date parsed from the header without modifying the header itself. Format:

```markdown
### 2024-07-014, Oblezenie Steadwick, Solmyr

- @Data: 2024-07-14
```

When `@Data` is present, `Get-Session` uses the specified date instead of parsing the header. This rescues sessions that would otherwise be flagged as failed. If the header already has a valid date, `@Data` replaces it. The `@Data` tag is excluded from mention detection.

Setting via command:

```powershell
Set-Session -DateOverride '2024-07-14' -File 'Postaci/Gracze/Crag Hack.md'
```

---

## PU Assignment Workflow

Pipeline (`Invoke-PlayerCharacterPUAssignment`):

1. Date range — `Year`/`Month` -> first/last day of month. Default: 2-month lookback.
2. Git optimization — `Get-GitChangeLog -NoPatch` pre-filters to `.md` files changed in range, passed to `Get-Session -File`. Falls back to full scan on failure.
3. Session filtering — select sessions with PU entries, exclude already-processed headers from `.robot/res/pu-sessions.md` via `Get-AdminHistoryEntries`.
4. Character resolution — `Get-PlayerCharacter` (merges Gracze.md + entities.md). Fail-early: throws `UnresolvedPUCharacters` error (with structured `TargetObject`) if any PU character name cannot be resolved.
5. PU computation (per character):
   ```
   BasePU       = 1 + Sum(session PU for this character)
   UsedExceeded = min(5 - BasePU, PUExceeded) when BasePU <= 5 and PUExceeded > 0
   OverflowPU   = BasePU - 5 when BasePU > 5
   GrantedPU    = min(BasePU + UsedExceeded, 5)
   Remaining    = (PUExceeded - UsedExceeded) + OverflowPU
   ```
6. Side effects (switch-gated):
   - `-UpdatePlayerCharacters` — `Set-PlayerCharacter` with PUSum, PUTaken, PUExceeded.
   - `-SendToDiscord` — grouped per player, sent via `Send-DiscordMessage` (username: `Bothen`).
   - `-AppendToLog` — `Add-AdminHistoryEntry` to `pu-sessions.md`.

Diagnostics (`Test-PlayerCharacterPUAssignment`) runs the PU pipeline in compute-only mode (`-WhatIf`). Catches `UnresolvedPUCharacters` errors and extracts `TargetObject`. Reports: unresolved character names, malformed (null) PU values, duplicate PU entries (same character, same session), failed sessions with PU content (silently dropped by normal pipeline), and stale history entries (headers in `pu-sessions.md` not matching any repository session).

Returns structured `[PSCustomObject]@{ OK; UnresolvedCharacters; MalformedPU; DuplicateEntries; FailedSessionsWithPU; StaleHistoryEntries; AssignmentResults }`.

New character PU estimate (`Get-NewPlayerCharacterPUCount`):

```
Include only characters with PUStart > 0
PU = Floor((Sum(PUTaken) / 2) + 20)
```

Minimum result is 20 (new players). Used by `New-PlayerCharacter` as fallback when `InitialPUStart` is not specified.

---

## Character File Operations

`private/charfile-helpers.ps1` parses and writes `Postaci/Gracze/*.md` files. Sections identified by `**Header:**` bold-header pattern.

Parsed properties: `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (three-tier: Pozytywna/Neutralna/Negatywna with Location/Detail objects), `AdditionalNotes`, `DescribedSessions` (read-only).

`Write-CharacterFileSection` replaces section content in-place on `List[string]` lines.

`Format-ReputationSection` renders reputation tiers — inline format when no details, nested bullets when details present.

---

## Configuration and State

Config resolution (`private/admin-config.ps1`) priority chain:
1. Explicit parameter
2. Environment variable (`$env:NERTHUS_REPO_WEBHOOK`, `$env:NERTHUS_BOT_USERNAME`)
3. Local config file (`.robot.new/local.config.psd1`, git-ignored)
4. Fail with error

Resolved paths: `RepoRoot`, `ModuleRoot`, `EntitiesFile`, `TemplatesDir`, `ResDir` (`.robot/res`), `CharactersDir` (`Postaci/Gracze`), `PlayersFile` (`Gracze.md`).

State files (`private/admin-state.ps1`) are append-only files in `.robot/res/`:
```
- YYYY-MM-dd HH:mm (UTC+HH:MM):
    - ### session header 1
    - ### session header 2
```

`Get-AdminHistoryEntries` returns `HashSet[string]` (OrdinalIgnoreCase, whitespace-normalized, `### ` prefix stripped). `Add-AdminHistoryEntry` appends with timestamp, sorts headers chronologically.

Templates are located in `.robot.new/templates/`. Files: `player-character-file.md.template`, `player-entry.md.template`. Rendering via `Get-AdminTemplate` with `{Placeholder}` substitution.

---

## Intel Resolution

`@Intel` entries in sessions use targeting directives:

| Directive | Syntax | Fan-out |
|---|---|---|
| `Grupa/` | `Grupa/OrgName` | Target org + all entities with `@grupa` membership matching the org |
| `Lokacja/` | `Lokacja/LocName` | Target location + sub-locations (BFS via `@lokacja`) + non-location entities within the tree |
| Direct | `Name` or `Name1, Name2` | Comma-split, resolved individually |

Resolution uses stages 1/2/2b of name resolution (exact -> declension -> stem alternation, no fuzzy). Webhook URLs resolved via `Resolve-EntityWebhook` (entity `@prfwebhook` override -> owning Player's `PRFWebhook`).

---

## Discord Messaging

`Send-DiscordMessage` is a low-level webhook sender. POSTs JSON payload (`content`, optional `username`) to Discord webhook URL via `HttpClient`. Validates URL format. No retry logic (delegated to future queue system). `SupportsShouldProcess`.

---

## Migration Phase Pipeline

The automated migration is orchestrated by `migration/migrate.ps1` (`Invoke-PhaseByNumber`). Nine phases run sequentially, with state checkpointing in `.robot/res/migration-state.json`. Each phase is idempotent.

State file resilience (`migration-state.ps1`): `Save-MigrationState` uses an atomic temp-file swap pattern — writes to `$Path.tmp` first, then creates a `.bak` backup of the current state, then moves the temp file to the target path. This prevents corruption from interrupted writes. `Get-MigrationState` implements backup recovery: if the primary state file is corrupt (JSON parse failure), it attempts to read from `$Path.bak`, restores the backup to the primary path, and returns the recovered state. If both are corrupt, falls back to `New-DefaultMigrationState`. All errors are logged to stderr with Polish-language messages.

Phase overview:

| Phase | Function | File | Purpose |
|---|---|---|---|
| 0 | `Invoke-MigrationPhase0` | `phase0-setup.ps1` | Przygotowanie i bootstrap — data manifest creation, prerequisite checks, bootstrap entity store from `Gracze.md` via `ConvertTo-EntitiesFromPlayers` |
| 1 | `Invoke-MigrationPhase1` | `phase1-session-hashes.ps1` | Baseline integralnosci sesji — generate baseline SHA256 hashes for all session headers (`Set-SessionHash -Full`) |
| 2 | `Invoke-MigrationPhase2` | `phase2-validation.ps1` | Walidacja i naprawa danych — validate entity parity between legacy and new stores, run PU diagnostics and narrator normalization |
| 3 | `Invoke-MigrationPhase3` | `phase3-location-import.ps1` | Import lokalizacji z mapy — bulk-import Mapa entities from maps.json to overflow file, derive Lokacja from hierarchy, apply overrides |
| 4 | `Invoke-MigrationPhase4` | `phase4-log-download.ps1` | Pobieranie logow sesji — bulk download of session logs from remote URLs to local `res/logs/` cache |
| 5 | `Invoke-MigrationPhase5` | `phase5-session-upgrade.ps1` | Upgrade formatu sesji — upgrade session formats from Gen1/2/3 to Gen4, including URL localization (replaces `https://` log URLs with `res/logs/` local paths via `Resolve-LogUrlToLocalPath`) |
| 6 | `Invoke-MigrationPhase6` | `phase6-door-inference.ps1` | Wnioskowanie drzwi z logow — infer `@Drzwi` (physical access connections) between locations by analyzing downloaded session logs |
| 7 | `Invoke-MigrationPhase7` | `phase7-currency.ps1` | Enrollment walut — currency entity creation and reconciliation |
| 8 | `Invoke-MigrationPhase8` | `phase8-cutover.ps1` | Przelaczenie (cutover) — final diagnostics, freeze `Gracze.md`, first standalone PU run |

Migration files:

| File | Purpose | Functions |
|---|---|---|
| `migrate.ps1` | Entry point and phase dispatcher | `Invoke-PhaseByNumber` |
| `migration-state.ps1` | State persistence (atomic writes, backup/recovery) | `Resolve-MigrationStatePath`, `New-DefaultMigrationState`, `ConvertTo-HashtableDeep`, `Get-MigrationState`, `Save-MigrationState`, `Get-PhaseStatus`, `Set-PhaseCompleted`, `Set-PhaseInProgress`, `Update-PhaseChecklist`, `Add-DiagnosticSnapshot` |
| `migration-shared.ps1` | Shared diagnostics and menu shortcuts | `Test-PhasePredecessor`, `Show-DiagnosticResults`, `Invoke-QuickDiagnostics`, `Invoke-FullReport` |
| `migration-ui.ps1` | Polish-language UI helpers (22 functions) | `Initialize-MigrationLog`, `Write-MigrationLog`, `Flush-MigrationLog`, `Resolve-MigrationColor`, `Get-PhaseName`, `Write-PhaseHeader`, `Write-Step`, `Write-StepOK`, `Write-StepWarning`, `Write-StepError`, `Write-SectionHeader`, `Write-ChecklistReport`, `Write-ActionRequired`, `Write-CommandHint`, `Write-PhaseSummary`, `Write-TableRow`, `Request-UserChoice`, `Request-YesNo`, `Request-Confirmation`, `Request-StringInput`, `Request-NumericInput`, `Show-ProgressSummary` |
| `migration-location-helpers.ps1` | Self-contained location name helpers; dot-sourced by Phase 3 | `Get-MapBaseNameIntermediates`, `Get-MapBaseNameDeterministic`, `Get-MapBaseNameCandidates` |
| `narrator-normalization.ps1` | Narrator mapping I/O | `Get-NarratorMappingsPath`, `Import-NarratorMappings`, `Export-NarratorMappings` |
| `phase0-setup.ps1` | Phase 0: Przygotowanie i bootstrap | `Invoke-MigrationPhase0` |
| `phase1-session-hashes.ps1` | Phase 1: Baseline integralnosci sesji | `Invoke-MigrationPhase1` |
| `phase2-validation.ps1` | Phase 2: Walidacja i naprawa danych | `Invoke-MigrationPhase2`, `Show-BRAKCharacters` |
| `phase3-location-import.ps1` | Phase 3: Import lokalizacji z mapy | `Invoke-MigrationPhase3` |
| `phase4-log-download.ps1` | Phase 4: Pobieranie logow sesji | `Invoke-MigrationPhase4` |
| `phase5-session-upgrade.ps1` | Phase 5: Upgrade formatu sesji | `Invoke-MigrationPhase5`, `Export-SessionReviewFile`, `Import-SessionReviewFile` |
| `phase6-door-inference.ps1` | Phase 6: Wnioskowanie drzwi z logow | `Invoke-MigrationPhase6` |
| `phase7-currency.ps1` | Phase 7: Enrollment walut | `Invoke-MigrationPhase7`, `Invoke-CurrencyCSVImport`, `Invoke-CurrencyInteractiveEntry`, `Invoke-NarratorBudgetEntry` |
| `phase8-cutover.ps1` | Phase 8: Przelaczenie (cutover) | `Invoke-MigrationPhase8` |

---

## Phase 1: Session Hash Baseline

Runs `Set-SessionHash -Full` to compute SHA256 content hashes for all headers in repository Markdown files. This captures the pre-mutation baseline before any validation, repair, or format-upgrade phases modify session content. The hash store is created in `{ResDir}/session-hashes/` and enables `Test-SessionIntegrity` to detect content tampering later. See [SESSION-INTEGRITY.md](SESSION-INTEGRITY.md).

---

## Phase 3: Location Import

Imports game-map data from `.robot/res/maps.json` as two entity types: Mapa entities (concrete game maps with metadata) written to the overflow file `maps-100-ent.md`, and Lokacja entities (conceptual locations) derived from the hierarchy and written to `entities.md`. Dot-sources `migration-location-helpers.ps1`.

`maps.json` format — the file is sourced from the Margonem game data. Expected structure:

```json
{
  "lastUpdated": "2026-03-04T10:00:00+01:00",
  "maps": [
    {
      "id": 1,
      "name": "Steadwick",
      "url": "https://example.com/steadwick.png",
      "outerior": true,
      "tileWidth": 32,
      "tileHeight": 32
    }
  ]
}
```

| Field | Type | Used by Phase 3 | Description |
|---|---|---|---|
| `id` | `int` | Yes | Margonem map ID, stored as `@margonemid` tag on Mapa entity |
| `name` | `string` | Yes | Map display name, becomes the Mapa entity name and input to hierarchy inference |
| `outerior` | `bool` | Yes | Whether the map is an exterior (overworld) location; stored as `@typ: zewnetrzna/wewnetrzna` |
| `url` | `string` | Yes | Map image URL, stored as `@url` tag on Mapa entity |
| `tileWidth` | `int` | Yes | Tile pixel width, stored as part of `@wymiary` (when both dimensions non-null) |
| `tileHeight` | `int` | Yes | Tile pixel height, stored as part of `@wymiary` (when both dimensions non-null) |

The top-level `lastUpdated` field is informational (ISO 8601 timestamp of last scrape). The `maps` array contains one entry per game location (~2,704 entries in production).

Location name helpers (`migration/migration-location-helpers.ps1`) — three functions for inferring parent-child hierarchy from Margonem game-map names. Regex patterns are imported from the canonical source in `private/location-helpers.ps1`.

`Get-MapBaseNameIntermediates` accepts a mandatory `Name` (string) parameter. Applies 9 precompiled regex patterns (difficulty, floor, room, sala, named sala, direction, pietro, piwnica, named subarea) iteratively until stable. Captures the result after each individual pattern application that changes the value. Returns `[string[]]` of unique intermediate base names ordered from most-specific (least stripped) to most-generic (most stripped). Returns empty array if no stripping occurred. This enables callers to check intermediate forms against a name set and pick the closest (most-specific) parent.

`Get-MapBaseNameDeterministic` accepts a mandatory `Name` (string) parameter. Delegates to `Get-MapBaseNameIntermediates` and returns the last (most-stripped) element, or the original name if no stripping occurred. Equivalent to `$Intermediates[$Intermediates.Count - 1]`.

`Get-MapBaseNameCandidates` accepts a mandatory `Name` (string) parameter. Pre-strips difficulty parenthetical, then progressively removes trailing words (split by whitespace). Returns `[string[]]` of candidate base names from longest to shortest. Trailing separators (space, dash, en-dash, em-dash) are cleaned. Returns empty array for single-word names. Used as fallback when deterministic stripping overshoots.

Hierarchy inference uses a 3-tier parent lookup for each map entry:

1. Intermediate check — compute `Get-MapBaseNameIntermediates`. Walk intermediates from most-specific (least stripped) to most-stripped; the first intermediate that exists in the map name set becomes the parent. Example: `"X - wieza p.1"` prefers parent `"X - wieza"` over `"X"` when both exist in the name set.
2. Progressive word removal — if no intermediate matched, call `Get-MapBaseNameCandidates` and check each candidate against the name set. First match wins.
3. Virtual parent — if no existing map matches any candidate, the most-stripped deterministic base name (last element of intermediates) is used as the parent. This parent does not exist as a Mapa entry and will be created as a Lokacja entity during the derivation step (Step 5). The phase reports virtual parent count separately.

Maps with no stripping (empty intermediates) are classified as root locations (no parent).

Mapa bulk import (Step 4): All maps.json entries are written as Mapa entities to the overflow file `maps-100-ent.md` (numeric key 100 gives medium primacy). Each Mapa entity gets these tags:

```markdown
* {map.name}
    - @margonemid: {map.id}
    - @lokacja: {parent}           # from hierarchy, if exists
    - @typ: zewnetrzna/wewnetrzna  # from map.outerior boolean
    - @url: {map.url}              # CDN image URL
    - @wymiary: {tileWidth}, {tileHeight}  # only if both non-null
```

Entities are sorted alphabetically within the `## Mapa` section. The overflow file is created fresh if missing, or appended to if it already exists.

Lokacja derivation (Step 5): A second pass extracts unique location names from the hierarchy — all root maps (no parent) and all parent values (including virtual parents from tier 3) — and creates Lokacja entities in `entities.md`. Each Lokacja gets `@lokacja` pointing to its own parent if the location name itself appeared as a child in the hierarchy. Virtual parents that do not exist as Mapa entries are included in this set, ensuring every `@lokacja` reference resolves to a concrete entity. This produces far fewer entities than the full map count (~unique base names).

Override file (Steps 6-7): Exports `.robot/res/location-overrides.txt` (TSV). Section 1 maps Margonem names to Nerthus names (`@nazwa_nerthus`) — applied to Mapa entities in the overflow file. Section 2 defines virtual locations — created as Lokacja entities in `entities.md`. Re-running the phase applies overrides via `Set-EntityTag` / `New-EntityBullet`.

Backward compatibility: The old `BulkImportDone` checklist key (from partial Phase 3 runs that created Lokacja entities directly) is recognized as equivalent to `MapaBulkImportDone`, allowing the Mapa import step to be skipped while the Lokacja derivation step still runs.

Checklist: `MapsJsonLoaded`, `HierarchyInferred`, `MapaBulkImportDone` (or legacy `BulkImportDone`), `LokacjaDerivationDone`, `OverridesExported`, `OverridesImported`, `Committed`. Phase completes when `MapaBulkImportDone` AND `LokacjaDerivationDone` AND `OverridesImported` are all true.

Tests: `tests/migration-phase5-location-import.Tests.ps1` (40 tests). Covers `Get-MapBaseNameDeterministic`, `Get-MapBaseNameIntermediates`, `Get-MapBaseNameCandidates`, and 3-tier hierarchy inference integration with fixture data from `tests/fixtures/maps-test.json`.

---

## Phase 4: Bulk Log Download

Downloads all session log files from remote URLs (discovered via `Get-Session` log metadata) to the local `res/logs/` cache directory using `Invoke-LogBatchFetch`. This ensures that all log content is available locally before Phase 5 upgrades session metadata and Phase 6 analyzes logs for `@Drzwi` inference. Idempotent — already-cached files are skipped.

---

## Phase 5: Session Review File

After format upgrade, narrator verification, and location review, Phase 5 generates a review artifact at `.robot/res/all-sessions-to-review.md` via `Export-SessionReviewFile`. The file contains all sessions sorted by header (chronological), with source file paths in `<!-- Zrodlo: relative/path -->` HTML comments.

URL localization: During session format upgrade, `Resolve-LogUrlToLocalPath` replaces remote `https://` log URLs with their corresponding `res/logs/` local paths when the cached file exists. This makes sessions self-contained with local log references.

Export (`Export-SessionReviewFile`): Calls `Get-Session -ExcludeDirectory $script:MigrationExcludeDirs -IncludeContent -Quiet`, sorts by `Header`, splits `Content` on `[char]10` with `.TrimEnd([char]13)`, builds relative paths from `FilePaths` via `$P.Substring($RepoRoot.Length + 1)`. Writes via `[System.IO.File]::WriteAllLines()` with UTF-8 no BOM.

Import (`Import-SessionReviewFile`): Parses the edited review file into session blocks (header + body + source comment). Fetches current state via `Get-Session -IncludeContent`. Classifies changes into Modified (header exists in both, content differs), New (header in review but not source), and Deleted (header in source but not review). Displays a change summary (modified, new, deleted, unchanged counts) and requires `Request-YesNo` confirmation before applying.

File operations are batched: all modifications and deletions are grouped by target file path into a `Dictionary[string, List[object]]` (`$FileOps`). Each file is read once via `[System.IO.File]::ReadAllLines()`, all operations are applied in-memory in reverse section order (highest `HeaderLineIdx` first, via `Sort` with descending comparator, to preserve line indices for earlier sections), and the result is written once via `[System.IO.File]::WriteAllLines()`.

Operation types: Each op is a hashtable with `Type` (`'Modify'` or `'Delete'`), `Header`, and optionally `NewBody`. `Find-SessionInFile` locates the header's line range in the file. For modifications, the section content between header and section end is replaced with the new body. For deletions, the entire section (header through section end) is removed. Array splicing uses `$FileLines[0..$Match.HeaderLineIdx]` / `$FileLines[$Match.SectionEndIdx..($FileLines.Count - 1)]` to reconstruct the file.

New sessions are written to `.robot/res/review-additions/YYYY-MM-DD-slug.md`. Requires `Request-YesNo` confirmation before applying.

Step lifecycle: On first run (checklist `SessionReviewFileGenerated` not set), generates the file. On subsequent runs, presents a `Request-UserChoice` menu: P (skip), Z (apply edits), R (regenerate), H (refresh hashes via `Set-SessionHash -Full`). The review step is Step 9; hash refresh is Step 10; graph build is Step 11.

Entity caching: Phase 5 loads the entity roster (`$PhaseEntities`) and player roster (`$PhasePlayers`) once at phase entry and passes them to all subsequent steps (format distribution, upgrade, narrator resolution, location review, session review). This avoids redundant `Get-Entity` / `Get-Player` calls within the phase.

Checklist: `SessionReviewFileGenerated`. Not included in the phase completion gate — the review workflow is optional and asynchronous.

---

## Phase 6: @Drzwi Door Inference

Analyzes downloaded session logs (from Phase 4) to infer `@Drzwi` (physical access / door connections) between location entities. Parses log content for movement events between named locations and creates bidirectional `@drzwi` tags on the corresponding Lokacja entities. Results are written to the entity registry. Idempotent — existing `@drzwi` tags are preserved, only new connections are added.

---

## Phase 8: Cutover

Runs final PU diagnostics (must pass to proceed), freezes `Gracze.md` with a read-only comment header, marks the legacy system as deprecated, executes the first standalone PU assignment, creates a post-migration git tag, and displays an announcement template.

---

## Migration Logging System

Implemented in `migration/migration-ui.ps1`. Three functions provide a structured text log written to `.robot/res/migration-log.txt`:

| Function | Purpose |
|---|---|
| `Initialize-MigrationLog` | Opens a fresh log file with timestamp header. Called once at migration start (`migrate.ps1`). Overwrites any previous log. |
| `Write-MigrationLog` | Appends a structured entry with level, phase context, summary, and optional detail lines. |
| `Flush-MigrationLog` | Writes accumulated lines to disk via `[System.IO.File]::WriteAllLines()` (UTF-8 no BOM). Called at phase boundaries (via `Write-PhaseSummary`) rather than after every log entry, reducing I/O overhead. |

`Write-MigrationLog` parameters:

| Parameter | Type | Description |
|---|---|---|
| `Level` | string | `INFO`, `WARN`, `ERROR`, or `ACTION` |
| `Phase` | string | Phase/step context label (auto-set by `Write-PhaseHeader`/`Write-Step` via `$script:LogPhaseContext`/`$script:LogStepContext`) |
| `Summary` | string | One-line summary (mandatory) |
| `Details` | string[] | Optional indented explanation lines |

The log is best-effort — failures in `Flush-MigrationLog` are silently caught. The file is overwritten on each migration run and contains results from the last run only.

`Write-StepWarning`, `Write-StepError`, and `Write-ActionRequired` accept an optional `-LogDetails` string array parameter that is forwarded to `Write-MigrationLog`. `Write-PhaseHeader`, `Write-Step`, `Write-StepOK`, and `Write-PhaseSummary` automatically log their output. Phase/step context is tracked via `$script:LogPhaseContext` and `$script:LogStepContext` module-scoped variables.

`Show-DiagnosticResults` in `migration-shared.ps1` builds detailed `$LogDetails` arrays for each diagnostic category (unresolved characters, malformed PU, duplicates, malformed dates) and passes them to `Write-MigrationLog` with `WARN` level. The malformed date handler auto-detects common typo patterns (extra digits in day part, missing separators) and suggests both header correction and `@Data:` override as repair options.

---

## Manual Migration Steps

These commands can be run independently outside the automated phase pipeline.

Bootstrap entity store:

```powershell
Import-Module ./.robot.new/robot.psd1
. ./.robot.new/private/entity-migrationhelpers.ps1
ConvertTo-EntitiesFromPlayers -OutputPath ./.robot.new/entities.md
```

All CRUD operations now use `Set-Player`, `Set-PlayerCharacter`, `New-Player`, `New-PlayerCharacter`, `Remove-PlayerCharacter`. These write to `entities.md` exclusively.

Upgrade session formats:

```powershell
Get-Session | Where-Object { $_.Format -ne 'Gen4' } | Set-Session -UpgradeFormat
```

Or per-file:
```powershell
Get-Session -File 'Watki/some-thread.md' | Set-Session -UpgradeFormat
```

Non-metadata blocks (`Objasnienia`, `Efekty`, etc.) and body text are preserved.

Validate parity by comparing pre/post outputs of `Get-Player` (merged data from both sources), `Get-Session` (auto-detects all formats), and `Get-PlayerCharacter -IncludeState` (three-layer merge).

Unresolved names in `Get-EntityState` / narrator resolution should be cleaned up by adding missing `Gracz` / entity entries.

---

## Transition Invariants

1. `Gracze.md` is never mutated by any module command.
2. All new mutable state persists in `entities.md` (and `*-NNN-ent.md`).
3. Gen1/2/3 sessions remain parseable after migration — `Get-Session` auto-detects transparently.
4. Gen4 is the canonical write format for all new/upgraded session metadata.
5. Soft-delete via `@status` — no physical removal of entity bullets or character files.
6. Read path is always merged — `Get-Player` overlays both stores, `Get-EntityState` merges entity + session data.
7. All write commands support `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).

---

## Module Structure

Exported commands (Verb-Noun, auto-loaded by `robot.psm1`):

| File | Function | Purpose |
|---|---|---|
| `public/player/get-player.ps1` | `Get-Player` | Parse Gracze.md + entity overlays |
| `public/player/get-playercharacter.ps1` | `Get-PlayerCharacter` | Typed projection with optional three-layer state merge |
| `public/get-entity.ps1` | `Get-Entity` | Parse entity registry files |
| `public/get-entitystate.ps1` | `Get-EntityState` | Merge entity data with session Zmiany |
| `public/session/get-session.ps1` | `Get-Session` | Parse session metadata (Gen1-Gen4) |
| `public/get-reporoot.ps1` | `Get-RepoRoot` | Locate git repository root |
| `public/get-nameindex.ps1` | `Get-NameIndex` | Token-based reverse lookup with BK-tree |
| `public/session/get-gitchangelog.ps1` | `Get-GitChangeLog` | Stream-parse git log into structured objects |
| `public/player/get-newplayercharacterpucount.ps1` | `Get-NewPlayerCharacterPUCount` | New character PU estimate |
| `public/player/set-player.ps1` | `Set-Player` | Update player metadata in entities.md |
| `public/player/set-playercharacter.ps1` | `Set-PlayerCharacter` | Update character PU/metadata/file |
| `public/session/set-session.ps1` | `Set-Session` | Modify session metadata, format upgrade |
| `public/player/new-player.ps1` | `New-Player` | Create player entry |
| `public/player/new-playercharacter.ps1` | `New-PlayerCharacter` | Create character entry + file |
| `public/session/new-session.ps1` | `New-Session` | Generate Gen4 session markdown |
| `public/player/remove-playercharacter.ps1` | `Remove-PlayerCharacter` | Soft-delete character |
| `public/resolve/resolve-name.ps1` | `Resolve-Name` | Multi-stage name resolution |
| `public/resolve/resolve-narrator.ps1` | `Resolve-Narrator` | Resolve narrator names from session headers |
| `public/workflow/invoke-playercharacterpuassignment.ps1` | `Invoke-PlayerCharacterPUAssignment` | Monthly PU workflow |
| `public/reporting/test-playercharacterpuassignment.ps1` | `Test-PlayerCharacterPUAssignment` | PU diagnostics |
| `public/workflow/send-discordmessage.ps1` | `Send-DiscordMessage` | Discord webhook sender |

Non-exported helpers (dot-sourced on demand):

| File | Purpose |
|---|---|
| `private/entity-findhelpers.ps1` | Entity section/bullet/tag locators (`Find-EntitySection`, `Find-EntityBullet`, `Find-EntityTag`); dot-sourced by `entity-writehelpers.ps1` |
| `private/entity-writehelpers.ps1` | Entity file read/write primitives (`Set-EntityTag`, `New-EntityBullet`, `Resolve-EntityTarget`, `Read-EntityFile`, `Write-EntityFile`, `Invoke-EnsureEntityFile`) |
| `private/entity-migrationhelpers.ps1` | Bootstrap migration (`ConvertTo-EntitiesFromPlayers`); dot-sourced by `migration/phase0-setup.ps1` |
| `private/charfile-helpers.ps1` | Character file parse/write for `Postaci/Gracze/*.md` |
| `private/format-sessionblock.ps1` | Shared Gen4 metadata block rendering |
| `private/admin-config.ps1` | Config resolution, template rendering |
| `private/admin-state.ps1` | Append-only history file read/write |
| `private/parse-markdownfile.ps1` | Single-file Markdown parser |

Data files:

| File | Purpose |
|---|---|
| `entities.md` | Base entity registry (lowest override primacy) |
| `entities-100-ent.md` | Override shard with primacy 100 |
| `maps-100-ent.md` | Mapa entity overflow file (~2,704 game-map entities, created by Phase 3) |
| `robot.psd1` | Module manifest |
| `robot.psm1` | Module loader (auto-discovers Verb-Noun `.ps1` files) |
| `templates/*.md.template` | Character file and player entry templates |
| `local.config.psd1` | Local config (git-ignored) |
| `.robot/res/migration-log.txt` | Structured diagnostic log (overwritten each run) |
| `.robot/res/all-sessions-to-review.md` | Session review artifact (Phase 5) |
| `.robot/res/review-additions/*.md` | New sessions from review import (Phase 5) |

---

## Related Documents

- [ENTITIES.md](ENTITIES.md) — Entity data model migrated from `Gracze.md`
- [SESSIONS.md](SESSIONS.md) — Session format generations (Gen1-Gen4)
- [SESSION-INTEGRITY.md](SESSION-INTEGRITY.md) — Session hash baseline (Phase 1)
- [CURRENCY.md](CURRENCY.md) — Currency entities created during Phase 7
- [PU.md](PU.md) — PU history migration

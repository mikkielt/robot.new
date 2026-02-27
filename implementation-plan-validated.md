# `.robot.new` Implementation Plan (Validated)

## 1) Purpose

Legacy `.robot/robot.ps1` mixes parsing/data extraction, CRUD edits in `Gracze.md`, operational admin tasks (monthly PU assignment, notifications, election list, wiki refresh, map checkups), and interactive controller/menu logic.

The new `.robot.new` module has a strong read/parse core (`Get-*`, `Resolve-*`, `Set-Session`, `New-Session`) but is missing most write/admin workflows from legacy.

This plan proposes a **phased migration** that:
- Migrates the write target from `Gracze.md` to `entities.md` from the start.
- Keeps backward-compatible read behavior (merging both sources via `Get-Player`).
- Aligns with `.robot.new/SYNTAX.md` conventions.
- Integrates existing but unplanned functions (`Get-GitChangeLog`, `Get-EntityState`) into admin workflows.

---

## 2) Key architectural decisions (from validation interview)

### 2.1 Write target: entities.md (not Gracze.md)

`Get-Player` already merges data from both `Gracze.md` and `entities.md`. Going forward:
- **`entities.md`** (and `*-NNN-ent.md` files) become the **primary write target** for all CRUD operations.
- **`Gracze.md`** becomes **read-only legacy** — still parsed by `Get-Player` for backward compatibility, but never written to by new commands.
- `Set-Player`, `Set-PlayerCharacter`, `New-PlayerCharacter` all write `@tag` entries into entity files.

### 2.2 @Intel is session-scoped only

The `@Intel` system in session metadata handles in-game intel tied to specific sessions. It does **not** replace the need for standalone webhook messaging unrelated to sessions or gameplay. A separate **structured messaging system** is needed for:
- Out-of-session administrative messages.
- Messages not tied to any specific session or game content.
- Template-based composition, recipient resolution via name index, delivery tracking, retry logic.

### 2.3 Discord notifications are actively used

Discord webhook notifications are a core part of the monthly workflow. They are **prioritized in Phase 2**, not deferred.

### 2.4 Interactive menu: ANSI/VT100 rich TUI

The interactive controller (`Invoke-NerthusController`) is retained alongside parameter-driven commands. The menu will use ANSI/VT100 escape codes for:
- Colored output, box-drawing characters, status indicators, styled headers.
- No external module dependencies — pure escape code rendering.

### 2.5 Get-GitChangeLog integration

`Get-GitChangeLog` (already in `.robot.new`) is integrated into admin workflows to optimize file scanning — e.g., only processing files changed since the last PU run, rather than full-repo scans.

### 2.6 Get-EntityState in PU workflow

The PU assignment workflow uses `Get-EntityState` (which merges entity file data with session Zmiany chronologically) rather than raw `Get-Entity` + `Get-Session` separately. This ensures the workflow sees fully resolved entity state.

### 2.7 Testing: manual first, Pester later

Phase 1-3 use fixture-based manual validation scripts. Pester test infrastructure is added in a future phase once core functionality is stable.

---

## 3) Existing `.robot.new` inventory (what's already built)

| File | Function(s) | Role |
|---|---|---|
| `get-reporoot.ps1` | `Get-RepoRoot` | Locates git repository root via .NET traversal |
| `parse-markdownfile.ps1` | (standalone script) | Single-file Markdown parser (headers, sections, lists, links) |
| `get-markdown.ps1` | `Get-Markdown` | Orchestrates Markdown parsing with optional RunspacePool parallelism |
| `resolve-name.ps1` | `Resolve-Name` + helpers | Multi-stage name resolution (exact, declension, stem-alternation, Levenshtein) |
| `get-player.ps1` | `Get-Player` | Parses `Gracze.md` + applies entity overrides from `entities.md` |
| `resolve-narrator.ps1` | `Resolve-Narrator` | Resolves narrator names from session headers to player objects |
| `get-nameindex.ps1` | `Get-NameIndex` + BK-tree | Token-based reverse lookup index with fuzzy matching |
| `get-gitchangelog.ps1` | `Get-GitChangeLog` | Stream-parses `git log` into structured commit objects |
| `get-entity.ps1` | `Get-Entity` + helpers | Parses entity registry files with temporal scoping and canonical names |
| `get-entitystate.ps1` | `Get-EntityState` | Merges entity file data with session Zmiany overrides |
| `get-session.ps1` | `Get-Session` + helpers | Parses session metadata (Gen1-Gen4 formats) with narrator/mention/intel resolution |
| `format-sessionblock.ps1` | `ConvertTo-Gen4MetadataBlock`, `ConvertTo-SessionMetadata` | Shared Gen4 rendering helpers (dot-sourced) |
| `new-session.ps1` | `New-Session` | Generates Gen4-format session markdown string |
| `set-session.ps1` | `Set-Session` + helpers | Modifies existing session metadata/content in Markdown files |
| `SYNTAX.md` | (documentation) | Coding style guide for the module |

---

## 4) Gap analysis (legacy -> new)

| Legacy capability | Legacy function(s) | New status | Migration target |
|---|---|---|---|
| Read players/characters | `Get-Player`, `Get-PlayerCharacter` | **Partial** | `Get-Player` exists; add `Get-PlayerCharacter` convenience wrapper |
| Update player metadata | `Set-Player` | **Missing** | Add `Set-Player` (writes to entities.md) |
| Update character PU/details | `Set-PlayerCharacter` | **Missing** | Add `Set-PlayerCharacter` (writes to entities.md) |
| Create character (+player bootstrap) | `New-PlayerCharacter` | **Missing** | Add `New-PlayerCharacter` (writes to entities.md) |
| Monthly PU assignment | `Invoke-PlayerCharacterPUAssignment` | **Missing** | Add (uses `Get-EntityState`, `Get-GitChangeLog`) |
| PU correctness check | `Invoke-..CorrectnessCheckup` | **Missing** | Add `Test-PlayerCharacterPUAssignment` |
| Session activity notifications | `Invoke-..SessionActivity*` | **Missing** | Add `Invoke-SessionActivityNotification` |
| Non-session webhook messages | `Invoke-..DiscordNotifications` | **Missing** | Add structured messaging system (`Send-DiscordMessage`, `Invoke-DiscordMessageQueue`) |
| New character PU estimator | `Invoke-NewPlayerCharacterPUCount` | **Missing** | Add `Get-NewPlayerCharacterPUCount` |
| Election list report | `Get-ElectionPlayerList` | **Missing** | Add `Get-ElectionPlayerList` |
| Wiki page regeneration | `New-PlayerCharacterWikiArticle` | **Missing** | Add `Update-PlayerCharacterWikiArticle` |
| Map external checkup | `Invoke-MapCheckup` | **Missing** | Optional isolated module |
| Interactive controller | `Invoke-NerthusController` | **Missing** | Add with ANSI/VT100 rich TUI |
| Git-optimized file scanning | (manual git config in legacy) | **Available** | `Get-GitChangeLog` already exists, needs integration |
| Entity state with session overrides | (not in legacy) | **Available** | `Get-EntityState` already exists, needs integration |

---

## 5) Design principles

1. **Reuse new parsers/indexing first.**
   Use `Get-Session`, `Get-Player`, `Get-Entity`, `Get-EntityState`, `Resolve-Name`, `Set-Session`, `Get-Markdown`, `Get-GitChangeLog` instead of legacy string heuristics.

2. **Write to entities.md, read from both.**
   All CRUD writes target entity files. `Gracze.md` is read-only legacy, still parsed by `Get-Player` for backward compatibility.

3. **Separate pure planning from side effects.**
   `Get-*Plan`/`Test-*` for computation (pure output), `Invoke-*` for apply/send (writes + network).

4. **Preserve idempotency behavior.**
   Keep `.robot/res/*.md` append-only logs in migration phase. Wrap in helper API.

5. **Use ShouldProcess + WhatIf consistently.**
   All write/send commands support `SupportsShouldProcess`.

6. **Move secrets/config out of code.**
   Replace hardcoded webhook/token values with env/config file resolution.

7. **.NET over cmdlets** (per SYNTAX.md).
   File I/O, collections, string comparison, regex — all use .NET static methods.

8. **PascalCase everything** (per SYNTAX.md).
   Variables, parameters, function names all PascalCase. `[void]` for output suppression.

---

## 6) Proposed module structure additions

### 6.1 New command files

| File | Function | Phase |
|---|---|---|
| `get-playercharacter.ps1` | `Get-PlayerCharacter` | 1 |
| `set-player.ps1` | `Set-Player` | 1 |
| `set-playercharacter.ps1` | `Set-PlayerCharacter` | 1 |
| `new-playercharacter.ps1` | `New-PlayerCharacter` | 1 |
| `invoke-playercharacterpuassignment.ps1` | `Invoke-PlayerCharacterPUAssignment` | 2 |
| `test-playercharacterpuassignment.ps1` | `Test-PlayerCharacterPUAssignment` | 2 |
| `get-newplayercharacterpucount.ps1` | `Get-NewPlayerCharacterPUCount` | 2 |
| `send-discordmessage.ps1` | `Send-DiscordMessage` | 2 |
| `invoke-sessionactivitynotification.ps1` | `Invoke-SessionActivityNotification` | 3 |
| `invoke-discordmessagequeue.ps1` | `Invoke-DiscordMessageQueue` | 3 |
| `get-electionplayerlist.ps1` | `Get-ElectionPlayerList` | 3 |
| `update-playercharacterwikiarticle.ps1` | `Update-PlayerCharacterWikiArticle` | 3 |
| `invoke-nerthuscontroller.ps1` | `Invoke-NerthusController` | 4 |
| `invoke-mapcheckup.ps1` | `Invoke-MapCheckup` | 4 (optional) |

### 6.2 Shared non-exported helpers (dot-sourced, non-Verb-Noun)

| File | Purpose |
|---|---|
| `admin-config.ps1` | Resolve repo paths for `.robot/res/*`, resolve webhooks from env/config, expose templates |
| `admin-state.ps1` | Read/write append-only history files, normalize/dedupe session header keys |
| `entity-writehelpers.ps1` | Entity file writing: append/update `@tag` entries in `entities.md` / `*-NNN-ent.md` |
| `discord-helpers.ps1` | Message composition, template rendering, delivery tracking, retry logic |
| `tui-helpers.ps1` | ANSI/VT100 escape code rendering: box-drawing, colors, status indicators, styled headers |

---

## 7) Detailed implementation by capability

### 7.1 CRUD domain (players/characters)

#### A) `Get-PlayerCharacter`

Purpose: typed projection from `Get-Player`.

```powershell
Get-PlayerCharacter [-PlayerName <string[]>] [-CharacterName <string[]>] [-Entities <object[]>]
```

Behavior:
- Flatten `Get-Player` output into character rows with `PlayerName` backreference.
- Preserve links to parent player object.
- Support exact/CI filtering by player and character name.
- Pass-through `-Entities` to avoid redundant parsing.

---

#### B) `Set-Player`

Purpose: update player-level fields by writing to entities.md.

```powershell
Set-Player -Name <string> [-PRFWebhook <string>] [-MargonemID <string>]
  [-Triggers <string[]>] [-WhatIf]
```

Implementation notes:
- Writes `@prfwebhook`, `@margonemid`, `@trigger` tags to the player's entity entry in entities.md.
- If the player has no entity entry yet, creates one under `## Gracz` section.
- Uses `entity-writehelpers.ps1` for file manipulation.
- Validates Discord webhook URL format (`https://discord.com/api/webhooks/*`).
- `SupportsShouldProcess`.

Note: Player **renaming** is not supported via entity overrides (entity names are identity keys). Renaming requires a separate migration utility if ever needed.

---

#### C) `Set-PlayerCharacter`

Purpose: update PU and character metadata by writing to entities.md.

```powershell
Set-PlayerCharacter -PlayerName <string> -CharacterName <string>
  [-PUExceeded <decimal>] [-PUStart <decimal>] [-PUSum <decimal>] [-PUTaken <decimal>]
  [-Aliases <string[]>] [-WhatIf]
```

Implementation notes:
- Writes `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`, `@alias` tags.
- Uses the same derivation rule as `Complete-PUData`:
  - If SUMA present and ZDOBYTE missing -> derive ZDOBYTE.
  - If ZDOBYTE present and SUMA missing -> derive SUMA.
- If the character has no entity entry yet, creates one under `## Postac (Gracz)` with `@nalezy_do: <PlayerName>`.
- `SupportsShouldProcess`.

---

#### D) `New-PlayerCharacter`

Purpose: create character for existing player or bootstrap new player entry.

```powershell
New-PlayerCharacter -PlayerName <string> -CharacterName <string>
  [-CharacterSheetUrl <string>] [-InitialPUStart <decimal>] [-WhatIf]
```

Behavior:
- Creates entity entry under `## Postac (Gracz)` with:
  - `@nalezy_do: <PlayerName>`
  - `@pu_startowe: <InitialPUStart>` (or computed via `Get-NewPlayerCharacterPUCount`)
- If player has no entity entry yet, also creates one under `## Gracz`.
- Creates/updates `Postaci/Gracze/<Character>.md` from template.
- `SupportsShouldProcess`.

---

### 7.2 Entity file writing strategy

Since writes now target `entities.md` (and `*-NNN-ent.md`), a dedicated helper (`entity-writehelpers.ps1`) handles:

1. **Locating an entity** in a file by name under a type section.
2. **Appending a new `@tag: value`** line as a child bullet of an existing entity.
3. **Updating an existing `@tag`** value (replacing the last occurrence).
4. **Creating a new entity bullet** under the correct `## Type` section header.
5. **Creating a new type section** if none exists in the file.

The helper uses `Get-Markdown` for parsing and raw line manipulation for writing (same approach as `Set-Session` — parse boundaries, then reconstruct via `StringBuilder`/line arrays and `[System.IO.File]::WriteAllText`).

---

### 7.3 Admin PU workflows

#### A) `Invoke-PlayerCharacterPUAssignment`

Purpose: monthly/date-range PU awarding with optional write + notifications.

```powershell
Invoke-PlayerCharacterPUAssignment [-Year <int>] [-Month <int>]
  [-MinDate <datetime>] [-MaxDate <datetime>] [-PlayerName <string[]>]
  [-UpdatePlayerCharacters] [-SendToDiscord] [-AppendToLog] [-Confirm]
```

Computation (preserve legacy semantics):
1. Source sessions: `Get-Session` in date range with PU entries.
2. **Optimization**: Use `Get-GitChangeLog -MinDate -MaxDate -NoPatch` to pre-filter to files with commits in the date range, then pass those files to `Get-Session -File`.
3. Exclude already-processed session headers from `.robot/res/pu-sessions.md` (via `admin-state.ps1` helper).
4. Resolve characters via `Get-EntityState` (fully merged entity state including session Zmiany).
5. For each character:
   - `BasePU = 1 + Sum(sessionPU)`
   - If `BasePU < 5` and has `PUExceeded > 0`, consume overflow: `UsedExceeded = Min(5 - BasePU, PUExceeded)`
   - If `BasePU > 5`, overflow becomes new `PUExceeded`: `Overflow = BasePU - 5`
   - Granted PU capped at 5.
   - `RemainingPUExceeded = (OriginalPUExceeded - UsedExceeded) + Overflow`
   - Update `PUTaken += GrantedPU`, recompute `PUSum`.
6. Build per-character message payload.

Side effects (gated by switches):
- `-UpdatePlayerCharacters`: call `Set-PlayerCharacter` (writes to entities.md).
- `-AppendToLog`: append processed headers with timestamp to `.robot/res/pu-sessions.md`.
- `-SendToDiscord`: send per-player notifications via `Send-DiscordMessage`.

---

#### B) `Test-PlayerCharacterPUAssignment`

Purpose: detect unresolved character names and PU assignment inconsistencies.

Behavior:
- Run assignment in compute-only mode for last month.
- Report: unknown character names, malformed PU values, duplicate anomalies, unresolvable entities.
- Return structured diagnostic objects (not just console output).

---

#### C) `Get-NewPlayerCharacterPUCount`

Purpose: estimate initial PU for a new character.

Formula (legacy-compatible):
```
Include only characters with PUStart > 0
PU = Floor((Sum(PUTaken) / 2) + 20)
```

```powershell
Get-NewPlayerCharacterPUCount -PlayerName <string> [-SendToDiscord]
```

---

### 7.4 Notifications

#### A) `Send-DiscordMessage`

Purpose: low-level Discord webhook message sender.

```powershell
Send-DiscordMessage -Webhook <string> -Message <string> [-Username <string>]
```

Implementation:
- POST to webhook URL with JSON body (`content`, `username`).
- Validate webhook URL format.
- Return response or throw on failure.
- No retry logic at this level (handled by queue system).

---

#### B) Structured messaging system (`Invoke-DiscordMessageQueue`)

Purpose: template-based message composition and delivery with tracking.

```powershell
Invoke-DiscordMessageQueue [-Source <string>] [-MinDate <datetime>]
  [-SendToDiscord] [-AppendToLog] [-WhatIf]
```

Components:
- **Message templates**: stored in `.robot.new/templates/` or `admin-config.ps1`.
- **Recipient resolution**: via `Resolve-Name` and name index to find webhook URLs.
- **Delivery tracking**: append-only state file (`.robot/res/discord-messages.md`) via `admin-state.ps1`.
- **Retry logic**: configurable retry count with backoff on HTTP failure.
- **Idempotency**: skip messages whose tracking key already exists in state file.

---

#### C) `Invoke-SessionActivityNotification`

Legacy equivalent: `Invoke-PlayerCharacterSessionActivityDiscordNotification*`.

```powershell
Invoke-SessionActivityNotification [-MinDate <datetime>] [-SessionHeader <string>]
  [-SendToDiscord] [-AppendToLog] [-Confirm]
```

Behavior:
- Find sessions with PU entries since `-MinDate`.
- Skip headers already in `.robot/res/player-character-session-activity-discord-notifications.md`.
- Optional filter by `-SessionHeader`.
- Send message per PU entry to owner's PRF webhook via `Send-DiscordMessage`.

---

### 7.5 Reporting/admin outputs

#### A) `Get-ElectionPlayerList`

Legacy behavior to preserve:
- Period: last 6 full months.
- Include only sessions present in PU assignment history log.
- Score = `Sum(sessionPU) + (number of active months with sessions)`.
- `VotingEligible = (PU >= 3.0)`.

Return structured objects; formatting left to caller.

---

#### B) `Update-PlayerCharacterWikiArticle`

Legacy equivalent: `New-PlayerCharacterWikiArticle`.

```powershell
Update-PlayerCharacterWikiArticle [-WhatIf]
```

Behavior:
- Target file: `Nerthus/Informacje/Postaci Graczy.md` (in MkDocs nav).
- Compute last activity from sessions and PU data.
- Fill "Postaci aktywne" (last 12 months) and "Postaci pozostale".
- Stamp update date.

Operational note: updating this file triggers the pages pipeline via `.gitlab-ci.yml` (scoped to `Nerthus/**/*`).

---

### 7.6 Interactive controller

#### `Invoke-NerthusController`

ANSI/VT100 rich TUI with:
- Box-drawn menu borders.
- Colored section headers and status indicators.
- Numbered option selection.
- Live progress/status during operations.
- Success/failure result summaries with color coding.

Helper file: `tui-helpers.ps1` (dot-sourced, non-Verb-Noun) providing:
- `Write-TUIBox`: renders a bordered box with title.
- `Write-TUIMenu`: renders numbered option list with optional descriptions.
- `Write-TUIStatus`: renders status line with icon (checkmark, cross, spinner).
- `Write-TUIHeader`: renders styled section header.
- ANSI color/style constants (`$TUI_Green`, `$TUI_Bold`, `$TUI_Reset`, etc.).

All rendering uses raw ANSI escape sequences — no external module dependencies.

---

### 7.7 Optional external admin module

#### `Invoke-MapCheckup` (Phase 4, optional)

Network-heavy, non-lore external dependencies — kept isolated:
- Fetch maps list from MargoWorld/Garmory APIs.
- Compare against `.robot/res/maps.md`.
- Append diffs and optionally notify repository webhook.

Excluded from core lore pipeline tests.

---

## 8) State/config strategy

### 8.1 Append-only file-based journals

Retain `.robot/res/*.md` format for continuity. Helper API in `admin-state.ps1`:

```powershell
# Read processed headers from a state file
Get-AdminHistoryEntries -Path <string>

# Append new entries with timestamp
Add-AdminHistoryEntry -Path <string> -Headers <string[]>
```

Header normalization: trim whitespace, collapse multiple spaces, strip `### ` prefix before comparison.

### 8.2 Secrets/config resolution

Priority order:
1. Explicit parameter (e.g. `-Webhook`).
2. Environment variable (e.g. `$env:NERTHUS_REPO_WEBHOOK`).
3. Local ignored config file (`.robot.new/local.config.psd1`, git-ignored).
4. Fail with clear error message.

Helper in `admin-config.ps1`:

```powershell
function Get-AdminConfig {
    # Returns hashtable with resolved config values
    # Throws if required values are missing
}
```

### 8.3 Templates

Move legacy templates from `.robot/robot-data.ps1` into `.robot.new/templates/` as standalone files:
- `player-character-file.md.template`
- `player-character-wiki-article.md.template`
- `player-entry.md.template`

Template rendering via simple `$Variable` substitution in `admin-config.ps1`.

---

## 9) Rollout phases

### Phase 1 — CRUD foundation (entities.md as write target)

Deliver:
- `entity-writehelpers.ps1` (shared helper for entity file manipulation)
- `Get-PlayerCharacter`
- `Set-Player` (writes to entities.md)
- `Set-PlayerCharacter` (writes to entities.md)
- `New-PlayerCharacter` (writes to entities.md)
- `admin-config.ps1` (config resolution + templates)

Acceptance:
- Entity entries created/updated correctly in entities.md.
- `Get-Player` returns merged data from both Gracze.md + entities.md (already works).
- `-WhatIf` works for all write commands.
- Manual validation against representative fixtures.

### Phase 2 — PU admin core + Discord

Deliver:
- `admin-state.ps1` (state file helpers)
- `Invoke-PlayerCharacterPUAssignment` (with `Get-EntityState` + `Get-GitChangeLog` integration)
- `Test-PlayerCharacterPUAssignment`
- `Get-NewPlayerCharacterPUCount`
- `Send-DiscordMessage`

Acceptance:
- Same granted PU outputs as legacy for sample months.
- `Get-GitChangeLog` optimization measurably reduces file scan scope.
- Discord messages sent correctly via webhook.
- State file append/dedup works correctly.

### Phase 3 — Notifications + reports + structured messaging

Deliver:
- `discord-helpers.ps1` (message templates, tracking, retry)
- `Invoke-SessionActivityNotification`
- `Invoke-DiscordMessageQueue`
- `Get-ElectionPlayerList`
- `Update-PlayerCharacterWikiArticle`

Acceptance:
- Idempotent repeat run (no duplicate sends when logs exist).
- Wiki page updates and remains MkDocs-compatible.
- Election list output matches legacy formula.
- Message queue delivers with retry and tracking.

### Phase 4 — Interactive TUI + optional modules

Deliver:
- `tui-helpers.ps1` (ANSI/VT100 rendering)
- `Invoke-NerthusController` (rich interactive menu)
- `Invoke-MapCheckup` (optional)
- Legacy command name compatibility wrappers (optional)

Acceptance:
- Menu renders correctly in PowerShell 7+ terminals.
- All menu options invoke the correct underlying commands.
- Operator can complete full monthly workflow via menu.

### Future — Pester test infrastructure

Deliver:
- Pester test setup and conventions.
- Unit tests for core helpers (entity-writehelpers, admin-state, PU calculation).
- Integration tests with fixture data.

---

## 10) Risks and mitigations

1. **Entity file write fragility**
   Mitigation: boundary-based section editing (same approach as `Set-Session`). Parse with `Get-Markdown`, manipulate via line arrays, write with `[System.IO.File]::WriteAllText`. Never broad regex replacements.

2. **Dual-source read complexity (Gracze.md + entities.md)**
   Mitigation: `Get-Player` already handles merging. Write commands only target entities.md. Over time, Gracze.md data migrates to entities.md entries, reducing duality.

3. **Duplicate sends/awards**
   Mitigation: centralize state log helpers in `admin-state.ps1` with header normalization. All notification/PU commands check state before acting.

4. **Config/secret leakage**
   Mitigation: remove hardcoded webhook/token usage. Enforce env/config resolution via `admin-config.ps1`. Git-ignore local config file.

5. **Behavior drift from legacy algorithms**
   Mitigation: lock algorithm parity for PU calculation and election list in Phase 2 before any refactors. Validate against historical months.

6. **CI mismatch with docs publishing**
   Mitigation: ensure `Update-PlayerCharacterWikiArticle` writes to `Nerthus/Informacje/Postaci Graczy.md` (within `.gitlab-ci.yml` pages trigger scope).

7. **ANSI/VT100 terminal compatibility**
   Mitigation: TUI helpers detect terminal capabilities. Degrade gracefully to plain text on unsupported terminals.

---

## 11) Execution order (first implementation slice)

1. Implement `entity-writehelpers.ps1` — the foundation all CRUD writes depend on.
2. Implement `Get-PlayerCharacter` (simple wrapper, unblocks downstream testing).
3. Implement `Set-PlayerCharacter` with `SupportsShouldProcess` — highest-impact write command (PU assignment depends on it).
4. Implement `Set-Player` — follows same pattern as Set-PlayerCharacter.
5. Implement `Invoke-PlayerCharacterPUAssignment` compute-only path + `-AppendToLog`.
6. Add `Send-DiscordMessage` and wire `-SendToDiscord` + `-UpdatePlayerCharacters` paths.
7. Verify PU assignment against one historical month.
8. Implement `Update-PlayerCharacterWikiArticle` to restore end-to-end monthly workflow.
9. Add notification commands after core data correctness is stable.
10. Implement TUI and interactive controller last.

---

## 12) Changes from original plan

| Area | Original plan | Validated plan | Reason |
|---|---|---|---|
| Write target | Gracze.md | entities.md | User decision: progressive migration to entities.md |
| Migration timing | Phase 1 writes Gracze.md | Phase 1 writes entities.md immediately | User decision: start clean |
| Get-GitChangeLog | Not mentioned | Integrated into PU workflow | Already exists, optimizes file scanning |
| Get-EntityState | Not mentioned | Used by PU workflow | Provides fully merged entity state |
| @Intel vs Komunikaty.md | Merged into one function | Separate systems | @Intel is session-scoped; non-session messages need structured system |
| Discord notifications | Phase 3 | Phase 2 | Actively used, prioritized |
| Interactive menu | Optional, simple | Required, ANSI/VT100 rich TUI | User preference for "bombastic" UI |
| Webhook messaging | Simple Send function | Structured system with templates/tracking/retry | User decision |
| Helper file: player-writehelpers.ps1 | Gracze.md section editing | `entity-writehelpers.ps1` (entity file editing) | Follows write target change |
| Testing | Manual validation only | Manual first, Pester later | User decision |
| Session Mentions system | Not referenced | Documented as available (not yet integrated) | Exists in Get-Session but no workflow uses it yet |

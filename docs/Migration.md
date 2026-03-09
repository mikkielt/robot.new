# Migration - Transition to the New Data and Session Management

## Purpose

This migration introduces a reliable, structured way to manage player data, character records, and session metadata. It replaces the manual-edit workflow with a system that validates updates, prevents duplicates, tracks processing history, and sends notifications automatically. The goal is less manual correction, fewer missed updates, and a clear audit trail.

## Scope

**What is included:**

- How player and character data is now stored and updated
- How session records transition to the new structured format
- How monthly PU assignments work under the new system
- What changes for narrators, coordinators, and players
- What the system tracks and verifies automatically
- How to handle errors and edge cases
- Currency tracking (new capability)
- Location name verification during migration
- Narrator name verification during migration

**What is excluded:**

- Low-level technical details (file parsers, data structures, internal algorithms)
- Development setup and contributing guidelines (see the technical docs in `devdocs/`)
- Step-by-step PowerShell commands (see [MIGRACJA-TECH.md](PL/MIGRACJA-TECH.md) for procedural details)

## Actors and Responsibilities

### Coordinator

- Initiates the one-time data migration from the legacy player file to the new entity store
- Runs the monthly PU assignment process
- Reviews diagnostic reports for data quality issues (unresolved names, stale records)
- Upgrades session records to the current format when needed
- Reviews location name reports and resolves conflicts
- Maintains player webhook addresses for notifications
- Manages the currency system (treasury, reconciliation)

### Narrator

- Documents sessions in the current metadata format (locations, logs, PU awards, changes, intel, transfers)
- Ensures character names in PU entries match known characters exactly
- Records world changes (Zmiany) in sessions so they are automatically applied to entity state
- Registers currency transfers between characters via `@Transfer` directives

### Player

- Receives PU assignment notifications via Discord
- Sees updated character records (PU totals, status, reputation) without manual intervention
- Provides initial currency balances during migration (one-time form)
- Can request new characters or report issues to the coordinator

## Architecture

### Dual Data Store

The new system operates on two data sources simultaneously:

| Store | File | Access | Role |
|---|---|---|---|
| **Legacy** | `Gracze.md` | Read-only | Historical player database. Never modified by the new system. |
| **Entity registry** | `entities.md` | Read + Write | Canonical write target for all CRUD operations. |

When reading data (e.g. `Get-Player`), the system merges both sources in memory - entities from `entities.md` override values from `Gracze.md` where they exist. This means no data is lost during transition, and the switch is gradual.

### Data Manifest

The file `.robot/robot-data.psd1` tells the module where to find `entities.md`. Without it, some commands would default to writing inside the `.robot.new` directory instead of the repository root. The migration script creates this manifest automatically during Phase 0.

### Session Format Generations

Session records exist in four format generations, accumulated over the project's history:

| Period | Format | Characteristics |
|---|---|---|
| Before 2022 | Gen1 (plain text) | No structured metadata, log links inline |
| 2022-2023 | Gen2 (italic locations) | Location line formatted in italic, log links inline |
| 2024-2025 | Gen3 (structured lists) | Location, logs, PU, and changes as list items |
| 2026 onward | Gen4 (current format) | All metadata prefixed with `@` markers for unambiguous parsing |

**All four formats remain readable** - the system auto-detects and parses each one transparently. No data is lost if older sessions are left in their original format.

## Migration Phases

The migration is divided into 7 phases (0-6). Not all require involvement from the entire team.

| Phase | What happens | Who is involved | Duration |
|---|---|---|---|
| **0. Przygotowanie i bootstrap** | Safety backup, module verification, data manifest, generate entity store | Coordinator | 1-2 days |
| **1. Baseline integralności sesji** | Compute and store baseline session content hashes | Coordinator | 1 day |
| **2. Walidacja i naprawa danych** | Verify data parity, fix typos, date errors, missing aliases, extended diagnostics | Coordinator, narrators | 3-5 days |
| **3. Import lokalizacji z mapy** | Import game-map locations as entities, review overrides | Coordinator | 2-3 days |
| **4. Upgrade formatu sesji** | Upgrade active session files to Gen4 format | Coordinator | 1-2 days |
| **5. Enrollment walut** | Collect and register currency balances | Everyone | ~1 week |
| **6. Przełączenie (cutover)** | Parallel period, verification, official switch to the new system | Coordinator | 2-4 weeks |

**Total estimated time**: 4-6 weeks, most of which is the parallel/cutover period.

**Diagnostic log**: Each migration run produces a diagnostic log file in `.robot/res/`. This log captures every step, warning, and error with timestamps and detailed repair instructions. The log is overwritten on each run and contains results from the last run only. The coordinator can review this file after running the migration to see all issues that were encountered and their suggested fixes.

### Phase 0 - Przygotowanie i bootstrap

The coordinator secures the current state before any changes, then generates the entity store from legacy data. This phase combines preparation and bootstrap into a single step (`phase0-setup.ps1`):

1. **Verify clean git state** - no uncommitted changes allowed before migration starts
2. **Create safety tag** (`pre-migration`) - provides a rollback point to the exact pre-migration state
3. **Verify PU state file** - the processing history file (`pu-sessions.md`) is preserved and continues to be used
4. **Verify submodule** - `.robot.new` must be registered as a git submodule
5. **Verify module** - confirm all commands are available
6. **Create data manifest** - `.robot/robot-data.psd1` ensures all commands write to the correct `entities.md` location
7. **Generate entity store** - reads all current player and character data from the existing player database and writes it into `entities.md`. The system creates one new file containing all players, their characters, and associated metadata (PU values, aliases, group memberships). The original player database remains untouched. Additional entity sections (NPC, Group, Location, Item) are added for future use.

### Phase 1 - Baseline integralności sesji

A read-only phase that computes and stores baseline SHA-256 content hashes for all session files (`phase1-session-hashes.ps1`). These hashes provide tamper detection and change tracking for session content going forward. The baseline is stored in `.robot/res/session-hashes/` and serves as the reference point for the `Test-SessionIntegrity` validator.

### Phase 2 - Walidacja i naprawa danych

This phase combines data parity validation with diagnostics and data repair (`phase2-validation.ps1`). It first verifies the new system correctly reads and merges data from both sources, then iteratively fixes issues surfaced by the stricter validation:

**Validation checks:**

- Player and character counts match expectations
- PU values match the original data (spot-checked)
- Aliases transferred correctly
- Players without webhook addresses identified
- Diagnostic tool run to surface any issues

**Diagnostics and repair:**

The new system is stricter about data validation. Issues that the old system silently ignored now surface as errors. This sub-phase fixes known problems iteratively:

- **Unresolved character names** - typos in session PU entries, fixed by correcting the name or adding an alias
- **Malformed session dates** - dates like `2025-6-15` corrected to `2025-06-15`
- **Duplicate PU entries** - same character listed multiple times in one session
- **Characters with PU = BRAK** - decision to mark as inactive or supply missing values
- **Stale history entries** - old session headers in the processing log that no longer match existing sessions (informational, non-blocking)

Additionally, a narrator report identifies raw narrator names from session headers that do not resolve to known players, allowing the coordinator to add normalization mappings.

The coordinator runs diagnostics, fixes issues, re-runs diagnostics, and repeats until the diagnostic tool returns OK.

### Phase 3 - Import lokalizacji z mapy

The coordinator imports all game-map locations into the entity store (`phase3-location-import.ps1`). This produces two entity types using a two-pass workflow:

**Mapa entities (concrete game maps):** The system reads the full map registry (~2,704 entries) and creates a Mapa entity for each one. Each Mapa entity records the Margonem map ID, map type (exterior/interior), CDN image URL, and tile dimensions. These are written to a dedicated overflow file (`maps-100-ent.md`) to keep the main `entities.md` manageable.

**Lokacja entities (conceptual locations):** The system infers parent-child relationships from naming conventions (e.g. "Piekielna Grota p.2" is a child of "Piekielna Grota") and derives deduplicated Lokacja entities from the hierarchy's unique base names. These represent the conceptual places — fewer than the total map count — and are written to `entities.md`.

**Coordinator review (second pass):** The system exports a tab-separated override file listing all imported maps. The coordinator edits this file to:

- Add Nerthus-specific names for maps that use different names in the RP setting (applied as `@nazwa_nerthus` on Mapa entities)
- Add virtual locations that exist only in the Nerthus setting (created as Lokacja entities)

After editing, the coordinator re-runs the phase to apply the overrides. The phase completes when the Mapa import, Lokacja derivation, and override steps are all done.

> This phase must run before the session format upgrade (Phase 4) because the location review step in Phase 4 expects Location entities to already exist.

### Phase 4 - Upgrade formatu sesji

The coordinator upgrades active session files from Gen1/Gen2/Gen3 to the current Gen4 format (`phase4-session-upgrade.ps1`). The upgrade changes **only metadata structure** - narrative text and special blocks (clarifications, effects, rewards) are preserved.

| Before | After |
|---|---|
| `- Lokalizacje:` | `- @Lokacje:` |
| `- Logi: URL` | `- @Logi:` + `    - URL` |
| `- PU:` | `- @PU:` |
| `*Lokalizacja: A, B*` (Gen2) | `- @Lokacje:` + `    - A` + `    - B` |

**Error handling**: If a particular file fails during upgrade (e.g. a malformed session header), processing continues with the remaining files. A summary of failed files is displayed at the end. Headers with irregular whitespace (e.g. double spaces after `###`) are normalized automatically.

**Narrator verification**: After the format upgrade, narrator names are verified against normalization mappings. Sessions with unresolved narrator names are flagged for review.

**Location name review**: After the format upgrade, a location report analyzes all location names used in active sessions. It compares them against registered Location entities and flags:

- **Unresolved locations** - names that don't match any registered entity. The coordinator must either create the missing entity or mark the value as a non-location (e.g. "na zewnątrz", "w drodze").
- **Warnings** - fuzzy matches, case variants, or hierarchy inconsistencies. Shown for awareness but don't block the process.

Non-location exclusions are stored in `.robot/res/location-exclusions.txt` and persist across re-runs. The commit step is blocked until all truly unresolved locations are handled.

**Session review file**: After the format upgrade and location review, a review file (`all-sessions-to-review.md`) is generated in `.robot/res/`. This file contains every session sorted chronologically, with source file paths embedded as HTML comments. The coordinator can:

- **Edit** session content directly in the review file (fix typos, upgrade old formats, correct metadata)
- **Delete** session blocks to remove them from source files
- **Add** new session blocks (these are placed in `.robot/res/review-additions/` for manual integration)

On subsequent runs of Phase 4, the coordinator can choose to **apply** edits from the review file back to source files, **regenerate** the review file, or **refresh hashes** after manual source edits. The review workflow is optional — Phase 4 can complete without it.

### Phase 5 - Enrollment walut

The currency system is an entirely new capability. This phase sets up the initial state (`phase5-currency.ps1`):

1. **Coordinator treasury** - a group entity (`Skarbiec Koordynatorów`) with initial reserves in three denominations:
   - **Korona** (gold) - 1 Korona = 100 Talarow
   - **Talar** (silver) - 1 Talar = 100 Kogow
   - **Kog** (copper) - base unit

2. **Player balances** - collected via a one-time form sent to players, then registered through commands or a technical initialization session

3. **Narrator budgets** - currency reserves allocated to narrators for distribution during sessions

4. **Verification** - a currency report and reconciliation check confirm all balances are consistent

Currency transfers during gameplay are registered by narrators in sessions via `@Transfer` directives.

### Phase 6 - Przełączenie (cutover)

This phase combines the parallel period and the official cutover into a single phase (`phase6-cutover.ps1`).

**Parallel period:** For 2-4 weeks, both the old and new systems run simultaneously. The coordinator runs PU assignment through both and compares results. During this period:

- **PU assignments** are compared between systems - results must match
- **New sessions** are written in Gen4 format by narrators
- **New characters** are created exclusively through the new system
- **Old sessions** remain readable without modification

**Cutover criteria** (all must be met before switching over):

- At least one full PU cycle with identical results from both systems
- All active narrators using Gen4 format
- Diagnostics clean (OK = true)
- Currency reconciliation without critical warnings

**Cutover steps** - the official switch to the new system as the sole operational tool:

1. **Final PU verification** - confirm diagnostics are clean
2. **Freeze Gracze.md** - add a read-only notice; the file becomes a historical archive
3. **Mark old system as deprecated**
4. **First standalone PU assignment** through the new system with full effects (entity updates, Discord notifications, history logging)
5. **Announce to the team**
6. **Create post-migration tag**

## Inputs Required

### For the initial migration

- Access to the existing player database (`Gracze.md`) - read-only, never modified
- A working copy of the repository with the `.robot.new` module available

### For ongoing operations

- Session files with proper headers (`### YYYY-MM-DD, Title, Narrator`) and metadata blocks
- Player webhook addresses for Discord notifications (optional but recommended)
- Character names that match registered names or aliases exactly

## Step-by-Step Flow: Ongoing Operations

### Recording a Session (Narrator)

The narrator documents each session using the current format:

- **Session header**: date, title, and narrator name
- **Locations** (`@Lokacje`): where the session took place
- **Logs** (`@Logi`): link(s) to the session transcript
- **PU awards** (`@PU`): each participating character and their earned PU value
- **Changes** (`@Zmiany`): world-state updates applied to entities (NPCs, groups, locations)
- **Intel** (`@Intel`): targeted information sent to specific recipients (individuals, groups, or locations)
- **Transfers** (`@Transfer`): currency transactions between characters

### Monthly PU Assignment (Coordinator)

1. The coordinator initiates the monthly PU assignment for the target period (typically the previous one or two months).

2. **The system scans sessions** in the date range, skipping any already processed (tracked in the history log).

3. **Character names are verified** against the player roster. If any name cannot be matched, the process stops immediately - no PU is awarded and no notifications are sent. The coordinator must fix the unrecognized names before retrying.

4. **PU is calculated** for each character:
   - Base PU = 1 (universal monthly base) + sum of session PU values
   - Monthly cap: 5 PU maximum
   - Excess PU above the cap is stored in the character's overflow pool
   - If a character earned less than 5 PU, the overflow pool supplements the difference (up to the cap)

5. **Results are applied** (when the coordinator confirms):
   - Character PU totals are updated in the entity store
   - Discord notifications are sent to each player's webhook, grouped by player
   - Processed session headers are logged in the history file

### Adding a New Player (Coordinator)

- The coordinator registers a new player with their basic information (Margonem ID, optional webhook address).
- The system validates that no duplicate player exists.
- Optionally, a first character can be created at the same time.

### Adding a New Character (Coordinator)

- A new character is created for an existing player.
- Starting PU is calculated automatically based on the player's other characters: half of their total earned PU plus 20, rounded down. New players start at 20 PU.
- A character file is created from the standard template.
- The character is registered in the entity store with ownership and starting PU.

### Removing a Character (Coordinator)

- Character removal is a soft operation - the character is marked as removed with an effective date, but no data is physically deleted.
- Removed characters stop appearing in standard queries but remain in the system for historical accuracy.
- This action requires explicit confirmation due to its significance.

## Expected Outcomes

After migration is complete:

1. **Single source of truth for mutable data** - all updates go to the entity store; the legacy file stays frozen as a read-only archive.

2. **Backward-compatible reading** - queries merge both old and new data transparently. No information is lost.

3. **Consistent session format** - new sessions use the current structured format; older sessions remain readable.

4. **Automated PU processing** - monthly PU assignment is calculated, validated, applied, and notified in one operation with full audit trail.

5. **Data quality enforcement** - unresolved character names block PU assignment; diagnostic tools surface stale records, duplicate entries, and parsing failures.

6. **Location verification** - location names in sessions are checked against the entity registry; conflicts and unresolved names are surfaced during migration.

7. **Currency tracking** - three-denomination currency system with per-entity balances, session-based transfers, and reconciliation.

8. **Clear audit trail** - every PU assignment is logged with timestamps and processed session headers.

## Rollback Plan

The migration is designed to be reversible at every stage:

| Level | Scenario | Action |
|---|---|---|
| **Single operation** | One PU assignment gave wrong results | `git revert HEAD` |
| **Specific phase** | A phase introduced bad data | `git revert <commit>` |
| **Session upgrade** | Format upgrade caused issues in a file | `git checkout pre-migration -- "path/to/file.md"` |
| **Full rollback** | Critical failure requiring complete reversal | `git reset --hard pre-migration` (destructive - last resort) |

**Key safety guarantee**: the new system **never modifies** `Gracze.md`. The old system always has access to its unmodified database. The `pre-migration` git tag provides a complete snapshot of the pre-migration state.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Unresolved character name in PU** | The entire PU assignment stops before any changes are made | Fix the character name in the session file (typo, missing alias) and retry |
| **Session with unparseable date** | The session is skipped silently during PU assignment | Run the diagnostic tool to surface these sessions; fix the date format (must be `YYYY-MM-DD`). If the header cannot be changed, add `- @Data: YYYY-MM-DD` to override the date |
| **Duplicate session across files** | Sessions with identical headers are automatically merged - PU is counted once, not per copy | No action needed; this is handled automatically |
| **Player has no webhook address** | PU is still calculated and applied, but the Discord notification for that player is skipped with a warning | Add the webhook address to the player's record and re-send manually if needed |
| **Stale history entries** | The diagnostic tool flags session headers in the processing log that no longer match any session in the repository | Review flagged entries; they may indicate renamed or deleted session files |
| **Character soft-deleted but still referenced** | Removed characters are excluded from standard views but still exist in the data | Use the include-deleted option to view them; they can be reactivated by updating their status |
| **Unresolved location name** | Phase 4 blocks the commit until the coordinator resolves or excludes the name | Create a Location entity or mark as non-location |
| **Session upgrade fails on a file** | The file is skipped; remaining files continue processing | Check the error message, fix the session header, and re-run |

## Audit Trail / Evidence of Completion

- **PU processing log** (`.robot/res/pu-sessions.md`): timestamped entries listing which sessions were processed in each run. Used to prevent double-counting.
- **Entity store changes**: all player and character updates are committed to the repository, providing full Git history.
- **Discord notifications**: each player receives a message confirming awarded PU, current totals, and overflow pool usage.
- **Diagnostic reports**: the validation tool produces a structured report showing whether all checks passed, with details on any issues found.
- **Location report** (`.robot/res/location-report.txt`): optional export of all location names with resolution status, variants, and conflicts.
- **Migration state** (`.robot/res/migration-state.json`): tracks per-phase completion, checklist items, and diagnostic history across runs.

## Related Documents

- [Glossary](Glossary.md) - Term definitions and Polish equivalents
- [Sessions](Sessions.md) - Session format reference (Gen4 metadata fields)
- [PU](PU.md) - Monthly PU assignment process
- [Players](Players.md) - Player and character lifecycle
- [World-State](World-State.md) - Entity tracking and temporal scope
- [Notifications](Notifications.md) - Intel, targeting, Discord notifications
- [Auditing](Auditing.md) - Audit and diagnostic capabilities
- [Troubleshooting](Troubleshooting.md) - Common issues and solutions
- [MIGRACJA.md](PL/MIGRACJA.md) - Team-facing migration guide (Polish)
- [MIGRACJA-TECH.md](PL/MIGRACJA-TECH.md) - Step-by-step technical procedures with commands (Polish)

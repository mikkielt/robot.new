# Migration - Transition to the New Data and Session Management

## Scope

This migration introduces a reliable, structured way to manage player data, character records, and session metadata. It replaces the manual-edit workflow with a system that validates updates, prevents duplicates, tracks processing history, and sends notifications automatically. The goal is less manual correction, fewer missed updates, and a clear audit trail.

The guide covers how player and character data is now stored and updated, how session records transition to the new structured format, how monthly PU assignments work under the new system, what changes for Narrators, Coordinators, and Players, what the system tracks and verifies automatically, how to handle errors and edge cases, currency tracking (new capability), location name verification during migration, and narrator name verification during migration.

For low-level technical details (file parsers, data structures, internal algorithms), see the technical docs in `devdocs/`. For step-by-step PowerShell commands, see [MIGRACJA-TECH.md](PL/MIGRACJA-TECH.md).

## Actors and Responsibilities

The Coordinator initiates the one-time data migration from the legacy player file to the new entity store, runs the monthly PU assignment process, reviews diagnostic reports for data quality issues (unresolved names, stale records), upgrades session records to the current format when needed, reviews location name reports and resolves conflicts, maintains player webhook addresses for notifications, and manages the currency system (treasury, reconciliation).

The Narrator documents sessions in the current metadata format (locations, logs, PU awards, changes, intel, transfers), ensures character names in PU entries match known characters exactly, records world changes (Zmiany) in sessions so they are automatically applied to entity state, and registers currency transfers between characters via `@Transfer` directives.

The Player receives PU assignment notifications via Discord, sees updated character records (PU totals, status, reputation) without manual intervention, provides initial currency balances during migration (one-time form), and can request new characters or report issues to the Coordinator.

## Architecture

The new system operates on two data sources simultaneously:

| Store | File | Access | Role |
|---|---|---|---|
| Legacy | `Gracze.md` | Read-only | Historical player database. Never modified by the new system. |
| Entity registry | `entities.md` | Read + Write | Canonical write target for all CRUD operations. |

When reading data, the system merges both sources in memory — entities from `entities.md` override values from `Gracze.md` where they exist. This means no data is lost during transition, and the switch is gradual.

The file `.robot/robot-data.psd1` tells the module where to find `entities.md`. Without it, some commands would default to writing inside the `.robot.new` directory instead of the repository root. The migration script creates this manifest automatically during Phase 0.

Session records exist in four format generations, accumulated over the project's history:

| Period | Format | Characteristics |
|---|---|---|
| Before 2022 | Gen1 (plain text) | No structured metadata, log links inline |
| 2022-2023 | Gen2 (italic locations) | Location line formatted in italic, log links inline |
| 2024-2025 | Gen3 (structured lists) | Location, logs, PU, and changes as list items |
| 2026 onward | Gen4 (current format) | All metadata prefixed with `@` markers for unambiguous parsing |

All four formats remain readable — the system auto-detects and parses each one transparently. No data is lost if older sessions are left in their original format.

## Migration Phases

The migration is divided into phases (0-8). Not all require involvement from the entire team.

| Phase | What happens | Who is involved | Duration |
|---|---|---|---|
| 0. Przygotowanie i bootstrap | Safety backup, module verification, data manifest, generate entity store | Coordinator | 1-2 days |
| 1. Baseline integralnosci sesji | Compute and store baseline session content hashes | Coordinator | 1 day |
| 2. Walidacja i naprawa danych | Verify data parity, fix typos, date errors, missing aliases, extended diagnostics | Coordinator, Narrators | 3-5 days |
| 3. Import lokalizacji z mapy | Import game-map locations as entities, review overrides | Coordinator | 2-3 days |
| 4. Pobieranie logow sesji | Download session log files from external URLs to local cache | Coordinator | 1 day |
| 5. Upgrade formatu sesji | Upgrade active session files to Gen4 format | Coordinator | 1-2 days |
| 6. Wnioskowanie drzwi z logow | Infer location connections from session log transitions | Coordinator | 1-2 days |
| 7. Enrollment walut | Collect and register currency balances | Everyone | ~1 week |
| 8. Przelaczenie (cutover) | Parallel period, verification, official switch to the new system | Coordinator | 2-4 weeks |

Total estimated time is 4-6 weeks, most of which is the parallel/cutover period.

Each migration run produces a diagnostic log file in `.robot/res/`. This log captures every step, warning, and error with timestamps and detailed repair instructions. The log is overwritten on each run and contains results from the last run only. The Coordinator can review this file after running the migration to see all issues that were encountered and their suggested fixes.

Migration progress is saved after each step. If a migration run is interrupted (e.g., terminal closed, system crash), the Coordinator can resume from where it left off — no progress is lost. A backup of the previous state is kept automatically, so even if the save itself is interrupted, the prior state is recoverable.

## Phase 0 — Przygotowanie i bootstrap

The Coordinator secures the current state before any changes, then generates the entity store from legacy data. This phase combines preparation and bootstrap into a single step.

The phase proceeds through the following steps. The system verifies a clean git state (no uncommitted changes allowed before migration starts). It creates a safety tag (`pre-migration`) providing a rollback point to the exact pre-migration state. It verifies the PU state file, ensuring the processing history file (`pu-sessions.json`) is preserved and continues to be used. It verifies the submodule (`.robot.new` must be registered as a git submodule) and confirms all commands are available. It creates the data manifest (`.robot/robot-data.psd1`) ensuring all commands write to the correct `entities.md` location. Finally, it generates the entity store by reading all current player and character data from the existing player database and writing it into `entities.md`. The system creates one new file containing all players, their characters, and associated metadata (PU values, aliases, group memberships). The original player database remains untouched. Additional entity sections (NPC, Group, Location, Item) are added for future use.

## Phase 1 — Baseline integralnosci sesji

A read-only phase that computes and stores baseline SHA-256 content hashes for all session files. These hashes provide tamper detection and change tracking for session content going forward. The baseline is stored in `.robot/res/session-hashes/` and serves as the reference point for the session integrity validator.

## Phase 2 — Walidacja i naprawa danych

This phase combines data parity validation with diagnostics and data repair. It first verifies the new system correctly reads and merges data from both sources, then iteratively fixes issues surfaced by the stricter validation.

Validation checks include verifying that player and character counts match expectations, PU values match the original data (spot-checked), aliases transferred correctly, and players without webhook addresses are identified. A diagnostic tool run surfaces any remaining issues.

The new system is stricter about data validation. Issues that the old system silently ignored now surface as errors. This sub-phase fixes known problems iteratively: unresolved character names (typos in session PU entries, fixed by correcting the name or adding an alias), malformed session dates (dates like `2025-6-15` corrected to `2025-06-15`), duplicate PU entries (same character listed multiple times in one session), characters with PU = BRAK (decision to mark as inactive or supply missing values), and stale history entries (old session headers in the processing log that no longer match existing sessions, informational and non-blocking).

Additionally, a narrator report identifies raw narrator names from session headers that do not resolve to known players, allowing the Coordinator to add normalization mappings.

The Coordinator runs diagnostics, fixes issues, re-runs diagnostics, and repeats until the diagnostic tool returns OK.

## Phase 3 — Import lokalizacji z mapy

The Coordinator imports all game-map locations into the entity store. This produces two entity types using a two-pass workflow.

Mapa entities (concrete game maps) are created first. The system reads the full map registry (~2,704 entries) and creates a Mapa entity for each one. Each Mapa entity records the Margonem map ID, map type (exterior/interior), CDN image URL, and tile dimensions. These are written to a dedicated overflow file (`maps-100-ent.md`) to keep the main `entities.md` manageable.

Lokacja entities (conceptual locations) are derived next. The system infers parent-child relationships from naming conventions (e.g., "Piekielna Grota p.2" is a child of "Piekielna Grota") and derives deduplicated Lokacja entities from the hierarchy's unique base names. These represent the conceptual places — fewer than the total map count — and are written to `entities.md`.

In the Coordinator review (second pass), the system exports a tab-separated override file listing all imported maps. The Coordinator edits this file to add Nerthus-specific names for maps that use different names in the RP setting (applied as `@nazwa_nerthus` on Mapa entities) and to add virtual locations that exist only in the Nerthus setting (created as Lokacja entities). After editing, the Coordinator re-runs the phase to apply the overrides. The phase completes when the Mapa import, Lokacja derivation, and override steps are all done.

This phase must run before the session format upgrade (Phase 5) because the location review step in Phase 5 expects Lokacja entities to already exist.

## Phase 4 — Pobieranie logow sesji

The system downloads all session log files from external URLs (primarily Pastebin) to the local `res/logs/` cache. This ensures the lore repository has a complete archive before any URLs expire. The fetch uses CDN-safe throttling and retry logic. Failed URLs are recorded for manual review.

## Phase 5 — Upgrade formatu sesji

The Coordinator upgrades active session files from Gen1/Gen2/Gen3 to the current Gen4 format. The upgrade changes only metadata structure — narrative text and special blocks (clarifications, effects, rewards) are preserved. Additionally, log URLs that have locally cached files (from Phase 4) are replaced with relative paths (`res/logs/filename`), making the repository self-contained.

| Before | After |
|---|---|
| `- Lokalizacje:` | `- @Lokacje:` |
| `- Logi: URL` | `- @Logi:` + `    - URL` |
| `- PU:` | `- @PU:` |
| `*Lokalizacja: A, B*` (Gen2) | `- @Lokacje:` + `    - A` + `    - B` |

If a particular file fails during upgrade (e.g., a malformed session header), processing continues with the remaining files. A summary of failed files is displayed at the end. Headers with irregular whitespace (e.g., double spaces after `###`) are normalized automatically.

After the format upgrade, narrator names are verified against normalization mappings. Sessions with unresolved narrator names are flagged for review.

A location report analyzes all location names used in active sessions. It compares them against registered Lokacja entities and flags unresolved locations (names that do not match any registered entity, where the Coordinator must either create the missing entity or mark the value as a non-location) and warnings (fuzzy matches, case variants, or hierarchy inconsistencies, shown for awareness but do not block the process).

Non-location exclusions are stored in `.robot/res/location-exclusions.txt` and persist across re-runs. The commit step is blocked until all truly unresolved locations are handled.

After the format upgrade and location review, a review file (`all-sessions-to-review.md`) is generated in `.robot/res/`. This file contains every session sorted chronologically, with source file paths embedded as HTML comments. The Coordinator can edit session content directly in the review file (fix typos, upgrade old formats, correct metadata), delete session blocks to remove them from source files, or add new session blocks (these are placed in `.robot/res/review-additions/` for manual integration).

On subsequent runs of Phase 5, the Coordinator can choose to apply edits from the review file back to source files, regenerate the review file, or refresh hashes after manual source edits. The review workflow is optional — Phase 5 can complete without it.

## Phase 6 — Wnioskowanie drzwi z logow

The system analyzes location transitions from session logs to infer physical connections (`@drzwi` tags) between locations. It builds a location graph, classifies Movement vs Teleport edges based on structural distance, and generates a review file with confidence-weighted candidates. The Coordinator reviews the candidates (accepting, rejecting, or marking for review), and accepted pairs receive bidirectional `@drzwi` tags with temporal annotations.

## Phase 7 — Enrollment walut

The currency system is an entirely new capability. This phase sets up the initial state.

The Coordinator treasury is a group entity (`Skarbiec Koordynatorow`) with initial reserves in three denominations: Korona (gold, 1 Korona = 100 Talarow), Talar (silver, 1 Talar = 100 Kogow), and Kog (copper, base unit).

Player balances are collected via a one-time form sent to players, then registered through commands or a technical initialization session.

Narrator budgets are currency reserves allocated to Narrators for distribution during sessions.

A verification step uses a currency report and reconciliation check to confirm all balances are consistent.

Currency transfers during gameplay are registered by Narrators in sessions via `@Transfer` directives.

## Phase 8 — Przelaczenie (cutover)

This phase combines the parallel period and the official cutover into a single phase.

During the parallel period (2-4 weeks), both the old and new systems run simultaneously. The Coordinator runs PU assignment through both and compares results. PU assignments are compared between systems (results must match), new sessions are written in Gen4 format by Narrators, new characters are created exclusively through the new system, and old sessions remain readable without modification.

All cutover criteria must be met before switching over: at least one full PU cycle with identical results from both systems, all active Narrators using Gen4 format, diagnostics clean, and currency reconciliation without critical warnings.

The cutover steps are the official switch to the new system as the sole operational tool. The Coordinator performs a final PU verification to confirm diagnostics are clean, freezes `Gracze.md` by adding a read-only notice (the file becomes a historical archive), marks the old system as deprecated, runs the first standalone PU assignment through the new system with full effects (entity updates, Discord notifications, history logging), announces to the team, and creates a post-migration tag.

## Inputs Required

For the initial migration, the Coordinator needs access to the existing player database (`Gracze.md`, read-only, never modified) and a working copy of the repository with the `.robot.new` module available.

For ongoing operations, the system requires session files with proper headers (`### YYYY-MM-DD, Title, Narrator`) and metadata blocks, player webhook addresses for Discord notifications (optional but recommended), and character names that match registered names or aliases exactly.

## Ongoing Operations

After migration, the following workflows continue on an ongoing basis.

When recording a session, the Narrator documents each session using the current format: session header (date, title, and narrator name), Lokacje (where the session took place), Logi (link(s) to the session transcript), PU (each participating character and their earned PU value), Zmiany (world-state updates applied to entities), Intel (targeted information sent to specific recipients), and Transfer (currency transactions between characters).

For monthly PU assignment, the Coordinator initiates the assignment for the target period (typically the previous one or two months). The system scans sessions in the date range, skipping any already processed. Character names are verified against the player roster — if any name cannot be matched, the process stops immediately with no PU awarded and no notifications sent. The Coordinator must fix the unrecognized names before retrying. PU is calculated for each character: base PU = 1 (universal monthly base) + sum of session PU values, with a monthly cap of 5 PU maximum. Excess PU above the cap is stored in the character's overflow pool. If a character earned less than 5 PU, the overflow pool supplements the difference (up to the cap). When the Coordinator confirms, character PU totals are updated in the entity store, Discord notifications are sent to each player's webhook (grouped by player), and processed session headers are logged in the history file.

When adding a new Player, the Coordinator registers the player with their basic information (Margonem ID, optional webhook address). The system validates that no duplicate player exists. Optionally, a first character can be created at the same time.

When adding a new character, the Coordinator creates a new character for an existing player. Starting PU is calculated automatically based on the player's other characters: half of their total earned PU plus 20, rounded down. New players start at 20 PU. A character file is created from the standard template. The character is registered in the entity store with ownership and starting PU.

When removing a character, the operation is a soft delete — the character is marked as removed with an effective date, and no data is physically deleted. Removed characters stop appearing in standard queries but remain in the system for historical accuracy. This action requires explicit confirmation due to its significance.

## Expected Outcomes

After migration is complete:

- Single source of truth for mutable data — all updates go to the entity store; the legacy file stays frozen as a read-only archive
- Backward-compatible reading — queries merge both old and new data transparently, with no information lost
- Consistent session format — new sessions use the current structured format; older sessions remain readable
- Automated PU processing — monthly PU assignment is calculated, validated, applied, and notified in one operation with full audit trail
- Data quality enforcement — unresolved character names block PU assignment; diagnostic tools surface stale records, duplicate entries, and parsing failures
- Location verification — location names in sessions are checked against the entity registry; conflicts and unresolved names are surfaced during migration
- Currency tracking — three-denomination currency system with per-entity balances, session-based transfers, and reconciliation
- Clear audit trail — every PU assignment is logged with timestamps and processed session headers

## Rollback Plan

The migration is designed to be reversible at every stage:

| Level | Scenario | Action |
|---|---|---|
| Single operation | One PU assignment gave wrong results | Revert the last commit |
| Specific phase | A phase introduced bad data | Revert the commit for that phase |
| Session upgrade | Format upgrade caused issues in a file | Restore the file from the pre-migration tag |
| Full rollback | Critical failure requiring complete reversal | Reset to the pre-migration tag (destructive, last resort) |

The new system never modifies `Gracze.md`. The old system always has access to its unmodified database. The `pre-migration` git tag provides a complete snapshot of the pre-migration state.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Unresolved character name in PU | The entire PU assignment stops before any changes are made | Fix the character name in the session file (typo, missing alias) and retry |
| Session with unparseable date | The session is skipped silently during PU assignment | Run the diagnostic tool to surface these sessions; fix the date format (must be `YYYY-MM-DD`). If the header cannot be changed, add `- @Data: YYYY-MM-DD` to override the date |
| Duplicate session across files | Sessions with identical headers are automatically merged — PU is counted once, not per copy | No action needed; this is handled automatically |
| Player has no webhook address | PU is still calculated and applied, but the Discord notification for that player is skipped with a warning | Add the webhook address to the player's record and re-send manually if needed |
| Stale history entries | The diagnostic tool flags session headers in the processing log that no longer match any session in the repository | Review flagged entries; they may indicate renamed or deleted session files |
| Character soft-deleted but still referenced | Removed characters are excluded from standard views but still exist in the data | Use the include-deleted option to view them; they can be reactivated by updating their status |
| Unresolved location name | Phase 5 blocks the commit until the Coordinator resolves or excludes the name | Create a Lokacja entity or mark as non-location |
| Session upgrade fails on a file | The file is skipped; remaining files continue processing | Check the error message, fix the session header, and re-run |

## Audit Trail / Evidence of Completion

- PU processing log (`.robot/res/pu-sessions.json`) — timestamped entries listing which sessions were processed in each run, used to prevent double-counting
- Entity store changes — all player and character updates are committed to the repository, providing full Git history
- Discord notifications — each player receives a message confirming awarded PU, current totals, and overflow pool usage
- Diagnostic reports — the validation tool produces a structured report showing whether all checks passed, with details on any issues found
- Location report (`.robot/res/location-report.txt`) — optional export of all location names with resolution status, variants, and conflicts
- Migration state (`.robot/res/migration-state.json`) — tracks per-phase completion, checklist items, and diagnostic history across runs

## Related Documents

- [Glossary](Glossary.md) — Term definitions and Polish equivalents
- [Sessions](Sessions.md) — Session format reference (Gen4 metadata fields)
- [PU](PU.md) — Monthly PU assignment process
- [Players](Players.md) — Player and character lifecycle
- [World-State](World-State.md) — Entity tracking and temporal scope
- [Currency](Currency.md) — Currency tracking and transfers
- [Economy](Economy.md) — Economic analysis and reports
- [Notifications](Notifications.md) — Intel, targeting, Discord notifications
- [Auditing](Auditing.md) — Audit and diagnostic capabilities
- [Troubleshooting](Troubleshooting.md) — Common issues and solutions
- [MIGRACJA.md](PL/MIGRACJA.md) — Team-facing migration guide (Polish)
- [MIGRACJA-TECH.md](PL/MIGRACJA-TECH.md) — Step-by-step technical procedures with commands (Polish)

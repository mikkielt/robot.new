# Migration — Transition to the New Data and Session Management

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

**What is excluded:**

- Low-level technical details (file parsers, data structures, internal algorithms)
- Development setup and contributing guidelines (see the technical `MIGRATION.md`)

## Actors and Responsibilities

### Coordinator

- Initiates the one-time data migration from the legacy player file to the new entity store
- Runs the monthly PU assignment process
- Reviews diagnostic reports for data quality issues (unresolved names, stale records)
- Upgrades session records to the current format when needed
- Maintains player webhook addresses for notifications

### Narrator

- Documents sessions in the current metadata format (locations, logs, PU awards, changes, intel)
- Ensures character names in PU entries match known characters exactly
- Records world changes (Zmiany) in sessions so they are automatically applied to entity state

### Player

- Receives PU assignment notifications via Discord
- Sees updated character records (PU totals, status, reputation) without manual intervention
- Can request new characters or report issues to the coordinator

## Inputs Required

### For the initial migration

- Access to the existing player database (`Gracze.md`) — read-only, never modified
- A working copy of the repository with the `.robot.new` module available

### For ongoing operations

- Session files with proper headers (`### YYYY-MM-DD, Title, Narrator`) and metadata blocks
- Player webhook addresses for Discord notifications (optional but recommended)
- Character names that match registered names or aliases exactly

## Step-by-Step Flow

### Phase 1 — Initial Data Migration

1. **The coordinator generates the new entity store** from the existing player database. This is a one-time operation that reads all current player and character data and writes it into the new structured format.

2. **The system creates one new file** (`entities.md`) containing all players, their characters, and associated metadata (PU values, aliases, group memberships). The original player database remains untouched and continues to serve as a read-only reference.

3. **The coordinator verifies parity** by comparing the merged output (old + new data) against expectations. The system reads both sources simultaneously and overlays them, so nothing is lost during transition.

### Phase 2 — Session Format Upgrade

Session records exist in four format generations, accumulated over the project's history:

| Period | Format | Characteristics |
|---|---|---|
| Before 2022 | Legacy (plain text) | No structured metadata, log links inline |
| 2022–2023 | Italic locations | Location line formatted in italic, log links inline |
| 2024–2026 | Structured lists | Location, logs, PU, and changes as list items |
| 2026 onward | Current format | All metadata prefixed with `@` markers for unambiguous parsing |

**All four formats remain readable** — the system auto-detects and parses each one transparently. No data is lost if older sessions are left in their original format.

**The coordinator can optionally upgrade** older sessions to the current format. The upgrade preserves all content (narrative text, clarifications, effects) and only restructures the metadata blocks. This is recommended for active session files but not required for archived ones.

### Phase 3 — Ongoing Operations

#### Recording a Session (Narrator)

The narrator documents each session using the current format:

- **Session header**: date, title, and narrator name
- **Locations**: where the session took place
- **Logs**: link(s) to the session transcript
- **PU awards**: each participating character and their earned PU value
- **Changes**: world-state updates applied to entities (NPCs, organizations, locations)
- **Intel**: targeted information sent to specific recipients (individuals, groups, or locations)

#### Monthly PU Assignment (Coordinator)

1. The coordinator initiates the monthly PU assignment for the target period (typically the previous one or two months).

2. **The system scans sessions** in the date range, skipping any already processed (tracked in the history log).

3. **Character names are verified** against the player roster. If any name cannot be matched, the process stops immediately — no PU is awarded and no notifications are sent. The coordinator must fix the unrecognized names before retrying.

4. **PU is calculated** for each character:
   - Base PU = 1 (universal monthly base) + sum of session PU values
   - Monthly cap: 5 PU maximum
   - Excess PU above the cap is stored in the character's overflow pool
   - If a character earned less than 5 PU, the overflow pool supplements the difference (up to the cap)

5. **Results are applied** (when the coordinator confirms):
   - Character PU totals are updated in the entity store
   - Discord notifications are sent to each player's webhook, grouped by player
   - Processed session headers are logged in the history file

#### Adding a New Player (Coordinator)

- The coordinator registers a new player with their basic information (Margonem ID, optional webhook address).
- The system validates that no duplicate player exists.
- Optionally, a first character can be created at the same time.

#### Adding a New Character (Coordinator)

- A new character is created for an existing player.
- Starting PU is calculated automatically based on the player's other characters: half of their total earned PU plus 20, rounded down. New players start at 20 PU.
- A character file is created from the standard template.
- The character is registered in the entity store with ownership and starting PU.

#### Removing a Character (Coordinator)

- Character removal is a soft operation — the character is marked as removed with an effective date, but no data is physically deleted.
- Removed characters stop appearing in standard queries but remain in the system for historical accuracy.
- This action requires explicit confirmation due to its significance.

#### Updating Character Data (Coordinator or Narrator)

Character updates can affect two areas:
- **Entity-level data** (PU values, aliases, status, group memberships) — stored in the entity store
- **Character file data** (character sheet, special items, reputation, conditions, notes) — stored in the character's individual file

Both are updated through a single operation. Unknown special items are automatically registered as new entities.

## Expected Outcomes

After migration is complete:

1. **Single source of truth for mutable data** — all updates go to the entity store; the legacy file stays frozen as a read-only archive.

2. **Backward-compatible reading** — queries merge both old and new data transparently. No information is lost.

3. **Consistent session format** — new sessions use the current structured format; older sessions remain readable.

4. **Automated PU processing** — monthly PU assignment is calculated, validated, applied, and notified in one operation with full audit trail.

5. **Data quality enforcement** — unresolved character names block PU assignment; diagnostic tools surface stale records, duplicate entries, and parsing failures.

6. **Clear audit trail** — every PU assignment is logged with timestamps and processed session headers.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Unresolved character name in PU** | The entire PU assignment stops before any changes are made | Fix the character name in the session file (typo, missing alias) and retry |
| **Session with unparseable date** | The session is skipped silently during PU assignment | Run the diagnostic tool to surface these sessions; fix the date format (must be `YYYY-MM-DD`) |
| **Duplicate session across files** | Sessions with identical headers are automatically merged — PU is counted once, not per copy | No action needed; this is handled automatically |
| **Player has no webhook address** | PU is still calculated and applied, but the Discord notification for that player is skipped with a warning | Add the webhook address to the player's record and re-send manually if needed |
| **Stale history entries** | The diagnostic tool flags session headers in the processing log that no longer match any session in the repository | Review flagged entries; they may indicate renamed or deleted session files |
| **Character soft-deleted but still referenced** | Removed characters are excluded from standard views but still exist in the data | Use the include-deleted option to view them; they can be reactivated by updating their status |

## Audit Trail / Evidence of Completion

- **PU processing log** (`.robot/res/pu-sessions.md`): timestamped entries listing which sessions were processed in each run. Used to prevent double-counting.
- **Entity store changes**: all player and character updates are committed to the repository, providing full Git history.
- **Discord notifications**: each player receives a message confirming awarded PU, current totals, and overflow pool usage.
- **Diagnostic reports**: the validation tool produces a structured report showing whether all checks passed, with details on any issues found.

## Related Documents

- [Glossary](Glossary.md) — Term definitions and Polish equivalents
- [MIGRATION.md](../MIGRATION.md) — Technical implementation reference (for developers)

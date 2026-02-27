# Monthly PU Assignment

## Purpose

The monthly PU assignment process calculates and distributes skill points (Punkty Umiejętności, PU) to player characters based on their participation in game sessions. It ensures every active character receives fair, consistent, and auditable PU awards each month, with automatic overflow handling, Discord notifications, and a processing log that prevents double-counting.

## Scope

**What is included:**

- How PU is calculated from session participation
- Monthly cap and overflow pool mechanics
- Who receives notifications and in what format
- What gets logged and how to verify results
- How to handle errors and edge cases
- How starting PU is determined for new characters

**What is excluded:**

- Session recording and metadata format (see the session format reference)
- Player and character registration (see the migration guide)
- Internal data structures and parser details

## Actors and Responsibilities

### Coordinator

- Initiates the monthly PU assignment for the target period
- Reviews diagnostic reports before applying changes
- Resolves data quality issues (unresolved character names, stale history entries)
- Confirms and applies PU updates, notifications, and history logging

### Narrator

- Documents sessions with correct character names in PU entries
- Uses names or registered aliases that match the character roster exactly
- Awards PU values within the established guidelines (0.1–0.5 per session participation)

### Player

- Receives a Discord notification confirming awarded PU, current totals, and overflow pool usage
- Does not need to take any action — updates are applied automatically

## Inputs Required

- **Session files** with proper headers (`### YYYY-MM-DD, Title, Narrator`) containing PU entries
- **Character roster** with registered names and aliases (maintained in the entity store)
- **Player webhook addresses** for Discord notifications (optional but recommended)
- **Processing history** (`pu-sessions.md`) — maintained automatically, prevents double-counting

## Step-by-Step Flow

### Step 1 — Determine the Time Period

The coordinator selects which months to process. The typical approach:

- **Specific month**: provide the year and month (e.g., January 2025)
- **Default**: the system looks back two months from today, covering sessions that may have been documented late

### Step 2 — Scan for Sessions

The system identifies all sessions in the selected period that contain PU entries. It uses the repository's change history to narrow the scan to recently modified files, falling back to a full scan if needed.

Sessions appearing in multiple files (e.g., a session logged in both a location file and a thread file) are automatically merged — PU is counted once per session, not per file copy.

### Step 3 — Exclude Already-Processed Sessions

Sessions whose headers appear in the processing history are skipped. This prevents the same session from being counted in multiple runs.

### Step 4 — Verify Character Names

Every character name in PU entries is checked against the known roster (including registered aliases). **If any name cannot be matched, the entire process stops immediately** — no PU is awarded, no notifications are sent, and no history is logged.

The coordinator must fix the unrecognized names (correct the spelling, add a missing alias, or update the character roster) and retry.

### Step 5 — Calculate PU

For each character with PU entries in the batch:

1. **Base PU** = 1 (universal monthly base for any participating character) + sum of all PU values from sessions
2. **Monthly cap** = 5 PU maximum per character
3. **Overflow pool interaction**:
   - If base PU is at or below 5 and the character has overflow PU from previous months, the overflow supplements the award up to the cap
   - If base PU exceeds 5, the excess is stored in the overflow pool for future months
4. **Granted PU** = the lesser of (base PU + overflow supplement) and 5
5. **Updated totals**: current PU sum and earned PU are increased by the granted amount

**Example — normal award with overflow supplement:**

> Korm earned 1.0 PU across sessions this month. He has 1.50 overflow PU from previous months.
>
> Base PU = 1 + 1.0 = 2.0. Overflow supplements 1.50 (up to cap of 5). Granted PU = 3.50. Overflow remaining = 0.00.

**Example — overflow generation:**

> Velrose earned 5.0 PU across sessions. She has 0.00 overflow PU.
>
> Base PU = 1 + 5.0 = 6.0. Exceeds cap by 1.0. Granted PU = 5.00. Overflow stored = 1.00 (available next month).

### Step 6 — Apply Results (Coordinator Confirms)

When the coordinator approves, three things happen:

1. **Character records are updated** — PU totals and overflow values are written to the entity store
2. **Discord notifications are sent** — one message per player, listing all their characters' awards, current totals, and any overflow usage
3. **Processing history is logged** — session headers are recorded with a timestamp so they are not processed again

Each of these steps can be enabled independently, and the coordinator can preview all changes before applying them.

### Discord Notification Format

Each player receives a single message containing all their characters' results:

> Postać "Korm Blackhand" (Gracz "Achalen") otrzymuje 3.50 PU.
> Aktualna suma PU tej Postaci: 48.50, wykorzystano PU nadmiarowe: 1.50

If a player has multiple characters, each one appears as a separate paragraph. If a player has no webhook address, their notification is skipped (with a warning) but the PU is still applied.

## Expected Outcomes

After a successful PU assignment:

1. **Each qualifying character** has received up to 5 PU based on session participation
2. **Overflow pools** are updated — excess PU is stored for future months, and previously stored overflow is consumed as needed
3. **PU totals** in the entity store reflect the new values
4. **Players are notified** via Discord with the exact amounts, current totals, and overflow usage
5. **The processing history** records which sessions were counted, preventing future double-counting

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Unresolved character name** | The entire PU assignment stops before any changes are made | Fix the name in the session file (typo, missing alias, unregistered character) and retry |
| **Session with unparseable date** | The session is silently skipped during PU assignment | Run the diagnostic tool to find these sessions; fix the date format to `YYYY-MM-DD` |
| **Duplicate session across files** | Automatically merged — PU counted once | No action needed |
| **Player has no webhook** | PU is calculated and applied, but the Discord notification is skipped with a warning | Add the webhook and, if needed, re-send the notification manually |
| **PU value is missing or malformed** | The entry contributes 0 to the calculation; flagged by the diagnostic tool | Correct the PU entry in the session file |
| **Duplicate PU entry for same character in one session** | Flagged by the diagnostic tool | Remove the duplicate entry |
| **All sessions already processed** | No changes are made; the system reports that everything is up to date | No action needed |
| **Discord message fails to send** | Other players' notifications continue; the failure is logged | Retry or send manually |

## New Character Starting PU

When a new character is created for an existing player, starting PU is determined automatically:

- The system sums all earned PU (PU zdobyte) across the player's existing characters
- Formula: half of the total earned PU plus 20, rounded down
- New players with no prior characters start at 20 PU
- Characters with no recorded starting PU are excluded from the calculation

**Example:** A player has two characters with 30 and 10 earned PU. New character starts with: floor((30 + 10) / 2 + 20) = floor(40) = 40 PU.

## Diagnostic Validation

Before running the actual PU assignment, the coordinator can run a diagnostic check that validates data quality without making any changes. The diagnostic reports:

| Check | What it finds |
|---|---|
| **Unresolved characters** | PU entries with character names that do not match any known character |
| **Malformed PU values** | Entries with missing or non-numeric PU values |
| **Duplicate entries** | Same character listed multiple times in one session's PU block |
| **Failed sessions with PU data** | Sessions with broken date formats that contain PU data the system cannot process |
| **Stale history entries** | Session headers in the processing log that no longer match any session in the repository (renamed, deleted, or corrupted) |

The diagnostic produces a clear pass/fail result. If any issue is found, the coordinator should resolve it before running the actual assignment.

## Audit Trail / Evidence of Completion

- **Processing log** (`.robot/res/pu-sessions.md`): each run appends a timestamped block listing which sessions were counted. Used to prevent double-counting and to verify what was processed.
- **Entity store changes**: all PU updates are committed to the repository, providing a full Git history of every value change.
- **Discord notifications**: each player receives a message confirming exact amounts, serving as a receipt.
- **Diagnostic reports**: structured validation results confirming data quality before and after processing.

## Related Documents

- [Glossary](Glossary.md) — Term definitions and Polish equivalents
- [Migration](Migration.md) — Transition guide covering data model and workflow changes

# Auditing and History

## Purpose

This guide explains how coordinators can review the historical record of changes, transactions, PU processing runs, and notifications across the game world. These tools provide a structured audit trail for verifying what happened, when, and to whom - without modifying any data.

## Scope

**What is included:**

- Viewing the full change history of a single entity
- Reviewing what world-state changes happened across sessions
- Tracking currency transactions over time
- Inspecting the PU processing log
- Reviewing what Intel notifications were sent from sessions

**What is excluded:**

- Modifying entity data (see [World-State.md](World-State.md))
- Running PU assignments (see [PU.md](PU.md))
- Currency reconciliation checks (see [World-State.md](World-State.md))
- Session recording format (see [Sessions.md](Sessions.md))

## Actors and Responsibilities

### Coordinator

- Reviews audit reports to verify data consistency
- Uses history views to investigate discrepancies or answer questions about past events
- Runs audit queries before and after monthly PU processing

### Narrator

- May review entity history to verify that session changes were applied correctly
- May check the notification log to confirm Intel messages were generated

## Available Audit Views

### 1. Entity History - "What happened to this entity?"

Shows a unified timeline of all changes to a single entity - location moves, status changes, group memberships, ownership transfers, type changes, door assignments, and quantity adjustments. All history types are merged into one chronological view.

**When to use:**

- Investigating when an NPC moved to a new location
- Checking when a character joined or left a group
- Verifying that session changes were applied correctly
- Reviewing the full lifecycle of a currency holding

**What you see:**

Each entry shows:
- The date the change took effect
- The end date (if the change was time-bounded)
- What property changed (Lokacja, Status, Grupa, etc.)
- The new value

Entries are sorted chronologically, with undated entries (baseline properties) listed first. Results can be filtered to a specific date range.

**Example questions this answers:**
- "When did Kupiec Orrin move to Steadwick?"
- "What groups has Rion belonged to over time?"
- "How has this currency entity's balance changed?"

### 2. Change Log - "What happened in the world?"

Shows all `@Zmiany` (world-state changes) recorded across sessions, in chronological order. This is a cross-entity view - it shows every change from every session in one report.

**When to use:**

- Reviewing all changes made during a specific time period
- Finding all sessions that affected a particular entity
- Checking what location moves happened last month
- Auditing which narrators recorded what changes

**What you see:**

Each entry shows:
- The session date
- The session title and narrator
- Which entity was changed
- What property was set (lokacja, grupa, status, etc.)
- The new value

Results can be filtered by entity name, property type, or date range. Entries are sorted by date, then by entity name.

**Example questions this answers:**
- "What world changes happened in June 2025?"
- "Which sessions changed Xeron Demonlord's properties?"
- "Show me all location moves recorded last month"

### 3. Transaction Ledger - "Where did the money go?"

Shows all `@Transfer` directives from sessions in chronological order. This is the complete record of currency movements between entities.

**When to use:**

- Tracking all currency transactions for a specific character
- Investigating a balance discrepancy
- Reviewing all transactions of a specific denomination
- Building a financial audit trail for a time period

**What you see:**

Each entry shows:
- The session date, title, and narrator
- The amount and denomination transferred
- Who sent and who received the currency

When filtering to a specific entity, additional information appears:
- Whether each transaction was incoming or outgoing for that entity
- A running balance showing cumulative effect

Results can be filtered by entity (source or destination), denomination, and date range.

**Example questions this answers:**
- "Show me all transactions involving Kupiec Orrin"
- "What Korony transfers happened this month?"
- "What is the net flow for Xeron Demonlord from all recorded transfers?"

### 4. PU Assignment Log - "When was PU processed?"

Shows the history of PU processing runs - when each run happened, and which sessions were included. This reads the processing history file that prevents double-counting.

**When to use:**

- Verifying that a specific session was included in a PU run
- Checking when the last PU processing happened
- Investigating why a session's PU might have been missed
- Auditing the processing timeline

**What you see:**

Each entry shows:
- When the PU run was executed (date, time, and timezone)
- How many sessions were included in that run
- For each session: the header (date, title, narrator)

Entries are sorted most recent first. Results can be filtered by date range.

**Example questions this answers:**
- "When was PU last processed?"
- "Was the June 15th session included in the July PU run?"
- "How many sessions were processed in each run this year?"

### 5. Notification Log - "What Intel was sent?"

Shows all `@Intel` directives from sessions - targeted messages that were intended for specific recipients. This reconstructs the notification intent from session data.

**When to use:**

- Verifying what messages were generated for a specific recipient
- Checking whether a group or location notification reached the right targets
- Auditing the notification history for a time period
- Investigating a player's claim that they didn't receive an Intel message

**What you see:**

Each entry shows:
- The session date, title, and narrator
- The targeting directive (Direct, Grupa, or Lokacja)
- The target name
- The message content
- How many recipients were resolved
- The list of resolved recipient names

Results can be filtered by target name, directive type, and date range.

**Important note:** This shows what was *intended* to be sent based on session data. It does not confirm actual delivery to Discord - delivery logging is a separate concern.

**Example questions this answers:**
- "What Intel messages targeted Xeron Demonlord?"
- "What group-wide notifications went to Rada Czarodziejow?"
- "What location-based messages were sent for Erathia?"

## Expected Outcomes

All audit views are read-only - they never modify data. They can be used at any time without risk.

A complete audit workflow typically involves:

1. Running the **PU Assignment Log** to verify processing history
2. Using the **Change Log** to review world-state changes for a period
3. Checking **Entity History** for specific entities that need investigation
4. Reviewing the **Transaction Ledger** for currency discrepancies
5. Consulting the **Notification Log** to verify Intel delivery intent

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Entity not found** | Entity History returns an empty result with a warning | Verify the entity name spelling and check aliases |
| **No sessions in date range** | Change Log, Transaction Ledger, and Notification Log return empty results | Widen the date range or verify session dates |
| **Processing history file missing** | PU Assignment Log returns an empty result with a warning | Verify the file path; the file is created automatically during the first PU run |
| **Unresolved Intel targets** | Notification Log shows 0 recipients for that entry | The entity name in the Intel target may not match a known entity |

## Related Documents

- [World-State.md](World-State.md) - Entity management and currency tracking
- [PU.md](PU.md) - Monthly PU assignment process
- [Sessions.md](Sessions.md) - Session recording format (including @Zmiany, @Transfer, @Intel)
- [Troubleshooting.md](Troubleshooting.md) - Diagnosing data quality issues
- [Glossary](Glossary.md) - Term definitions

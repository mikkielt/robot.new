# Auditing and History

## Scope

Coordinators can review the historical record of changes, transactions, PU processing runs, and notifications across the game world. These tools provide a structured audit trail for verifying what happened, when, and to whom — all views are read-only.

This guide covers viewing the full change history of a single entity, reviewing world-state changes across sessions, tracking currency transactions over time, inspecting the PU processing log, and reviewing Intel notifications sent from sessions.

For modifying entity data, see [World-State.md](World-State.md). For running PU assignments, see [PU.md](PU.md). For currency reconciliation, see [Currency.md](Currency.md). For the session recording format, see [Sessions.md](Sessions.md).

## Actors and Responsibilities

The Coordinator reviews audit reports to verify data consistency, uses history views to investigate discrepancies or answer questions about past events, and runs audit queries before and after monthly PU processing.

The Narrator may review entity history to verify that session changes were applied correctly, and may check the notification log to confirm Intel messages were generated.

## Entity History

Entity History answers the question "What happened to this entity?" It shows a unified timeline of all changes to a single entity — location moves, status changes, group memberships, ownership transfers, type changes, door assignments, and quantity adjustments. All history types are merged into one chronological view.

Use this view when investigating when an NPC moved to a new location, checking when a character joined or left a group, verifying that session changes were applied correctly, or reviewing the full lifecycle of a currency holding.

Each entry shows the date the change took effect, the end date (if the change was time-bounded), what property changed (Lokacja, Status, Grupa, etc.), and the new value. Entries are sorted chronologically, with undated entries (baseline properties) listed first. Results can be filtered to a specific date range.

Example questions this answers: "When did Kupiec Orrin move to Steadwick?" — "What groups has Rion belonged to over time?" — "How has this currency entity's balance changed?"

## Change Log

The Change Log answers the question "What happened in the world?" It shows all Zmiany (world-state changes) recorded across sessions in chronological order. This is a cross-entity view — it shows every change from every session in one report.

Use this view when reviewing all changes made during a specific time period, finding all sessions that affected a particular entity, checking what location moves happened last month, or auditing which narrators recorded what changes.

Each entry shows the session date, the session title and narrator, which entity was changed, what property was set (lokacja, grupa, status, etc.), and the new value. Results can be filtered by entity name, property type, or date range. Entries are sorted by date, then by entity name.

Example questions this answers: "What world changes happened in June 2025?" — "Which sessions changed Xeron Demonlord's properties?" — "Show me all location moves recorded last month."

## Transaction Ledger

The Transaction Ledger answers the question "Where did the money go?" It shows all Transfer directives from sessions in chronological order. This is the complete record of currency movements between entities.

Use this view when tracking all currency transactions for a specific character, investigating a balance discrepancy, reviewing all transactions of a specific denomination, or building a financial audit trail for a time period.

Each entry shows the session date, title, and narrator, the amount and denomination transferred, and who sent and who received the currency. When filtering to a specific entity, additional information appears: whether each transaction was incoming or outgoing for that entity, and a running balance showing cumulative effect. Results can be filtered by entity (source or destination), denomination, and date range.

Example questions this answers: "Show me all transactions involving Kupiec Orrin" — "What Korony transfers happened this month?" — "What is the net flow for Xeron Demonlord from all recorded transfers?"

## PU Assignment Log

The PU Assignment Log answers the question "When was PU processed?" It shows the history of PU processing runs — when each run happened and which sessions were included. This reads the processing history file that prevents double-counting.

Use this view when verifying that a specific session was included in a PU run, checking when the last PU processing happened, investigating why a session's PU might have been missed, or auditing the processing timeline.

Each entry shows when the PU run was executed (date, time, and timezone), how many sessions were included in that run, and for each session the header (date, title, narrator). Entries are sorted most recent first. Results can be filtered by date range.

Example questions this answers: "When was PU last processed?" — "Was the June 15th session included in the July PU run?" — "How many sessions were processed in each run this year?"

## Notification Log

The Notification Log answers the question "What Intel was sent?" It shows all Intel directives from sessions — targeted messages that were intended for specific recipients. This reconstructs the notification intent from session data.

Use this view when verifying what messages were generated for a specific recipient, checking whether a group or location notification reached the right targets, auditing the notification history for a time period, or investigating a player's claim that they did not receive an Intel message.

Each entry shows the session date, title, and narrator, the targeting directive (Direct, Grupa, or Lokacja), the target name, the message content, how many recipients were resolved, and the list of resolved recipient names. Results can be filtered by target name, directive type, and date range.

This view shows what was *intended* to be sent based on session data. Actual delivery to Discord is a separate concern — delivery logging is handled independently.

Example questions this answers: "What Intel messages targeted Xeron Demonlord?" — "What group-wide notifications went to Rada Czarodziejow?" — "What location-based messages were sent for Erathia?"

## Typical Audit Workflow

All audit views are read-only — they never modify data and can be used at any time without risk.

A complete audit workflow typically involves reviewing the PU Assignment Log to verify processing history, using the Change Log to review world-state changes for a period, checking Entity History for specific entities that need investigation, reviewing the Transaction Ledger for currency discrepancies, and consulting the Notification Log to verify Intel delivery intent.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Entity not found | Entity History returns an empty result with a warning | Verify the entity name spelling and check aliases |
| No sessions in date range | Change Log, Transaction Ledger, and Notification Log return empty results | Widen the date range or verify session dates |
| Processing history file missing | PU Assignment Log returns an empty result with a warning | Verify the file path; the file is created automatically during the first PU run |
| Unresolved Intel targets | Notification Log shows 0 recipients for that entry | The entity name in the Intel target may not match a known entity |

## Related Documents

- [World-State.md](World-State.md) — Entity management and world-state changes
- [Currency.md](Currency.md) — Currency tracking and reconciliation
- [PU.md](PU.md) — Monthly PU assignment process
- [Sessions.md](Sessions.md) — Session recording format (including @Zmiany, @Transfer, @Intel)
- [Troubleshooting.md](Troubleshooting.md) — Diagnosing data quality issues
- [Glossary](Glossary.md) — Term definitions

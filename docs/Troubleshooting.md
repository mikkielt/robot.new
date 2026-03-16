# Troubleshooting

## Scope

This guide helps Coordinators and Narrators identify, diagnose, and fix common data quality issues that can affect PU processing, session parsing, and notification delivery.

The guide covers common data quality issues and their symptoms, how to use the diagnostic tool, step-by-step fixes for each issue type, and when to escalate versus fix independently.

## When to Run Diagnostics

Run the diagnostic tool before each monthly PU assignment (recommended), when a PU assignment fails with unresolved character names, when a session appears to be "missing" from PU processing, and periodically to catch stale data before it becomes a problem.

## Unresolved Character Name

Symptom: PU assignment stops immediately with an error listing unresolved character names.

This happens when a character name in a session's PU entry does not match any registered character or alias. Common causes include a typo in the character name (e.g., "Crag Hak" instead of "Crag Hack"), a character that has not yet been registered in the system, or a nickname that is not registered as an alias.

To fix this, check the error message for the exact unresolved name, compare it with the known character roster, and then correct the issue. If it is a typo in the session file, correct the name in the PU entry. If it is a missing alias, ask the Coordinator to register the alias. If the character is unregistered, ask the Coordinator to register the character. Then retry the PU assignment.

The system attempts several strategies to match a name before giving up. Exact match checks whether the name matches a registered character name or alias (case-insensitive). Declension accounts for Polish grammatical forms (e.g., "Craga" for "Crag", "Sandry" for "Sandra"). Stem alternation tries common Polish consonant changes (e.g., "k"/"c", "g"/"dz"). Fuzzy match tolerates small typos (1-2 character differences) for longer names.

Matching may fail despite a valid name in certain situations. Very short names (2-3 characters) require the name to be long enough to allow edit distance tolerance. Unusual declension patterns with irregular Polish forms may not be handled automatically. Name collisions where a name closely resembles multiple entities may prevent confident resolution.

If a name form consistently fails to resolve, ask the Coordinator to add it as an alias to the character's entity entry. After the alias is registered, the system will match it exactly on future runs. You can verify the fix by running the diagnostic tool — previously unresolved names should now pass.

## Session with Broken Date

Symptom: A session is silently skipped during PU processing — no error, but the PU is not awarded.

This happens when the session header date is not in the correct `YYYY-MM-DD` format.

| Wrong format | Correct format |
|---|---|
| `2025-6-15` | `2025-06-15` |
| `15-06-2025` | `2025-06-15` |
| `2025/06/15` | `2025-06-15` |
| `2025-13-01` | (invalid month — must be 01-12) |
| `June 15, 2025` | `2025-06-15` |

To fix this, run the diagnostic tool (it reports sessions with broken dates that contain PU data), find the session in the Markdown file, fix the date in the header to `YYYY-MM-DD` format, and retry the PU assignment.

## Duplicate PU Entry

Symptom: The diagnostic tool flags a character appearing multiple times in the same session's PU block.

This happens when the same character was listed twice in one session, possibly with different PU values. To fix this, open the session file, find the duplicate entry, and remove the duplicate (keep the correct PU value).

## Malformed PU Value

Symptom: The diagnostic tool flags PU entries with missing or non-numeric values.

| Wrong | Correct |
|---|---|
| `- Crag Hack:` (no value) | `- Crag Hack: 0.3` |
| `- Crag Hack: trzy` | `- Crag Hack: 0.3` |
| `- Crag Hack 0.3` (missing colon) | `- Crag Hack: 0.3` |

To fix this, open the session file, fix the PU entry to include a valid decimal value, and use a period (`.`) as the decimal separator.

## Missing Webhook Address

Symptom: PU is calculated and applied correctly, but the player does not receive a Discord notification.

To fix this, ask the Coordinator to add the player's webhook address. The webhook URL must follow the format `https://discord.com/api/webhooks/...`. Once added, the notification can be re-sent manually if needed.

## Stale History Entries

Symptom: The diagnostic tool reports session headers in the processing history that no longer match any session in the repository.

This happens when a session was renamed, deleted, or its header was modified after it was already processed. Stale entries do not cause processing errors, but they clutter the history file.

To fix this, review the flagged entries and determine if the session was renamed (find the new header) or genuinely deleted. If the stale entries are harmless, no action is needed. For cleanup, coordinate with the team before modifying the history file.

## Session Not Appearing in PU Processing

Symptom: A session exists in the repository but is not picked up during PU assignment.

| Check | What to look for |
|---|---|
| Date format | Is the date in `YYYY-MM-DD` format? |
| Date range | Is the session date within the processing period? |
| PU block | Does the session have a `- @PU:` or `- PU:` block? |
| Already processed | Was this session already processed in a previous run? |
| File location | Is the file a `.md` file inside the repository? |

## Intel Not Delivered

Symptom: An Intel message was not received by the intended recipient.

| Check | What to look for |
|---|---|
| Target name | Does the target name resolve to a known entity? |
| Targeting syntax | Is the syntax correct (`Grupa/Name`, `Lokacja/Name`, or bare `Name`)? |
| Webhook | Does the target entity or its owning player have a webhook configured? |
| Group membership | Is the entity a member of the group at the session date? |
| Location | Is the entity present at the location at the session date? |

## Using the Diagnostic Tool

The diagnostic tool validates data quality without making any changes.

| Check | What it finds |
|---|---|
| Unresolved characters | PU entries with character names that do not match any known character |
| Malformed PU values | Entries with missing or non-numeric PU values |
| Duplicate entries | Same character listed multiple times in one session's PU block |
| Failed sessions with PU data | Sessions with broken date formats that contain PU data |
| Stale history entries | Processed session headers that no longer match any session |

The diagnostic produces a clear pass/fail result. If any issue is found, resolve it before running the actual PU assignment.

## When to Escalate

Fix it yourself: typos in character names or dates, missing PU values, and duplicate entries.

Ask the Coordinator: registering new characters or aliases, adding or updating webhook addresses, cleaning up the processing history, and reactivating removed characters.

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Sessions.md](Sessions.md) — Session recording guide
- [Players.md](Players.md) — Player and character management
- [Name-Resolution.md](Name-Resolution.md) — How name matching works
- [Glossary](Glossary.md) — Term definitions

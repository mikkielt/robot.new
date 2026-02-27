# Troubleshooting

## Purpose

This guide helps coordinators and narrators identify, diagnose, and fix common data quality issues that can affect PU processing, session parsing, and notification delivery.

## Scope

**What is included:**

- Common data quality issues and their symptoms
- How to use the diagnostic tool
- Step-by-step fixes for each issue type
- When to escalate vs. fix independently

**What is excluded:**

- Technical implementation details
- Module development and debugging

## When to Run Diagnostics

Run the diagnostic tool:

- **Before** each monthly PU assignment (recommended)
- When a PU assignment fails with unresolved character names
- When a session appears to be "missing" from PU processing
- Periodically, to catch stale data before it becomes a problem

## Common Issues and Fixes

### 1. Unresolved Character Name

**Symptom:** PU assignment stops immediately with an error listing unresolved character names.

**Why it happens:** A character name in a session's PU entry does not match any registered character or alias.

**Common causes:**
- Typo in the character name (e.g., `Crag Hak` instead of `Crag Hack`)
- Character not yet registered in the system
- Using a nickname that is not registered as an alias

**How to fix:**

1. Check the error message for the exact unresolved name
2. Compare it with the known character roster
3. Fix the issue:
   - **Typo in session file:** Correct the name in the PU entry
   - **Missing alias:** Ask the coordinator to register the alias
   - **Unregistered character:** Ask the coordinator to register the character
4. Retry the PU assignment

### 2. Session with Broken Date

**Symptom:** A session is silently skipped during PU processing — no error, but the PU is not awarded.

**Why it happens:** The session header date is not in the correct `YYYY-MM-DD` format.

**Common mistakes:**

| Wrong format | Correct format |
|---|---|
| `2025-6-15` | `2025-06-15` |
| `15-06-2025` | `2025-06-15` |
| `2025/06/15` | `2025-06-15` |
| `2025-13-01` | (invalid month — must be 01–12) |
| `June 15, 2025` | `2025-06-15` |

**How to fix:**

1. Run the diagnostic tool — it reports sessions with broken dates that contain PU data
2. Find the session in the Markdown file
3. Fix the date in the header to `YYYY-MM-DD` format
4. Retry the PU assignment

### 3. Duplicate PU Entry

**Symptom:** The diagnostic tool flags a character appearing multiple times in the same session's PU block.

**Why it happens:** The same character was listed twice in one session, possibly with different PU values.

**How to fix:**

1. Open the session file
2. Find the duplicate entry
3. Remove the duplicate (keep the correct PU value)

### 4. Malformed PU Value

**Symptom:** The diagnostic tool flags PU entries with missing or non-numeric values.

**Common mistakes:**

| Wrong | Correct |
|---|---|
| `- Crag Hack:` (no value) | `- Crag Hack: 0.3` |
| `- Crag Hack: trzy` | `- Crag Hack: 0.3` |
| `- Crag Hack 0.3` (missing colon) | `- Crag Hack: 0.3` |

**How to fix:**

1. Open the session file
2. Fix the PU entry to include a valid decimal value
3. Use a period (`.`) as the decimal separator

### 5. Missing Webhook Address

**Symptom:** PU is calculated and applied correctly, but the player does not receive a Discord notification.

**How to fix:**

1. Ask the coordinator to add the player's webhook address
2. The webhook URL must follow the format: `https://discord.com/api/webhooks/...`
3. Once added, the notification can be re-sent manually if needed

### 6. Stale History Entries

**Symptom:** The diagnostic tool reports session headers in the processing history that no longer match any session in the repository.

**Why it happens:** A session was renamed, deleted, or its header was modified after it was already processed.

**Impact:** Stale entries do not cause processing errors, but they clutter the history file.

**How to fix:**

1. Review the flagged entries
2. Determine if the session was renamed (find the new header) or genuinely deleted
3. If the stale entries are harmless, no action is needed
4. For cleanup: coordinate with the team before modifying the history file

### 7. Session Not Appearing in PU Processing

**Symptom:** A session exists in the repository but is not picked up during PU assignment.

**Possible causes and checks:**

| Check | What to look for |
|---|---|
| **Date format** | Is the date in `YYYY-MM-DD` format? |
| **Date range** | Is the session date within the processing period? |
| **PU block** | Does the session have a `- @PU:` or `- PU:` block? |
| **Already processed** | Was this session already processed in a previous run? |
| **File location** | Is the file a `.md` file inside the repository? |

### 8. Intel Not Delivered

**Symptom:** An Intel message was not received by the intended recipient.

**Possible causes:**

| Check | What to look for |
|---|---|
| **Target name** | Does the target name resolve to a known entity? |
| **Targeting syntax** | Is the syntax correct (`Grupa/Name`, `Lokacja/Name`, or bare `Name`)? |
| **Webhook** | Does the target entity or its owning player have a webhook configured? |
| **Group membership** | Is the entity a member of the group at the session date? |
| **Location** | Is the entity present at the location at the session date? |

## Using the Diagnostic Tool

The diagnostic tool validates data quality without making any changes. It checks:

| Check | What it finds |
|---|---|
| **Unresolved characters** | PU entries with character names that do not match any known character |
| **Malformed PU values** | Entries with missing or non-numeric PU values |
| **Duplicate entries** | Same character listed multiple times in one session's PU block |
| **Failed sessions with PU data** | Sessions with broken date formats that contain PU data |
| **Stale history entries** | Processed session headers that no longer match any session |

The diagnostic produces a clear **pass/fail** result. If any issue is found, resolve it before running the actual PU assignment.

## When to Escalate

Fix it yourself:
- Typos in character names or dates
- Missing PU values
- Duplicate entries

Ask the coordinator:
- Registering new characters or aliases
- Adding or updating webhook addresses
- Cleaning up the processing history
- Reactivating removed characters

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Sessions.md](Sessions.md) — Session recording guide
- [Players.md](Players.md) — Player and character management
- [Glossary](Glossary.md) — Term definitions

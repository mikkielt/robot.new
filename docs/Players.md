# Player & Character Management

## Purpose

This guide explains how coordinators register new players, create and update characters, and manage the player roster. It covers the full lifecycle from registration through ongoing updates to character removal.

## Scope

**What is included:**

- Registering new players
- Creating new characters (including starting PU calculation)
- Updating player and character data
- Removing characters (soft-delete)
- What changes for players after updates

**What is excluded:**

- Monthly PU assignment process (see [PU.md](PU.md))
- Session recording (see [Sessions.md](Sessions.md))
- Internal data structures and file formats

## Actors and Responsibilities

### Coordinator

- Registers new players with their basic information
- Creates new characters for players
- Updates player metadata (webhook, triggers)
- Updates character data (PU values, aliases, status, character sheet)
- Removes characters when needed (soft-delete)

### Player

- Provides their Margonem ID and Discord webhook address
- Requests new characters or reports issues to the coordinator
- Receives updates automatically via Discord notifications

## Adding a New Player

### What is needed

| Information | Required | Description |
|---|---|---|
| Player name | Yes | Display name used throughout the system |
| Margonem ID | Recommended | Game platform identifier |
| Discord webhook | Recommended | For receiving PU and Intel notifications |
| First character name | Optional | Can create the first character at the same time |

### What happens

1. The coordinator registers the player in the entity store
2. The system validates that no duplicate player exists (throws an error if one does)
3. If a first character is requested, it is created at the same time
4. The player's data becomes available for name resolution, PU processing, and notifications

### What the player sees

- Discord notifications begin arriving when webhook is configured
- Their character appears in PU reports and session records

## Adding a New Character

### What is needed

| Information | Required | Description |
|---|---|---|
| Player name | Yes | Which player owns the character |
| Character name | Yes | Must be unique across all characters |
| Character sheet URL | Recommended | Link to the character sheet |
| Starting PU | Optional | Calculated automatically if not specified |

### Starting PU calculation

When a new character is created without specifying starting PU, the system calculates it automatically:

1. Sum all earned PU (PU zdobyte) across the player's existing characters
2. Formula: **half of the total earned PU plus 20, rounded down**
3. New players with no prior characters start at **20 PU**

**Example:** A player has two characters with 30 and 10 earned PU. New character starts with: floor((30 + 10) / 2 + 20) = floor(40) = **40 PU**.

### What happens

1. The character is registered in the entity store with ownership and starting PU
2. A character file is created from a standard template (unless skipped)
3. The character becomes available for PU processing and name resolution
4. If the player doesn't exist yet, a player entry is automatically created

## Updating Player Data

### What can be updated

| Field | Description | Example |
|---|---|---|
| Discord webhook | Address for receiving notifications | `https://discord.com/api/webhooks/...` |
| Margonem ID | Game platform identifier | `12345` |
| Triggers | Restricted session topics the player wants to avoid | `spiders`, `heights` |

### Webhook validation

The Discord webhook URL must follow the format `https://discord.com/api/webhooks/...`. Invalid URLs are rejected.

### Trigger replacement

When triggers are updated, all existing triggers are replaced with the new list. To add a trigger, the full list must be provided.

## Updating Character Data

### Entity-level data

These updates affect the character's record in the entity store:

| Field | Description |
|---|---|
| PU values | Sum, earned, overflow, starting PU |
| Aliases | Alternative names for name resolution |
| Status | Active (`Aktywny`), Inactive (`Nieaktywny`), or Removed (`Usunięty`) |

**PU auto-derivation:** When updating PU Sum, the system automatically calculates PU Earned if it's missing (and vice versa), using the formula: Earned = Sum − Starting.

**Aliases are additive:** New aliases are added alongside existing ones. They are not replaced.

### Character file data

These updates affect the character's individual file:

| Field | Description |
|---|---|
| Character sheet | URL to the character sheet |
| Restricted topics | Session topics the player wants to avoid |
| Condition | Character's current health/condition |
| Special items | Notable items the character possesses |
| Reputation | Three-tier reputation (positive, neutral, negative) with locations |
| Additional notes | Free-form notes about the character |

**Unknown special items** are automatically registered as new entities in the system.

### Both targets are updated in a single operation

When the coordinator updates a character, both the entity store and the character file are modified in one step.

## Removing a Character

### What happens

1. The character is marked as **removed** (`Usunięty`) with an effective date
2. No data is physically deleted — the character remains in the system
3. Removed characters stop appearing in standard queries and PU processing
4. This action requires explicit confirmation due to its significance

### Reversal

Removed characters can be reactivated by updating their status back to `Aktywny`.

### Viewing removed characters

Removed characters are hidden by default but can be included in queries when needed.

## Expected Outcomes

After player and character management operations:

1. **Player data is consistent** — webhook, triggers, and Margonem ID are validated and stored
2. **Characters are properly owned** — each character is linked to its player
3. **Starting PU is fair** — calculated automatically based on the player's total earned PU
4. **Name resolution works** — character names and aliases are indexed for automatic matching
5. **Removed characters are preserved** — soft-delete ensures no historical data is lost

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Duplicate player name** | Registration fails with an error | Use a different name or check for existing entries |
| **Duplicate character name** | Creation fails with an error | Use a different name |
| **Invalid webhook URL** | Update fails with validation error | Provide a valid `https://discord.com/api/webhooks/...` URL |
| **Character has no player** | Player entry is automatically created | No action needed |
| **Removed character referenced in session** | Character exists in the data for historical accuracy | No action needed; use include-deleted option to view |

## Audit Trail / Evidence of Completion

- **Entity store changes**: All player and character updates are committed to the repository, providing full Git history
- **Character files**: Individual files in `Postaci/Gracze/` track character-level changes
- **Discord notifications**: Players receive confirmation of PU updates

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Sessions.md](Sessions.md) — How sessions are recorded
- [Glossary](Glossary.md) — Term definitions
- [Migration](Migration.md) — Transition from the legacy system

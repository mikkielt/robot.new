# Player & Character Management

## Overview

Coordinators register new players, create and update characters, and manage the player roster. This guide covers the full lifecycle from registration through ongoing updates to character removal.

## Actors and Responsibilities

The Coordinator registers new players with their basic information, creates new characters for players, updates player metadata (webhook, triggers), updates character data (PU values, aliases, status, character sheet), and removes characters when needed (soft-delete).

The Player provides their Margonem ID and Discord webhook address, requests new characters or reports issues to the Coordinator, and receives updates automatically via Discord notifications.

## Adding a New Player

The following information is used during registration:

| Information | Required | Description |
|---|---|---|
| Player name | Yes | Display name used throughout the system |
| Margonem ID | Recommended | Game platform identifier |
| Discord webhook | Recommended | For receiving PU and Intel notifications |
| First character name | Optional | Can create the first character at the same time |

The Coordinator registers the player in the entity store. The system validates that no duplicate player exists (throws an error if one does). If a first character is requested, it is created at the same time. The player's data becomes available for name resolution, PU processing, and notifications.

Once registered, the player begins receiving Discord notifications when a webhook is configured, and their character appears in PU reports and session records.

## Adding a New Character

The following information is used when creating a character:

| Information | Required | Description |
|---|---|---|
| Player name | Yes | Which player owns the character |
| Character name | Yes | Must be unique across all characters |
| Character sheet URL | Recommended | Link to the character sheet |
| Starting PU | Optional | Calculated automatically if not specified |

When a new character is created without specifying starting PU, the system calculates it automatically. It sums all earned PU (PU zdobyte) across the player's existing characters, then applies the formula: half of the total earned PU plus 20, rounded down. New players with no prior characters start at 20 PU.

Example: A player has two characters with 30 and 10 earned PU. New character starts with: floor((30 + 10) / 2 + 20) = floor(40) = 40 PU.

The character is registered in the entity store with ownership and starting PU. A character file is created from a standard template (unless skipped). The character becomes available for PU processing and name resolution. If the player does not exist yet, a player entry is automatically created.

## Updating Player Data

The following player fields can be updated:

| Field | Description | Example |
|---|---|---|
| Discord webhook | Address for receiving notifications | `https://discord.com/api/webhooks/...` |
| Margonem ID | Game platform identifier | `12345` |
| Triggers | Restricted session topics the player wants to avoid | `spiders`, `heights` |

The Discord webhook URL must follow the format `https://discord.com/api/webhooks/...`. Invalid URLs are rejected. When triggers are updated, all existing triggers are replaced with the new list. To add a trigger, the full list must be provided.

## Updating Character Data

Character updates affect two targets in a single operation: the entity store and the character file.

Entity-level data in the entity store includes:

| Field | Description |
|---|---|
| PU values | Sum, earned, overflow, starting PU |
| Aliases | Alternative names for name resolution |
| Status | Active (Aktywny), Inactive (Nieaktywny), or Removed (Usunięty) |

When updating PU Sum, the system automatically calculates PU Earned if it is missing (and vice versa), using the formula: Earned = Sum - Starting. New aliases are added alongside existing ones — they are additive, not replaced.

Character file data includes:

| Field | Description |
|---|---|
| Character sheet | URL to the character sheet |
| Restricted topics | Session topics the player wants to avoid |
| Condition | Character's current health/condition |
| Special items | Notable items the character possesses |
| Reputation | Three-tier reputation (positive, neutral, negative) with locations |
| Additional notes | Free-form notes about the character |

Unknown special items are automatically registered as new entities in the system.

## Removing a Character

The character is marked as removed (Usunięty) with an effective date. No data is physically deleted — the character remains in the system. Removed characters stop appearing in standard queries and PU processing. This action requires explicit confirmation due to its significance.

Removed characters can be reactivated by updating their status back to Aktywny. Removed characters are hidden by default but can be included in queries when needed.

## Expected Outcomes

After player and character management operations:

1. Player data is consistent — webhook, triggers, and Margonem ID are validated and stored
2. Characters are properly owned — each character is linked to its player
3. Starting PU is fair — calculated automatically based on the player's total earned PU
4. Name resolution works — character names and aliases are indexed for automatic matching
5. Removed characters are preserved — soft-delete ensures no historical data is lost

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Duplicate player name | Registration fails with an error | Use a different name or check for existing entries |
| Duplicate character name | Creation fails with an error | Use a different name |
| Invalid webhook URL | Update fails with validation error | Provide a valid `https://discord.com/api/webhooks/...` URL |
| Character has no player | Player entry is automatically created | No action needed |
| Removed character referenced in session | Character exists in the data for historical accuracy | No action needed; use include-deleted option to view |

## Audit Trail

- Entity store changes — all player and character updates are committed to the repository, providing full Git history
- Character files — each character's individual file tracks character-level changes (condition, items, reputation)
- Discord notifications — players receive confirmation of PU updates

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Sessions.md](Sessions.md) — How sessions are recorded
- [Glossary](Glossary.md) — Term definitions
- [Structures](Structures.md) — What data the system tracks for each concept
- [Migration](Migration.md) — Transition from the legacy system

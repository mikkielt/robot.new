# Entity & World State

## Purpose

This guide explains how the repository tracks the state of the game world — NPCs, organizations, locations, and player characters. It covers how world-state changes from sessions are recorded, how the system tracks things that change over time, and how to query the current or historical state of any entity.

## Scope

**What is included:**

- What entities are and how they are organized
- How session changes (Zmiany) update entity data
- How temporal scoping works (things that change over time)
- How to understand the current and historical state of entities
- What the entity store contains

**What is excluded:**

- Player and character registration (see [Players.md](Players.md))
- Session recording format (see [Sessions.md](Sessions.md))
- Internal data structures and parsing details

## Actors and Responsibilities

### Narrator

- Records world-state changes in sessions via `@Zmiany` blocks
- Ensures entity names in changes match known entities

### Coordinator

- Maintains the entity registry (NPCs, organizations, locations)
- Reviews diagnostic reports for unresolved entity names
- Adds new entities when they first appear in the game world

## What Are Entities?

An entity is any named element of the game world that the system tracks. Each entity has a type:

| Entity type | What it represents | Examples |
|---|---|---|
| **NPC** | A non-player character | Sandro, Lord Haart |
| **Organizacja** | A group, faction, or organization | Bractwo Miecza, Nekromanci |
| **Lokacja** | A place in the game world | Erathia, Bracada, Zamek Steadwick |
| **Gracz** | A player (real person) | Roland, Catherine |
| **Postać (Gracz)** | A player character | Crag Hack, Gem |
| **Przedmiot** | A notable item | Miecz Piekieł, Tarcza Krasnoludów |

## How Entities Are Organized

### The Entity Store

All entity data is stored in structured Markdown files. Each entity has:

- A **name** — the canonical display name
- A **type** — which category it belongs to
- **Metadata** — properties like location, group memberships, status, and aliases
- **History** — a timeline of changes to each property

### Location Hierarchy

Locations can contain other locations, forming a hierarchy:

```
Antagarich (continent)
└── Erathia (city)
    ├── Zamek Steadwick (building)
    └── Plac Gryfów (district)
└── Bracada (city)
```

This hierarchy is used for location-based Intel targeting — a message sent to "Lokacja/Erathia" reaches everyone in Erathia and all its sub-locations.

### Aliases

Entities can have alternative names (aliases) that the system recognizes. For example, "Sandro" might also be known as "Mroczny Mag" or "Lich z Deyji".

Aliases can be **time-scoped** — valid only during a specific period. For example, a character might use a different name while undercover.

## How World State Changes

### Session Changes (Zmiany)

When something changes in the game world during a session, the narrator records it in the `@Zmiany` block:

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine
- @Zmiany:
    - Crag Hack
        - @lokacja: Bracada
        - @grupa: Bractwo Miecza
    - Sandro
        - @lokacja: Bracada
```

This records that:
- Crag Hack moved to Bracada and joined the Bractwo Miecza
- Sandro moved to Bracada

These changes are applied with the session's date as the effective date.

### What can change

| Property | What it means |
|---|---|
| `@lokacja` | Where the entity is permanently located |
| `@grupa` | Which group/faction the entity belongs to |
| `@status` | Whether the entity is active, inactive, or removed |
| `@alias` | An alternative name for the entity |
| Any other property | Custom metadata stored with the entity |

### Automatic dating

When a change is recorded in a session, it automatically receives the session's date as its starting point. This means you don't need to specify dates manually — the system knows when each change took effect.

## Temporal Scoping

### What it means

Many entity properties change over time. The system tracks not just the current value, but the full history:

- **When did this NPC move to Bracada?** → After the session on 2025-06-15
- **Who was in the Bractwo Miecza in January 2024?** → All entities with an active `@grupa` membership at that date
- **What was this character's status last year?** → Check the status history

### How it works

Each property change has a validity period:
- **Always active** — no dates specified (e.g., an entity's original name)
- **Open-ended** — starts on a date, no end (e.g., `(2025-06:)` = from June 2025 onward)
- **Bounded** — starts and ends on specific dates (e.g., `(2024-01:2024-06)` = January to June 2024)

The most recent active value wins for single-value properties (like location). For multi-value properties (like group memberships), all active values are collected.

## Three Sources of Entity Data

The system combines data from three sources to build the complete picture:

| Source | What it provides | Temporal behavior |
|---|---|---|
| **Entity store** (entities.md) | Registered entities with their base properties | Properties can be time-scoped |
| **Session changes** (`@Zmiany`) | Updates from gameplay sessions | Automatically dated to the session date |
| **Character files** (for player characters) | Character sheet, condition, items, reputation | Undated baseline (always active) |

When querying entity state, all three sources are merged. The most recent dated value takes priority.

## Understanding Location

Entities can be "at" a location in three ways:

1. **Permanent location** (entity store): Where the entity normally resides
2. **Session visit** (session locations): Where the entity was during a specific session (temporary)
3. **Permanent move** (session Zmiany): The entity moved as a result of a session (permanent change)

When asking "where was X on date Y?", the system checks session visits first, then falls back to the permanent location.

## Expected Outcomes

The world-state tracking system ensures:

1. **Consistent world state** — all changes are recorded with dates and applied automatically
2. **Historical accuracy** — you can query what the world looked like at any point in time
3. **Automatic updates** — session changes are applied without manual entity editing
4. **Name resolution** — entity names and aliases are recognized in session text
5. **Intel targeting** — group and location memberships determine who receives targeted messages

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Unresolved entity name in Zmiany** | The change is skipped with a warning | Add the entity to the registry or fix the name |
| **Circular location hierarchy** | Detected automatically; falls back to flat naming | Fix the `@lokacja` chain to remove the cycle |
| **Entity in multiple files** | Data is merged across files automatically | No action needed |
| **Conflicting property values** | Most recent dated value wins | Check which source has the latest date |

## Related Documents

- [Sessions.md](Sessions.md) — How to record session changes
- [Players.md](Players.md) — Player and character management
- [Notifications.md](Notifications.md) — How Intel targeting uses entity data
- [Glossary](Glossary.md) — Term definitions

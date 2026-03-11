# Entity & World State

## Purpose

This guide explains how the repository tracks the state of the game world - NPCs, groups, locations, and player characters. It covers how world-state changes from sessions are recorded, how the system tracks things that change over time, and how to query the current or historical state of any entity.

## Scope

**What is included:**

- What entities are and how they are organized
- How coordinators manage entities (create, update, remove)
- How session changes (Zmiany) update entity data
- How temporal scoping works (things that change over time)
- How currency is tracked, transferred, and managed - including out-of-game reserves
- How to understand the current and historical state of entities

**What is excluded:**

- Player and character registration (see [Players.md](Players.md))
- Session recording format (see [Sessions.md](Sessions.md))
- Internal data structures and parsing details

## Actors and Responsibilities

### Narrator

- Records world-state changes in sessions via `@Zmiany` blocks
- Ensures entity names in changes match known entities

### Coordinator

- Maintains the entity registry (NPCs, groups, locations)
- Creates, updates, and removes entities using dedicated commands
- Reviews diagnostic reports for unresolved entity names
- Manages currency reserves and distributes budgets to narrators

## What Are Entities?

An entity is any named element of the game world that the system tracks. Each entity has a type:

| Entity type | What it represents | Examples |
|---|---|---|
| **NPC** | A non-player character | Sandro, Lord Haart |
| **Grupa** | A group, faction, or organization | Bractwo Miecza, Nekromanci |
| **Lokacja** | A place in the game world | Erathia, Bracada, Zamek Steadwick |
| **Mapa** | A game map (floor/interior) tied to a location | Komnata Rady, Piwnica Ratusza |
| **Gracz** | A player (real person) | Roland, Catherine |
| **Postać** | A player character | Crag Hack, Gem |
| **Przedmiot** | A notable item | Miecz Piekieł, Tarcza Krasnoludów |

## Managing Entities

### Adding New Entities

When a new NPC, group, location, or item first appears in the game world, the coordinator registers it in the entity store. Each entity gets a type, a name, and optional starting properties (such as initial location or group membership).

Player and character entities are managed through the player registration process - see [Players.md](Players.md).

### Updating Entities

The coordinator can update any entity's properties at any time. Each update is time-stamped, so the system preserves a full history of what changed and when. This is separate from session changes - coordinators use this for administrative corrections or out-of-session updates.

When two entities share the same name across different types, the coordinator specifies the type to disambiguate.

### Removing Entities

Entities are never physically deleted. Instead, the coordinator marks them as removed ("Usunięty") with an effective date. Removed entities:

- Stop appearing in standard queries and reports
- Remain available for historical lookups
- Can be restored later if the removal was a mistake

## Currency

### What This Covers

Currency in the Nerthus world is tracked as physical items that characters can carry, drop, trade, or store. This section explains how currency is recorded, how transfers between characters work, and how coordinators can verify that nothing was lost or duplicated.

### The Three Denominations

| Denomination | Tier | Common short forms |
|---|---|---|
| Korony Elanckie | Gold | koron, korony |
| Talary Hirońskie | Silver | talarów, talary |
| Kogi Skeltvorskie | Copper | kogi, kog |

**Exchange rates**: 100 Kog = 1 Talar, 100 Talarów = 1 Korona (so 1 Korona = 10 000 Kogi).

### How Currency Belongs to Someone

Every currency holding is recorded as a separate Przedmiot (item) in the entity store. The item name follows the convention **"{Denomination} {Owner}"** - for example, "Korony Xeron Demonlorda" or "Kogi Gildi Kupców".

Each currency item specifies:

- **Who owns it** - the character or group that carries the coins
- **Or where it is** - if the coins are dropped at a location instead of carried
- **How many coins** - the current count

Currency is either carried by someone or dropped somewhere - never both at the same time.

### Recording Currency Changes in Sessions

There are two ways to record that currency changed hands during a session.

#### Option 1: Quick Transfer (recommended for simple moves)

Use `@Transfer` when coins move from one character to another. Write it as a session-level entry:

```markdown
### 2025-06-01, Handel na rynku, Solmyr

- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
- @Transfer: 50 talarów, Kupiec Orrin -> Kyrre
```

The format is: `- @Transfer: {amount} {denomination}, {source} -> {destination}`

You can use colloquial denomination names ("koron", "talarów", "kogi") - the system recognizes them automatically. Multiple transfers per session are allowed.

The system finds the right currency items for the source and destination and adjusts the counts automatically. If a character's currency item doesn't exist yet, the system will warn you - create the item first.

#### Option 2: Manual Zmiany (for complex scenarios)

When currency changes involve more than simple transfers (e.g., coins found as loot, destroyed, or split across stacks), record them manually in the Zmiany block:

```markdown
- Zmiany:
    - Korony Xeron Demonlorda
        - @ilość: -20
    - Korony Kupca Orrina
        - @ilość: +20
```

Use `+N` to add coins and `-N` to subtract coins.

### Currency Lifecycle

| Status | What it means |
|---|---|
| **Aktywny** | Currency is in play. Balance is tracked and reported. |
| **Nieaktywny** | Currency is out of play (lost account, confiscated, frozen). Balance is preserved but hidden from reports. Can be restored later. |
| **Usunięty** | The entry was a mistake. Ignored everywhere. |

### Checking Currency Holdings

The coordinator can review currency across the world at any time. Holdings can be filtered by owner (who has the coins) or by denomination (which type of coin). Deleted or inactive entries are hidden by default but can be included when needed for auditing.

### Managing Currency Holdings

The coordinator can directly create, adjust, or remove currency holdings outside of sessions:

- **Creating** a new currency holding for a character or group - the system auto-generates the entity name from the denomination and owner (e.g., "Korony Erdamon")
- **Adjusting** a holding's quantity, either to a specific value or by adding/subtracting a delta
- **Transferring** ownership to a different character or group
- **Dropping** currency at a location instead of carried by someone
- **Removing** a holding - soft-delete with a warning if the balance is not zero

These actions are time-stamped and preserved in history, just like session changes.

### Out-of-Game Currency: The Treasury

Not all currency is in active gameplay. Coordinators maintain a reserve pool and distribute budgets to narrators before sessions. Narrators then award currency to player characters during gameplay.

This out-of-game supply chain is modeled using a **group** entity as the treasury (e.g., "Skarbiec Koordynatorów"). The coordinator creates currency holdings owned by the treasury, then distributes portions to narrators as needed.

**The distribution flow works like this:**

1. **Coordinator creates the treasury** - a one-time setup. A Grupa entity represents the currency reserve, with initial currency holdings for each denomination.

2. **Coordinator distributes to narrator** - before a session, the coordinator subtracts from the treasury's balance and adds to a narrator's budget. This happens outside any game session and is tracked through the entity history.

3. **Narrator awards to player character** - during the session, the narrator records a `@Transfer` in the standard session format. The system handles the balance adjustments automatically.

The total currency supply across all holders - treasury, narrators, and player characters - should remain constant over time. Monthly reconciliation detects any supply drift, which may indicate a recording error or forgotten adjustment.

### Reconciliation - Catching Errors

A monthly reconciliation check can flag problems automatically:

- **Negative balance** - a character somehow has fewer than zero coins (likely a recording error)
- **Stale balance** - someone has currency that hasn't changed in over 3 months (may need review)
- **Orphaned currency** - currency assigned to a character who is no longer active
- **Asymmetric transactions** - coins left a character but didn't arrive anywhere (or vice versa)
- **Supply tracking** - total coins per denomination across the entire world, for detecting drift over time

Reconciliation can run as a standalone check or as part of the monthly PU process.

### Common Risks and How to Avoid Them

| Risk | What can happen | How to prevent it |
|---|---|---|
| **Dual placement** | Currency recorded as both carried and dropped at the same time | When moving currency, always end the previous placement before starting the new one |
| **Negative quantities** | More coins subtracted than available | Reconciliation flags this automatically |
| **Phantom creation** | Currency created without an in-game source | Only coordinators should create new currency items |
| **Quantity mismatch** | Splitting or merging stacks without correct totals | Verify the total stays constant; use @Transfer for simple moves |
| **Orphaned currency** | Coins belonging to a deleted or inactive character | Reconciliation flags this automatically |
| **Multiple stacks** | Same character has multiple entries for the same denomination | Allowed - total wealth is the sum of all stacks |
| **Accuracy drift** | Physical items lost or transferred outside session scope | Monthly reconciliation + periodic baseline resets |

## How Entities Are Organized

### The Entity Store

All entity data is stored in structured Markdown files. Each entity has:

- A **name** - the canonical display name
- A **type** - which category it belongs to
- **Metadata** - properties like location, group memberships, status, and aliases
- **History** - a timeline of changes to each property

### Location Hierarchy

Locations can contain other locations, forming a hierarchy:

```
Antagarich (continent)
└── Erathia (city)
    ├── Zamek Steadwick (building)
    └── Plac Gryfów (district)
└── Bracada (city)
```

This hierarchy is used for location-based Intel targeting - a message sent to "Lokacja/Erathia" reaches everyone in Erathia and all its sub-locations.

### Nerthus Names

Locations in Margonem have game-assigned names, but the Nerthus RP server uses its own names for many locations. Use `@nazwa_nerthus` to record the RP override name:

```markdown
* Gwiżdżąca Grota
    - @nazwa_nerthus: Kryjówka Craga Hacka (2024-01:)
```

The entity's `Name` stays as the Margonem game name. The Nerthus name is added to the entity's searchable names, so both names resolve to the same entity.

### Map Entities (Mapa) vs Location Entities (Lokacja)

**Mapa** entities represent individual game maps — each floor, interior, or instance from the Margonem map registry. Every Mapa entity carries a unique game map ID, a map type (outdoor or indoor), a CDN image URL, and tile dimensions. Mapa entities are stored in a dedicated overflow file due to their volume (~2,704 entries).

**Lokacja** entities represent conceptual places in the game world — deduplicated location names derived from the Mapa hierarchy. A single Lokacja (e.g., "Gwiżdżąca Grota") may correspond to many Mapa entities (one per floor or variant). Lokacja entities live in the main entity store.

Both Mapa and Lokacja entities participate in the location hierarchy via `@lokacja` — they can have a parent location, door connections, and Nerthus names. When two maps share the same name (e.g., multiple "Apartament" in different buildings), each can be given a unique slug to distinguish them.

### Slugs (Disambiguation)

When multiple entities share the same name (common with maps and generic locations), a slug provides a unique identifier that the system recognizes for resolution. For example, two maps both named "Komnata Rady" can be distinguished by their slugs "komnata-rady-ratusz" and "komnata-rady-zamek".

Slugs are searchable — you can use a slug anywhere an entity name is expected, and the system will find the right entity.

### Aliases

Entities can have alternative names (aliases) that the system recognizes. For example, "Sandro" might also be known as "Mroczny Mag" or "Lich z Deyji".

Aliases can be **time-scoped** - valid only during a specific period. For example, a character might use a different name while undercover.

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
| `@info` | A description or note about the entity (displayed prominently in the entity card) |
| Any other property | Custom metadata stored with the entity |

### Automatic dating

When a change is recorded in a session, it automatically receives the session's date as its starting point. This means you don't need to specify dates manually - the system knows when each change took effect.

## Temporal Scoping

### What it means

Many entity properties change over time. The system tracks not just the current value, but the full history:

- **When did this NPC move to Bracada?** -> After the session on 2025-06-15
- **Who was in the Bractwo Miecza in January 2024?** -> All entities with an active `@grupa` membership at that date
- **What was this character's status last year?** -> Check the status history

### How it works

Each property change has a validity period:
- **Always active** - no dates specified (e.g., an entity's original name)
- **Open-ended** - starts on a date, no end (e.g., `(2025-06:)` = from June 2025 onward)
- **Bounded** - starts and ends on specific dates (e.g., `(2024-01:2024-06)` = January to June 2024)
- **Seasonal** - active only during a specific season (e.g., `(zima)` = active in winter)
- **Date + seasonal** - both date range and season must match (e.g., `(2024-01:, lato)` = from January 2024, but only in summer)

Season keywords (Polish): `wiosna` (spring, Mar-May), `lato` (summer, Jun-Aug), `jesień` (autumn, Sep-Nov), `zima` (winter, Dec-Feb).

The most recent active value wins for single-value properties (like location). For multi-value properties (like group memberships), all active values are collected.

## Three Sources of Entity Data

The system combines data from three sources to build the complete picture:

| Source | What it provides | Temporal behavior |
|---|---|---|
| **Entity store** | Registered entities with their base properties | Properties can be time-scoped |
| **Session changes** (`@Zmiany`) | Updates from gameplay sessions | Automatically dated to the session date |
| **Character files** (for player characters) | Character sheet, condition, items, reputation | Undated baseline (always active) |

When querying entity state, all three sources are merged. The most recent dated value takes priority.

## Understanding Location

Entities can be "at" a location in three ways:

1. **Permanent location** (entity store): Where the entity normally resides
2. **Session visit** (session locations): Where the entity was during a specific session (temporary)
3. **Permanent move** (session Zmiany): The entity moved as a result of a session (permanent change)

When asking "where was X on date Y?", the system checks session visits first, then falls back to the permanent location.

## Economic Queries

Beyond tracking currency holdings and transfers, the system provides tools for analyzing the broader economic picture.

### Economic Snapshot

A point-in-time overview of the entire economy:

- **Supply breakdown**: Total currency in circulation, split by denomination and by physical vs virtual
- **Physical vs virtual**: Physical currency is owned by player characters (actual Margonem items). Virtual currency is held by NPCs, groups, or treasuries (RP bookkeeping only)
- **Wealth distribution**: Who holds the most currency, and how unequally wealth is distributed (Gini coefficient — 0 means everyone has equal wealth, 1 means one entity holds everything)
- **Transaction volume**: How many @Transfer directives have been recorded

Snapshots can be scoped to a specific denomination, owner, or point in time.

### Economic Timeline

Monthly trend data over a date range. For each month, the system computes:

- Total supply in circulation (in Kogi base units)
- Physical vs virtual supply split
- Number of @Transfer transactions in that month

This reveals trends like supply growth, shifts between physical and virtual holdings, or periods of high transaction activity.

### Materialization Report

Analyzes the relationship between physical and virtual currency:

- **Per-denomination breakdown**: What percentage of each denomination is physically held vs virtual bookkeeping
- **Per-player breakdown**: How much physical currency each player holds across all their characters
- **Orphaned physical currency**: Currency assigned to inactive or removed player characters — these represent physical Margonem items that may need to be returned to coordinators

## Expected Outcomes

The world-state tracking system ensures:

1. **Consistent world state** - all changes are recorded with dates and applied automatically
2. **Historical accuracy** - you can query what the world looked like at any point in time
3. **Automatic updates** - session changes are applied without manual entity editing
4. **Name resolution** - entity names and aliases are recognized in session text
5. **Intel targeting** - group and location memberships determine who receives targeted messages

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Unresolved entity name in Zmiany** | The change is skipped with a warning | Add the entity to the registry or fix the name |
| **Circular location hierarchy** | Detected automatically; falls back to flat naming | Fix the `@lokacja` chain to remove the cycle |
| **Entity in multiple files** | Data is merged across files automatically | No action needed |
| **Conflicting property values** | Most recent dated value wins | Check which source has the latest date |

## Related Documents

- [Sessions.md](Sessions.md) - How to record session changes
- [Players.md](Players.md) - Player and character management
- [Notifications.md](Notifications.md) - How Intel targeting uses entity data
- [Location-Graph.md](Location-Graph.md) - Location analysis and connection graph
- [Glossary](Glossary.md) - Term definitions

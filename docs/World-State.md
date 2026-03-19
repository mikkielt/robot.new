# Entity & World State

## Purpose

The repository tracks the state of the game world — NPCs, groups, locations, and player characters. World-state changes from sessions are recorded automatically, the system tracks properties that change over time, and Coordinators can query the current or historical state of any entity.

## Scope

This guide covers entity types, registration, temporal scoping, world-state changes from sessions, and location hierarchy.

For currency tracking, see [Currency.md](Currency.md). For economic analysis, see [Economy.md](Economy.md). For how entity names are matched, see [Name-Resolution.md](Name-Resolution.md). For player and character management, see [Players.md](Players.md).

## Actors and Responsibilities

The Narrator records world-state changes in sessions via `@Zmiany` blocks and ensures entity names in changes match known entities.

The Coordinator maintains the entity registry (NPCs, groups, locations), creates, updates, and removes entities using dedicated commands, and reviews diagnostic reports for unresolved entity names.

## What Are Entities?

An entity is any named element of the game world that the system tracks. Each entity has a type:

| Entity type | What it represents | Examples |
|---|---|---|
| NPC | A non-player character | Sandro, Lord Haart |
| Grupa | A group, faction, or organization | Bractwo Miecza, Nekromanci |
| Lokacja | A place in the game world | Erathia, Bracada, Zamek Steadwick |
| Mapa | A game map (floor/interior) tied to a location | Komnata Rady, Piwnica Ratusza |
| Gracz | A player (real person) | Roland, Catherine |
| Postać | A player character | Crag Hack, Gem |
| Przedmiot | A notable item | Miecz Piekieł, Tarcza Krasnoludów |

## Managing Entities

When a new NPC, group, location, or item first appears in the game world, the Coordinator registers it in the entity store. Each entity gets a type, a name, and optional starting properties (such as initial location or group membership). Player and character entities are managed through the player registration process — see [Players.md](Players.md).

The Coordinator can update any entity's properties at any time. Each update is time-stamped, so the system preserves a full history of what changed and when. This is separate from session changes — Coordinators use this for administrative corrections or out-of-session updates. When two entities share the same name across different types, the Coordinator specifies the type to disambiguate.

Entities are never physically deleted. The Coordinator marks them as removed (Usunięty) with an effective date. Removed entities stop appearing in standard queries and reports, remain available for historical lookups, and can be restored later if the removal was a mistake.

## How Entities Are Organized

All entity data is stored in structured Markdown files. Each entity has a name (the canonical display name), a type (which category it belongs to), metadata (properties like location, group memberships, status, and aliases), and history (a timeline of changes to each property).

Locations can contain other locations, forming a hierarchy. For example, the continent Antagarich contains the city Erathia, which in turn contains the building Zamek Steadwick and the district Plac Gryfów. This hierarchy is used for location-based Intel targeting — a message sent to "Lokacja/Erathia" reaches everyone in Erathia and all its sub-locations.

Locations in Margonem have game-assigned names, but the Nerthus RP server uses its own names for many locations. The `@nazwa_nerthus` tag records the RP override name:

```markdown
* Gwiżdżąca Grota
    - @nazwa_nerthus: Kryjówka Craga Hacka (2024-01:)
```

The entity's name stays as the Margonem game name. The Nerthus name is added to the entity's searchable names, so both names resolve to the same entity.

Mapa entities represent individual game maps — each floor, interior, or instance from the Margonem map registry. Every Mapa entity carries a unique game map ID, a map type (outdoor or indoor), a CDN image URL, and tile dimensions. Mapa entities are stored in a dedicated overflow file due to their volume (~2,704 entries). Lokacja entities represent conceptual places in the game world — deduplicated location names derived from the Mapa hierarchy. A single Lokacja (e.g., "Gwiżdżąca Grota") may correspond to many Mapa entities (one per floor or variant). Lokacja entities live in the main entity store.

Both Mapa and Lokacja entities participate in the location hierarchy via `@lokacja` — they can have a parent location, door connections, and Nerthus names. When two maps share the same name (e.g., multiple "Apartament" in different buildings), each can be given a unique slug to distinguish them.

Lokacja entities are automatically classified as **exterior** (has coordinates or outdoor maps), **interior** (all maps are indoor), or **unknown** (no evidence). Interior locations gain a qualified path linking them to their nearest exterior ancestor — for example, "Erathia/Komnata Rady" — making them findable by name resolution even when multiple locations share the same name.

Slugs provide unique identifiers when multiple entities share the same name (common with maps and generic locations). For example, two maps both named "Komnata Rady" can be distinguished by their slugs "komnata-rady-ratusz" and "komnata-rady-zamek". Slugs are searchable — you can use a slug anywhere an entity name is expected, and the system will find the right entity.

Entities can have alternative names (aliases) that the system recognizes. For example, "Sandro" might also be known as "Mroczny Mag" or "Lich z Deyji". Aliases can be time-scoped — valid only during a specific period. For example, a character might use a different name while undercover.

## How World State Changes

When something changes in the game world during a session, the Narrator records it in the `@Zmiany` block:

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine
- @Zmiany:
    - Crag Hack
        - @lokacja: Bracada
        - @grupa: Bractwo Miecza
    - Sandro
        - @lokacja: Bracada
```

This records that Crag Hack moved to Bracada and joined the Bractwo Miecza, and that Sandro moved to Bracada. These changes are applied with the session's date as the effective date.

The following properties can change:

| Property | What it means |
|---|---|
| `@lokacja` | Where the entity is permanently located |
| `@grupa` | Which group/faction the entity belongs to |
| `@status` | Whether the entity is active, inactive, or removed |
| `@alias` | An alternative name for the entity |
| `@info` | A description or note about the entity (displayed prominently in the entity card) |
| Any other property | Custom metadata stored with the entity |

When a change is recorded in a session, it automatically receives the session's date as its starting point. Dates do not need to be specified manually — the system knows when each change took effect.

## Temporal Scoping

Many entity properties change over time. The system tracks the full history, answering questions like "When did this NPC move to Bracada?", "Who was in the Bractwo Miecza in January 2024?", and "What was this character's status last year?"

Each property change has a validity period. A change with no dates specified is always active (e.g., an entity's original name). An open-ended change starts on a date with no end (e.g., `(2025-06:)` = from June 2025 onward). A bounded change starts and ends on specific dates (e.g., `(2024-01:2024-06)` = January to June 2024). A seasonal change is active only during a specific season (e.g., `(zima)` = active in winter). A date-plus-seasonal change requires both date range and season to match (e.g., `(2024-01:, lato)` = from January 2024, but only in summer).

Season keywords (Polish): `wiosna` (spring, Mar-May), `lato` (summer, Jun-Aug), `jesień` (autumn, Sep-Nov), `zima` (winter, Dec-Feb).

The most recent active value wins for single-value properties (like location). For multi-value properties (like group memberships), all active values are collected.

## Three Sources of Entity Data

The system combines data from three sources to build the complete picture:

| Source | What it provides | Temporal behavior |
|---|---|---|
| Entity store | Registered entities with their base properties | Properties can be time-scoped |
| Session changes (`@Zmiany`) | Updates from gameplay sessions | Automatically dated to the session date |
| Character files (for player characters) | Character sheet, condition, items, reputation | Undated baseline (always active) |

When querying entity state, all three sources are merged. The most recent dated value takes priority.

## Understanding Location

Entities can be "at" a location in three ways. Permanent location (entity store) is where the entity normally resides. Session visit (session locations) is where the entity was during a specific session (temporary). Permanent move (session Zmiany) means the entity moved as a result of a session (permanent change).

When asking "where was X on date Y?", the system checks session visits first, then falls back to the permanent location.

## Expected Outcomes

The world-state tracking system ensures:

1. Consistent world state — all changes are recorded with dates and applied automatically
2. Historical accuracy — you can query what the world looked like at any point in time
3. Automatic updates — session changes are applied without manual entity editing
4. Name resolution — entity names and aliases are recognized in session text
5. Intel targeting — group and location memberships determine who receives targeted messages

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Unresolved entity name in Zmiany | The change is skipped with a warning | Add the entity to the registry or fix the name |
| Circular location hierarchy | Detected automatically; falls back to flat naming | Fix the `@lokacja` chain to remove the cycle |
| Entity in multiple files | Data is merged across files automatically | No action needed |
| Conflicting property values | Most recent dated value wins | Check which source has the latest date |

## Related Documents

- [Sessions.md](Sessions.md) — How to record session changes
- [Players.md](Players.md) — Player and character management
- [Currency.md](Currency.md) — Currency tracking and transfers
- [Economy.md](Economy.md) — Economic analysis and reports
- [Name-Resolution.md](Name-Resolution.md) — How entity names are matched
- [Notifications.md](Notifications.md) — How Intel targeting uses entity data
- [Location-Graph.md](Location-Graph.md) — Location analysis and connection graph
- [Structures](Structures.md) — What data the system tracks for each concept
- [Campaign Data API](REST-API.md) — Querying entity data from external tools
- [Glossary](Glossary.md) — Term definitions

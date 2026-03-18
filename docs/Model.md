# How the Repository Is Organized

## Purpose

The Robot module reads structured Markdown files from the lore repository to build a complete picture of the game world. This guide explains what files the repository contains, how they relate to each other, and how the system combines them into a unified world model.

## Scope

This guide covers the repository layout, what each file type contributes, and how data from different sources flows together. It answers "where does the system find entity data?" and "how do session changes reach the world state?"

For what fields each data type carries, see [Structures.md](Structures.md). For entity management, see [World-State.md](World-State.md). For session recording, see [Sessions.md](Sessions.md). For player management, see [Players.md](Players.md). For term definitions, see [Glossary.md](Glossary.md).

---

## The Repository Layout

The lore repository contains four categories of files that the system reads:

| Category | Location | What It Contains |
|---|---|---|
| Entity registry | `entities.md` and overflow files | All tracked elements of the game world (NPCs, groups, locations, items, maps, players, characters) |
| Player database | `Gracze.md` | Player accounts, their characters, PU balances, and notification settings |
| Character files | `Postaci/Gracze/` folder | One file per character with condition, reputation, special items, and session descriptions |
| Session files | Anywhere in the repository | Game session records with world-state changes, PU awards, transfers, and intelligence |

The module itself lives in the `.robot.powershell/` folder as a submodule. Runtime state (PU history, session integrity checks, participation graphs) is stored in `.robot.local/res/`.

---

## The Entity Registry

The entity registry is the central database of the game world. It consists of one main file (`entities.md`) and optional overflow files for bulk data (like maps). Each file groups entities by type using section headers.

Within each section, every entity is a bullet point with its name, followed by indented lines for its properties. Each property uses an `@` prefix:

```markdown
## Lokacja

* Erathia
    - @lokacja: Antagarich
    - @grupa: Sojusz Światła (2023-06:)
    - @drzwi: Bracada
    - @drzwi: Zamek Steadwick
```

When an entity has overflow files (e.g., maps stored in a separate file), the system automatically merges all files into a single combined view. The Coordinator does not need to manage which file an entity lives in — the system handles discovery and merging.

---

## Properties That Change Over Time

Most entity properties keep a full history. Each value can carry a time window showing when it was active:

```markdown
* Sandro
    - @lokacja: Deyja (2021-01:2023-06)
    - @lokacja: Erathia (2023-07:)
    - @grupa: Nekromanci (2021-01:2023-12)
    - @status: Nieaktywny (2024-01:)
```

This history means: Sandro was in Deyja from January 2021 through June 2023, moved to Erathia in July 2023, was a member of Nekromanci from 2021 through 2023, and became inactive in January 2024.

The system uses these histories to answer questions about the past ("Where was Sandro in March 2022?") and the present ("Who is currently in Erathia?"). Properties without dates are treated as always active.

Some properties also support seasonal restrictions — a value can be active only during a specific season (wiosna, lato, jesień, or zima).

---

## The Player Database

`Gracze.md` is a legacy file that records every player, their characters, PU balances, notification webhooks, and content warnings. It is never modified by the system — all new player data is managed through the entity registry instead.

When a Coordinator registers a new player, the system creates a Gracz entity in the entity registry. The entity registry data extends (does not replace) anything already in `Gracze.md`. This means both data sources contribute to the complete player picture.

---

## Character Files

Each player character has a dedicated Markdown file in `Postaci/Gracze/`. These files contain the character's sheet URL, current condition, special items, reputation across locations and factions, additional notes, and described sessions.

Character files provide a baseline that the system enriches with entity registry data and session changes. When querying a character's full state, the system combines all three sources with a clear priority:

| Priority | Source | What It Provides |
|---|---|---|
| Lowest | Character file | Baseline condition, reputation, items |
| Middle | Entity registry | Dated property changes from `entities.md` |
| Highest | Session changes | World-state changes recorded in `@Zmiany` blocks |

For properties that change over time (like location or group membership), the most recently dated value wins. For properties that can have multiple values (like groups), all active values are collected from every source.

---

## Session Files and World-State Changes

Session files can live anywhere in the repository. The system scans all Markdown files looking for session headers in the format `### YYYY-MM-DD, Title, Narrator`. Each session can contain structured metadata blocks that drive automatic updates:

| Block | What It Does |
|---|---|
| `@PU` | Awards skill points to characters |
| `@Zmiany` | Changes entity properties (location, status, groups, etc.) |
| `@Transfer` | Moves items or currency between entities |
| `@Intel` | Delivers targeted intelligence messages |
| `@Lokacje` | Records where the session took place |

When a Narrator writes `@Zmiany` in a session, those changes are applied to the world state as of the session's date. This means the entity's history automatically includes the change with the correct timestamp — no separate update step is needed.

The same session can appear in multiple files (for example, in both a thread file and a location file). The system detects duplicates by matching headers and automatically merges them into a single record.

---

## How Data Connects

The system builds a complete world model by combining four data sources:

```
Entity Registry          Session Files           Player Database        Character Files
(entities.md)            (*.md everywhere)       (Gracze.md)           (Postaci/Gracze/*.md)
     │                        │                       │                       │
     │  entity properties     │  @Zmiany changes      │  player accounts      │  baseline state
     │  with dates            │  @Transfer moves      │  character lists      │  reputation
     │  aliases, groups       │  @PU awards           │  PU balances          │  condition, items
     │  locations, status     │  @Intel messages      │  webhooks             │  session descriptions
     │                        │                       │                       │
     └────────────────────────┴───────────────────────┴───────────────────────┘
                                        │
                              Unified World Model
                        (queryable current + historical state)
```

An entity's complete state at any point in time is the combination of its registry entry plus all session changes up to that date. A character's complete state adds the character file baseline underneath. A player's complete profile combines Gracze.md data with any Gracz entity data.

---

## Name Matching

Every entity can be found by its primary name, any alias, its Nerthus game name, or any slug. The system handles Polish noun declension — if a Narrator writes an entity name in a different grammatical case (like "Erathii" instead of "Erathia"), the system recognizes it as the same entity.

When an exact match is not found, the system tries progressively broader matching: declension stripping, consonant mutation reversal, and finally fuzzy matching based on spelling similarity. This ensures that minor spelling variations in session files do not cause lost data.

---

## Items and Currency

Items and currency are both tracked as Przedmiot (item) entities. Currency entities have denomination names (like "Korona Elancka") that link them to the currency system. The `@ilość` tag tracks the quantity or balance.

When a session includes `@Transfer` directives, the system moves quantities between entities. It first tries to match by currency denomination, then by item name. Each transfer is atomic — if either the source or destination cannot be found, the entire transfer is skipped and reported for manual review.

---

## Expected Outcomes

After reading this guide, Coordinators and Narrators should understand where each type of data lives in the repository, how session `@Zmiany` blocks flow into the permanent world state, how the three-source character merge produces a complete character picture, and how the system finds entities despite name variations.

---

## Exceptions and Recovery

| Situation | What Happens | Recovery |
|---|---|---|
| Entity name in `@Zmiany` does not match any known entity | The change is recorded as unresolved and appears in diagnostic reports | Fix the entity name spelling in the session or register the missing entity |
| Same session header appears in multiple files | The system merges them into one record automatically | No action needed — this is expected for cross-posted sessions |
| Character file is missing for a registered character | The system returns entity and player data without the character file baseline | Create the character file in `Postaci/Gracze/` |
| PU assignment references an unknown character | The entire PU batch is aborted — no partial writes | Fix all character names before re-running the assignment |
| Entity file cannot be parsed | The system skips the file and logs a warning | Check the file for Markdown syntax errors |

---

## Related Documents

- [Structures.md](Structures.md) — what fields each data type carries
- [World-State.md](World-State.md) — managing entities and querying state
- [Sessions.md](Sessions.md) — recording sessions and metadata blocks
- [Players.md](Players.md) — player and character management
- [Currency.md](Currency.md) — currency tracking and transfers
- [Name-Resolution.md](Name-Resolution.md) — how entity names are matched
- [Glossary.md](Glossary.md) — term definitions

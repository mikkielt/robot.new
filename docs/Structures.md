# Data the System Tracks

## Purpose

The Robot module maintains a structured database of the game world — entities, sessions, players, characters, currency, and logs. This guide explains what data is recorded for each concept, how it is organized, and how different pieces of data relate to each other.

## Scope

This guide covers the shape of data that the system stores and returns. It answers "what fields does an entity have?" and "what information is recorded per session?", not "how do I create an entity?" or "how does the parser work?"

For working with entities, see [World-State.md](World-State.md). For session recording, see [Sessions.md](Sessions.md). For player management, see [Players.md](Players.md). For currency, see [Currency.md](Currency.md). For economic reports, see [Economy.md](Economy.md). For term definitions, see [Glossary.md](Glossary.md).

---

## Entity Data

An entity is any tracked element of the game world. Each entity carries:

| Field | What it holds |
|---|---|
| Name | The canonical display name |
| Type | What kind of entity: NPC, Grupa, Lokacja, Mapa, Gracz, Postać, or Przedmiot |
| Status | Whether the entity is Aktywny (active), Nieaktywny (inactive), or Usunięty (removed) |
| Owner | Who or what this entity belongs to (e.g., a character's player, an item's holder) |
| Location | Where the entity is permanently located |
| Groups | Which factions or organizations the entity belongs to (can be multiple) |
| Aliases | Alternative names, each with an optional time window when the alias was valid |
| Nerthus name | The RP override name used on the Nerthus server (for Margonem locations) |
| Doors | Door connections to other locations (for Lokacja and Mapa entities) |
| Quantity | A numeric value (used by currency entities to track balance) |
| File path | Associated file (character files for Postać, overflow files for bulk entities) |
| Coordinates | Map coordinates (X, Y position) |
| Contains | Child entities (locations within this location) |

Every entity property that changes over time (location, status, groups, owner, aliases, and others) keeps a full history. Each history entry records the value, when it became active, when it stopped being active (if ever), and an optional season restriction. The system uses these histories to answer questions like "Where was this NPC in January 2024?" or "Who was in the Bractwo Miecza last summer?"

---

## Location and Map Entity Data

When querying locations, the system returns enriched records that combine the entity's base properties with hierarchy and connectivity information:

| Field | What it holds |
|---|---|
| Entity name | The location or map display name |
| Type | Lokacja (conceptual place) or Mapa (concrete game map) |
| Parent | The parent location in the hierarchy |
| Children | Child locations and maps contained within this location |
| Door connections | Physical links to other locations, with resolution status |
| Coordinates | Map tile position (X, Y) for exterior locations |
| Hierarchical path | Full path through the location tree (e.g., Antagarich/Erathia/Zamek Steadwick) |
| Nerthus name | The RP override name for Margonem locations |
| Entity count | How many non-location entities are present at this location |
| Status | Active, inactive, or removed |

Mapa entities carry additional map-specific metadata: a unique slug for disambiguation, a CDN image URL, an optional Nerthus-specific image URL, and tile dimensions.

---

## Session Data

A session record captures everything that happened during one game session:

| Field | What it holds |
|---|---|
| Header | The unique session identifier: date, title, and narrator name |
| Date | When the session took place |
| End date | When a multi-day session ended (same as start date for single-day sessions) |
| Title | The session's descriptive title |
| Narrator | Who ran the session, with confidence level for the match |
| Format | The recording format generation (Gen1 through Gen4, reflecting how sessions evolved over time) |
| Locations | Where the session took place (one or more location names) |
| Logs | URLs to chat logs from the session |
| PU | Skill point awards — which characters received how many points |
| Changes | World-state changes from `@Zmiany` — which entities had properties updated |
| Transfers | Currency movements from `@Transfer` — amount, denomination, source, and destination |
| Intel | Targeted intelligence messages from `@Intel` — who should receive what information |
| Mentions | Entity names that appear in the session content |
| Content | The full session body text (available on request) |
| Log data | Parsed chat log content (available on request) |

When the same session appears in multiple files (cross-file sessions), the system automatically merges them into a single record with combined data.

---

## Player and Character Data

A player record represents a real person who participates in the campaign:

| Field | What it holds |
|---|---|
| Name | Player name |
| Margonem ID | Their Margonem game account ID |
| Webhook | Discord notification webhook URL |
| Triggers | Restricted topics that should trigger warnings |
| Characters | All characters belonging to this player |

Each character within a player carries:

| Field | What it holds |
|---|---|
| Name | Character name |
| Active | Whether the character is currently active |
| Aliases | Alternative names |
| File path | Path to the character's detail file |
| PU start | Starting skill point value |
| PU sum | Total skill points accumulated |
| PU taken | Skill points used |
| PU exceeded | Overflow beyond the cap |

When full state is requested, additional fields are merged from the character file and entity data:

| Field | What it holds |
|---|---|
| Status | Current entity status (Aktywny, Nieaktywny, Usunięty) |
| Character sheet | URL to the character sheet |
| Restricted topics | Topics that should be avoided with this character |
| Condition | Current character condition |
| Special items | Notable items the character carries |
| Reputation | Reputation at various locations, organized by tier (Positive, Neutral, Negative) |
| Additional notes | Extra information about the character |
| Described sessions | Sessions recorded in the character file, each with date, title, and narrator |

Each reputation entry records the location name and an optional detail describing the reputation.

---

## Currency Data

The currency system uses three denominations:

| Denomination | Short name | Tier | Exchange rate |
|---|---|---|---|
| Korony Elanckie | Korony | Gold | 1 Korona = 100 Talarów = 10,000 Kogi |
| Talary Hirońskie | Talary | Silver | 1 Talar = 100 Kogi |
| Kogi Skeltvorskie | Kogi | Copper | Base unit |

Each currency holding is tracked as an entity with:

| Field | What it holds |
|---|---|
| Entity name | Auto-generated: denomination + owner name |
| Denomination | Which currency type |
| Tier | Gold, Silver, or Copper |
| Owner | Who holds this currency |
| Location | Where the currency is (for dropped/hidden currency) |
| Balance | Current quantity |
| Status | Active, inactive, or removed |

Currency holdings are classified as physical (owned by a player character — represents actual game items) or virtual (owned by an NPC, group, or player account — represents RP bookkeeping).

---

## Item Data

Items (Przedmiot entities) are tracked with enriched properties: entity name, owner, owner type (Physical for player characters, Virtual for NPCs/groups, Unknown otherwise), location, quantity, status, and whether the item is a currency denomination. Items default to excluding currency entities and inactive/deleted entries.

Reverse lookups let you query entities by property values: "what entities are at location X?", "what does character Y own?", "who is in group Z?" Filters are AND-combined and optional. Results are original entity objects with no transformation.

---

## Reports and Analysis

The system produces several types of reports, each with its own data shape.

A currency report shows holdings per currency entity: denomination, owner, balance, last change date, and status warnings (negative balance, stale balance).

A currency reconciliation checks for discrepancies: negative balances, stale holdings, orphaned currency (owned by inactive entities), and asymmetric transactions (transfers where amounts do not balance). It also tracks total supply per denomination, split by physical and virtual.

An economic snapshot captures the state of the economy at a point in time: total supply in each denomination, physical vs virtual split, wealth distribution (Gini coefficient), top holders, and transaction volume.

An economic timeline shows monthly trends: how supply and transactions change over time.

A materialization report breaks down physical vs virtual currency by denomination and by player, and flags orphaned physical currency.

A dormancy report identifies entities with no recent activity. It scans all property history lists and the session graph index for the most recent activity date, then flags entities exceeding a configurable inactivity threshold (default 6 months). Each dormant entity reports its name, type, days dormant, last activity source (property change, session mention, or creation), and creation date.

A session frequency trend groups sessions by calendar month, counting sessions, unique narrators, and format breakdown (Gen1-Gen4). Supports date range filtering.

An entity delta compares an entity's state at two points in time, reporting which properties changed. Compares scalar properties (location, owner, type, status, quantity) and multi-valued properties (groups, doors) using set difference.

An entity history shows the timeline of property changes for a single entity: what changed, when, and the value.

A change log lists all `@Zmiany` directives across sessions: date, session, entity, property, and new value.

A transaction ledger lists all `@Transfer` directives: date, session, amount, denomination, source, and destination.

A PU assignment log records each batch processing run: timestamp, timezone, and the sessions included.

A notification log lists all `@Intel` deliveries: date, session, targeting directive, message, and recipients.

---

## Location and Session Graphs

The location graph maps how locations connect to each other through containment (parent-child hierarchy), door connections, routes observed in sessions, movements seen in chat logs, and teleportation (non-adjacent transitions). Each connection records when it was first and last observed, and whether it may be outdated.

The session graph maps which entities participated in which sessions. Participation is classified into three tiers: direct (characters and narrators), mentioned (entity names appearing in session text), and inferred (from log analysis). The graph tracks total sessions, unique participants, and format distribution.

---

## How Data Connects

The system builds a complete picture by combining multiple data sources:

The entity store provides base properties and temporal histories. Session `@Zmiany` blocks provide dated property updates that merge into entity histories. Character files provide baseline character data (sheet, condition, items, reputation). Session `@Transfer` directives create symmetric quantity changes on currency entities. Session `@PU` entries feed into player character skill point calculations. Session `@Intel` entries combine with entity group and location memberships to determine notification recipients.

When the Coordinator queries a character's full state, the system merges data from the entity registry, all relevant sessions, and the character file. The most recently dated value takes priority for single-value properties. For multi-value properties (like group memberships), all active values are collected.

---

## Expected Outcomes

After reading this guide, you should understand what information the system records for each domain concept, how entity histories work and what fields are tracked over time, what data a session record contains and how session directives feed into other parts of the system, how player and character data is assembled from multiple sources, and how currency, reports, and graphs are structured.

---

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Missing entity property | Property returns empty or null | Check whether the property was ever set in the entity store or session changes |
| Unresolved entity name | Name resolution failed, data not linked | Register the entity or fix the name spelling |
| Orphaned currency | Currency entity's owner is inactive or removed | Transfer the currency to an active entity or remove it |
| Stale history entries | Property changes with overlapping or contradictory dates | Review the temporal scoping in entity tags and session dates |
| Missing character file | Character state merges without charfile data | Create the character file using the standard template |

---

## Related Documents

- [Model.md](Model.md) — Repository layout and how data sources connect
- [World-State.md](World-State.md) — Managing entities and world state
- [Sessions.md](Sessions.md) — Recording sessions and directives
- [Players.md](Players.md) — Player and character management
- [Currency.md](Currency.md) — Currency tracking and transfers
- [Economy.md](Economy.md) — Economic reports and analysis
- [Location-Graph.md](Location-Graph.md) — Location connectivity
- [Session-Graph.md](Session-Graph.md) — Session participation
- [Session-Logs.md](Session-Logs.md) — Chat log processing
- [Notifications.md](Notifications.md) — Intel targeting
- [Glossary.md](Glossary.md) — Term definitions

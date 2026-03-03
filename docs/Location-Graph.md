# Location Analysis and Graph

## Purpose

This guide explains how the system analyzes location data across sessions and logs to build a unified picture of the game world's geography. It covers how locations are connected, how movement routes are tracked, and how coordinators can review the location graph for data quality.

## Scope

**What is included:**

- How the system discovers location connections from multiple sources
- How movement routes between locations are extracted from sessions
- How movement transitions are detected in session logs
- How map coordinates work for exterior locations
- How the location graph brings everything together
- How to use the location graph tool

**What is excluded:**

- How to register location entities (see [World-State.md](World-State.md))
- How to write session entries with location metadata (see [Sessions.md](Sessions.md))
- How to include and fetch session logs (see [Session-Logs.md](Session-Logs.md))

## Actors and Responsibilities

### Coordinator

- Reviews the location graph to find missing connections or inconsistencies
- Maintains map coordinates for exterior locations
- Uses the graph to identify stale data after location moves
- Creates missing location entities identified through the graph

### Narrator

- Ensures location names in session metadata match the entity registry
- May optionally use `->` notation in `@Lokacje` entries to indicate location transitions within a session

## How Locations Are Connected

The system discovers location connections from multiple sources and merges them into a single graph. Each source provides a different kind of relationship:

### Hierarchy (Parent-Child)

When a location's parent is set (e.g., "Zamek Steadwick belongs to Erathia"), this creates a containment relationship. These form the backbone of the location tree.

### Doors

When a location has door connections (e.g., "Zamek Steadwick connects to Komnata Królewska"), this creates a direct physical link between two locations.

### Session Metadata

Session `@Lokacje` entries record where meaningful action took place — they answer the question "in which locations did something important happen during this session?" They are **not** a physical route map. Characters may traverse many intermediate game locations between the ones listed.

When a narrator uses `->` notation (e.g., `Erathia -> Bracada`), this indicates a location transition within the session. The system extracts these as route connections. This notation is optional and not widely used.

Slash-separated paths (e.g., `Erathia/Zamek Steadwick`) are also extracted as inferred parent-child hierarchy.

### Movement in Session Logs (Primary Source for Connectivity)

Session logs are the **primary source of truth** for physical location connectivity. When characters move through the game world, the log transcript records each location they visit as a location header. Consecutive location headers represent actual physical movement between game locations — including intermediate locations that may not appear in the session's `@Lokacje` metadata.

> For example, a session's `@Lokacje` might list only "Erathia" and "Bracada" as the meaningful action locations. But the session log might show the character physically passing through "Erathia → Droga przez Puszczę → Przełęcz Gryfów → Bracada", revealing connectivity between all four locations.

This source is optional and must be explicitly requested, since it requires fetched and parsed log data. When available, it provides the most granular and accurate connectivity information.

## Map Coordinates

Exterior locations (those visible on the game world map) can have map tile coordinates recorded. These indicate the location's position on the Margonem world map in tile units (32×32 pixels).

Coordinates are recorded in the entity store:

```markdown
* Zamek Steadwick
    - @koordynaty: 125, 80
```

Coordinates support temporal scoping, so when a location moves on the map, the history is preserved:

```markdown
* Zamek Steadwick
    - @koordynaty: 125, 80
    - @koordynaty: 130, 85 (2025-01:)
```

Locations without coordinates are classified as **interior** (not directly on the world map). Locations with coordinates are classified as **exterior**.

## The Location Graph

The location graph merges all four connection sources into a unified view of the game world's geography.

### What It Shows

Each entry in the graph represents a location and includes:

- **Entity match** — whether the location name was found in the entity registry
- **RP name** — the Nerthus override name, if one exists
- **Coordinates** — map position for exterior locations
- **Connection count** — how many connections lead to and from this location

Each connection includes:

- **Type** — hierarchy, door, route, or movement
- **Weight** — how many times this connection was observed
- **Date range** — when the connection was first and last seen
- **Staleness flag** — whether the connection may be outdated

### Staleness Detection

When a location's map coordinates change (e.g., the game world is updated), connections involving that location from before the coordinate change are flagged as **possibly stale**. This helps coordinators identify connections that may no longer be geographically accurate.

> For example, if Zamek Steadwick's coordinates were updated in January 2025, any route connection from December 2024 involving Zamek Steadwick would be flagged as possibly stale.

### Using the Location Graph

The location graph is available through the CLI under the Reporting menu. The workflow prompts for:

1. **Date range** — which sessions to include (start and end dates, both optional)
2. **Movement edges** — whether to include transitions from session logs (requires fetched logs)

After processing, the tool displays:

- A **summary** with counts: total locations, connections by type, resolved vs. unresolved locations, exterior vs. interior, and stale connections
- A **location table** listing each location with its RP name, coordinates, and connection counts

### Connection Types at a Glance

| Source | What it captures | When it's available |
|---|---|---|
| **Hierarchy** | Parent-child containment from entity registry | Always (from registered locations) |
| **Doors** | Physical connections between locations | Always (from registered locations) |
| **Routes** | Location transitions from session metadata | When sessions use `->` notation (optional, uncommon) |
| **Inferred hierarchy** | Parent-child from slash-separated names | When sessions use `Parent/Child` notation |
| **Movement** | Physical movement from log location headers | Only when requested and logs are fetched (most accurate connectivity source) |
| **Teleport** | Non-adjacent log transitions (magical/instant travel) | Detected automatically when movement edges are included |

## Expected Outcomes

1. **Comprehensive location map** — all known location connections from entity data, session metadata, and logs are merged into a single view
2. **Teleport detection** — transitions between structurally non-adjacent locations are automatically classified as teleports and excluded from physical connectivity analysis
3. **Data quality insight** — unresolved location names, missing entities, and stale connections are surfaced for coordinator review
3. **Temporal awareness** — coordinate changes are tracked historically, and connections are checked for currency
4. **Flexible scope** — date ranges and optional movement edges allow focused or broad analysis

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Location name not in entity registry** | Appears as "unresolved" in the graph | Create the location entity or add an alias |
| **Session logs not fetched** | Movement edges unavailable | Run the log fetch tool first, or omit movement edges |
| **Stale connection detected** | Flagged with reason (which location moved and when) | Review the connection and update if no longer valid |
| **Coordinate format error** | The coordinate entry is skipped; location classified as interior | Fix the coordinate value in the entity store |
| **No sessions in date range** | Graph shows only entity-based connections (hierarchy, doors) | Expand the date range or omit date filters |

## Related Documents

- [World-State.md](World-State.md) - Entity management, location hierarchy, Nerthus names
- [Sessions.md](Sessions.md) - How to record sessions with location metadata
- [Session-Logs.md](Session-Logs.md) - Log fetching and location analysis
- [Auditing.md](Auditing.md) - Other reporting and audit tools

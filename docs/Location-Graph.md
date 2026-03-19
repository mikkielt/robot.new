# Location Analysis and Graph

## Scope

The system analyzes location data across sessions and logs to build a unified picture of the game world's geography. It covers how locations are connected, how movement routes are tracked, and how Coordinators can review the location graph for data quality.

This guide covers how the system discovers location connections from multiple sources, how movement routes between locations are extracted from sessions, how movement transitions are detected in session logs, how map coordinates work for exterior locations, how the location graph brings everything together, and how to use the location graph tool.

For registering location entities, see [World-State.md](World-State.md). For how location names are matched, see [Name-Resolution.md](Name-Resolution.md). For writing session entries with location metadata, see [Sessions.md](Sessions.md). For including and fetching session logs, see [Session-Logs.md](Session-Logs.md).

## Actors and Responsibilities

The Coordinator reviews the location graph to find missing connections or inconsistencies, maintains map coordinates for exterior locations, uses the graph to identify stale data after location moves, creates missing location entities identified through the graph, and uses map traversal analysis to discover and apply missing door connections between locations.

The Narrator ensures location names in session metadata match the entity registry, and may optionally use `->` notation in `@Lokacje` entries to indicate location transitions within a session.

## How Locations Are Connected

The system discovers location connections from multiple sources and merges them into a single graph. Each source provides a different kind of relationship.

Hierarchy (parent-child) connections are formed when a location's parent is set (e.g., "Zamek Steadwick belongs to Erathia"), creating a containment relationship. These form the backbone of the location tree.

Door connections are created when a location has physical links to another (e.g., "Zamek Steadwick connects to Komnata Królewska"), creating a direct physical link between two locations.

Session metadata connections come from `@Lokacje` entries, which record where meaningful action took place — they answer the question "in which locations did something important happen during this session?" They are not a physical route map. Characters may traverse many intermediate game locations between the ones listed. When a narrator uses `->` notation (e.g., `Erathia -> Bracada`), this indicates a location transition within the session, and the system extracts these as route connections. This notation is optional and not widely used. Slash-separated paths (e.g., `Erathia/Zamek Steadwick`) are also extracted as inferred parent-child hierarchy.

Map traversal connections come from analyzing game-map movement logs at the individual map (Mapa) level. The system resolves raw game-map names against the Mapa entity registry, builds map-to-map transitions, and projects them up to Lokacja-level connections. This provides a high-volume, automated source of physical connectivity data that complements the other sources.

## Map Traversal Analysis

Game map movement logs contain detailed location data at the individual map level (Mapa entities), which is more granular than the Lokacja level used by session metadata. Map traversal analysis resolves raw game-map names against the Mapa entity registry, builds a graph of map-to-map transitions, and then projects those transitions up to Lokacja-level connections.

This projection means that even if characters move through many individual game maps within a larger area, the system can determine which high-level locations (Lokacje) are physically connected. The resolution pipeline handles common game-map naming conventions such as floor numbers, room suffixes, direction labels, and difficulty markers — matching names like "Piekielna Grota p.3 - sala 2" back to the registered Mapa entity "Piekielna Grota p.3" or its parent "Piekielna Grota".

Map traversal analysis is a separate data source from the per-session log movement edges described below. When map traversal data is available, it takes priority as the movement edge source in the location graph.

## Movement in Session Logs

Session logs are the primary source of truth for physical location connectivity. When characters move through the game world, the log transcript records each location they visit as a location header. Consecutive location headers represent actual physical movement between game locations — including intermediate locations that may not appear in the session's `@Lokacje` metadata.

For example, a session's `@Lokacje` might list only "Erathia" and "Bracada" as the meaningful action locations. But the session log might show the character physically passing through "Erathia, Droga przez Puszcze, Przelecz Gryfow, Bracada", revealing connectivity between all four locations.

This source is optional and must be explicitly requested, since it requires fetched and parsed log data. When available, it provides the most granular and accurate connectivity information.

Game-map names often contain floor numbers, room suffixes, direction labels, or difficulty markers (e.g., "Piekielna Grota p.3 - sala 2" or "Klasztor Rozanitow - wieza pln.-wsch. p.1"). When the system resolves a log location header against the entity registry and finds no direct match, it progressively strips these trailing suffixes and retries. This means a log header like "Piekielna Grota p.3" can still resolve to the registered entity "Piekielna Grota" without requiring a separate alias.

## Map Coordinates

Exterior locations (those visible on the game world map) can have map tile coordinates recorded. These indicate the location's position on the Margonem world map in tile units (32x32 pixels).

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

Locations without coordinates are classified as interior (not directly on the world map). Locations with coordinates are classified as exterior.

## The Location Graph

The location graph merges all connection sources into a unified view of the game world's geography.

Each entry in the graph represents a location and includes the entity match (whether the location name was found in the entity registry), the RP name (the Nerthus override name, if one exists), coordinates (map position for exterior locations), and connection count (how many connections lead to and from this location).

Each connection includes the type (hierarchy, door, route, or movement), weight (how many times this connection was observed), date range (when the connection was first and last seen), and a staleness flag (whether the connection may be outdated).

When a location's map coordinates change (e.g., the game world is updated), connections involving that location from before the coordinate change are flagged as possibly stale. This helps Coordinators identify connections that may no longer be geographically accurate. For example, if Zamek Steadwick's coordinates were updated in January 2025, any route connection from December 2024 involving Zamek Steadwick would be flagged as possibly stale.

## Discovering Missing Door Connections

The system can automatically discover missing door connections between locations by analyzing map traversal data. When the location graph classifies a transition between two locations as a teleport (meaning no structural path exists between them), it indicates that a physical connection may be missing from the entity registry.

By examining teleport edges that appear repeatedly across multiple sessions, the system identifies high-confidence candidates for new door connections. A minimum observation threshold filters out one-off transitions that may represent actual magical travel rather than missing data. When the Coordinator approves, the system writes bidirectional door connections to both locations in the entity store.

The system also identifies frequently occurring unresolved map names — game maps that could not be matched to any registered Mapa entity. For each, it infers the likely parent Lokacja from neighboring resolved maps in the same session. These are presented as suggestions for the Coordinator to review and create manually.

## Using the Location Graph

The location graph is available through the CLI under the Reporting menu. The workflow prompts for a date range (which sessions to include, with start and end dates both optional) and whether to include movement edges (transitions from session logs, which requires fetched logs).

After processing, the tool displays a summary with counts (total locations, connections by type, resolved vs. unresolved locations, exterior vs. interior, and stale connections) and a location table listing each location with its RP name, coordinates, and connection counts.

The CLI also supports building a map traversal graph and updating location connections based on the analysis. The Coordinator can review discovered door candidates and unresolved map suggestions, then choose to apply the door connections or create new entities as needed. A report-only mode is available for reviewing candidates without making changes.

| Source | What it captures | When it is available |
|---|---|---|
| Hierarchy | Parent-child containment from entity registry | Always (from registered locations) |
| Doors | Physical connections between locations | Always (from registered locations) |
| Routes | Location transitions from session metadata | When sessions use `->` notation (optional, uncommon) |
| Inferred hierarchy | Parent-child from slash-separated names | When sessions use `Parent/Child` notation |
| Map traversal | Lokacja-level connections projected from game-map movement | When map traversal analysis is run (takes priority over per-session log movement) |
| Movement | Physical movement from log location headers | When requested and logs are fetched, or projected from map traversal |
| Teleport | Non-adjacent log transitions (magical/instant travel) | Detected automatically when movement edges are included |

## Expected Outcomes

- Comprehensive location map — all known location connections from entity data, session metadata, logs, and map traversal analysis are merged into a single view
- Automatic door discovery — repeated teleport edges reveal missing physical connections, which can be applied to the entity registry
- Map entity suggestions — frequently occurring unresolved game-map names are surfaced with inferred parent locations for the Coordinator to review
- Teleport detection — transitions between structurally non-adjacent locations are automatically classified as teleports and excluded from physical connectivity analysis
- Data quality insight — unresolved location names, missing entities, and stale connections are surfaced for Coordinator review
- Temporal awareness — coordinate changes are tracked historically, and connections are checked for currency
- Flexible scope — date ranges and optional movement edges allow focused or broad analysis

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Location name not in entity registry | Appears as "unresolved" in the graph | Create the location entity or add an alias |
| Session logs not fetched | Movement edges unavailable | Run the log fetch tool first, or omit movement edges |
| Stale connection detected | Flagged with reason (which location moved and when) | Review the connection and update if no longer valid |
| Coordinate format error | The coordinate entry is skipped; location classified as interior | Fix the coordinate value in the entity store |
| No sessions in date range | Graph shows only entity-based connections (hierarchy, doors) | Expand the date range or omit date filters |

## Related Documents

- [World-State.md](World-State.md) — Entity management, location hierarchy, Nerthus names
- [Name-Resolution.md](Name-Resolution.md) — How location names are matched
- [Sessions.md](Sessions.md) — How to record sessions with location metadata
- [Session-Logs.md](Session-Logs.md) — Log fetching and location analysis
- [Auditing.md](Auditing.md) — Other reporting and audit tools

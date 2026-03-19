# Location Graph

## Scope

The location graph subsystem comprises `Get-LocationGraph` (multi-source edge merging, node construction, staleness detection), route edge extraction in `Get-NamedLocationReport`, transition edge extraction in `Get-NamedLogLocationReport`, and `@koordynaty` tag parsing in `Get-Entity`/`Get-EntityState`.

Location entity CRUD is documented in [ENTITY-WRITES.md](ENTITY-WRITES.md). Log fetching and parsing is documented in [LOGS.md](LOGS.md). Name resolution internals are documented in [NAME-RESOLUTION.md](NAME-RESOLUTION.md). Session format and metadata extraction is documented in [SESSIONS.md](SESSIONS.md).

---

## Architecture Overview

```
Data Sources                          Intermediate Reports              Graph Assembly
─────────────────────────────────     ─────────────────────────         ──────────────────
Entity Registry (@lokacja, @drzwi) ─┐
                                     ├─> Get-LocationGraph
Session Metadata (@Lokacje) ────────>│      (Containment, Door edges)
    └─> Get-NamedLocationReport ─────┤      (Route, InferredHierarchy edges)
         └── RouteEdges              │
                                     │
Session Logs (LocationSegments) ────>│
    └─> Get-NamedLogLocationReport ──┤      (Movement edges, optional)
         └── Transitions             │
                                     ├─> Nodes (entity resolution, coordinates)
@koordynaty (entity tags) ──────────>│      (exterior/interior classification)
                                     └─> Staleness detection (CoordinateHistory)
```

Source files:

| File | Function | Role |
|---|---|---|
| `public/reporting/get-locationgraph.ps1` | `Get-LocationGraph` | Core graph assembly |
| `public/reporting/get-maptraversalgraph.ps1` | `Get-MapTraversalGraph` | Map traversal graph (Mapa-level edges, Lokacja projection) |
| `public/reporting/get-namedlocationreport.ps1` | `Get-NamedLocationReport` | Route edge extraction (and location analysis) |
| `public/reporting/get-namedloglocationreport.ps1` | `Get-NamedLogLocationReport` | Transition edge extraction (and log location analysis) |
| `public/get-entity.ps1` | `Get-Entity` | `@koordynaty` tag parsing |
| `public/get-entitystate.ps1` | `Get-EntityState` | `@koordynaty` Zmiany override |
| `lib/MapTraversalGraph.cs` | `Robot.MapTraversalBuilder` | C# map resolution and graph building |
| `private/cli/cli-registry.ps1` | -- | CLI menu entry `location-graph` |
| `private/cli/cli-wf-reporting.ps1` | `Invoke-LocationGraphWorkflow` | CLI workflow |
| `private/location-helpers.ps1` | `Get-MapBaseName` | Map name suffix stripping |
| `public/location/set-traversalentities.ps1` | `Set-TraversalEntities` | Traversal-based @drzwi update and Mapa suggestions |

---

## @koordynaty Tag

Syntax:

```markdown
* Wieża Obserwacyjna
    - @koordynaty: 125, 80
    - @koordynaty: 130, 85 (2025-01:)
```

Format: `X, Y` where X and Y are integer tile coordinates (32x32 pixel units on the Margonem world map). Supports temporal validity ranges like all other tags (see [ENTITIES.md](ENTITIES.md) Temporal Scoping section).

Interior locations (no world-map position) omit `@koordynaty` entirely; their `Coordinates` property resolves to `$null`.

In `public/get-entity.ps1`, the `@koordynaty` case in the tag switch: (1) Splits the value on `,` -- expects exactly 2 parts. (2) Validates both parts parse as `[int]`. (3) Builds a history entry: `@{ X; Y; ValidFrom; ValidTo; Season }`. (4) Appends to `$CoordinateHistory` (a `List[object]`). Active coordinate resolution mirrors `@nazwa_nerthus`: iterates `$CoordinateHistory` in reverse, applies `Test-TemporalActivity`, and takes the first active entry.

Entity object properties added: `Coordinates` (`@{ X = [int]; Y = [int] }` or `$null` for the active value) and `CoordinateHistory` (`List[object]` of all temporal entries).

In `public/get-entitystate.ps1`, the `@koordynaty` case in the Zmiany tag switch follows the same parse-validate-append pattern. The entry is auto-dated from the session date (same as `@lokacja`, `@nazwa_nerthus`, etc.).

`CoordinateHistory` merge follows the same pattern as `NerthusNameHistory`: entries from secondary files are appended, then the combined list is re-sorted and active value recomputed.

---

## Route Edges

Implemented in `Get-NamedLocationReport` (`public/reporting/get-namedlocationreport.ps1`).

Session `@Lokacje` entries record locations where meaningful action took place -- they do not represent a physical route. The optional `->` separator indicates a location transition within a session:

```markdown
- @Lokacje:
    - Erathia -> Bracada
```

This notation is not widely used. When present, the function splits each location string on `\s*->\s*|\s+- \s*` (precompiled regex `$RouteSplitRegex`), cleans segments (trim, strip trailing `*`, skip `Brak`), then extracts consecutive pairs as route edges.

`Get-NamedLocationReport` returns a `[PSCustomObject]` wrapper:

```powershell
[PSCustomObject]@{
    Locations  = $Result      # [PSCustomObject[]] — the location report entries
    RouteEdges = @($RouteEdges)  # [PSCustomObject[]] — extracted edges
}
```

Breaking change: callers that previously iterated the return value directly must now access `.Locations`. Updated callers: `migration/phase5-session-upgrade.ps1` uses `$LocationReportResult.Locations`; CLI registry `location-report` entry uses `DataTransform = { param($R) $R.Locations }` for backward-compatible table display.

Route edge schema:

| Property | Type | Description |
|---|---|---|
| `Source` | string | Cleaned name of the departure location |
| `Target` | string | Cleaned name of the destination location |
| `SessionDate` | string | Session date as `yyyy-MM-dd` |
| `Header` | string | Session header string |
| `FilePath` | string | Source file path |

---

## Transition Edges

Session logs are the primary source of truth for physical location connectivity. Session `@Lokacje` metadata records only where meaningful action occurred; log LocationSegments capture every physical location a character passes through -- including intermediate locations omitted from session metadata.

Implemented in `Get-NamedLogLocationReport` (`public/reporting/get-namedloglocationreport.ps1`). After building the `$LocationEntries` list from resolved LocationSegments, the function iterates consecutive pairs. Self-transitions (same resolved or raw name, case-insensitive) are skipped.

Each session result object gains two properties:

| Property | Type | Description |
|---|---|---|
| `Transitions` | `PSCustomObject[]` | Consecutive location pair edges |
| `Summary.TransitionCount` | int | Count of transitions for the session |

Transition edge schema:

| Property | Type | Description |
|---|---|---|
| `Source` | string | Resolved or raw name of departure |
| `Target` | string | Resolved or raw name of destination |
| `SourceRaw` | string | Original raw text |
| `TargetRaw` | string | Original raw text |
| `LogUrl` | string | Source log URL |
| `SessionTitle` | string | Session title |
| `SessionDate` | datetime | Session date |

---

## Map Name Stripping — Get-MapBaseName

Game maps use naming conventions with floor, room, direction, and difficulty suffixes (e.g. `Piekielna Grota p.3 - sala 1`). When `Resolve-Name` fails on a raw LocationSegment header, `Get-NamedLogLocationReport` falls back to `Get-MapBaseName` to produce progressively shorter candidate names.

Algorithm: (1) Strip trailing difficulty parenthetical `(poziom: ...)` if present -- add the cleaned name as the first candidate. (2) Split the remaining name by whitespace. (3) Progressively drop trailing words, keeping at least 1 word. Each shorter version becomes a candidate. (4) Trailing separators (`-`, `--`, `---`) are trimmed from each candidate. (5) Return all candidates ordered from longest (least stripped) to shortest.

The caller iterates candidates in order and uses `Resolve-Name` on each. The first candidate that resolves is used. The `StrippedName` output property records which candidate matched.

Source: `private/location-helpers.ps1` -- dot-sourced by `Get-NamedLogLocationReport`. Resolved entries receive `Stage = 'MapStrip'`.

---

## Map Traversal Graph

The map traversal graph is an intermediate Mapa-level graph built from session log LocationSegments. It resolves raw game-map names to Mapa entities, builds Mapa-to-Mapa transition edges, and projects those edges to Lokacja-to-Lokacja edges via `@lokacja` parent links.

```
Session Logs (LocationSegments)
    │
    ▼
Get-MapTraversalGraph (PowerShell orchestrator)
    │   - Builds Mapa lookup from entities (Name + Aliases → Entity)
    │   - Extracts raw segments from Get-SessionLog output
    │   - Dispatches to C# MapTraversalBuilder.Build() or PS fallback
    │
    ▼
MapTraversalBuilder.Build() (C# — lib/MapTraversalGraph.cs)
    │   Input: MapEntry[], string[][] (segments per session), string[] (dates)
    │   Processing:
    │     1. Case-insensitive map dictionary (Name + all Aliases → MapEntry)
    │     2. Resolution: Exact → SuffixStrip → WordDrop → Unresolved
    │     3. Build Mapa→Mapa edges (skip same-map self-transitions)
    │     4. Project to Lokacja→Lokacja edges (skip same-Lokacja)
    │   Output: TraversalResult
    │
    ▼
Get-LocationGraph (updated — new $MapTraversalGraph parameter)
    │   Consumes LocationEdges from TraversalResult
    │   Classifies as Movement/Teleport using structural adjacency
```

### Resolution Pipeline

The map traversal resolution is a simplified, Mapa-scoped alternative to the full `Resolve-Name` pipeline used by `Get-NamedLogLocationReport`. Game map names are proper nouns from the Margonem engine, not Polish-inflected prose, so declension stripping, stem alternation, and fuzzy matching are deliberately omitted to avoid false positives.

| Stage | Algorithm | Description |
|---|---|---|
| Exact | Dictionary lookup (OrdinalIgnoreCase) | Raw name matches Mapa Name or Alias |
| SuffixStrip | 9-pattern iterative `do..while` stable | Strips floor/room/direction/difficulty/subarea suffixes, retries exact |
| WordDrop | Progressive trailing-word removal | Falls back to `Get-MapBaseName` candidates (longest→shortest), retries each |
| Unresolved | -- | Name could not be matched; breaks the consecutive edge chain |

The SuffixStrip stage uses the margoworld plugin's `do..while` iterative approach (all 9 patterns applied until stable), not the core `Get-MapBaseName` single-pass word-drop.

### Get-MapTraversalGraph

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `SessionLog` | object[] | Yes | Session log output from `Get-SessionLog` |
| `Entities` | object[] | Yes | Entity list from `Get-Entity` |
| `Quiet` | switch | No | Suppress warnings |

Mapa entities are identified by: `$Entity.Overrides.ContainsKey('margonemid')` and `$Entity.Location` is non-null.

The lookup dictionary indexes all Mapa aliases (from `$Entity.Names[]`), not just the primary `Name`.

Output: `TraversalResult` (C# class or PSCustomObject fallback) with:

| Property | Type | Description |
|---|---|---|
| `MapEdges` | MapEdge[] | Mapa-to-Mapa transition edges with weight and date range |
| `LocationEdges` | LocationEdge[] | Projected Lokacja-to-Lokacja edges |
| `Segments` | ResolvedSegment[] | Per-segment resolution detail |
| `UnresolvedNames` | string[] | Names that failed all resolution stages |
| `TotalSegments` | int | Total segments processed |
| `ResolvedCount` | int | Number of segments resolved |
| `UnresolvedCount` | int | Number of unresolved segments |

### C# Types

See [STRUCTURES.md](STRUCTURES.md) for full property tables for `MapEntry`, `MapEdge` (struct), `LocationEdge` (struct), `ResolvedSegment` (struct), and `TraversalResult`.

---

## Set-TraversalEntities

Analyzes the Map Traversal Graph to discover missing `@drzwi` connections between Lokacja entities and suggest new Mapa entities from unresolved map names. Heritage: mirrors `phase6-door-inference.ps1` batch write pattern.

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Entities` | object[] | No | Pre-fetched entities from `Get-Entity` |
| `Sessions` | object[] | No | Pre-fetched sessions from `Get-Session` |
| `MinDate` | datetime | No | Delta mode — only sessions on or after this date |
| `MinDoorWeight` | int | No | Minimum Teleport edge weight for @drzwi candidates (default: 3) |
| `MinMapWeight` | int | No | Minimum unresolved name occurrences for Mapa suggestions (default: 5) |
| `SkipDoors` | switch | No | Skip @drzwi discovery |
| `SkipMaps` | switch | No | Skip Mapa entity suggestions |
| `ReportOnly` | switch | No | Return analysis without writing |
| `Quiet` | switch | No | Suppress warnings |

### Algorithm (7 stages)

1. **Data Loading** — auto-fetch entities/sessions if not provided; apply `-MinDate` to `Get-Session`; fetch session logs via `Get-SessionLog -SkipFetch`; build entity lookup (`Dictionary[string,object]`, OrdinalIgnoreCase)
2. **Traversal Graph** — `Get-MapTraversalGraph -SessionLog -Entities -Quiet`
3. **Location Graph** — `Get-LocationGraph -MapTraversalGraph -IncludeMovementEdges -Quiet`; collect Teleport, Door, and Containment edges
4. **@drzwi Candidate Discovery** — aggregate Teleport edges with canonical key (alphabetical `"A|B"`) deduplication; filter out existing doors, containment pairs, self-transitions, and sub-threshold weights
5. **Mapa Suggestion Discovery** — group unresolved segments by suffix-stripped base name; infer parent Lokacja from nearest resolved neighbors in same session; filter by `$MinMapWeight`
6. **Apply @drzwi** — group insertions by file path; bidirectional tags (A→B and B→A); `Read-EntityFile` → `Find-EntitySection` → `Find-EntityBullet` → bottom-to-top insertion → `Write-EntityFile`; `ShouldProcess` per file; `Set-SessionGraphStale` after writes
7. **Return** — `TraversalUpdateResult` (see [STRUCTURES.md](STRUCTURES.md))

### Why Teleport edges

Phase 6 uses Movement edges because it runs before `@drzwi` data exists. This function runs on a mature registry where `@drzwi` connections exist. **Teleport** edges (transitions between structurally disconnected locations at distance > 2) indicate **missing** `@drzwi`. Movement edges already have structural paths.

### Edge Cases

| Scenario | Behaviour |
|---|---|
| Empty sessions/entities | Returns valid empty result |
| Existing `@drzwi` (entity or file level) | Pair goes to `DoorsSkipped` |
| Containment pair | Excluded from candidates |
| Weight below threshold | Excluded from candidates |
| `-ReportOnly` | `DoorsApplied` empty, no file writes |
| `-WhatIf` | No file writes, `DoorCandidates` still populated |
| Mapa suggestions | Report only — does NOT auto-create entities (missing `@margonemid`) |

---

## Get-LocationGraph

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Sessions` | object[] | No | Pre-fetched sessions from `Get-Session` |
| `Entities` | object[] | No | Pre-fetched entities from `Get-Entity` |
| `SessionLog` | object[] | No | Pre-fetched log report from `Get-NamedLogLocationReport` |
| `MapTraversalGraph` | object | No | Pre-built map traversal graph from `Get-MapTraversalGraph` |
| `MinDate` | datetime | No | Include only sessions on or after this date |
| `MaxDate` | datetime | No | Include only sessions on or before this date |
| `IncludeMovementEdges` | switch | No | Include transition edges from session logs |
| `Quiet` | switch | No | Suppress warnings |

Algorithm: (1) Load data -- auto-fetch `Get-Entity` and `Get-Session` if not provided (passes `MinDate`/`MaxDate`). (2) Build entity lookup -- case-insensitive dictionary keyed by `Name` and all entries in `Names` (aliases). (3) Edge accumulation -- uses a `$AddEdge` scriptblock closure over an `$EdgeKey` dictionary (key = `"Source|Target|Type"`, case-insensitive); duplicate edges increment `Weight` and extend `Sources` list. (4) Containment edges (Type=`Containment`) from `@lokacja` chain: `parent -> child` for every `Lokacja` entity with a non-null `Location`. (5) Door edges (Type=`Door`) from `@drzwi`: `entity -> door_target` for every Lokacja with non-empty `Doors` list. (6) Route edges (Type=`Route`) from `Get-NamedLocationReport` `.RouteEdges` -- consecutive `->` segments from session metadata. (7) Inferred hierarchy edges (Type=`InferredHierarchy`) from `Get-NamedLocationReport` `.Locations[].InferredParents` -- slash-path parent-child relationships. (8) Movement edges (Type=`Movement`, optional) -- two sources, checked in priority order: (a) `$MapTraversalGraph.LocationEdges` -- projected Lokacja edges from `Get-MapTraversalGraph` (data source `MapTraversal`), (b) `$SessionLog` or auto-built `Get-NamedLogLocationReport` transitions (data source `SessionLog`). When `$MapTraversalGraph` is provided, the `$SessionLog` path is skipped. Only included when `-IncludeMovementEdges` is set. (9) Node construction -- all unique endpoint names from edges form the node set; each node resolves against the entity lookup for `CN`, `NerthusName`, `Coordinates`, and `IsExterior` classification. (10) Degree computation -- in-degree and out-degree per node. (11) Staleness detection -- for each edge, checks if source or target entity has `CoordinateHistory` with entries whose `ValidFrom` is after the edge's `FirstSeen`; marks `PossiblyStale = $true` with reason string.

Edge object schema:

| Property | Type | Description |
|---|---|---|
| `Source` | string | Source location name |
| `Target` | string | Target location name |
| `Type` | string | `Containment`, `Door`, `Route`, `InferredHierarchy`, or `Movement` |
| `Weight` | int | Number of times this edge was seen |
| `Sources` | List[string] | Data sources that produced this edge (`Entity`, `SessionMeta`, `SessionLog`) |
| `FirstSeen` | datetime | Earliest date this edge was observed |
| `LastSeen` | datetime | Latest date this edge was observed |
| `PossiblyStale` | bool | Whether coordinate changes suggest the edge may be outdated |
| `StaleReason` | string | Human-readable explanation of staleness (or `$null`) |

Node object schema:

| Property | Type | Description |
|---|---|---|
| `Name` | string | Location name (as seen in edges) |
| `EntityMatch` | object | Matched entity object, or `$null` |
| `CN` | string | Canonical Name from entity, or `$null` |
| `NerthusName` | string | RP override name, or `$null` |
| `Coordinates` | hashtable | `@{ X; Y }` from `@koordynaty`, or `$null` |
| `IsExterior` | bool | `$true` if entity has computed `IsExterior` classification or coordinates (falls back to coordinates check for unresolved entities) |
| `InDegree` | int | Number of inbound edges |
| `OutDegree` | int | Number of outbound edges |

Summary object schema:

| Property | Type | Description |
|---|---|---|
| `NodeCount` | int | Total unique location names |
| `EdgeCount` | int | Total unique edges |
| `ContainmentEdges` | int | `@lokacja` hierarchy edges |
| `DoorEdges` | int | `@drzwi` connection edges |
| `RouteEdges` | int | Session metadata `->` edges |
| `MovementEdges` | int | Log transition edges (0 if not requested) |
| `TeleportEdges` | int | Non-adjacent log transitions classified as teleport |
| `InferredEdges` | int | Slash-path hierarchy edges |
| `ResolvedNodes` | int | Nodes matched to entity registry |
| `UnresolvedNodes` | int | Nodes with no entity match |
| `ExteriorNodes` | int | Nodes with coordinates |
| `InteriorNodes` | int | Nodes without coordinates |
| `PossiblyStaleEdges` | int | Edges flagged as potentially outdated |

Edge types and data sources:

| Edge Type | Source | Directionality | Notes |
|---|---|---|---|
| `Containment` | Entity `@lokacja` | Parent to Child | Structural hierarchy |
| `Door` | Entity `@drzwi` | Entity to Door target | Physical link |
| `Route` | Session `@Lokacje` with `->` | Sequential | Optional notation, uncommon |
| `InferredHierarchy` | Session `@Lokacje` with `/` | Parent to Child | E.g., `Erathia/Zamek Steadwick` |
| `Movement` | Log LocationSegments | Sequential | Walkable transitions (structurally adjacent, distance <= 2) |
| `Teleport` | Log LocationSegments | Sequential | Non-adjacent transitions -- excluded from physical connectivity |

After building structural edges (Containment + Door), an adjacency set is constructed for each location. A log transition A to B is classified as Movement if A and B are within graph distance <= 2 through structural edges (direct neighbor, or share a common neighbor -- e.g., two children of the same parent). If neither direct adjacency nor a shared neighbor exists, it is classified as Teleport. Teleport edges are recorded in the graph with `Type = 'Teleport'` but are semantically distinct from Movement -- they represent magical/instant travel and should be excluded from physical connectivity analysis.

Progressive refinement: Migration Phase 9 creates Lokacja entities with canonical names and `@margonemid` tags but does not populate `@drzwi` connections. In this initial state, adjacency is limited to containment (parent-child), so most transitions between standalone exterior locations are classified as Teleport. As `@drzwi` connections are added -- manually or through analysis of high-frequency movement patterns -- the classification improves. Full multi-signal teleport detection (movement frequency, coordinate proximity, external data from MargoWorld plugin) is an advanced concern beyond core scope.

An edge is marked `PossiblyStale` when either the source or target entity has multiple `CoordinateHistory` entries and at least one history entry has `ValidFrom` after the edge's `FirstSeen` date. This indicates the location moved on the map after the edge was established. The `StaleReason` string format: `"Source coordinates changed at YYYY-MM-DD"` or `"Target coordinates changed at YYYY-MM-DD"`.

---

## CLI Integration

Registry key: `location-graph`, Mode: `Workflow`, Category: `Raporty`.

The `location-report` entry has a `DataTransform` scriptblock to extract `.Locations` from the new wrapper return type for backward-compatible table display.

`Invoke-LocationGraphWorkflow` in `private/cli/cli-wf-reporting.ps1`: (1) Date range wizard (start/end date prompts). (2) Movement edges choice (Yes/No via `Show-ArrowMenu`). (3) Invokes `Get-LocationGraph` with collected parameters. (4) Displays summary table (node/edge counts by type). (5) Displays node table (Name, NerthusName, Coordinates, In/Out degree).

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| `@koordynaty` with non-integer values | Skipped with warning; `Coordinates` remains `$null` |
| `@koordynaty` with wrong number of parts (not 2) | Skipped silently |
| Interior location (no `@koordynaty`) | `Coordinates = $null`, `IsExterior = $false` (or `$true` if exterior Mapa children exist) |
| Self-transition in logs (same location twice) | Skipped -- not added to `Transitions` |
| Route edge `A -> A` (same location) | Preserved -- route edges do not filter self-loops |
| Entity alias resolution in node construction | Lookup checks both `Name` and `Names` (aliases) |
| Duplicate edge from multiple sources | Weight incremented, Sources list extended |
| No sessions in date range | Returns graph with only entity-sourced edges |
| `Get-NamedLogLocationReport` fails | Warning emitted, movement edges skipped (graph still built) |
| Empty `@Lokacje` entry | Skipped (filtered by `IsNullOrWhiteSpace` check) |
| Location name `Brak` | Filtered out during route edge extraction |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/koordynaty-parsing.Tests.ps1` | `@koordynaty` parsing: simple, temporal, empty, invalid, multi-entity merge |
| `tests/get-namedlocationreport.Tests.ps1` | Route edges: extraction, consecutive pairs, multi-session, wrapper return type |
| `tests/get-namedloglocationreport.Tests.ps1` | Transition edges: consecutive pairs, self-transition skip, resolved names, empty logs (+ existing resolution tests) |
| `tests/get-locationgraph.Tests.ps1` | Containment, door, coordinate, route, inferred hierarchy edges; MapTraversalGraph parameter; node resolution; summary counts; empty inputs |
| `tests/get-maptraversalgraph.Tests.ps1` | Resolution stages (exact, alias, suffix strip, word drop, unresolved); self-transition skip; Lokacja projection; edge weight; date handling; empty input |

Fixture files:

| Fixture | Used by |
|---|---|
| `tests/fixtures/entities-koordynaty.md` | koordynaty-parsing, get-locationgraph |
| `tests/fixtures/sessions-route-edges.md` | get-namedlocationreport, get-locationgraph |
| `tests/fixtures/entities.md` | get-locationgraph (containment/door edges) |
| `tests/fixtures/map-traversal-logs.md` | get-maptraversalgraph (Lokacja + Mapa entities with aliases) |

---

## Related Documents

- [ENTITIES.md](ENTITIES.md) -- Entity data model, `@koordynaty` tag, temporal history arrays
- [SESSIONS.md](SESSIONS.md) -- Session metadata extraction (`@Lokacje`, route edge source)
- [LOGS.md](LOGS.md) -- Log location analysis (transition edge source)
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) -- Name resolution used for entity matching in nodes
- [AUDITING.md](AUDITING.md) -- Other reporting functions (`Get-NamedLocationReport` scope note)

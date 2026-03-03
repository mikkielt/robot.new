# Location Graph - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the location graph subsystem: `Get-LocationGraph` (multi-source edge merging, node construction, staleness detection), route edge extraction in `Get-NamedLocationReport`, transition edge extraction in `Get-NamedLogLocationReport`, and `@koordynaty` tag parsing in `Get-Entity`/`Get-EntityState`.

**Not covered**: Location entity CRUD — see [ENTITY-WRITES.md](ENTITY-WRITES.md). Log fetching and parsing — see [LOGS.md](LOGS.md). Name resolution internals — see [NAME-RESOLUTION.md](NAME-RESOLUTION.md). Session format and metadata extraction — see [SESSIONS.md](SESSIONS.md).

---

## 2. Architecture Overview

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

### Source Files

| File | Function | Role |
|---|---|---|
| `public/reporting/get-locationgraph.ps1` | `Get-LocationGraph` | Core graph assembly |
| `public/reporting/get-namedlocationreport.ps1` | `Get-NamedLocationReport` | Route edge extraction (and location analysis) |
| `public/reporting/get-namedloglocationreport.ps1` | `Get-NamedLogLocationReport` | Transition edge extraction (and log location analysis) |
| `public/get-entity.ps1` | `Get-Entity` | `@koordynaty` tag parsing |
| `public/get-entitystate.ps1` | `Get-EntityState` | `@koordynaty` Zmiany override |
| `private/cli/cli-registry.ps1` | — | CLI menu entry `location-graph` |
| `private/cli/cli-wf-reporting.ps1` | `Invoke-LocationGraphWorkflow` | CLI workflow |
| `private/location-helpers.ps1` | `Get-MapBaseName` | Map name suffix stripping |

---

## 3. `@koordynaty` Tag

### 3.1 Syntax

```markdown
* Wieża Obserwacyjna
    - @koordynaty: 125, 80
    - @koordynaty: 130, 85 (2025-01:)
```

Format: `X, Y` where X and Y are integer tile coordinates (32×32 pixel units on the Margonem world map). Supports temporal validity ranges like all other tags (see [ENTITIES.md](ENTITIES.md) §3.6).

Interior locations (no world-map position) omit `@koordynaty` entirely; their `Coordinates` property resolves to `$null`.

### 3.2 Parsing (Get-Entity)

In `public/get-entity.ps1`, the `@koordynaty` case in the tag switch:

1. Splits the value on `,` — expects exactly 2 parts
2. Validates both parts parse as `[int]`
3. Builds a history entry: `@{ X; Y; ValidFrom; ValidTo; Season }`
4. Appends to `$CoordinateHistory` (a `List[object]`)

Active coordinate resolution mirrors `@nazwa_nerthus`: iterates `$CoordinateHistory` in reverse, applies `Test-TemporalActivity`, and takes the first active entry.

Entity object properties added:
- `Coordinates` — `@{ X = [int]; Y = [int] }` or `$null` (active value)
- `CoordinateHistory` — `List[object]` of all temporal entries

### 3.3 Session Overrides (Get-EntityState)

In `public/get-entitystate.ps1`, the `@koordynaty` case in the Zmiany tag switch follows the same parse-validate-append pattern. The entry is auto-dated from the session date (same as `@lokacja`, `@nazwa_nerthus`, etc.).

### 3.4 Merge (Get-Entity multi-file)

`CoordinateHistory` merge follows the same pattern as `NerthusNameHistory`: entries from secondary files are appended, then the combined list is re-sorted and active value recomputed.

---

## 4. Route Edges

### 4.1 Extraction

Implemented in `Get-NamedLocationReport` (`public/reporting/get-namedlocationreport.ps1`).

Session `@Lokacje` entries record locations where meaningful action took place — they do not represent a physical route. The optional `->` separator indicates a location transition within a session:

```markdown
- @Lokacje:
    - Erathia -> Bracada
```

This notation is not widely used. When present, the function splits each location string on `\s*->\s*|\s+- \s*` (precompiled regex `$RouteSplitRegex`), cleans segments (trim, strip trailing `*`, skip `Brak`), then extracts consecutive pairs as route edges.

### 4.2 Return Type Change

`Get-NamedLocationReport` returns a `[PSCustomObject]` wrapper instead of a plain array:

```powershell
[PSCustomObject]@{
    Locations  = $Result      # [PSCustomObject[]] — the location report entries
    RouteEdges = @($RouteEdges)  # [PSCustomObject[]] — extracted edges
}
```

**Breaking change**: callers that previously iterated the return value directly must now access `.Locations`. Updated callers:
- `migration/phase4-session-upgrade.ps1` — uses `$LocationReportResult.Locations`
- CLI registry `location-report` entry — `DataTransform = { param($R) $R.Locations }` for backward-compatible table display

### 4.3 Route Edge Schema

| Property | Type | Description |
|---|---|---|
| `Source` | string | Cleaned name of the departure location |
| `Target` | string | Cleaned name of the destination location |
| `SessionDate` | string | Session date as `yyyy-MM-dd` |
| `Header` | string | Session header string |
| `FilePath` | string | Source file path |

---

## 5. Transition Edges (Primary Connectivity Source)

Session logs are the primary source of truth for physical location connectivity. While session `@Lokacje` metadata records only where meaningful action occurred, log LocationSegments capture every physical location a character passes through — including intermediate locations omitted from session metadata.

### 5.1 Extraction

Implemented in `Get-NamedLogLocationReport` (`public/reporting/get-namedloglocationreport.ps1`).

After building the `$LocationEntries` list from resolved LocationSegments, the function iterates consecutive pairs. Self-transitions (same resolved or raw name, case-insensitive) are skipped.

### 5.2 Integration in Output

Each session result object gains two properties:

| Property | Type | Description |
|---|---|---|
| `Transitions` | `PSCustomObject[]` | Consecutive location pair edges |
| `Summary.TransitionCount` | int | Count of transitions for the session |

### 5.3 Transition Edge Schema

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

## 5b. Map Name Stripping (`Get-MapBaseName`)

Game maps use naming conventions with floor, room, direction, and difficulty suffixes (e.g. `Piekielna Grota p.3 - sala 1`). When `Resolve-Name` fails on a raw LocationSegment header, `Get-NamedLogLocationReport` falls back to `Get-MapBaseName` to produce progressively shorter candidate names.

### Algorithm

1. Strip trailing difficulty parenthetical `(poziom: ...)` if present — add the cleaned name as the first candidate.
2. Split the remaining name by whitespace.
3. Progressively drop trailing words, keeping at least 1 word. Each shorter version becomes a candidate.
4. Trailing separators (`-`, `–`, `—`) are trimmed from each candidate.
5. Return all candidates ordered from longest (least stripped) to shortest.

The caller iterates candidates in order and uses `Resolve-Name` on each. The **first** candidate that resolves is used. The `StrippedName` output property records which candidate matched.

### Source

`private/location-helpers.ps1` — dot-sourced by `Get-NamedLogLocationReport`. Resolved entries receive `Stage = 'MapStrip'`.

---

## 6. `Get-LocationGraph`

### 6.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Sessions` | object[] | No | Pre-fetched sessions from `Get-Session` |
| `Entities` | object[] | No | Pre-fetched entities from `Get-Entity` |
| `SessionLog` | object[] | No | Pre-fetched log report from `Get-NamedLogLocationReport` |
| `MinDate` | datetime | No | Include only sessions on or after this date |
| `MaxDate` | datetime | No | Include only sessions on or before this date |
| `IncludeMovementEdges` | switch | No | Include transition edges from session logs |
| `Quiet` | switch | No | Suppress warnings |

### 6.2 Algorithm

1. **Load data**: Auto-fetch `Get-Entity` and `Get-Session` if not provided (passes `MinDate`/`MaxDate`)
2. **Build entity lookup**: Case-insensitive dictionary keyed by `Name` and all entries in `Names` (aliases)
3. **Edge accumulation**: Uses a `$AddEdge` scriptblock closure over an `$EdgeKey` dictionary (key = `"Source|Target|Type"`, case-insensitive). Duplicate edges increment `Weight` and extend `Sources` list
4. **Containment edges** (Type=`Containment`): From `@lokacja` chain — `parent → child` for every `Lokacja` entity with a non-null `Location`
5. **Door edges** (Type=`Door`): From `@drzwi` — `entity → door_target` for every Lokacja with non-empty `Doors` list
6. **Route edges** (Type=`Route`): From `Get-NamedLocationReport` `.RouteEdges` — consecutive `->` segments from session metadata
7. **Inferred hierarchy edges** (Type=`InferredHierarchy`): From `Get-NamedLocationReport` `.Locations[].InferredParents` — slash-path parent-child relationships
8. **Movement edges** (Type=`Movement`, optional): From `Get-NamedLogLocationReport` `.Transitions` — consecutive log location segments. Only included when `-IncludeMovementEdges` is set
9. **Node construction**: All unique endpoint names from edges form the node set. Each node resolves against the entity lookup for `CN`, `NerthusName`, `Coordinates`, and `IsExterior` classification
10. **Degree computation**: In-degree and out-degree per node
11. **Staleness detection**: For each edge, checks if source or target entity has `CoordinateHistory` with entries whose `ValidFrom` is after the edge's `FirstSeen` — marks `PossiblyStale = $true` with reason string

### 6.3 Edge Object Schema

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

### 6.4 Node Object Schema

| Property | Type | Description |
|---|---|---|
| `Name` | string | Location name (as seen in edges) |
| `EntityMatch` | object | Matched entity object, or `$null` |
| `CN` | string | Canonical Name from entity, or `$null` |
| `NerthusName` | string | RP override name, or `$null` |
| `Coordinates` | hashtable | `@{ X; Y }` from `@koordynaty`, or `$null` |
| `IsExterior` | bool | `$true` if entity has coordinates (world-map tile) |
| `InDegree` | int | Number of inbound edges |
| `OutDegree` | int | Number of outbound edges |

### 6.5 Summary Object Schema

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

### 6.6 Edge Types and Data Sources

| Edge Type | Source | Directionality | Notes |
|---|---|---|---|
| `Containment` | Entity `@lokacja` | Parent → Child | Structural hierarchy |
| `Door` | Entity `@drzwi` | Entity → Door target | Physical link |
| `Route` | Session `@Lokacje` with `->` | Sequential | Optional notation, uncommon |
| `InferredHierarchy` | Session `@Lokacje` with `/` | Parent → Child | E.g., `Erathia/Zamek Steadwick` |
| `Movement` | Log LocationSegments | Sequential | Walkable transitions (structurally adjacent, distance ≤ 2) |
| `Teleport` | Log LocationSegments | Sequential | Non-adjacent transitions — excluded from physical connectivity |

### 6.7 Teleport Detection

After building structural edges (Containment + Door), an **adjacency set** is constructed for each location. A log transition A → B is classified as:

- **Movement** if A and B are within **graph distance ≤ 2** through structural edges (direct neighbor, or share a common neighbor — e.g., two children of the same parent)
- **Teleport** if neither direct adjacency nor a shared neighbor exists

Teleport edges are recorded in the graph with `Type = 'Teleport'` but are semantically distinct from Movement — they represent magical/instant travel and should be excluded from physical connectivity analysis.

**Progressive refinement**: Migration Phase 9 creates Lokacja entities with canonical names and `@margonemid` tags but does **not** populate `@drzwi` connections. In this initial state, adjacency is limited to containment (parent-child), so most transitions between standalone exterior locations are classified as Teleport. As `@drzwi` connections are added — manually or through analysis of high-frequency movement patterns — the classification improves. Full multi-signal teleport detection (movement frequency, coordinate proximity, external data from MargoWorld plugin) is an advanced concern beyond core scope.

### 6.8 Staleness Detection

An edge is marked `PossiblyStale` when:
- Either the source or target entity has multiple `CoordinateHistory` entries
- At least one history entry has `ValidFrom` after the edge's `FirstSeen` date
- This indicates the location moved on the map after the edge was established

The `StaleReason` string format: `"Source coordinates changed at YYYY-MM-DD"` or `"Target coordinates changed at YYYY-MM-DD"`.

---

## 7. CLI Integration

### 7.1 Menu Entry

Registry key: `location-graph`, Mode: `Workflow`, Category: `Raporty`.

The `location-report` entry has a `DataTransform` scriptblock to extract `.Locations` from the new wrapper return type for backward-compatible table display.

### 7.2 Workflow

`Invoke-LocationGraphWorkflow` in `private/cli/cli-wf-reporting.ps1`:

1. Date range wizard (start/end date prompts)
2. Movement edges choice (Yes/No via `Show-ArrowMenu`)
3. Invokes `Get-LocationGraph` with collected parameters
4. Displays summary table (node/edge counts by type)
5. Displays node table (Name, NerthusName, Coordinates, In/Out degree)

---

## 8. Edge Cases

| Scenario | Behavior |
|---|---|
| `@koordynaty` with non-integer values | Skipped with warning; `Coordinates` remains `$null` |
| `@koordynaty` with wrong number of parts (not 2) | Skipped silently |
| Interior location (no `@koordynaty`) | `Coordinates = $null`, `IsExterior = $false` |
| Self-transition in logs (same location twice) | Skipped — not added to `Transitions` |
| Route edge `A -> A` (same location) | Preserved — route edges do not filter self-loops |
| Entity alias resolution in node construction | Lookup checks both `Name` and `Names` (aliases) |
| Duplicate edge from multiple sources | Weight incremented, Sources list extended |
| No sessions in date range | Returns graph with only entity-sourced edges |
| `Get-NamedLogLocationReport` fails | Warning emitted, movement edges skipped (graph still built) |
| Empty `@Lokacje` entry | Skipped (filtered by `IsNullOrWhiteSpace` check) |
| Location name `Brak` | Filtered out during route edge extraction |

---

## 9. Testing

| Test file | Coverage |
|---|---|
| `tests/koordynaty-parsing.Tests.ps1` | `@koordynaty` parsing: simple, temporal, empty, invalid, multi-entity merge |
| `tests/get-namedlocationreport.Tests.ps1` | Route edges: extraction, consecutive pairs, multi-session, wrapper return type |
| `tests/get-namedloglocationreport.Tests.ps1` | Transition edges: consecutive pairs, self-transition skip, resolved names, empty logs (+ existing resolution tests) |
| `tests/get-locationgraph.Tests.ps1` | Containment, door, coordinate, route, inferred hierarchy edges; node resolution; summary counts; empty inputs |

**Fixture files:**

| Fixture | Used by |
|---|---|
| `tests/fixtures/entities-koordynaty.md` | koordynaty-parsing, get-locationgraph |
| `tests/fixtures/sessions-route-edges.md` | get-namedlocationreport, get-locationgraph |
| `tests/fixtures/entities.md` | get-locationgraph (containment/door edges) |

---

## 10. Related Documents

- [ENTITIES.md](ENTITIES.md) - Entity data model, `@koordynaty` tag, temporal history arrays
- [SESSIONS.md](SESSIONS.md) - Session metadata extraction (`@Lokacje`, route edge source)
- [LOGS.md](LOGS.md) - Log location analysis (transition edge source)
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) - Name resolution used for entity matching in nodes
- [AUDITING.md](AUDITING.md) - Other reporting functions (`Get-NamedLocationReport` scope note)

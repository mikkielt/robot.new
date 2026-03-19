# Campaign Data API

## Purpose

The Campaign Data API gives external tools — dashboards, Discord bots, custom scripts — access to campaign data. It acts as a bridge between the Robot module and any tool that needs to read or write entity, session, player, or currency information without using the CLI directly.

## Scope

This guide covers what data is available through the API, what operations it supports, and how the Coordinator manages the server. For entity data, see [World-State.md](World-State.md). For session data, see [Sessions.md](Sessions.md). For currency, see [Currency.md](Currency.md).

## Actors and Responsibilities

The Coordinator starts and stops the API server through the CLI, configures access control and server capacity, and monitors server health.

The Integrator builds clients (dashboards, bots, scripts) that consume the API, chooses appropriate query parameters for filtering and pagination, and handles error responses.

## Inputs Required

- The Robot module with the robot-api plugin enabled
- A free network port on the host machine (default 8642)

## Available Data

The API provides read access to the full campaign dataset.

Entities — browse, search, and inspect all entities (NPCs, locations, items, groups, maps) with full change history and temporal diffs. Queries accept both Polish and English values for types and statuses.

Locations — browse locations with enriched hierarchy, door connections, child locations, and entity counts. Query which entities are present at a given location. Create, update, and remove locations with the same parent and coordinate validation as the CLI.

Maps — list all game-map entries and create new ones.

Players and characters — player roster with character assignments.

Sessions — session list and session participation graph, including per-entity session profiles, overlap analysis between entities, and leaderboards. Create new sessions (single or batch) with the same metadata fields available in the CLI.

Currency and economy — currency holdings, transaction ledger, economic snapshots (supply breakdown, wealth distribution), and monthly economic timelines.

Reports — change audit, dormancy, session frequency, narrator statistics, location data, PU processing history, notification logs, and Discord webhook delivery history.

Validation — PU assignments, currency reconciliation, session integrity, and graph integrity checks.

Name resolution — resolve any name to its entity or player, with fuzzy matching when the exact name is not found. Batch resolution accepts multiple names at once and returns enriched results including session participation data when available.

Log parsing — submit raw log text and receive structured data back, or provide log URLs to fetch and parse their content. Preview session markdown with name resolution before committing.

File listing — retrieve a list of Markdown file paths from the repository, useful for autocomplete in client applications.

Dashboard — the web dashboard is served directly by the API as a self-contained page, accessible in a browser at the server address.

All data uses Polish canonical values for types, statuses, and domain terms. Clients can request English labels alongside Polish values for localization.

## Write Operations

When write access is enabled, the API supports creating new entities (with a name and type), updating entity tags, soft-deleting entities (marking them as Usunięty — they are never physically removed), creating and updating locations and maps (with parent validation and coordinate checks), creating players and player characters, creating or updating currency holdings, creating sessions (single or batch), and triggering maintenance workflows such as rebuilding the session graph or updating session content hashes.

Write operations automatically notify connected real-time clients when entities are created or modified.

## Filtering, Sorting, and Pagination

List queries support filtering by any field (type, status, name, location, and others), with both Polish and English values accepted. Multiple filters can be combined. Results can be sorted by any field in ascending or descending order, and limited to specific fields for efficiency.

Large result sets are paginated automatically. The default page size is 50 items, with a maximum of 500. Each response includes a continuation token for retrieving the next page.

## Real-Time Notifications

External tools can subscribe to a live event stream that pushes notifications whenever an entity is created, an entity's data changes, or a new player character is registered. Dashboards use this to update without polling.

## Server Management

The Coordinator starts and stops the API server through the CLI menu. The status view shows uptime, request count, queue depth, and connected real-time clients.

Access control is optional — when configured, all requests require a token. When not configured, the API is open. A read-only mode disables all write operations, allowing safe exposure to broader audiences.

The server enforces request rate limits per client. When a client exceeds the limit, it receives a brief wait instruction before retrying. The number of parallel workers controls how many requests the server handles simultaneously — more workers handle more load but consume more memory.

## Expected Outcomes

- Dashboards and bots can display live campaign data without CLI access
- Entity, session, player, currency, and report data is available for any external tool to consume
- Write-capable clients can create entities and update currency with the same safeguards as CLI operations
- Real-time subscribers receive immediate notification of data changes

## Exceptions and Recovery

| Situation | What Happens | Recovery |
|---|---|---|
| No access token provided when required | The request is rejected | Configure the token in the client application |
| Too many requests from one client | The client receives a wait instruction | Slow down requests; wait before retrying |
| Write request in read-only mode | The request is rejected | Switch to read-only queries, or disable read-only mode |
| Server is overloaded | The request is deferred | Wait and retry; the Coordinator can increase worker capacity |
| A query takes too long | The request times out | Narrow the query (smaller date range, fewer entities) |
| Data not found | Empty result returned | Verify the entity or session exists; check spelling |

## Related Documents

- [World-State.md](World-State.md) — Entity management and temporal scoping
- [Players.md](Players.md) — Player and character management
- [Sessions.md](Sessions.md) — Session recording and formats
- [Currency.md](Currency.md) — Currency holdings and transfers
- [Economy.md](Economy.md) — Economic analysis
- [Session-Graph.md](Session-Graph.md) — Session participation graph
- [Name-Resolution.md](Name-Resolution.md) — How name resolution works
- [Location-Graph.md](Location-Graph.md) — Location connectivity and analysis

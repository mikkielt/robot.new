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

Maps — list all game-map entries, create new ones, and update existing maps (slug, dimensions, parent, doors).

Players and characters — player roster with character assignments. Individual characters can be inspected with their merged temporal state (active state on a chosen date, optional inclusion of soft-deleted characters). A per-player starting-PU preview reports the pool a brand-new character would receive based on the player's existing PU history.

Items — browse Przedmiot entities enriched with owner type (physical character holding, virtual NPC/group/player holding, or unknown), location, current quantity, and currency classification. Filters cover owner, location, name substring, active date, and whether to include inactive, soft-deleted, or currency entities. Items use the same paginated list envelope as entities.

Sessions — session list and session participation graph, including per-entity session profiles, overlap analysis between two or more entities at once, leaderboards, and per-narrator profiles (session count, date range, unique participants by type, average party size). Create new sessions (single or batch) and update existing sessions in place (identified by date plus file path) with the same metadata fields available in the CLI.

Currency and economy — currency holdings, transaction ledger, economic snapshots (supply breakdown, wealth distribution), monthly economic timelines, and a materialization report that separates physical currency (held by characters) from virtual currency (held by NPCs, groups, or players) and flags orphaned funds attached to inactive or removed characters.

PU — recent-window voting eligibility for players, computed from the PU assignment history. The threshold and lookback window are tunable per request.

Reports — change audit, dormancy, session frequency, narrator statistics, location data, PU processing history, notification logs, and Discord webhook delivery history.

Validation — PU assignments, currency reconciliation, session integrity, and graph integrity checks.

Name resolution — resolve any name to its entity or player, with fuzzy matching when the exact name is not found. Batch resolution accepts multiple names at once and returns enriched results including session participation data when available.

Log parsing — submit raw log text and receive structured data back, or provide log URLs to fetch and parse their content. Preview session markdown with name resolution before committing.

File listing — retrieve a flat list of Markdown file paths from the repository, or a hierarchical directory tree of those files. The flat list is useful for autocomplete in client applications; the tree structure supports file browsers and path navigation in dashboards.

Dashboard — the web dashboard is served directly by the API as a self-contained page, accessible in a browser at the server address.

Help — the API is self-documenting. A help index lists all available help components (such as API endpoints, editor zones, and CLI categories). Querying a specific component returns detailed field descriptions, accepted parameters, and response formats. Results can be filtered by language (Polish or English) and by which fields to include, so clients fetch only the documentation they need. Help data is loaded once at server startup from sidecar files shipped with the plugin.

Server diagnostics — a set of lightweight endpoints provide operational information without touching campaign data. These include a health check (confirms the server is running), a route listing (all registered endpoints with methods and descriptions), a metrics summary (uptime, request count, queue depth, route count), and a schema dictionary (all domain names, types, statuses, and enum values used by the API). These endpoints are handled entirely by the server engine with no worker overhead, making them suitable for monitoring and integration discovery.

All data uses Polish canonical values for types, statuses, and domain terms. Clients can request English labels alongside Polish values for localization.

## Write Operations

When write access is enabled, the API supports creating new entities (with a name and type), updating entity tags, soft-deleting entities (marking them as Usunięty — they are never physically removed), creating and updating locations and maps (with parent validation, coordinate checks, slug uniqueness, and door connection management), creating players and player characters, updating player metadata (MargonemID, PRF webhook, triggers, aliases, status), updating individual character fields (PU values, reputation tiers, profile, status), soft-deleting characters, creating or updating currency holdings and soft-deleting currency entities (with a warning when a non-zero balance is removed), creating sessions and updating existing sessions in place, and triggering maintenance workflows. Maintenance workflows include rebuilding the session graph, updating session content hashes, force-rebuilding the name index, fetching missing session logs sequentially with retries, and running the monthly PU assignment with fail-early validation and opt-in flags for persisting PU to character files, sending Discord notifications, appending to the PU processing log, and reconciling currency afterwards. The two long-running workflows (log fetch and PU assignment) are rate-limited per client to prevent accidental bulk runs.

Write operations automatically notify connected real-time clients when entities are created or modified.

## Filtering, Sorting, and Pagination

List queries support filtering by any field (type, status, name, location, and others), with both Polish and English values accepted. Multiple filters can be combined. Results can be sorted by any field in ascending or descending order, and limited to specific fields for efficiency.

Large result sets are paginated automatically. The default page size is 50 items, with a maximum of 500. Each response includes a continuation token for retrieving the next page.

## Response Caching

The API caches responses for expensive read operations (entity state, economy, leaderboard, dormancy, frequency, narrator statistics, location graph, and PU processing history). Cached results are stored as files on disk and reused across server restarts. Each cached response tracks which data domains it depends on — entities, sessions, or the session graph. When data in a domain changes (for example, after a write operation modifies an entity), all cached responses that depend on that domain are automatically invalidated.

Clients that include conditional request headers (ETags) receive a short "not modified" response when the underlying data has not changed, reducing bandwidth and improving response times for dashboards and bots that poll frequently.

## Real-Time Notifications

External tools can subscribe to a live event stream that pushes notifications whenever an entity is created, an entity's data changes, or a new player character is registered. Dashboards use this to update without polling.

## Schema and Migrations

The API exposes the repository's schema version, the list of discoverable migrations, and the operations required to advance or roll the schema back. A read of `/schema/version` returns the current version, the range the module supports, whether the module is in Normal mode (writes permitted) or Read-Only mode (writes refused until migrations are applied), how many migrations are still pending, and whether a migration is currently holding the schema lock.

A read of `/migrations` lists every migration the module can discover — those shipped with the module, those contributed by loaded plugins, and those the Coordinator has dropped into `<repo>/.robot.local/migrations/`. Each entry carries its version, description, requires-predecessor, affected categories (entity schema, session format, state file, cache, external import), estimated duration, and origin tag. A read of `/migrations/pending` returns just the migrations strictly above the current version, in the order they would apply.

A read of `/migrations/<id>/preview` runs the migration's dry-run report and returns the files that would be modified, created, or deleted; entity counts before and after where applicable; sample diffs; and any warnings the migration emits during preview. Previews are read-only — they do not write data and do not hit the network unless the request explicitly opts in.

A write to `/migrations/apply` runs the migration. The body specifies the target (by migration id, or by version for a chain), whether the apply should block until completion (`mode: sync`) or return a job id immediately (`mode: async`), the branching strategy (apply in place, on a new git branch, or on a branch that fast-forward merges back on success), and whether the Coordinator has reviewed and accepted an operator-local unsigned migration. A sync apply on a migration estimated to take more than ten seconds is refused with a hint to switch to async — this prevents the request from outliving the HTTP timeout. Long applies are tracked as background jobs whose status is read at `/migrations/jobs/<id>`.

If a migration crash leaves the schema lock held by a dead process, the Coordinator can clear it with `DELETE /schema/lock` (requires a token with the `migration:admin` scope). The framework also surfaces locks older than the configured stale-TTL with a "likely stale" flag in the `/schema/version` response, so the Coordinator can distinguish a genuine in-progress migration from a wedged one.

If a release of the repository has to be rolled back (for example, after a bad commit was reverted in git), the schema pointer can be brought into sync with the reverted state via `POST /schema/restore` (requires the separate `migration:restore` scope, which is held independently of `migration:admin` so downgrade rights can be granted without lock-clearing rights). The target version must already appear in the schema's history — the operation is pointer-only; no migration script runs.

Tokens scoped to `migration:read` can preview and inspect; `migration:write` is required to apply; `migration:admin` clears stale locks; `migration:restore` downgrades the pointer.

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

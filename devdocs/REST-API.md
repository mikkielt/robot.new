# REST API - Technical Reference

## Scope

This document covers the compiled C# server engine (`lib/Api*.cs`), the plugin shell (`plugins/robot-api/`), the RunspacePool worker bridge, the RSQL query layer, the endpoint reference, and the request/response protocol.

For plugin system mechanics, see [PLUGINS.md](PLUGINS.md). For entity data access, see [ENTITIES.md](ENTITIES.md). For session graph reporting, see [SESSION-GRAPH.md](SESSION-GRAPH.md).

## Architecture Overview

```
                    HttpListener (C#)
                    GetContextAsync() on .NET ThreadPool
                         |
                    ApiMiddleware (C#)
                    Auth → CORS → RateLimit → SizeCheck
                         |
                    ApiRouter (C#)
                    Compiled regex route matching
                    Path param extraction
                         |
        +----------------+------------------+
        |                |                  |
   Static (C#)     Dynamic (PS)        SSE
   /health         BlockingCollection   ApiSseManager
   /routes         <ApiRequest>         ConcurrentDictionary
   /metrics        enqueue              broadcast
   /schema              |
                    RunspacePool (N=4-16)
                    Each: Import-Module robot
                    Dequeue → Invoke → Result
                    Set TaskCompletionSource
                         |
                    ApiSerializer (C#)
                    Utf8JsonWriter → OutputStream
```

The server uses a hybrid architecture: a compiled C# engine handles HTTP I/O, routing, middleware, and serialization, while PowerShell RunspacePool workers execute the business logic handlers. Static routes (`/health`, `/routes`, `/metrics`, `/schema`) respond entirely in C# without touching the worker pool.

## Endpoint Reference

Base URL: `http://<address>:<port>/api/` (default `http://localhost:8642/api/`). All paths below are relative to this prefix.

System endpoints respond entirely in C# without touching the worker pool:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/health` | Static (C#) | Server health (status, uptime, request count) |
| GET | `/routes` | Static (C#) | Registered route list |
| GET | `/metrics` | Static (C#) | Request count, queue depth, SSE clients, route count |
| GET | `/schema` | Static (C#) | Name dictionary — all valid enum values with Polish/English mappings |
| GET | `/events` | SSE (C#) | Server-Sent Events stream |

Entity endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/entities` | `Invoke-ApiGetEntities` | List with RSQL filter, sort, pagination |
| GET | `/entities/:name` | `Invoke-ApiGetEntity` | Single entity (fuzzy name resolution via `Resolve-Name`) |
| GET | `/entities/:name/history` | `Invoke-ApiGetEntityHistory` | Temporal changelog |
| GET | `/entities/:name/delta` | `Invoke-ApiGetEntityDelta` | Property diff between two dates |
| GET | `/entity-state` | `Invoke-ApiGetEntityState` | Enriched state with session overrides |
| POST | `/entities` | `Invoke-ApiCreateEntity` | Create entity (name + type required) |
| PUT | `/entities/:name` | `Invoke-ApiUpdateEntity` | Update entity tags |
| DELETE | `/entities/:name` | `Invoke-ApiDeleteEntity` | Soft-delete (status → Usuniety) |

Player endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/players` | `Invoke-ApiGetPlayers` | List all players |
| GET | `/players/:name` | `Invoke-ApiGetPlayer` | Single player with characters |
| POST | `/players` | `Invoke-ApiCreatePlayer` | Create player |
| POST | `/players/:name/characters` | `Invoke-ApiCreateCharacter` | Create player character |

Session endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/sessions` | `Invoke-ApiGetSessions` | List sessions |
| GET | `/session-graph/entity/:name` | `Invoke-ApiGetEntityProfile` | Participation profile |
| GET | `/session-graph/compare` | `Invoke-ApiCompareParticipation` | Overlap analysis |
| GET | `/session-graph/leaderboard` | `Invoke-ApiGetLeaderboard` | Top entities by session count |

Currency and economy endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/currency` | `Invoke-ApiGetCurrency` | Currency holdings |
| GET | `/economy/snapshot` | `Invoke-ApiGetEconomicSnapshot` | Supply, Gini, top holders |
| GET | `/economy/timeline` | `Invoke-ApiGetEconomicTimeline` | Monthly trends |
| GET | `/transactions` | `Invoke-ApiGetTransactions` | Transaction ledger |
| POST | `/currency` | `Invoke-ApiCreateCurrency` | Create holding |
| PUT | `/currency/:name` | `Invoke-ApiUpdateCurrency` | Update amount |

Name resolution, validation, report, and workflow endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/resolve/:name` | `Invoke-ApiResolveName` | Resolve name to entity or player |
| GET | `/validate/pu` | `Invoke-ApiValidatePU` | PU assignment validation |
| GET | `/validate/currency` | `Invoke-ApiValidateCurrency` | Currency reconciliation |
| GET | `/validate/sessions` | `Invoke-ApiValidateSessions` | Session integrity |
| GET | `/validate/graph` | `Invoke-ApiValidateGraph` | Session graph integrity |
| GET | `/reports/changelog` | `Invoke-ApiGetChangelog` | Entity change audit log |
| GET | `/reports/dormancy` | `Invoke-ApiGetDormancy` | Inactive entity report |
| GET | `/reports/frequency` | `Invoke-ApiGetFrequency` | Session frequency trends |
| GET | `/reports/narrators` | `Invoke-ApiGetNarrators` | Narrator statistics |
| GET | `/reports/locations` | `Invoke-ApiGetLocations` | Location reference data |
| GET | `/reports/location-graph` | `Invoke-ApiGetLocationGraph` | Location topology |
| GET | `/reports/pu-log` | `Invoke-ApiGetPULog` | PU processing history |
| GET | `/reports/notifications` | `Invoke-ApiGetNotifications` | Notification audit log |
| GET | `/reports/discord-delivery` | `Invoke-ApiGetDeliveryLog` | Discord webhook delivery history |
| POST | `/workflow/session-graph` | `Invoke-ApiRebuildGraph` | Rebuild session graph index |
| POST | `/workflow/session-hash` | `Invoke-ApiRebuildHashes` | Update session content hashes |

Auth management endpoints (require `auth:manage` scope):

| Method | Path | Handler | Description |
|---|---|---|---|
| POST | `/auth/token` | `Invoke-ApiCreateToken` | Create a new scoped token |
| DELETE | `/auth/token/:name` | `Invoke-ApiDeleteToken` | Delete a token by name |
| GET | `/auth/status` | `Invoke-ApiGetAuthStatus` | List tokens and count |

## Authentication & Authorization

The API supports three auth modes, resolved in priority order:

1. Multi-token store (preferred): tokens stored in `.robot/res/api-tokens.psd1`, each with a name and scope list. Created via `New-RobotApiToken` or `POST /auth/token`. The token file must be gitignored — startup fails with a security error otherwise.
2. Single token: `AuthToken` config value or `ROBOT_API_TOKEN` env var. Token gets synthetic `admin:all` scope.
3. Open access: no tokens configured and no `AuthToken` set. All requests pass auth with synthetic `admin:all`.

Token format: `rbt_` prefix + 44 base62 chars (~48 chars total), generated via `System.Security.Cryptography.RandomNumberGenerator`.

## Scope Enforcement

Each route declares a `RequiredScope` (visible in `GET /routes` response). The middleware chain:

```
CORS → Authenticate (401) → RateLimit → RouteMatch (404) → ScopeCheck (403) → ReadOnly (403) → ContentType (415) → dispatch
```

Scope matching rules (implemented in `ApiMiddleware.HasScope`):
- `admin:all` matches any scope (wildcard)
- Exact match: token scope `entity:read` matches route requiring `entity:read`
- Hierarchical: token scope `entity:read` matches route requiring `entity:read:own`

## Scope Reference

| Scope | Routes |
|---|---|
| _(none)_ | Static: /health, /routes, /metrics, /schema; SSE: /events |
| `entity:read` | GET /entities, /entities/:name, /entity-state, /entities/:name/history, /entities/:name/delta, /resolve/:name, /currency, /economy/snapshot, /economy/timeline, /transactions |
| `entity:write` | POST /entities, PUT /entities/:name, DELETE /entities/:name, POST /currency, PUT /currency/:name |
| `player:read` | GET /players, /players/:name |
| `player:write` | POST /players, POST /players/:name/characters |
| `session:read` | GET /sessions, /session-graph/entity/:name, /session-graph/compare, /session-graph/leaderboard |
| `admin:read` | GET /validate/\*, /reports/\* |
| `admin:write` | POST /workflow/\* |
| `auth:manage` | POST /auth/token, DELETE /auth/token/:name, GET /auth/status |

## Token Management

```powershell
# Create a read-only token
$Token = New-RobotApiToken -Name 'frontend' -Scopes 'entity:read', 'session:read'
# $Token.Token contains the raw value (shown only once)

# List tokens (no raw values)
Get-RobotApiToken

# Remove a token
Remove-RobotApiToken -Name 'frontend' -Confirm:$false
```

## Request Protocol

Authentication: when tokens are configured (multi-token store or single `AuthToken`), all requests must include `Authorization: Bearer <token>`. Multi-token authentication scans all tokens with constant-time comparison via XOR accumulator in `ApiMiddleware`. Missing or invalid token returns HTTP 401. Insufficient scope returns HTTP 403.

CORS: when `CorsOrigin` is set, `ApiMiddleware` injects `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, and `Access-Control-Allow-Headers` on every response. Preflight `OPTIONS` requests receive HTTP 204 with the same headers. When unset, no CORS headers are sent.

Read-only mode: when `ReadOnly` is `true`, `ApiMiddleware` rejects POST/PUT/DELETE requests with HTTP 403 before they reach the router.

Request body limit: bodies exceeding `MaxRequestBody` (default 65536 bytes) are rejected with HTTP 413.

Response format: all responses are JSON via `ApiSerializer`. List endpoints return a pagination envelope:

```json
{
    "count": 142,
    "pageSize": 50,
    "hasMore": true,
    "nextCursor": "eyJuYW1lIjoiWm9sdGFuIn0=",
    "items": [...]
}
```

Label enrichment: `?labels=true` adds English label fields alongside Polish canonical values. Example response for `GET /api/entities/Ratusz%20Ithan?labels=true`:

```json
{
    "name": "Ratusz Ithan",
    "type": "Lokacja",
    "typeLabel": "location",
    "status": "Aktywny",
    "statusLabel": "active",
    "location": "Ithan"
}
```

Error responses:

| HTTP Status | Condition |
|---|---|
| 400 | Invalid JSON body or missing required parameters |
| 401 | Missing or invalid Bearer token |
| 403 | Insufficient scope or write request in read-only mode |
| 404 | Route not found |
| 413 | Request body exceeds size limit |
| 415 | Missing or incorrect Content-Type (must be `application/json`) |
| 422 | Handler processing error (invalid input data) |
| 429 | Rate limit exceeded (`Retry-After: 1` header) |
| 503 | Queue full (all workers busy, backpressure) |
| 504 | Handler timeout (60-second limit) |

## Query Examples

```bash
# List active locations with RSQL filter
curl http://localhost:8642/api/entities?filter=type==Lokacja;status==Aktywny

# English aliases work the same
curl http://localhost:8642/api/entities?filter=type==location;status==active

# Single entity with English labels
curl http://localhost:8642/api/entities/Solmyr?labels=true

# Sorted, paginated, sparse fieldset
curl 'http://localhost:8642/api/entities?sort=name&page[size]=10&fields=name,type'

# Create entity (requires auth token if configured)
curl -X POST http://localhost:8642/api/entities \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"name": "Nowa Lokacja", "type": "Lokacja"}'

# Health check (static route, no worker pool)
curl http://localhost:8642/api/health

# Name dictionary discovery
curl http://localhost:8642/api/schema
```

SSE client example:

```javascript
const events = new EventSource('http://localhost:8642/api/events');

events.addEventListener('entity:write', (e) => {
    const data = JSON.parse(e.data);
    console.log('Entity updated:', data.name);
});

events.addEventListener('entity:create', (e) => {
    const data = JSON.parse(e.data);
    console.log('New entity:', data.name, data.type);
});

events.addEventListener('character:create', (e) => {
    const data = JSON.parse(e.data);
    console.log('New character:', data.name);
});
```

## C# Class Responsibilities

`Robot.ApiServer` (`lib/ApiServer.cs`) — Async HTTP listener backed by `System.Net.HttpListener`. Manages the accept loop (`GetContextAsync` on the .NET ThreadPool), dispatches each request to `Task.Run` for parallel handling, and bridges to PowerShell via a `BlockingCollection<ApiRequest>` with configurable bounded capacity (default 512). Exposes `CacheVersion` as a static `Interlocked` counter for cross-runspace cache invalidation. Provides `GetStatus()` for the status endpoint.

`Robot.ApiRouter` (`lib/ApiRouter.cs`) — Compiled-regex URL route matcher. Routes are registered at startup and compiled once via `RegexOptions.Compiled`. Supports `:param` path segments that become named regex groups. Static routes (no params) use `Dictionary<string, ApiRoute>` for O(1) lookup before falling through to the regex list. Two handler types: `StaticHandler` (C# `Func<RouteMatch, ApiServer, object>`) and `HandlerName` (string identifying a PS function).

`Robot.ApiMiddleware` (`lib/ApiMiddleware.cs`) — Authentication (Bearer token with constant-time comparison via XOR accumulator), CORS header injection, per-IP token bucket rate limiting with `ConcurrentDictionary`, body size enforcement, and read-only mode flag. All checks execute in compiled C# with zero PowerShell overhead.

`Robot.ApiSerializer` (`lib/ApiSerializer.cs`) — Direct-to-stream JSON serialization via `System.Text.Json.Utf8JsonWriter`. Type dispatch chain: `Entity` (typed property access, no reflection), `IDictionary` (sorted keys), PSCustomObject/PSObject (reflection via `Properties` enumeration), `IList`, primitives (`string`, `int`, `long`, `double`, `decimal`, `bool`, `DateTime`), `IEnumerable`, and `ToString()` fallback. MaxDepth guard (12) prevents stack overflow on circular references.

`Robot.ApiSseManager` (`lib/ApiSseManager.cs`) — Thread-safe Server-Sent Events manager using `ConcurrentDictionary<long, SseClient>` keyed by monotonic client ID. Broadcasts events as JSON via `Utf8JsonWriter`. Dead client detection during broadcast (failed writes remove the client). 30-second heartbeat timer sends `: keepalive` comments to detect stale connections.

`Robot.ApiQueryParser` (`lib/ApiQueryParser.cs`) — RSQL filter parser and JSON:API query parameter processor. Parses `filter` (`;` = AND groups, `,` = OR within group), `sort` (`-` prefix = descending), `fields` (sparse fieldsets), `page[size]` / `page[after]` (cursor-based pagination). Entity-specific helpers for field access, filtering, sorting, and pagination. Stateless methods — safe for concurrent RunspacePool use.

`Robot.ApiNameDictionary` (`lib/ApiNameDictionary.cs`) — Static, thread-safe bidirectional mapping between canonical Polish domain terms and English API labels. Covers entity types (7), statuses (3), tags (14), seasons (4), denominations (3+3 short forms), session formats (4), participation sources (5), intel directives (3), and owner types (3). All lookups O(1) via `Dictionary<string, string>` with `OrdinalIgnoreCase`. Zero allocation on the hot path.

## Async Request Flow

1. `HttpListener.GetContextAsync()` accepts a connection on the .NET thread pool
2. `Task.Run` dispatches the request for parallel handling (does not block the accept loop)
3. Middleware chain executes in C#: CORS preflight check, Bearer auth verification, per-IP rate limit check
4. Router matches the URL against the compiled regex table and extracts path params
5. Static routes return directly from C# — the PS worker pool is never involved
6. SSE requests register the response stream with `ApiSseManager` and keep the connection open
7. Dynamic routes read the request body (with size check), create an `ApiRequest` with a `TaskCompletionSource<ApiResponse>`, and enqueue it to the `BlockingCollection`
8. If the queue is full, HTTP 503 is returned immediately (backpressure)
9. The HTTP thread awaits `TaskCompletionSource.Task` with a 60-second timeout (HTTP 504 on expiry)
10. A PowerShell worker dequeues the request, invokes the handler, and calls `SetResult` to unblock the HTTP thread
11. `ApiSerializer` writes the response directly to `HttpListenerResponse.OutputStream`

## BlockingCollection / TaskCompletionSource Bridge

The C# HTTP thread and the PowerShell worker thread communicate through two mechanisms:

`BlockingCollection<ApiRequest>` — bounded FIFO queue (default capacity 512). The HTTP thread calls `TryAdd` with a 5-second timeout. Worker threads call `Take` which blocks until a request is available or `CompleteAdding` is called during shutdown. This provides backpressure: when all workers are busy and the queue fills, new requests get HTTP 503 instead of unbounded memory growth.

`TaskCompletionSource<ApiResponse>` — per-request completion signal. Created with `RunContinuationsAsynchronously` to prevent worker thread hijacking. The HTTP thread awaits this task (with timeout). The PS worker calls `SetResult` after handler invocation. On handler error, the worker calls `SetResult` with a 500-status `ApiResponse` containing the error message.

## RunspacePool Worker Lifecycle

Worker initialization (`Start-ApiWorkerPool`):

1. For each of N workers (configurable, default 8): create an isolated `System.Management.Automation.Runspaces.Runspace`
2. Open the runspace and import the Robot module via `AddScript('Import-Module ...')`
3. Dot-source handler files: `api-handlers-read.ps1`, `api-handlers-write.ps1`
4. Each worker gets its own `PowerShell` instance bound to its runspace

Worker dequeue loop:

1. `$Server.RequestQueue.Take($Cts.Token)` blocks until a request arrives
2. Check cache coherence: read shared `CacheVersion`, compare to local version, call `Clear-ParseCaches` on mismatch
3. Look up handler by name from `$HandlerMap`
4. Build `$ApiContext` hashtable with `PathParams`, `QueryParams`, `Body`, `Method`, `Path`
5. Parse JSON body if present
6. Invoke the handler: `$PS.AddCommand($HandlerName).AddParameter('ApiContext', $Ctx).Invoke()`
7. Extract result hashtable with `StatusCode` and `Body`
8. For write methods (POST/PUT/DELETE): increment `CacheVersion` via `Interlocked.Increment`
9. Wrap in `ApiResponse` and call `ResponseSource.SetResult()`

Graceful shutdown (`Stop-ApiWorkerPool`):

1. Cancel the dequeue loop via `CancellationTokenSource`
2. Dispose each `PowerShell` instance
3. Close and dispose each `Runspace`

## Cache Coherence Protocol

The module uses in-memory parse caches (`$script:CachedEntities`, `$script:CachedSessions`, etc.) that are per-runspace. When a write handler modifies data, other runspaces must invalidate their stale caches.

`Robot.ApiServer.CacheVersion` is a `static long` accessed via `Interlocked.Read` and `Interlocked.Increment`. Each worker thread maintains a local version number. Before executing a read handler, the worker compares its local version against the shared version. On mismatch, it calls `Clear-ParseCaches` to force a re-parse on the next data access, then updates its local version. After executing a write handler, the worker increments the shared version.

This is an optimistic scheme: read-read sequences across workers share the same cache epoch without contention. Only writes (which are infrequent) force a global cache invalidation on the next read.

## Serializer Type Dispatch

`ApiSerializer.WriteValue` dispatches on type in this priority order:

1. Depth guard — beyond MaxDepth (12), `ToString()` the value
2. Null / DBNull — `WriteNullValue()`
3. String — `WriteStringValue()`
4. Numeric primitives — `int`, `long`, `double`, `decimal`, `float` → `WriteNumberValue()`
5. Boolean — `WriteBooleanValue()`
6. DateTime — ISO 8601 format `yyyy-MM-dd'T'HH:mm:ss`
7. Robot.Entity — typed property access (all 27 properties, no reflection)
8. IDictionary — JSON object via `DictionaryEntry` enumeration
9. PSCustomObject / PSObject — reflection: enumerate `Properties` collection, read `Name` and `Value`
10. IList — JSON array via indexed access
11. IEnumerable — JSON array via `foreach`
12. Fallback — `ToString()`

The Entity fast path writes all scalar properties (`Name`, `CN`, `Type`, `Status`, `Location`, `Owner`, `Quantity`, `FilePath`, `NerthusName`) and collection properties (`Aliases`, `Groups`, `Doors`, `Names`, `Coordinates`, `Contains`) with null-skip for collections. This avoids the reflection overhead of the PSObject path.

## Token Bucket Rate Limiter

`ApiMiddleware` uses a per-IP token bucket stored in `ConcurrentDictionary<string, TokenBucket>`. Each bucket has a configurable capacity (burst, default 200) and refill rate (per second, default 100).

Algorithm: on each request, refill tokens based on elapsed time since last refill (`elapsed * refillRate`, capped at capacity), then try to consume one token. If `tokens < 1.0`, the request is rejected with HTTP 429 and a `Retry-After: 1` header.

Stale eviction: buckets that have not been accessed for 10 minutes are removed on the next access attempt. This prevents memory growth from scanning or one-off clients.

Disabled when `RateLimitPerSecond <= 0`.

## SSE Event System

The SSE endpoint (`/events`) registers the client's `HttpListenerResponse` with `ApiSseManager`. The response is kept open with `SendChunked = true`, `Content-Type: text/event-stream`, and `Cache-Control: no-cache`.

Events are broadcast by plugin hooks registered in `plugin.psd1`: `Write-EntityFile` (AfterWrite), `New-Entity` (AfterCreate), `New-PlayerCharacter` (AfterCreate), `Remove-Entity` (AfterWrite), `Set-CurrencyEntity` (AfterWrite), and `New-Player` (AfterCreate). The hook handler `Invoke-ApiEventBroadcast` builds an event data dictionary and calls `ApiSseManager.Broadcast(eventType, data)`.

Event types: `entity:write`, `entity:create`, `entity:delete`, `character:create`, `currency:write`, `player:create`. Each event includes entity name, type, path, and a UTC timestamp.

Dead clients are detected during broadcast (failed `OutputStream.Write`) and removed from the client dictionary. The 30-second heartbeat timer sends `: keepalive\n\n` SSE comments to proactively detect stale connections.

## RSQL Query Layer

Filter syntax: `?filter=field==value;field!=value,field=gt=value`

Semicolons split into AND groups. Commas split within a group into OR conditions. All groups must match (AND). Within a group, any condition matches (OR).

Operators: `==` (eq), `!=` (neq), `=gt=`, `=ge=`, `=lt=`, `=le=`, `=in=(a,b,c)`, `=out=(a,b)`, `=like=` (wildcard `*`/`?`).

All string comparisons use `OrdinalIgnoreCase`. The `=like=` operator converts wildcards to regex (`*` → `.*`, `?` → `.`).

Filter alias resolution: when the filter field has a known category mapping (type, status, season, denomination, format, source, directive, ownerType), the value is resolved through `ApiNameDictionary.ResolveCanonical` before comparison. This allows `?filter=type==item` to match entities with `Type = "Przedmiot"`.

Sort: `?sort=-date,name` — comma-separated fields, `-` prefix for descending, `+` or no prefix for ascending.

Fields: `?fields=name,type,status` — sparse fieldsets. Omit to return all properties.

Pagination: `?page[size]=50&page[after]=<cursor>` — cursor-based. Default page size 50, max 500. Cursor is base64-encoded value of the last item's cursor field (default: `name`). Response includes `hasMore` and `nextCursor`.

## ApiNameDictionary Design

The dictionary maps 9 categories of Polish domain terms to English API labels:

- Entity types (7): NPC↔npc, Gracz↔player, Postac↔character, Grupa↔group, Lokacja↔location, Mapa↔map, Przedmiot↔item
- Statuses (3): Aktywny↔active, Nieaktywny↔inactive, Usuniety↔deleted
- Tags (14): lokacja↔location, drzwi↔doors, typ↔type, nalezy_do↔owner, etc.
- Seasons (4): wiosna↔spring, lato↔summer, jesien↔autumn, zima↔winter
- Denominations (3): Korony Elanckie↔gold, Talary Hironskie↔silver, Kogi Skeltvorskie↔copper
- Session formats (4): Gen1↔legacy, Gen2↔italic-location, Gen3↔pu-prefix, Gen4↔tagged
- Participation sources (5): FilePath↔filesystem, PU↔skillPoints, Changes↔entityChanges, Transfer↔transfer, Intel↔intelligence
- Intel directives (3): Direct↔direct, Grupa↔group, Lokacja↔location
- Owner types (3): Physical↔physical, Virtual↔virtual, Unknown↔unknown

Two directions: `ResolveCanonical(category, value)` accepts either canonical or label and returns canonical (for filter resolution). `GetLabel(category, canonical)` returns the English label (for response enrichment with `?labels=true`). `GetSchema()` returns the complete dictionary for the `/schema` discovery endpoint.

All dictionaries are `static readonly` — zero allocation, thread-safe by construction.

## Plugin Structure

```
plugins/robot-api/
+-- plugin.psd1                      # Manifest, config schema, hooks, menu items
+-- public/
|   +-- Start-RobotApi.ps1           # Init C# engine + PS worker pool
|   +-- Stop-RobotApi.ps1            # Graceful shutdown
|   +-- Get-RobotApiStatus.ps1       # Status snapshot
|   +-- New-RobotApiToken.ps1        # Create scoped API token
|   +-- Remove-RobotApiToken.ps1     # Delete token by name
|   +-- Get-RobotApiToken.ps1        # List tokens (no raw values)
+-- private/
|   +-- api-routes.ps1               # Route registration (static + dynamic)
|   +-- api-worker.ps1               # RunspacePool worker threads
|   +-- api-handlers-read.ps1        # 28 read handlers
|   +-- api-handlers-write.ps1       # 9 write handlers
|   +-- api-handlers-auth.ps1        # Auth token API handlers
|   +-- api-handlers-events.ps1      # SSE broadcast hook handler
|   +-- api-token-helpers.ps1        # Token file I/O and generation helpers
+-- cli/
|   +-- cli-wf-robot-api.ps1         # CLI workflow functions (start/stop/status)
+-- tests/
    +-- api-router.Tests.ps1
    +-- api-middleware.Tests.ps1
    +-- api-query.Tests.ps1
    +-- api-dictionary.Tests.ps1
    +-- api-server.Tests.ps1
    +-- api-handlers.Tests.ps1
    +-- api-worker.Tests.ps1
    +-- api-token-helpers.Tests.ps1
    +-- api-token-management.Tests.ps1
```

## Configuration

Plugin config (`plugin.psd1`) with environment variable overrides:

| Key | Default | Env Var | Purpose |
|---|---|---|---|
| `ListenPort` | 8642 | `ROBOT_API_PORT` | HTTP listening port |
| `ListenAddress` | localhost | `ROBOT_API_LISTEN` | Bind address (localhost or * for all interfaces) |
| `AuthToken` | null | `ROBOT_API_TOKEN` | Bearer token (null = no auth) |
| `CorsOrigin` | null | `ROBOT_API_CORS` | Allowed CORS origin (* = all, null = disabled) |
| `ReadOnly` | false | `ROBOT_API_READONLY` | Disable write endpoints |
| `WorkerCount` | 8 | `ROBOT_API_WORKERS` | Parallel PS runspaces |
| `RateLimitPerSecond` | 100 | `ROBOT_API_RATE_LIMIT` | Max requests per second per IP (0 = unlimited) |
| `MaxRequestBody` | 65536 | — | Maximum request body size in bytes |

## Testing

Test files: `api-router.Tests.ps1` (11 tests), `api-middleware.Tests.ps1` (9 tests), `api-query.Tests.ps1` (37 tests), `api-dictionary.Tests.ps1` (28 tests), `api-server.Tests.ps1` (server lifecycle, concurrent requests, rate limit, shutdown), `api-handlers.Tests.ps1` (per-handler tests with mock ApiContext), `api-worker.Tests.ps1` (worker pool lifecycle, concurrent processing, cache version propagation)

All tests use the `PSTypeName` guard pattern to skip if C# types are not compiled.

## Related Documents

- [PLUGINS.md](PLUGINS.md) — Plugin system mechanics, manifest schema, hook registry
- [ENTITIES.md](ENTITIES.md) — Entity data model consumed by API handlers
- [SESSIONS.md](SESSIONS.md) — Session data consumed by session-related endpoints
- [SESSION-GRAPH.md](SESSION-GRAPH.md) — Session graph data for participation endpoints
- [ECONOMY.md](ECONOMY.md) — Economic analysis behind /economy endpoints
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) — Name resolution pipeline behind /resolve endpoint
- [CLI.md](CLI.md) — CLI framework for workflow menu items

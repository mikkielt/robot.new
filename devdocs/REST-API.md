# REST API - Technical Reference

## Scope

The REST API subsystem comprises the compiled C# server engine (`lib/Api*.cs`), the plugin shell (`plugins/robot-api/`), the RunspacePool worker bridge, the RSQL query layer, the help registry, the fingerprint-based response cache, the endpoint reference, and the request/response protocol.

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
        +--------+-------+------------------+
        |        |       |                  |
   Static    Cache   Dynamic (PS)        SSE
   (C#)      HIT    BlockingCollection   ApiSseManager
   /health   ETag   <ApiRequest>         ConcurrentDictionary
   /routes   304    enqueue              broadcast
   /metrics  /help       |
   /schema          RunspacePool (N=4-16)
                    Each: Import-Module robot
                    Dequeue → Invoke → Result
                    Set TaskCompletionSource
                         |
                    ApiSerializer (C#)
                    Utf8JsonWriter → OutputStream
                         |
                    ApiResponseCache (C#)
                    Sidecar write on MISS
```

The server uses a hybrid architecture: a compiled C# engine handles HTTP I/O, routing, middleware, serialization, and response caching, while PowerShell RunspacePool workers execute the business logic handlers. Static routes (`/health`, `/routes`, `/metrics`, `/schema`, `/help`) respond entirely in C# without touching the worker pool. Cacheable GET routes check sidecar files before enqueueing to the worker pool: an ETag match returns 304, a fingerprint-valid sidecar streams pre-serialized JSON directly, and only a cache MISS falls through to PowerShell.

## Endpoint Reference

Base URL: `http://<address>:<port>/api/` (default `http://localhost:8642/api/`). All paths below are relative to this prefix.

System endpoints respond entirely in C# without touching the worker pool:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/health` | Static (C#) | Server health (status, uptime, request count) |
| GET | `/routes` | Static (C#) | Registered route list |
| GET | `/metrics` | Static (C#) | Request count, queue depth, SSE clients, route count |
| GET | `/schema` | Static (C#) | Name dictionary — all valid enum values with Polish/English mappings |
| GET | `/help` | Static (C#) | List available help components |
| GET | `/help/:component` | Static (C#) | Component help with field descriptions (`?lang=pl\|en`, `?include=description,format`) |
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
| GET | `/players/:name/pu-preview` | `Invoke-ApiGetCharacterPuPreview` | Starting-PU preview for a new character on this player |
| GET | `/players/:name/characters/:character` | `Invoke-ApiGetCharacter` | Single character with merged temporal state (`?includeState`, `?activeOn`, `?includeDeleted`) |
| POST | `/players` | `Invoke-ApiCreatePlayer` | Create player |
| PUT | `/players/:name` | `Invoke-ApiUpdatePlayer` | Update MargonemID, PRF webhook, triggers, aliases, status (omitted fields preserved) |
| POST | `/players/:name/characters` | `Invoke-ApiCreateCharacter` | Create player character |
| PUT | `/players/:name/characters/:character` | `Invoke-ApiUpdateCharacter` | Update PU, reputation, profile, status (PU fields: omitted or null preserves existing) |
| DELETE | `/players/:name/characters/:character` | `Invoke-ApiDeleteCharacter` | Soft-delete character (`?validFrom=YYYY-MM`) |

Location endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/locations` | `Invoke-ApiGetLocationList` | Enriched location list with filters |
| GET | `/locations/:name` | `Invoke-ApiGetLocation` | Single location with children and doors |
| GET | `/locations/:name/contents` | `Invoke-ApiGetLocationContents` | Entities at this location |
| POST | `/locations` | `Invoke-ApiCreateLocation` | Create location with domain validation |
| PUT | `/locations/:name` | `Invoke-ApiUpdateLocation` | Update location (parent, doors, coordinates) |
| DELETE | `/locations/:name` | `Invoke-ApiDeleteLocation` | Soft-delete location |

Map endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/maps` | `Invoke-ApiGetMaps` | List all Mapa entities |
| POST | `/maps` | `Invoke-ApiCreateMap` | Create map entity |
| PUT | `/maps/:name` | `Invoke-ApiUpdateMap` | Update map (slug, parent, url, doors, tags) |

Session endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/sessions` | `Invoke-ApiGetSessions` | List sessions |
| POST | `/sessions` | `Invoke-ApiCreateSession` | Create session (single or batch) |
| PUT | `/sessions` | `Invoke-ApiUpdateSession` | Update existing session identified by body `{date, file}` (metadata arrays are full-replace; Gen2/Gen3 → Gen4 requires `upgradeFormat=true`) |
| GET | `/session-graph/entity/:name` | `Invoke-ApiGetEntityProfile` | Participation profile |
| GET | `/session-graph/compare` | `Invoke-ApiCompareParticipation` | Overlap analysis — `?entities=A,B,C` accepts N entities (comma-split), returns full overlap matrix |
| GET | `/session-graph/leaderboard` | `Invoke-ApiGetLeaderboard` | Top entities by session count |
| GET | `/session-graph/narrator/:name` | `Invoke-ApiGetNarratorProfile` | Narrator session profile: count, date range, participant breakdown, average party size (`?minDate`, `?maxDate`, `?minTier`) |

Currency and economy endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/currency` | `Invoke-ApiGetCurrency` | Currency holdings |
| GET | `/economy/snapshot` | `Invoke-ApiGetEconomicSnapshot` | Supply, Gini, top holders |
| GET | `/economy/timeline` | `Invoke-ApiGetEconomicTimeline` | Monthly trends |
| GET | `/economy/materialization` | `Invoke-ApiGetMaterializationReport` | Physical/virtual currency split, per-player holdings, orphaned funds (`?activeOn`) |
| GET | `/transactions` | `Invoke-ApiGetTransactions` | Transaction ledger |
| POST | `/currency` | `Invoke-ApiCreateCurrency` | Create holding |
| PUT | `/currency/:name` | `Invoke-ApiUpdateCurrency` | Update amount |
| DELETE | `/currency/:name` | `Invoke-ApiDeleteCurrency` | Soft-delete currency entity (attaches `warning` field when balance is non-zero) |

Items endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/items` | `Invoke-ApiGetItems` | List Przedmiot entities with owner (Physical/Virtual/Unknown), location, quantity, currency classification (`?owner`, `?location`, `?name`, `?includeInactive`, `?includeDeleted`, `?includeCurrency`, `?activeOn`) |
| GET | `/items/:name` | `Invoke-ApiGetItem` | Single Przedmiot entity (exact name match, case-insensitive); returns 404 when no exact match |

PU endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/pu/voting-eligibility` | `Invoke-ApiGetVotingEligibility` | Players above PU threshold over a recent window (`?months` default 6, `?minPU` default 3.0) — pure computation off `pu-sessions.json` |

Name resolution, validation, report, and workflow endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/resolve/:name` | `Invoke-ApiResolveName` | Resolve name to entity or player (`?ownerType=Player\|NPC\|Grupa\|Lokacja`, `?topN=1-20`, `?noFuzzy=true`) |
| POST | `/resolve/batch` | `Invoke-ApiResolveBatch` | Batch resolve names with scope-gated enrichment |
| GET | `/name-index/lookup/:token` | `Invoke-ApiGetNameIndexLookup` | Raw name-index entry (Stage 1 exact, optional Stage 2 stem candidates via `?includeStems=true`) — diagnostic, does not run Stage 3 fuzzy |
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
| POST | `/workflow/name-index` | `Invoke-ApiRebuildNameIndex` | Force-rebuild the cached name index (clears parse caches, returns build stats) |
| POST | `/workflow/log-fetch` | `Invoke-ApiRunLogFetch` | Fetch missing session logs sequentially with retries and `.failed` markers (rate-limited 5/min/IP); body honors `minDate`, `maxDate`, `delayMs`, `maxRetries`, `retryDelayMs`, `retryFailed`, `logDirectory` |
| POST | `/workflow/pu-assignment` | `Invoke-ApiRunPuAssignment` | Run monthly PU assignment (rate-limited 1/min/IP); fail-early on unresolved character names; opt-in flags `updatePlayerCharacters`, `sendToDiscord`, `appendToLog`, `reconcileCurrency` |

Analytics endpoints (PU-centric and cross-cutting aggregations over a date window). All accept the standard `filter`/`sort`/`fields`/`page[size]`/`page[after]` query envelope via `ApiQueryParser`. Most are cacheable with `entity`/`session` domain fingerprints; see the Response Cache table.

| Method | Path | Handler | Description |
|---|---|---|---|
| GET | `/analytics/pu/by-character` | `Invoke-ApiAnalyticsPuByCharacter` | PU aggregation per character over a date window |
| GET | `/analytics/pu/by-location` | `Invoke-ApiAnalyticsPuByLocation` | PU aggregation per location over a date window |
| GET | `/analytics/pu/timeline` | `Invoke-ApiAnalyticsPuTimeline` | Monthly/weekly PU velocity per character |
| GET | `/analytics/pu/by-narrator` | `Invoke-ApiAnalyticsPuByNarrator` | PU statistics per narrator (count, sum, avg) |
| GET | `/analytics/co-engagement` | `Invoke-ApiAnalyticsCoEngagement` | Top character pairs by session co-occurrence |
| GET | `/analytics/character-territory/:name` | `Invoke-ApiAnalyticsCharacterTerritory` | Character location footprint + adjacency density |
| GET | `/analytics/entity-lifecycle` | `Invoke-ApiAnalyticsEntityLifecycle` | Status/group/owner/location transitions over time |
| GET | `/analytics/location-graph/metrics` | `Invoke-ApiAnalyticsLocationGraphMetrics` | Graph metrics: degree, components, choke points |
| GET | `/analytics/logs/speaker-leaderboard` | `Invoke-ApiAnalyticsLogsSpeakerLeaderboard` | Chat presence leaderboard from parsed logs |
| GET | `/analytics/logs/channel-mix` | `Invoke-ApiAnalyticsLogsChannelMix` | ChatLog channel breakdown (secrecy density) |
| GET | `/analytics/logs/coverage` | `Invoke-ApiAnalyticsLogsCoverage` | Log fetch coverage / health stats |
| GET | `/analytics/resolution/quality` | `Invoke-ApiAnalyticsResolutionQuality` | Name index health: ambiguity, stem collisions, stage distribution |
| GET | `/analytics/integrity/trends` | `Invoke-ApiAnalyticsIntegrityTrends` | Integrity check trends over time |
| GET | `/analytics/metadata/coverage` | `Invoke-ApiAnalyticsMetadataCoverage` | Metadata coverage report (IsExterior, slugs, etc.) |

Parse, file, and dashboard endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| POST | `/parse/log` | `Invoke-ApiParseLog` | Parse raw log text into structured data |
| POST | `/logs/fetch` | `Invoke-ApiFetchLogContent` | Fetch raw log content by URLs (disk cache then HTTP) |
| POST | `/logs/parse` | `Invoke-ApiParseLogEnriched` | Combined fetch + parse + resolve (urls[] or content) — returns Speakers/Channels/LocationSegments/Mentions in one call |
| POST | `/parse/session-preview` | `Invoke-ApiSessionPreview` | Preview session markdown with name resolution |
| GET | `/files` | `Invoke-ApiGetFiles` | List .md file paths for autocomplete |
| GET | `/files/tree` | `Invoke-ApiGetFilesTree` | Directory tree of .md files for path navigation |
| GET | `/dashboard` | `Invoke-ApiGetDashboard` | Web dashboard SPA (text/html) |

Auth management endpoints:

| Method | Path | Handler | Description |
|---|---|---|---|
| POST | `/auth/token` | `Invoke-ApiCreateToken` | Create a new scoped token |
| DELETE | `/auth/token/:name` | `Invoke-ApiDeleteToken` | Delete a token by name |
| GET | `/auth/status` | `Invoke-ApiGetAuthStatus` | List tokens and count |
| GET | `/auth/whoami` | `Invoke-ApiGetWhoami` | Current token identity and scopes |

## Authentication & Authorization

The API supports three auth modes, resolved in priority order:

1. Multi-token store (preferred): tokens stored in `.robot.local/res/api-tokens.psd1`, each with a name and scope list. Created via `New-RobotApiToken` or `POST /auth/token`. The token file must be gitignored — startup fails with a security error otherwise.
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
| _(none)_ | Static: /health, /routes, /metrics, /schema, /help, /help/:component; SSE: /events; GET /dashboard, /auth/whoami |
| `entity:read` | GET /entities, /entities/:name, /entity-state, /entities/:name/history, /entities/:name/delta, /resolve/:name, /name-index/lookup/:token, /currency, /economy/snapshot, /economy/timeline, /economy/materialization, /transactions, /items, /items/:name, /locations, /locations/:name, /locations/:name/contents, /maps, /analytics/location-graph/metrics, /analytics/resolution/quality, /analytics/metadata/coverage; POST /resolve/batch |
| `entity:write` | POST /entities, PUT /entities/:name, DELETE /entities/:name, POST /currency, PUT /currency/:name, DELETE /currency/:name, POST /locations, PUT /locations/:name, DELETE /locations/:name, POST /maps, PUT /maps/:name |
| `player:read` | GET /players, /players/:name, /players/:name/characters/:character, /players/:name/pu-preview |
| `player:write` | POST /players, PUT /players/:name, POST /players/:name/characters, PUT /players/:name/characters/:character, DELETE /players/:name/characters/:character |
| `session:read` | GET /sessions, /session-graph/entity/:name, /session-graph/compare, /session-graph/leaderboard, /session-graph/narrator/:name, /pu/voting-eligibility, /files, /files/tree, /analytics/pu/by-character, /analytics/pu/by-location, /analytics/pu/timeline, /analytics/pu/by-narrator, /analytics/co-engagement, /analytics/character-territory/:name, /analytics/entity-lifecycle, /analytics/logs/speaker-leaderboard, /analytics/logs/channel-mix, /analytics/logs/coverage; POST /parse/log, /logs/fetch, /logs/parse, /parse/session-preview |
| `session:write` | POST /sessions, PUT /sessions |
| `admin:read` | GET /validate/\*, /reports/\*, /analytics/integrity/trends |
| `admin:write` | POST /workflow/\* (includes /workflow/log-fetch and /workflow/pu-assignment, both per-IP rate-limited) |
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

CORS: when `CorsOrigin` is set, `ApiMiddleware` injects `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`, and `Access-Control-Expose-Headers` (`ETag`, `X-Cache`) on every response. Preflight `OPTIONS` requests receive HTTP 204 with the same headers. When unset, no CORS headers are sent.

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

Conditional requests: cacheable endpoints return `ETag` and `X-Cache` (`HIT` or `MISS`) headers. Clients may send `If-None-Match` with a previously received ETag to receive HTTP 304 (Not Modified) when the underlying data has not changed.

Non-success responses:

| HTTP Status | Condition |
|---|---|
| 304 | Not Modified — ETag matches current fingerprint (conditional GET, no body) |
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

# Batch resolve names with temporal context
curl -X POST http://localhost:8642/api/resolve/batch \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"names": ["Solmyr", "Ithan", "Zoltan"], "activeOn": "2025-06-15"}'
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

## Batch Name Resolution (POST /resolve/batch)

`Invoke-ApiResolveBatch` resolves up to 100 names in a single request. It uses a shared `Resolve-Name` cache across all lookups in the batch, avoiding repeated name index rebuilds.

Request body:

| Field | Type | Required | Description |
|---|---|---|---|
| `names` | string[] | Yes | 1-100 name queries to resolve |
| `activeOn` | string (ISO date) | No | Temporal filter — restricts alias matching to aliases valid on this date |

When `activeOn` is provided, the handler builds a date-filtered name index via `Get-Entity -ActiveOn` so that expired aliases do not match.

Resolution uses a multi-pass strategy per name. The first pass calls `Resolve-Name -NoFuzzy` (exact and declension matching only, stages 1-2). On miss, multi-word queries attempt per-word stemming via `Get-DeclensionStem` on each word independently — this handles inflected multi-word names (e.g. "Alabastrowego Hotelu" stems to "Alabastrow Hotel") that whole-query stemming would miss. If per-word stemming produces a match, it counts as stage 2. Otherwise, the final pass calls `Resolve-Name -TopN 5` with full fuzzy matching (stage 3). The `matchStage` field in the response indicates which pass produced the result: 2 for exact/declension, 3 for fuzzy, 0 for unresolved.

Response fields are scope-gated. The base response (requiring `entity:read`) always includes:

| Field | Type | Description |
|---|---|---|
| `name` | string | Canonical entity name |
| `type` | string | Entity type (Polish canonical) |
| `status` | string | Entity status (defaults to `Aktywny` if absent) |
| `aliases` | string[] | Known aliases excluding the canonical name |
| `cn` | string | Canonical name path (Type/Name); for player queries matched to a character, returns the character's CN |
| `matchStage` | int | Resolution stage: 0 = unresolved, 2 = exact/declension, 3 = fuzzy |
| `filePath` | string | Source file path (entity FilePath or matched character Path); null when unavailable |
| `candidates` | object[] | Fuzzy match candidates (only present when matchStage = 3); each has `name` and `distance` |

With `session:read` scope, the response adds session graph enrichment:

| Field | Type | Description |
|---|---|---|
| `sessions` | int | Total session participation count |
| `lastActive` | datetime | Most recent session date |
| `tiers` | object | Participation counts by tier (`0`, `1`, `2`) |

With `admin:read` scope, the response adds PU and co-participation data:

| Field | Type | Description |
|---|---|---|
| `puWeight` | decimal | Cumulative PU weight (rounded to 2 decimal places) |
| `coParticipants` | string[] | Top 3 most frequent co-participants by session overlap |

Unresolved names return `null` in the results dictionary. Error responses:

| HTTP Status | Condition |
|---|---|
| 400 | Missing `names` array, empty array, or more than 100 entries |

Response envelope:

```json
{
    "results": {
        "Solmyr": {
            "name": "Solmyr",
            "type": "NPC",
            "status": "Aktywny",
            "aliases": ["Sol"],
            "cn": "NPC/Solmyr",
            "matchStage": 2,
            "filePath": "entities.md",
            "sessions": 15,
            "lastActive": "2025-06-10T00:00:00",
            "tiers": { "0": 3, "1": 7, "2": 5 }
        },
        "Nieznany": null
    }
}
```

## C# Class Responsibilities

`Robot.ApiServer` (`lib/ApiServer.cs`) — Async HTTP listener backed by `System.Net.HttpListener`. Manages the accept loop (`GetContextAsync` on the .NET ThreadPool), dispatches each request to `Task.Run` for parallel handling, and bridges to PowerShell via a `BlockingCollection<ApiRequest>` with configurable bounded capacity (default 512). Exposes `CacheVersion` as a static `Interlocked` counter for cross-runspace cache invalidation. Static fields `ResponseCache` and `RepoRoot` are set once at startup by `Start-RobotApi` and shared across all runspaces for sidecar file caching. The request pipeline intercepts cacheable GET routes (those with a `CacheKey`) before enqueueing: ETag match returns 304, sidecar HIT streams pre-serialized JSON directly, and only MISS falls through to the worker pool. On MISS with a 200 response, the serialized bytes are persisted as a sidecar via `ApiResponseCache.Save`. Static handlers now support returning error status codes via an `IDictionary` with a `StatusCode` key (used by `/help/:component` for 404). Provides `GetStatus()` for the status endpoint.

`Robot.ApiRouter` (`lib/ApiRouter.cs`) — Compiled-regex URL route matcher. Routes are registered at startup and compiled once via `RegexOptions.Compiled`. Supports `:param` path segments that become named regex groups. Static routes (no params) use `Dictionary<string, ApiRoute>` for O(1) lookup before falling through to the regex list. Two handler types: `StaticHandler` (C# `Func<RouteMatch, ApiServer, object>`) and `HandlerName` (string identifying a PS function). `AddCacheableRoute` registers a dynamic PS route with sidecar cache metadata (`CacheKey` and `CacheDomains`) on the `ApiRoute` object. `RouteMatch` now carries a `QueryParams` dictionary populated by `ApiServer.HandleRequestAsync` before dispatch, making query parameters available to both static and dynamic handlers.

`Robot.ApiMiddleware` (`lib/ApiMiddleware.cs`) — Authentication (Bearer token with constant-time comparison via XOR accumulator), CORS header injection, per-IP token bucket rate limiting with `ConcurrentDictionary`, body size enforcement, and read-only mode flag. All checks execute in compiled C# with zero PowerShell overhead.

`Robot.ApiSerializer` (`lib/ApiSerializer.cs`) — Direct-to-stream JSON serialization via `System.Text.Json.Utf8JsonWriter`. Type dispatch chain: `Entity` (typed property access, no reflection), `IDictionary` (sorted keys), PSCustomObject/PSObject (reflection via `Properties` enumeration with `BaseObject` unwrap for wrapped primitives), `IList`, primitives (`string`, `int`, `long`, `double`, `decimal`, `bool`, `DateTime`), `IEnumerable`, public-property+public-field reflection for plain C# objects (covers property-backed types like `Robot.SessionPU` and field-backed types like `Robot.LogParser.LogLine` and `Robot.LogParser.LocationSegment`; properties take precedence on name collision), and `ToString()` fallback. MaxDepth guard (12) prevents stack overflow on circular references. `SerializeToBytes` serializes any object to a UTF-8 byte array using the same dispatch logic as `WriteObject`, used by the response cache to capture sidecar content with byte-level equality between cached and fresh responses.

`Robot.ApiSseManager` (`lib/ApiSseManager.cs`) — Thread-safe Server-Sent Events manager using `ConcurrentDictionary<long, SseClient>` keyed by monotonic client ID. Broadcasts events as JSON via `Utf8JsonWriter`. Dead client detection during broadcast (failed writes remove the client). 30-second heartbeat timer sends `: keepalive` comments to detect stale connections.

`Robot.ApiQueryParser` (`lib/ApiQueryParser.cs`) — RSQL filter parser and JSON:API query parameter processor. Parses `filter` (`;` = AND groups, `,` = OR within group), `sort` (`-` prefix = descending), `fields` (sparse fieldsets), `page[size]` / `page[after]` (cursor-based pagination). Two helper families: `Entity`-specific (`GetEntityField`, `FilterEntities`, `SortEntities`, `PaginateEntities`) for `/entities` and `Robot.Entity[]` consumers, and **generic** (`GetObjectField`, `FilterList`, `SortList`, `PaginateList`) for arbitrary `object[]` lists. The generic accessor `GetObjectField` reflects over `IDictionary` keys, `PSObject.Properties` (without an SMA compile-time dependency), and plain CLR public instance properties — letting `Invoke-ApiObjectListQuery` apply the standard query envelope to sessions, players, currency holdings, transactions, reports, and analytics outputs without per-handler boilerplate. Filter alias resolution maps known field categories (`type`, `status`, `season`, `format`, `source`, `directive`, `ownerType`, `denomination`, `denomShort`, `tier`) through `ApiNameDictionary.ResolveCanonical` so English labels in queries match Polish canonical values in data. Stateless methods — safe for concurrent RunspacePool use. Data types: `FilterGroup` (AND-joined OR-conditions), `FilterCondition` (field/operator/value/values), `SortField` (field + descending), `PageParams` (Size 1-500, AfterCursor), `PageResult<T>` (Items, TotalCount, HasMore, NextCursor).

`Robot.ApiNameDictionary` (`lib/ApiNameDictionary.cs`) — Static, thread-safe bidirectional mapping between canonical Polish domain terms and English API labels. Covers entity types (7), statuses (3), tags (14), seasons (4), denominations (3+3 short forms), session formats (4), participation sources (5), intel directives (3), and owner types (3). All lookups O(1) via `Dictionary<string, string>` with `OrdinalIgnoreCase`. Zero allocation on the hot path.

`Robot.ApiHelpRegistry` (`lib/ApiHelpRegistry.cs`) — Static, thread-safe help registry that loads sidecar `*.help.json` files from the plugin's `help/` directory. Called once by `Start-RobotApi` via `Load(directoryPath)`. Each sidecar file declares a `component` name and contains bilingual (pl/en) endpoint documentation with descriptions, query parameters, and body fields. Three structural variants are supported: API components (with `endpoints` array), the editor component (with `zones` object), and the CLI component (with `categories` object). Query API: `GetComponents()` returns sorted component names, `GetHelp(component, lang, include)` returns a filtered help object with optional language selection (`pl` or `en`) and field-level include filtering (comma-separated property names). Returns `null` for unknown components, enabling the `/help/:component` static route to return 404.

`Robot.ApiResponseCache` (`lib/ApiResponseCache.cs`) — Fingerprint-based sidecar file cache for pre-serialized JSON responses. Stores cached responses as paired `.json` + `.meta` files under `.robot.local/.cache/api/`. Three independent fingerprint domains track data lifecycles: **entity** (entities.md, overflow `*-NNN-ent.md`, Gracze.md), **session** (all `.md` files under `Sesje/`), and **graph** (`_index.json` + `_meta.json` in the session-graph persistence directory). Fingerprints are computed from `LastWriteTimeUtc.Ticks` of the relevant files. The cache is accessed via the static `ApiServer.ResponseCache` field, shared across all runspaces. `TryLoad` validates sidecar fingerprints against current state and returns cached bytes on match. `Save` writes response bytes via a temp-file-then-rename pattern for atomic writes. `InvalidateDomain` scans all `.meta` files and deletes sidecars that depend on the specified domain. `Clear` removes the entire cache directory. Thread safety: file I/O is not locked — concurrent writes to the same sidecar may race, but the worst case is a redundant recompute (no corruption). Fingerprint state is protected by a lock for cross-thread consistency.

## Async Request Flow

1. `HttpListener.GetContextAsync()` accepts a connection on the .NET thread pool
2. `Task.Run` dispatches the request for parallel handling (does not block the accept loop)
3. Middleware chain executes in C#: CORS preflight check, Bearer auth verification, per-IP rate limit check
4. Router matches the URL against the compiled regex table and extracts path params; query params are parsed into `RouteMatch.QueryParams`
5. Static routes return directly from C# — the PS worker pool is never involved
6. SSE requests register the response stream with `ApiSseManager` and keep the connection open
7. **Cache intercept** (cacheable GET routes only, no query string): refresh domain fingerprints, check `If-None-Match` for 304, check sidecar file for HIT — both bypass the worker pool entirely
8. Dynamic routes read the request body (with size check), create an `ApiRequest` with a `TaskCompletionSource<ApiResponse>`, and enqueue it to the `BlockingCollection`
9. If the queue is full, HTTP 503 is returned immediately (backpressure)
10. The HTTP thread awaits `TaskCompletionSource.Task` with a 60-second timeout (HTTP 504 on expiry)
11. A PowerShell worker dequeues the request, invokes the handler, and calls `SetResult` to unblock the HTTP thread
12. `ApiSerializer` writes the response directly to `HttpListenerResponse.OutputStream`
13. **Sidecar write** (cacheable route MISS with 200 status): serialize response via `SerializeToBytes`, persist sidecar, and add `ETag` + `X-Cache: MISS` headers

## BlockingCollection / TaskCompletionSource Bridge

The C# HTTP thread and the PowerShell worker thread communicate through two mechanisms:

`BlockingCollection<ApiRequest>` — bounded FIFO queue (default capacity 512). The HTTP thread calls `TryAdd` with a 5-second timeout. Worker threads call `Take` which blocks until a request is available or `CompleteAdding` is called during shutdown. This provides backpressure: when all workers are busy and the queue fills, new requests get HTTP 503 instead of unbounded memory growth.

`TaskCompletionSource<ApiResponse>` — per-request completion signal. Created with `RunContinuationsAsynchronously` to prevent worker thread hijacking. The HTTP thread awaits this task (with timeout). The PS worker calls `SetResult` after handler invocation. On handler error, the worker calls `SetResult` with a 500-status `ApiResponse` containing the error message.

## RunspacePool Worker Lifecycle

Worker initialization (`Start-ApiWorkerPool`):

1. For each of N workers (configurable, default 8): create an isolated `System.Management.Automation.Runspaces.Runspace`
2. Open the runspace and import the Robot module via `AddScript('Import-Module ...')`
3. Dot-source handler files: `api-handlers-read.ps1`, `api-handlers-write.ps1`, `api-handlers-analytics.ps1`, `api-handlers-auth.ps1`, `api-handlers-dashboard.ps1`, `api-token-helpers.ps1`
4. Each worker gets its own `PowerShell` instance bound to its runspace

Worker dequeue loop:

1. `$Queue.Take()` blocks until a request arrives (terminates via `InvalidOperationException` when `CompleteAdding` is called)
2. Check cache coherence: read shared `CacheVersion`, compare to local version, call `Clear-ParseCaches` on mismatch
3. Look up handler by name from `$HandlerMap`
4. Build `$ApiContext` hashtable with `PathParams`, `QueryParams`, `Body`, `Method`, `Path`, `TokenName`, `TokenScopes`
5. Parse JSON body if present
6. Invoke the handler directly: `& $HandlerName -ApiContext $Ctx`
7. Extract result hashtable with `StatusCode` and `Body`
8. For write methods (POST/PUT/DELETE): increment `CacheVersion` via `Interlocked.Increment`
9. Wrap in `ApiResponse` and call `ResponseSource.SetResult()`

Graceful shutdown (`Stop-ApiWorkerPool` + `Stop-RobotApi`):

1. Stop each worker's `PowerShell` instance (aborts the dequeue loop)
2. Dispose each `PowerShell` instance
3. Close and dispose each `Runspace`
4. Clear static `ApiServer.ResponseCache` and `ApiServer.RepoRoot` fields to release sidecar cache references

## Cache Coherence Protocol

The module uses in-memory parse caches (`$script:CachedEntities`, `$script:CachedSessions`, etc.) that are per-runspace. When a write handler modifies data, other runspaces must invalidate their stale caches.

`Robot.ApiServer.CacheVersion` is a `static long` accessed via `Interlocked.Read` and `Interlocked.Increment`. Each worker thread maintains a local version number. Before executing a read handler, the worker compares its local version against the shared version. On mismatch, it calls `Clear-ParseCaches` to force a re-parse on the next data access, then updates its local version. After executing a write handler, the worker increments the shared version.

This is an optimistic scheme: read-read sequences across workers share the same cache epoch without contention. Only writes (which are infrequent) force a global cache invalidation on the next read.

In addition to in-memory cache invalidation, write handlers call `Invoke-SidecarInvalidation -Domain <domain>` to purge any sidecar-cached HTTP responses that depend on the affected domain. This helper accesses the static `[Robot.ApiServer]::ResponseCache` field and calls `InvalidateDomain`, which scans `.meta` files to find and delete sidecars referencing that domain. The domain mapping is: entity mutations invalidate `entity`, session writes invalidate `session`, and graph rebuilds invalidate `graph`.

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
9. PSCustomObject / PSObject — unwrap `BaseObject` if it is a primitive (string, numeric, bool, DateTime), otherwise reflection: enumerate `Properties` collection, read `Name` and `Value`
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

## Response Cache

The API implements a two-tier caching strategy: in-memory parse caches per runspace (see Cache Coherence Protocol above) and fingerprint-based sidecar file caching for expensive GET endpoints.

Cacheable routes are registered via `AddCacheableRoute` with a `cacheKey` (sidecar filename stem) and `cacheDomains` (fingerprint domains the route depends on). The following routes are cacheable:

| Route | Cache Key | Domains |
|---|---|---|
| `GET /entity-state` | `entity-state` | entity, session |
| `GET /session-graph/leaderboard` | `leaderboard` | graph |
| `GET /session-graph/narrator/:name` | `narrator-profile` | session |
| `GET /economy/snapshot` | `economy-snapshot` | entity, session |
| `GET /economy/timeline` | `economy-timeline` | entity, session |
| `GET /economy/materialization` | `economy-materialization` | entity, session |
| `GET /items` | `items` | entity |
| `GET /reports/dormancy` | `dormancy` | entity, graph |
| `GET /reports/frequency` | `frequency` | session |
| `GET /reports/narrators` | `narrators` | session |
| `GET /reports/location-graph` | `location-graph` | entity, session |
| `GET /reports/pu-log` | `pu-log` | session |
| `GET /analytics/pu/by-character` | `analytics-pu-character` | session |
| `GET /analytics/pu/by-location` | `analytics-pu-location` | session |
| `GET /analytics/pu/by-narrator` | `analytics-pu-narrator` | session |
| `GET /analytics/co-engagement` | `analytics-co-engagement` | session |
| `GET /analytics/entity-lifecycle` | `analytics-entity-lifecycle` | entity, session |
| `GET /analytics/location-graph/metrics` | `analytics-location-graph-metrics` | entity, session |
| `GET /analytics/metadata/coverage` | `analytics-metadata-coverage` | entity |

Caching is only active for GET requests with no query string parameters (filtered or paginated requests always go through the worker pool).

Sidecar file format (stored under `.robot.local/.cache/api/`):
- `<cacheKey>.json` — pre-serialized JSON response bytes
- `<cacheKey>.meta` — line-delimited key=value pairs: `generatedAt=<ISO8601>` followed by `<domain>=<fingerprint>` for each dependency domain

Request flow for cacheable routes:
1. `RefreshFingerprints` recomputes all three domain fingerprints from file timestamps
2. `BuildETag` concatenates domain fingerprints into a deterministic string
3. If `If-None-Match` header matches the ETag, return **304 Not Modified**
4. If `TryLoad` finds a valid sidecar (all domain fingerprints match), stream cached JSON with `X-Cache: HIT` and `ETag` headers
5. On MISS, fall through to the worker pool; after a 200 response, `SerializeToBytes` captures the response and `Save` persists the sidecar with `X-Cache: MISS`

Invalidation: each write handler calls `Invoke-SidecarInvalidation -Domain <domain>` after a successful mutation. This calls `ApiResponseCache.InvalidateDomain`, which scans `.meta` files and deletes any sidecar that depends on the affected domain. `Clear-ParseCaches` can also call `ResponseCache.Clear()` to wipe the entire cache directory.

## Help Registry

The API exposes self-documenting endpoint help via the `ApiHelpRegistry` and two static routes.

Sidecar files: 20 `*.help.json` files in `plugins/robot-api/help/`, one per component (includes `items.help.json` and `pu.help.json` added with the corresponding endpoint families). Each file contains:
- `component` — component name (e.g. "entities", "sessions", "cli")
- Bilingual content blocks under `pl` and `en` keys
- Three structural variants: `endpoints` array (API components), `zones` object (editor), `categories` object (CLI)

API endpoint content includes: `method`, `path`, `handler`, `scope`, plus per-language `description`, `queryParams` (with name, type, required, description, format), and `bodyFields` (with name, type, required, description).

Load mechanism: `Start-RobotApi` calls `[Robot.ApiHelpRegistry]::Load($HelpDir)` once during startup. The registry parses all sidecar files into a `Dictionary<string, JsonElement>` keyed by component name. If the C# type is not compiled or the help directory is missing, a warning is emitted and the `/help` endpoints are not registered.

Routes:
- `GET /help` — returns `{ components: [...] }` with sorted component names (no auth required)
- `GET /help/:component` — returns filtered help for one component; supports `?lang=pl|en` (language filter) and `?include=description,format` (field-level filter). Returns 404 for unknown components via the static handler error protocol (`{ StatusCode: 404, Body: { error: "..." } }`)

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
|   +-- api-routes.ps1               # Route registration (static + dynamic + cacheable)
|   +-- api-worker.ps1               # RunspacePool worker threads
|   +-- api-handlers-read.ps1        # 47+ read handlers + Invoke-ApiObjectListQuery + Invoke-ApiParseLogEnriched
|   +-- api-handlers-write.ps1       # 22 write handlers + 1 cache invalidation helper
|   +-- api-handlers-analytics.ps1   # 14 analytics handlers (PU-centric + cross-cutting)
|   +-- api-handlers-auth.ps1        # Auth token API handlers (4 handlers)
|   +-- api-handlers-dashboard.ps1   # Dashboard SPA endpoint handler
|   +-- api-handlers-events.ps1      # SSE broadcast hook handler
|   +-- api-token-helpers.ps1        # Token file I/O and generation helpers
+-- help/                            # Sidecar help files (*.help.json) — 20 components
|   +-- entities.help.json           # (plus analytics, auth, cli, currency, economy, editor, items, pu, etc.)
+-- cli/
|   +-- cli-wf-robot-api.ps1         # CLI workflow functions (start/stop/status)
+-- tests/
    +-- api-router.Tests.ps1
    +-- api-middleware.Tests.ps1
    +-- api-query.Tests.ps1
    +-- api-dictionary.Tests.ps1
    +-- api-server.Tests.ps1
    +-- api-handlers.Tests.ps1
    +-- api-handlers-session.Tests.ps1
    +-- api-worker.Tests.ps1
    +-- api-token-helpers.Tests.ps1
    +-- api-token-management.Tests.ps1
    +-- api-help-registry.Tests.ps1
    +-- api-pagination-analytics.Tests.ps1
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

Test files: `api-router.Tests.ps1` (15 tests — route matching, static route O(1) lookup, RouteMatch QueryParams property), `api-middleware.Tests.ps1` (25 tests — auth, CORS, rate limiting, scope matching, read-only mode), `api-query.Tests.ps1` (37 tests), `api-dictionary.Tests.ps1` (28 tests), `api-server.Tests.ps1` (20 tests — server lifecycle, concurrent requests, rate limit, shutdown, cache version), `api-handlers.Tests.ps1` (per-handler tests with mock ApiContext — covers the entity, currency, player, character, session, items, materialization, narrator-profile, voting-eligibility, workflow log-fetch, workflow pu-assignment, name-resolution parameter-forwarding, and SSE broadcast handlers), `api-handlers-session.Tests.ps1` (session creation single and batch modes + `/parse/log` + `/logs/parse`), `api-worker.Tests.ps1` (10 tests — worker pool lifecycle, concurrent processing, cache version propagation), `api-token-helpers.Tests.ps1` (9 tests — token file I/O and generation), `api-token-management.Tests.ps1` (6 tests — New/Remove/Get-RobotApiToken), `api-help-registry.Tests.ps1` (17 tests — load/components, language filtering, include filtering, content validation across all 20 help components), `api-pagination-analytics.Tests.ps1` (30 tests — generic list query envelope, RSQL filter/sort/pagination on non-Entity collections, analytics handler smoke tests)

All tests use the `PSTypeName` guard pattern to skip if C# types are not compiled.

## Margonem Session Authentication

Browser add-ons running on a Player's machine can mint a short-lived Robot bearer token without an operator-issued credential.

Flow:
1. Add-on POSTs to `https://public-api.margonem.pl/account/validate` with the Player's cookies and a `token` postdata field. Margonem returns a signed JSON envelope `{ user_id, token, ts, validatedString, signatureBase64 }`.
2. Add-on forwards the JSON verbatim to Robot: `POST /api/auth/margonem` body: `{ "payload": "{...}" }`.
3. Robot reconstructs `validatedString` as `"{user_id}+{token}+{ts}"`, decodes the signature, and verifies against the cached RSA public key (algorithm: **RSA-SHA256, PKCS#1 v1.5 padding** — pinned in `MargonemValidator.cs`). The supplied `validatedString` field is IGNORED — only the components are trusted.
4. Robot enforces `abs(server_now - ts) <= MargonemFreshnessSeconds` (default 300 s) — defends against replay of stale payloads.
5. Robot resolves `user_id` to a Player by matching the `@margonemid` integer tag in `Gracze.md`. Missing tag → 404. Ambiguous → 409. Resolution is **status-agnostic** — soft-deleted players still resolve; revocation goes through `DELETE /auth/sessions/:player` or removal of the tag.
6. Robot mints a session bearer token (`rbs_` + 44-char base62), inserts it into the in-memory `ApiSessionTokenStore` with `ExpiresAt = now + MargonemSessionTtlSeconds` (default 4 h) and the configured `MargonemDefaultScopes`, and returns it.

When the session token expires or is rejected with `401` + header `WWW-Authenticate: Bearer error="invalid_token"`, the add-on SHOULD replay step 1. There is no separate refresh token — the Player's Margonem cookies are the long-lived credential.

Operator endpoints (scope `auth:manage`):
- `GET /auth/sessions` — list active sessions (no raw tokens)
- `DELETE /auth/sessions/:player` — forcibly invalidate every session for a player
- `POST /auth/margonem/refresh-key` — fetch the upstream PEM, validate, atomically swap on disk, hot-reload the cache
- `GET /auth/margonem/health` — local-key state + upstream reachability + clock-skew probe
- `POST /auth/margonem/verify` — cross-service: verify a Margonem payload without minting (returns identity only)
- `POST /auth/introspect` — RFC 7662 introspection: takes a Robot bearer, returns active + identity

Public discovery (no auth):
- `GET /auth/margonem/info` — PEM SHA-256 fingerprint, TTL, freshness window, endpoint list, token-format prefix (`rbs_`)

Per-route rate limits (per-IP, in addition to the global limiter):

| Route | Per minute |
|---|---|
| `POST /auth/margonem` | 10 |
| `POST /auth/margonem/refresh-key` | 2 |
| `GET /auth/margonem/health` | 6 |
| `POST /auth/margonem/verify` | 30 |
| `GET /auth/margonem/info` | 60 |

Public key management: the PEM lives at the path resolved from `MargonemPublicKeyFile` (default `.robot.local/.cache/margonem/signing-key.pem`), which inherits gitignore protection from the module's existing `**/.robot.local/.cache/` rule. Refresh by calling `POST /auth/margonem/refresh-key` (scope `auth:manage`) — the handler fetches the upstream PEM, validates it parses, atomically swaps the on-disk file, and hot-reloads the cache. The server NEVER fetches the key over the network on the request hot path; only the explicit refresh endpoint does.

Audit log: outcomes are appended as line-delimited JSON to `MargonemAuditLogFile` (default `.robot.local/.cache/margonem/audit.log`). Events: `mint-ok`, `mint-fail`, `verify-ok`, `verify-fail`, `introspect`, `refresh-key`, `sessions-invalidated`. The log NEVER contains the payload, the raw bearer, the signature, or the caller IP — IP collection is deliberately omitted.

## Restart Semantics & Persistence

Session tokens are in-memory only. Every restart of the API server invalidates every active session — this is a deliberate security property: a stolen process dump cannot exfiltrate live bearer tokens that outlive the process. The browser add-on transparently mints a fresh token via the silent-refresh flow on the first failed request after a restart, so the user-visible cost is one extra Margonem-validate round-trip.

Operator-issued persistent tokens live in `api-tokens.psd1` and MUST be gitignored (enforced by `Test-TokenFileGitignored`, additionally defended by the `Test-GitignoreIntegrity` startup check). For stronger at-rest protection, place `.robot.local/` on an OS-encrypted volume (LUKS / FileVault / BitLocker).

Shamir-style unsealing (à la HashiCorp Vault) was considered and deliberately rejected:
- The Margonem public key is public — nothing to seal.
- Session tokens already die on restart — sealing the dead is pointless.
- The only on-disk secret is `api-tokens.psd1`, gitignored and (under the recommended deployment) on encrypted storage.
- Shamir's operational cost (unseal API, K-of-N key ceremony, sealed-state startup, re-unseal after every crash) is wildly out of scale with the tabletop-RPG-server threat model.
The right answer for "what if the disk leaks" is OS-level encryption, not a sealed-storage state machine.

## Related Documents

- [PLUGINS.md](PLUGINS.md) — Plugin system mechanics, manifest schema, hook registry
- [ENTITIES.md](ENTITIES.md) — Entity data model consumed by API handlers
- [SESSIONS.md](SESSIONS.md) — Session data consumed by session-related endpoints
- [SESSION-GRAPH.md](SESSION-GRAPH.md) — Session graph data for participation endpoints
- [ECONOMY.md](ECONOMY.md) — Economic analysis behind /economy endpoints
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) — Name resolution pipeline behind /resolve endpoint
- [CLI.md](CLI.md) — CLI framework for workflow menu items

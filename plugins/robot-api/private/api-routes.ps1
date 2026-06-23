<#
    .SYNOPSIS
    Route registration and static handler definitions for the robot-api plugin.

    .DESCRIPTION
    This file contains Register-AllApiRoutes — the central route table for
    the REST API. Called by Start-RobotApi during server initialization.

    Routes are organized in four tiers:
    1. Static C# routes (/health, /routes, /metrics, /schema, /help) —
       handled entirely in compiled C# via static methods on ApiServer,
       registered as Func<RouteMatch, ApiServer, object> delegates.
       No RunspacePool invocation, zero PowerShell overhead.
       The /routes handler accesses the router via ApiServer.Router at
       request time (set during Start).
    2. Dynamic PS read routes (GET) — dispatched via RequestQueue to
       worker runspaces that invoke handler functions from
       api-handlers-read.ps1. Expensive read endpoints (entity-state,
       economy, leaderboard, reports) use AddCacheableRoute with sidecar
       metadata (cacheKey + cacheDomains) for fingerprint-based HTTP
       caching in ApiServer.HandleRequestAsync.
    3. Dynamic PS write routes (POST/PUT/DELETE) — same dispatch, with
       the worker pool incrementing CacheVersion after completion.
    4. Auth management routes (/auth/*) — token CRUD endpoints gated
       by the auth:manage scope, handled by api-handlers-auth.ps1.

    Every AddRoute call includes an expected status code and a scope
    string (e.g. 'entity:read', 'admin:write') used by the C# middleware
    pipeline for bearer-token authorization before the request reaches
    the PowerShell worker pool.

    The /schema endpoint uses [Robot.ApiNameDictionary]::GetSchema() to
    expose the full domain name dictionary and enum values for API clients.

    The function builds a $HandlerMap hashtable mapping handler function
    names to $true, returned to Start-ApiWorkerPool so workers can reject
    unknown handler names early (routing mismatch or stale map).

    Helpers:
    - Register-AllApiRoutes: registers all routes and returns handler map
#>

function Register-AllApiRoutes {
    param(
        [Parameter(Mandatory)] [Robot.ApiRouter]$Router,
        [Parameter(Mandatory)] [Robot.ApiServer]$Server
    )

    $HandlerMap = @{}

    # ── Static C# routes (no PS invocation) ───────────────────────────
    # These use pure C# static methods on [Robot.ApiServer] as delegates.
    # Previous ScriptBlock-based delegates failed on thread pool threads
    # because PowerShell ScriptBlocks require a Runspace to execute.

    $T = [Func[Robot.RouteMatch, Robot.ApiServer, object]]
    $Router.AddStaticRoute('GET', '/health',
        $T::CreateDelegate($T, [Robot.ApiServer].GetMethod('HandleHealth')),
        'System health check')

    $Router.AddStaticRoute('GET', '/routes',
        $T::CreateDelegate($T, [Robot.ApiServer].GetMethod('HandleRoutes')),
        'List registered API routes')

    $Router.AddStaticRoute('GET', '/metrics',
        $T::CreateDelegate($T, [Robot.ApiServer].GetMethod('HandleMetrics')),
        'Server metrics')

    # Schema discovery — exposes domain name dictionary via compiled C# for zero-PS-overhead
    $Router.AddStaticRoute('GET', '/schema',
        $T::CreateDelegate($T, [Robot.ApiServer].GetMethod('HandleSchema')),
        'Domain name dictionary and enum values')

    # Help discovery and detail — requires Robot.ApiHelpRegistry C# type
    if (([System.Management.Automation.PSTypeName]'Robot.ApiHelpRegistry').Type) {
        $Router.AddStaticRoute('GET', '/help',
            $T::CreateDelegate($T, [Robot.ApiServer].GetMethod('HandleHelp')),
            'List available help components')

        $Router.AddStaticRoute('GET', '/help/:component',
            $T::CreateDelegate($T, [Robot.ApiServer].GetMethod('HandleHelpComponent')),
            'Component help with field descriptions')
    }

    # ── SSE endpoint ──────────────────────────────────────────────────
    $Router.AddSseRoute('/events', 'Server-Sent Events stream for real-time data changes')

    # ── Dynamic PS routes (read) ──────────────────────────────────────

    # --- Entities ---
    $Router.AddRoute('GET', '/entities', 'Invoke-ApiGetEntities', 'List all entities', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetEntities'] = $true

    $Router.AddRoute('GET', '/entities/:name', 'Invoke-ApiGetEntity', 'Get single entity', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetEntity'] = $true

    $Router.AddRoute('GET', '/entities/:name/history', 'Invoke-ApiGetEntityHistory',
        'Entity temporal changelog', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetEntityHistory'] = $true

    $Router.AddRoute('GET', '/entities/:name/delta', 'Invoke-ApiGetEntityDelta',
        'Entity property diff between dates', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetEntityDelta'] = $true

    $Router.AddCacheableRoute('GET', '/entity-state', 'Invoke-ApiGetEntityState',
        'Enriched entity state with session overrides', 200, 'entity:read',
        'entity-state', @('entity', 'session'))
    $HandlerMap['Invoke-ApiGetEntityState'] = $true

    # --- Locations ---
    $Router.AddRoute('GET', '/locations', 'Invoke-ApiGetLocationList',
        'List locations with enrichment', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetLocationList'] = $true

    $Router.AddRoute('GET', '/locations/:name', 'Invoke-ApiGetLocation',
        'Get single location with children and doors', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetLocation'] = $true

    $Router.AddRoute('GET', '/locations/:name/contents', 'Invoke-ApiGetLocationContents',
        'Entities at this location', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetLocationContents'] = $true

    # --- Maps ---
    $Router.AddRoute('GET', '/maps', 'Invoke-ApiGetMaps', 'List all maps', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetMaps'] = $true

    # --- Players ---
    $Router.AddRoute('GET', '/players', 'Invoke-ApiGetPlayers', 'List all players', 200, 'player:read')
    $HandlerMap['Invoke-ApiGetPlayers'] = $true

    $Router.AddRoute('GET', '/players/:name', 'Invoke-ApiGetPlayer', 'Get single player', 200, 'player:read')
    $HandlerMap['Invoke-ApiGetPlayer'] = $true

    # --- Sessions ---
    $Router.AddRoute('GET', '/sessions', 'Invoke-ApiGetSessions', 'List sessions', 200, 'session:read')
    $HandlerMap['Invoke-ApiGetSessions'] = $true

    # --- Session Graph ---
    $Router.AddRoute('GET', '/session-graph/entity/:name', 'Invoke-ApiGetEntityProfile',
        'Session participation profile', 200, 'session:read')
    $HandlerMap['Invoke-ApiGetEntityProfile'] = $true

    $Router.AddRoute('GET', '/session-graph/compare', 'Invoke-ApiCompareParticipation',
        'Participation overlap analysis', 200, 'session:read')
    $HandlerMap['Invoke-ApiCompareParticipation'] = $true

    $Router.AddCacheableRoute('GET', '/session-graph/leaderboard', 'Invoke-ApiGetLeaderboard',
        'Top entities by session count', 200, 'session:read',
        'leaderboard', @('graph'))
    $HandlerMap['Invoke-ApiGetLeaderboard'] = $true

    # --- Currency & Economy ---
    $Router.AddRoute('GET', '/currency', 'Invoke-ApiGetCurrency', 'Currency holdings report', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetCurrency'] = $true

    $Router.AddCacheableRoute('GET', '/economy/snapshot', 'Invoke-ApiGetEconomicSnapshot',
        'Point-in-time economic analysis', 200, 'entity:read',
        'economy-snapshot', @('entity', 'session'))
    $HandlerMap['Invoke-ApiGetEconomicSnapshot'] = $true

    $Router.AddCacheableRoute('GET', '/economy/timeline', 'Invoke-ApiGetEconomicTimeline',
        'Monthly economic trends', 200, 'entity:read',
        'economy-timeline', @('entity', 'session'))
    $HandlerMap['Invoke-ApiGetEconomicTimeline'] = $true

    $Router.AddRoute('GET', '/transactions', 'Invoke-ApiGetTransactions',
        'Currency transaction ledger', 200, 'entity:read')
    $HandlerMap['Invoke-ApiGetTransactions'] = $true

    # --- Name Resolution ---
    $Router.AddRoute('GET', '/resolve/:name', 'Invoke-ApiResolveName',
        'Resolve a name to entity/player', 200, 'entity:read')
    $HandlerMap['Invoke-ApiResolveName'] = $true

    $Router.AddRoute('POST', '/resolve/batch', 'Invoke-ApiResolveBatch',
        'Resolve multiple names in batch', 200, 'entity:read')
    $HandlerMap['Invoke-ApiResolveBatch'] = $true

    # --- Validation ---
    $Router.AddRoute('GET', '/validate/pu', 'Invoke-ApiValidatePU', 'PU assignment validation', 200, 'admin:read')
    $HandlerMap['Invoke-ApiValidatePU'] = $true

    $Router.AddRoute('GET', '/validate/currency', 'Invoke-ApiValidateCurrency',
        'Currency reconciliation', 200, 'admin:read')
    $HandlerMap['Invoke-ApiValidateCurrency'] = $true

    $Router.AddRoute('GET', '/validate/sessions', 'Invoke-ApiValidateSessions',
        'Session integrity check', 200, 'admin:read')
    $HandlerMap['Invoke-ApiValidateSessions'] = $true

    $Router.AddRoute('GET', '/validate/graph', 'Invoke-ApiValidateGraph',
        'Session graph integrity', 200, 'admin:read')
    $HandlerMap['Invoke-ApiValidateGraph'] = $true

    # --- Reports ---
    $Router.AddRoute('GET', '/reports/changelog', 'Invoke-ApiGetChangelog',
        'Entity change audit log', 200, 'admin:read')
    $HandlerMap['Invoke-ApiGetChangelog'] = $true

    $Router.AddCacheableRoute('GET', '/reports/dormancy', 'Invoke-ApiGetDormancy',
        'Inactive entity report', 200, 'admin:read',
        'dormancy', @('entity', 'graph'))
    $HandlerMap['Invoke-ApiGetDormancy'] = $true

    $Router.AddCacheableRoute('GET', '/reports/frequency', 'Invoke-ApiGetFrequency',
        'Session frequency trends', 200, 'admin:read',
        'frequency', @('session'))
    $HandlerMap['Invoke-ApiGetFrequency'] = $true

    $Router.AddCacheableRoute('GET', '/reports/narrators', 'Invoke-ApiGetNarrators',
        'Narrator stats', 200, 'admin:read',
        'narrators', @('session'))
    $HandlerMap['Invoke-ApiGetNarrators'] = $true

    $Router.AddRoute('GET', '/reports/locations', 'Invoke-ApiGetLocations',
        'Location reference data', 200, 'admin:read')
    $HandlerMap['Invoke-ApiGetLocations'] = $true

    $Router.AddCacheableRoute('GET', '/reports/location-graph', 'Invoke-ApiGetLocationGraph',
        'Location topology', 200, 'admin:read',
        'location-graph', @('entity', 'session'))
    $HandlerMap['Invoke-ApiGetLocationGraph'] = $true

    $Router.AddCacheableRoute('GET', '/reports/pu-log', 'Invoke-ApiGetPULog', 'PU processing history', 200, 'admin:read',
        'pu-log', @('session'))
    $HandlerMap['Invoke-ApiGetPULog'] = $true

    $Router.AddRoute('GET', '/reports/notifications', 'Invoke-ApiGetNotifications',
        'Notification audit', 200, 'admin:read')
    $HandlerMap['Invoke-ApiGetNotifications'] = $true

    $Router.AddRoute('GET', '/reports/discord-delivery', 'Invoke-ApiGetDeliveryLog',
        'Discord webhook delivery history', 200, 'admin:read')
    $HandlerMap['Invoke-ApiGetDeliveryLog'] = $true

    # ── Analytics endpoints (Phase 3a: PU-centric) ─────────────────────
    $Router.AddCacheableRoute('GET', '/analytics/pu/by-character',
        'Invoke-ApiAnalyticsPuByCharacter',
        'PU aggregation per character over a date window', 200, 'session:read',
        'analytics-pu-character', @('session'))
    $HandlerMap['Invoke-ApiAnalyticsPuByCharacter'] = $true

    $Router.AddCacheableRoute('GET', '/analytics/pu/by-location',
        'Invoke-ApiAnalyticsPuByLocation',
        'PU aggregation per location over a date window', 200, 'session:read',
        'analytics-pu-location', @('session'))
    $HandlerMap['Invoke-ApiAnalyticsPuByLocation'] = $true

    $Router.AddCacheableRoute('GET', '/analytics/co-engagement',
        'Invoke-ApiAnalyticsCoEngagement',
        'Top character pairs by co-occurrence', 200, 'session:read',
        'analytics-co-engagement', @('session'))
    $HandlerMap['Invoke-ApiAnalyticsCoEngagement'] = $true

    $Router.AddRoute('GET', '/analytics/character-territory/:name',
        'Invoke-ApiAnalyticsCharacterTerritory',
        'Character location footprint + adjacency density', 200, 'session:read')
    $HandlerMap['Invoke-ApiAnalyticsCharacterTerritory'] = $true

    $Router.AddRoute('GET', '/analytics/pu/timeline',
        'Invoke-ApiAnalyticsPuTimeline',
        'Monthly/weekly PU velocity per character', 200, 'session:read')
    $HandlerMap['Invoke-ApiAnalyticsPuTimeline'] = $true

    $Router.AddCacheableRoute('GET', '/analytics/pu/by-narrator',
        'Invoke-ApiAnalyticsPuByNarrator',
        'PU statistics per narrator', 200, 'session:read',
        'analytics-pu-narrator', @('session'))
    $HandlerMap['Invoke-ApiAnalyticsPuByNarrator'] = $true

    # ── Analytics endpoints (Phase 3b: cross-cutting) ──────────────────
    $Router.AddCacheableRoute('GET', '/analytics/entity-lifecycle',
        'Invoke-ApiAnalyticsEntityLifecycle',
        'Status/group/owner/location transitions over time', 200, 'session:read',
        'analytics-entity-lifecycle', @('entity', 'session'))
    $HandlerMap['Invoke-ApiAnalyticsEntityLifecycle'] = $true

    $Router.AddCacheableRoute('GET', '/analytics/location-graph/metrics',
        'Invoke-ApiAnalyticsLocationGraphMetrics',
        'Graph metrics: degree, components, choke points', 200, 'entity:read',
        'analytics-location-graph-metrics', @('entity', 'session'))
    $HandlerMap['Invoke-ApiAnalyticsLocationGraphMetrics'] = $true

    $Router.AddRoute('GET', '/analytics/logs/speaker-leaderboard',
        'Invoke-ApiAnalyticsLogsSpeakerLeaderboard',
        'Chat presence leaderboard from logs', 200, 'session:read')
    $HandlerMap['Invoke-ApiAnalyticsLogsSpeakerLeaderboard'] = $true

    $Router.AddRoute('GET', '/analytics/logs/channel-mix',
        'Invoke-ApiAnalyticsLogsChannelMix',
        'ChatLog channel breakdown (secrecy density)', 200, 'session:read')
    $HandlerMap['Invoke-ApiAnalyticsLogsChannelMix'] = $true

    $Router.AddRoute('GET', '/analytics/logs/coverage',
        'Invoke-ApiAnalyticsLogsCoverage',
        'Log fetch coverage / health stats', 200, 'session:read')
    $HandlerMap['Invoke-ApiAnalyticsLogsCoverage'] = $true

    $Router.AddRoute('GET', '/analytics/resolution/quality',
        'Invoke-ApiAnalyticsResolutionQuality',
        'Name index health: ambiguity, stem collisions, stages', 200, 'entity:read')
    $HandlerMap['Invoke-ApiAnalyticsResolutionQuality'] = $true

    $Router.AddRoute('GET', '/analytics/integrity/trends',
        'Invoke-ApiAnalyticsIntegrityTrends',
        'Integrity check trends over time', 200, 'admin:read')
    $HandlerMap['Invoke-ApiAnalyticsIntegrityTrends'] = $true

    $Router.AddCacheableRoute('GET', '/analytics/metadata/coverage',
        'Invoke-ApiAnalyticsMetadataCoverage',
        'Metadata coverage report (IsExterior, slugs, etc.)', 200, 'entity:read',
        'analytics-metadata-coverage', @('entity'))
    $HandlerMap['Invoke-ApiAnalyticsMetadataCoverage'] = $true

    # ── Write endpoints ────────────────────────────────────────────────
    $Router.AddRoute('POST', '/entities', 'Invoke-ApiCreateEntity', 'Create entity', 201, 'entity:write')
    $HandlerMap['Invoke-ApiCreateEntity'] = $true

    $Router.AddRoute('PUT', '/entities/:name', 'Invoke-ApiUpdateEntity', 'Update entity tags', 200, 'entity:write')
    $HandlerMap['Invoke-ApiUpdateEntity'] = $true

    $Router.AddRoute('DELETE', '/entities/:name', 'Invoke-ApiDeleteEntity',
        'Soft-delete entity', 200, 'entity:write')
    $HandlerMap['Invoke-ApiDeleteEntity'] = $true

    $Router.AddRoute('POST', '/currency', 'Invoke-ApiCreateCurrency', 'Create currency', 201, 'entity:write')
    $HandlerMap['Invoke-ApiCreateCurrency'] = $true

    $Router.AddRoute('PUT', '/currency/:name', 'Invoke-ApiUpdateCurrency',
        'Update currency amount', 200, 'entity:write')
    $HandlerMap['Invoke-ApiUpdateCurrency'] = $true

    $Router.AddRoute('POST', '/players', 'Invoke-ApiCreatePlayer', 'Create player', 201, 'player:write')
    $HandlerMap['Invoke-ApiCreatePlayer'] = $true

    $Router.AddRoute('POST', '/players/:name/characters', 'Invoke-ApiCreateCharacter',
        'Create player character', 201, 'player:write')
    $HandlerMap['Invoke-ApiCreateCharacter'] = $true

    $Router.AddRoute('POST', '/workflow/session-graph', 'Invoke-ApiRebuildGraph',
        'Rebuild session graph index', 200, 'admin:write')
    $HandlerMap['Invoke-ApiRebuildGraph'] = $true

    $Router.AddRoute('POST', '/workflow/session-hash', 'Invoke-ApiRebuildHashes',
        'Update session content hashes', 200, 'admin:write')
    $HandlerMap['Invoke-ApiRebuildHashes'] = $true

    $Router.AddRoute('POST', '/sessions', 'Invoke-ApiCreateSession',
        'Create a new session in target file(s)', 201, 'session:write')
    $HandlerMap['Invoke-ApiCreateSession'] = $true

    # --- Locations (write) ---
    $Router.AddRoute('POST', '/locations', 'Invoke-ApiCreateLocation', 'Create location', 201, 'entity:write')
    $HandlerMap['Invoke-ApiCreateLocation'] = $true

    $Router.AddRoute('PUT', '/locations/:name', 'Invoke-ApiUpdateLocation', 'Update location', 200, 'entity:write')
    $HandlerMap['Invoke-ApiUpdateLocation'] = $true

    $Router.AddRoute('DELETE', '/locations/:name', 'Invoke-ApiDeleteLocation',
        'Soft-delete location', 200, 'entity:write')
    $HandlerMap['Invoke-ApiDeleteLocation'] = $true

    # --- Maps (write) ---
    $Router.AddRoute('POST', '/maps', 'Invoke-ApiCreateMap', 'Create map', 201, 'entity:write')
    $HandlerMap['Invoke-ApiCreateMap'] = $true
    $Router.AddRoute('PUT', '/maps/:name', 'Invoke-ApiUpdateMap', 'Update map', 200, 'entity:write')
    $HandlerMap['Invoke-ApiUpdateMap'] = $true

    # --- Files ---
    $Router.AddRoute('GET', '/files', 'Invoke-ApiGetFiles', 'List .md file paths for autocomplete', 200, 'session:read')
    $HandlerMap['Invoke-ApiGetFiles'] = $true
    $Router.AddRoute('GET', '/files/tree', 'Invoke-ApiGetFilesTree', 'Directory tree of .md files', 200, 'session:read')
    $HandlerMap['Invoke-ApiGetFilesTree'] = $true

    # ── Dashboard ──────────────────────────────────────────────────────
    $Router.AddRoute('GET', '/dashboard', 'Invoke-ApiGetDashboard',
        'Web dashboard SPA', 200, $null)
    $HandlerMap['Invoke-ApiGetDashboard'] = $true

    # ── Parse endpoints (read-only) ───────────────────────────────────
    $Router.AddRoute('POST', '/parse/log', 'Invoke-ApiParseLog',
        'Parse raw log text into structured data', 200, 'session:read')
    $HandlerMap['Invoke-ApiParseLog'] = $true

    $Router.AddRoute('POST', '/logs/fetch', 'Invoke-ApiFetchLogContent',
        'Fetch raw log content by URLs (disk cache then HTTP)', 200, 'session:read')
    $HandlerMap['Invoke-ApiFetchLogContent'] = $true

    $Router.AddRoute('POST', '/logs/parse', 'Invoke-ApiParseLogEnriched',
        'Fetch + parse + resolve logs in one call (urls[] or content)', 200, 'session:read')
    $HandlerMap['Invoke-ApiParseLogEnriched'] = $true

    $Router.AddRoute('POST', '/parse/session-preview', 'Invoke-ApiSessionPreview',
        'Preview session markdown with name resolution', 200, 'session:read')
    $HandlerMap['Invoke-ApiSessionPreview'] = $true

    # ── Auth endpoints ─────────────────────────────────────────────────
    $Router.AddRoute('POST', '/auth/token', 'Invoke-ApiCreateToken', 'Create API token', 201, 'auth:manage')
    $HandlerMap['Invoke-ApiCreateToken'] = $true

    $Router.AddRoute('DELETE', '/auth/token/:name', 'Invoke-ApiDeleteToken', 'Delete API token', 200, 'auth:manage')
    $HandlerMap['Invoke-ApiDeleteToken'] = $true

    $Router.AddRoute('GET', '/auth/status', 'Invoke-ApiGetAuthStatus', 'Token store status', 200, 'auth:manage')
    $HandlerMap['Invoke-ApiGetAuthStatus'] = $true

    $Router.AddRoute('GET', '/auth/whoami', 'Invoke-ApiGetWhoami',
        'Current token identity and scopes', 200, $null)
    $HandlerMap['Invoke-ApiGetWhoami'] = $true

    return $HandlerMap
}

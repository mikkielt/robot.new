<#
    .SYNOPSIS
    Route registration and static handler definitions for the robot-api plugin.

    .DESCRIPTION
    This file contains Register-AllApiRoutes — the central route table for
    the REST API. Called by Start-RobotApi during server initialization.

    Routes are organized in three tiers:
    1. Static C# routes (/health, /routes, /metrics, /schema) — handled
       entirely in compiled C# via Func<RouteMatch, ApiServer, object>
       delegates. No RunspacePool invocation, zero PowerShell overhead.
    2. Dynamic PS read routes (GET) — dispatched via RequestQueue to worker
       runspaces that invoke handler functions from api-handlers-read.ps1.
    3. Dynamic PS write routes (POST/PUT/DELETE) — same dispatch, with the
       worker pool incrementing CacheVersion after completion.

    The function builds a $HandlerMap hashtable mapping handler function names
    to $true, returned to Start-ApiWorkerPool so workers can validate handler
    lookups before invocation.

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

    $Router.AddStaticRoute('GET', '/health',
        [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
            param([Robot.RouteMatch]$Match, [Robot.ApiServer]$Srv)
            $S = $Srv.GetStatus()
            $S['status'] = 'ok'
            return $S
        }, 'System health check')

    # Capture $Router for the /routes closure
    $CapturedRouter = $Router
    $Router.AddStaticRoute('GET', '/routes',
        [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
            param([Robot.RouteMatch]$Match, [Robot.ApiServer]$Srv)
            return @{ routes = $CapturedRouter.ListRoutes() }
        }.GetNewClosure(), 'List registered API routes')

    $Router.AddStaticRoute('GET', '/metrics',
        [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
            param([Robot.RouteMatch]$Match, [Robot.ApiServer]$Srv)
            $S = $Srv.GetStatus()
            $S['routeCount'] = $CapturedRouter.ListRoutes().Count
            return $S
        }.GetNewClosure(), 'Server metrics')

    # Schema discovery — returns full name dictionary
    $Router.AddStaticRoute('GET', '/schema',
        [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
            param([Robot.RouteMatch]$Match, [Robot.ApiServer]$Srv)
            return [Robot.ApiNameDictionary]::GetSchema()
        }, 'Domain name dictionary and enum values')

    # ── SSE endpoint ──────────────────────────────────────────────────
    $Router.AddSseRoute('/events', 'Server-Sent Events stream for real-time data changes')

    # ── Dynamic PS routes (read) ──────────────────────────────────────

    # --- Entities ---
    $Router.AddRoute('GET', '/entities', 'Invoke-ApiGetEntities', 'List all entities')
    $HandlerMap['Invoke-ApiGetEntities'] = $true

    $Router.AddRoute('GET', '/entities/:name', 'Invoke-ApiGetEntity', 'Get single entity')
    $HandlerMap['Invoke-ApiGetEntity'] = $true

    $Router.AddRoute('GET', '/entities/:name/history', 'Invoke-ApiGetEntityHistory',
        'Entity temporal changelog')
    $HandlerMap['Invoke-ApiGetEntityHistory'] = $true

    $Router.AddRoute('GET', '/entities/:name/delta', 'Invoke-ApiGetEntityDelta',
        'Entity property diff between dates')
    $HandlerMap['Invoke-ApiGetEntityDelta'] = $true

    $Router.AddRoute('GET', '/entity-state', 'Invoke-ApiGetEntityState',
        'Enriched entity state with session overrides')
    $HandlerMap['Invoke-ApiGetEntityState'] = $true

    # --- Players ---
    $Router.AddRoute('GET', '/players', 'Invoke-ApiGetPlayers', 'List all players')
    $HandlerMap['Invoke-ApiGetPlayers'] = $true

    $Router.AddRoute('GET', '/players/:name', 'Invoke-ApiGetPlayer', 'Get single player')
    $HandlerMap['Invoke-ApiGetPlayer'] = $true

    # --- Sessions ---
    $Router.AddRoute('GET', '/sessions', 'Invoke-ApiGetSessions', 'List sessions')
    $HandlerMap['Invoke-ApiGetSessions'] = $true

    # --- Session Graph ---
    $Router.AddRoute('GET', '/session-graph/entity/:name', 'Invoke-ApiGetEntityProfile',
        'Session participation profile')
    $HandlerMap['Invoke-ApiGetEntityProfile'] = $true

    $Router.AddRoute('GET', '/session-graph/compare', 'Invoke-ApiCompareParticipation',
        'Participation overlap analysis')
    $HandlerMap['Invoke-ApiCompareParticipation'] = $true

    $Router.AddRoute('GET', '/session-graph/leaderboard', 'Invoke-ApiGetLeaderboard',
        'Top entities by session count')
    $HandlerMap['Invoke-ApiGetLeaderboard'] = $true

    # --- Currency & Economy ---
    $Router.AddRoute('GET', '/currency', 'Invoke-ApiGetCurrency', 'Currency holdings report')
    $HandlerMap['Invoke-ApiGetCurrency'] = $true

    $Router.AddRoute('GET', '/economy/snapshot', 'Invoke-ApiGetEconomicSnapshot',
        'Point-in-time economic analysis')
    $HandlerMap['Invoke-ApiGetEconomicSnapshot'] = $true

    $Router.AddRoute('GET', '/economy/timeline', 'Invoke-ApiGetEconomicTimeline',
        'Monthly economic trends')
    $HandlerMap['Invoke-ApiGetEconomicTimeline'] = $true

    $Router.AddRoute('GET', '/transactions', 'Invoke-ApiGetTransactions',
        'Currency transaction ledger')
    $HandlerMap['Invoke-ApiGetTransactions'] = $true

    # --- Name Resolution ---
    $Router.AddRoute('GET', '/resolve/:name', 'Invoke-ApiResolveName',
        'Resolve a name to entity/player')
    $HandlerMap['Invoke-ApiResolveName'] = $true

    # --- Validation ---
    $Router.AddRoute('GET', '/validate/pu', 'Invoke-ApiValidatePU', 'PU assignment validation')
    $HandlerMap['Invoke-ApiValidatePU'] = $true

    $Router.AddRoute('GET', '/validate/currency', 'Invoke-ApiValidateCurrency',
        'Currency reconciliation')
    $HandlerMap['Invoke-ApiValidateCurrency'] = $true

    $Router.AddRoute('GET', '/validate/sessions', 'Invoke-ApiValidateSessions',
        'Session integrity check')
    $HandlerMap['Invoke-ApiValidateSessions'] = $true

    $Router.AddRoute('GET', '/validate/graph', 'Invoke-ApiValidateGraph',
        'Session graph integrity')
    $HandlerMap['Invoke-ApiValidateGraph'] = $true

    # --- Reports ---
    $Router.AddRoute('GET', '/reports/changelog', 'Invoke-ApiGetChangelog',
        'Entity change audit log')
    $HandlerMap['Invoke-ApiGetChangelog'] = $true

    $Router.AddRoute('GET', '/reports/dormancy', 'Invoke-ApiGetDormancy',
        'Inactive entity report')
    $HandlerMap['Invoke-ApiGetDormancy'] = $true

    $Router.AddRoute('GET', '/reports/frequency', 'Invoke-ApiGetFrequency',
        'Session frequency trends')
    $HandlerMap['Invoke-ApiGetFrequency'] = $true

    $Router.AddRoute('GET', '/reports/narrators', 'Invoke-ApiGetNarrators',
        'Narrator stats')
    $HandlerMap['Invoke-ApiGetNarrators'] = $true

    $Router.AddRoute('GET', '/reports/locations', 'Invoke-ApiGetLocations',
        'Location reference data')
    $HandlerMap['Invoke-ApiGetLocations'] = $true

    $Router.AddRoute('GET', '/reports/location-graph', 'Invoke-ApiGetLocationGraph',
        'Location topology')
    $HandlerMap['Invoke-ApiGetLocationGraph'] = $true

    $Router.AddRoute('GET', '/reports/pu-log', 'Invoke-ApiGetPULog', 'PU processing history')
    $HandlerMap['Invoke-ApiGetPULog'] = $true

    $Router.AddRoute('GET', '/reports/notifications', 'Invoke-ApiGetNotifications',
        'Notification audit')
    $HandlerMap['Invoke-ApiGetNotifications'] = $true

    # ── Write endpoints (Phase 3) ─────────────────────────────────────
    $Router.AddRoute('POST', '/entities', 'Invoke-ApiCreateEntity', 'Create entity', 201)
    $HandlerMap['Invoke-ApiCreateEntity'] = $true

    $Router.AddRoute('PUT', '/entities/:name', 'Invoke-ApiUpdateEntity', 'Update entity tags')
    $HandlerMap['Invoke-ApiUpdateEntity'] = $true

    $Router.AddRoute('DELETE', '/entities/:name', 'Invoke-ApiDeleteEntity',
        'Soft-delete entity')
    $HandlerMap['Invoke-ApiDeleteEntity'] = $true

    $Router.AddRoute('POST', '/currency', 'Invoke-ApiCreateCurrency', 'Create currency', 201)
    $HandlerMap['Invoke-ApiCreateCurrency'] = $true

    $Router.AddRoute('PUT', '/currency/:name', 'Invoke-ApiUpdateCurrency',
        'Update currency amount')
    $HandlerMap['Invoke-ApiUpdateCurrency'] = $true

    $Router.AddRoute('POST', '/players', 'Invoke-ApiCreatePlayer', 'Create player', 201)
    $HandlerMap['Invoke-ApiCreatePlayer'] = $true

    $Router.AddRoute('POST', '/players/:name/characters', 'Invoke-ApiCreateCharacter',
        'Create player character', 201)
    $HandlerMap['Invoke-ApiCreateCharacter'] = $true

    $Router.AddRoute('POST', '/workflow/session-graph', 'Invoke-ApiRebuildGraph',
        'Rebuild session graph index')
    $HandlerMap['Invoke-ApiRebuildGraph'] = $true

    $Router.AddRoute('POST', '/workflow/session-hash', 'Invoke-ApiRebuildHashes',
        'Update session content hashes')
    $HandlerMap['Invoke-ApiRebuildHashes'] = $true

    return $HandlerMap
}

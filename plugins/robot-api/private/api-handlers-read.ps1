<#
    .SYNOPSIS
    Read-only REST API handler functions for the robot-api plugin.

    .DESCRIPTION
    This file defines handler functions that are dot-sourced into each worker
    runspace at startup. Each handler accepts a [hashtable]$ApiContext with
    PathParams, QueryParams, Body, Method, and Path, and returns a hashtable
    with StatusCode, Body, and optionally IncludeLabels.

    Helpers:
    - Invoke-ApiEntityListQuery: reusable RSQL query pipeline (filter -> sort
      -> paginate -> sparse fieldset) via Robot.ApiQueryParser

    Handler groups:
    Entities:   Invoke-ApiGetEntities, Invoke-ApiGetEntity,
                Invoke-ApiGetEntityHistory, Invoke-ApiGetEntityDelta,
                Invoke-ApiGetEntityState
    Players:    Invoke-ApiGetPlayers, Invoke-ApiGetPlayer
    Sessions:   Invoke-ApiGetSessions
    Graph:      Invoke-ApiGetEntityProfile, Invoke-ApiCompareParticipation,
                Invoke-ApiGetLeaderboard
    Currency:   Invoke-ApiGetCurrency, Invoke-ApiGetEconomicSnapshot,
                Invoke-ApiGetEconomicTimeline, Invoke-ApiGetTransactions
    Resolution: Invoke-ApiResolveName
    Validation: Invoke-ApiValidatePU, Invoke-ApiValidateCurrency,
                Invoke-ApiValidateSessions, Invoke-ApiValidateGraph
    Reports:    Invoke-ApiGetChangelog, Invoke-ApiGetDormancy,
                Invoke-ApiGetFrequency, Invoke-ApiGetNarrators,
                Invoke-ApiGetLocations, Invoke-ApiGetLocationGraph,
                Invoke-ApiGetPULog, Invoke-ApiGetNotifications

    Handlers follow a common pattern: extract query parameters, build a
    splatted parameter hashtable for the backing module function (with -Quiet
    where supported), and wrap the result in a standard response hashtable.
    Errors return 422; missing required params return 400.

    The IncludeLabels flag (?labels=true) passes through to ApiSerializer
    so Entity objects receive *Label companion fields via ApiNameDictionary.
#>

# ── Helper: build standard list response with RSQL query support ──────

function Invoke-ApiEntityListQuery {
    param(
        [hashtable]$ApiContext,
        [object[]]$Entities
    )

    $QP = $ApiContext.QueryParams

    # RSQL filter
    $FilterStr = $QP['filter']
    if ($FilterStr) {
        $Groups = [Robot.ApiQueryParser]::ParseFilter($FilterStr)
        $EntityList = [System.Collections.Generic.List[Robot.Entity]]::new($Entities.Count)
        foreach ($E in $Entities) { $EntityList.Add($E) }
        $EntityList = [Robot.ApiQueryParser]::FilterEntities($EntityList, $Groups)
        $Entities = @($EntityList)
    }

    # Sort
    $SortStr = $QP['sort']
    $SortFields = [Robot.ApiQueryParser]::ParseSort($SortStr)
    $SortedList = [System.Collections.Generic.List[Robot.Entity]]::new($Entities.Count)
    foreach ($E in $Entities) { $SortedList.Add($E) }
    if ($SortFields.Count -gt 0) {
        [Robot.ApiQueryParser]::SortEntities($SortedList, $SortFields)
    }

    # Pagination
    $PageParams = [Robot.ApiQueryParser]::ParsePage($QP)
    $Page = [Robot.ApiQueryParser]::PaginateEntities($SortedList, $PageParams)

    # Sparse fieldsets
    $FieldSet = [Robot.ApiQueryParser]::ParseFields($QP['fields'])
    $Items = if ($null -ne $FieldSet) {
        @($Page.Items | ForEach-Object {
            $Obj = @{}
            foreach ($F in $FieldSet) {
                $Val = [Robot.ApiQueryParser]::GetEntityField($_, $F)
                if ($null -ne $Val) { $Obj[$F] = $Val }
            }
            [PSCustomObject]$Obj
        })
    } else {
        @($Page.Items)
    }

    $IncludeLabels = $QP['labels'] -eq 'true'

    return @{
        StatusCode    = 200
        IncludeLabels = $IncludeLabels
        Body          = @{
            count      = $Page.TotalCount
            pageSize   = $PageParams.Size
            hasMore    = $Page.HasMore
            nextCursor = $Page.NextCursor
            items      = $Items
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# ENTITIES
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetEntities {
    param([hashtable]$ApiContext)

    $QP       = $ApiContext.QueryParams
    $ActiveOn = $QP['activeOn']
    $Params   = @{ Quiet = $true }
    if ($ActiveOn) { $Params.ActiveOn = [datetime]::Parse($ActiveOn) }

    $Entities = @(Get-Entity @Params)

    return (Invoke-ApiEntityListQuery -ApiContext $ApiContext -Entities $Entities)
}

function Invoke-ApiGetEntity {
    param([hashtable]$ApiContext)

    $Name     = $ApiContext.PathParams['name']
    $Entities = Get-Entity -Quiet

    $Match = @($Entities | Where-Object {
        [string]::Equals($_.Name, $Name, 'OrdinalIgnoreCase') -or
        [string]::Equals($_.CN, $Name, 'OrdinalIgnoreCase')
    })

    if ($Match.Count -eq 0) {
        $Resolved = Resolve-Name -Query $Name -Quiet
        if ($Resolved) {
            $Match = @($Entities | Where-Object { $_.Name -eq $Resolved.Name })
        }
    }

    if ($Match.Count -eq 0) {
        return @{ StatusCode = 404; Body = @{ error = "Entity not found: $Name" } }
    }

    $IncludeLabels = $ApiContext.QueryParams['labels'] -eq 'true'
    return @{ StatusCode = 200; Body = $Match[0]; IncludeLabels = $IncludeLabels }
}

function Invoke-ApiGetEntityHistory {
    param([hashtable]$ApiContext)

    $Name     = $ApiContext.PathParams['name']
    $QP       = $ApiContext.QueryParams
    $Params   = @{}

    if ($QP['minDate'])  { $Params.MinDate    = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate'])  { $Params.MaxDate    = [datetime]::Parse($QP['maxDate']) }
    if ($Name)           { $Params.EntityName = $Name }

    try {
        $Log = @(Get-ChangeLog @Params)
        return @{ StatusCode = 200; Body = @{ count = $Log.Count; items = $Log } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetEntityDelta {
    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $QP   = $ApiContext.QueryParams

    if (-not $QP['from'] -or -not $QP['to']) {
        return @{ StatusCode = 400; Body = @{ error = 'from and to date query params required' } }
    }

    try {
        $Result = Get-EntityDelta -Name $Name `
            -FromDate ([datetime]::Parse($QP['from'])) `
            -ToDate ([datetime]::Parse($QP['to'])) `
            -Quiet
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetEntityState {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{}

    if ($QP['activeOn']) { $Params.ActiveOn = [datetime]::Parse($QP['activeOn']) }

    try {
        $States = @(Get-EntityState @Params)
        return @{ StatusCode = 200; Body = @{ count = $States.Count; items = $States } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# PLAYERS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetPlayers {
    param([hashtable]$ApiContext)

    $Players = @(Get-Player)
    return @{ StatusCode = 200; Body = @{ count = $Players.Count; items = $Players } }
}

function Invoke-ApiGetPlayer {
    param([hashtable]$ApiContext)

    $Name    = $ApiContext.PathParams['name']
    $Players = @(Get-Player -Name $Name)

    if ($Players.Count -eq 0) {
        return @{ StatusCode = 404; Body = @{ error = "Player not found: $Name" } }
    }

    return @{ StatusCode = 200; Body = $Players[0] }
}

# ═══════════════════════════════════════════════════════════════════════
# SESSIONS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetSessions {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{}

    if ($QP['minDate']) { $Params.MinDate = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate = [datetime]::Parse($QP['maxDate']) }
    if ($QP['includeContent'] -eq 'true') { $Params.IncludeContent = $true }

    $Sessions = @(Get-Session @Params)

    # Inject format labels if requested
    if ($QP['labels'] -eq 'true') {
        foreach ($S in $Sessions) {
            $FormatLabel = [Robot.ApiNameDictionary]::GetLabel('format', $S.Format)
            if ($FormatLabel) {
                $S | Add-Member -NotePropertyName 'formatLabel' `
                    -NotePropertyValue $FormatLabel -Force
            }
        }
    }

    return @{
        StatusCode = 200
        Body       = @{ count = $Sessions.Count; items = $Sessions }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SESSION GRAPH
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetEntityProfile {
    param([hashtable]$ApiContext)

    $Name   = $ApiContext.PathParams['name']
    $QP     = $ApiContext.QueryParams
    $Params = @{ EntityName = $Name; Quiet = $true }

    if ($QP['minTier']) { $Params.MinTier = [int]$QP['minTier'] }

    try {
        $Profile = Get-EntitySessionProfile @Params
        return @{ StatusCode = 200; Body = $Profile }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiCompareParticipation {
    param([hashtable]$ApiContext)

    $QP    = $ApiContext.QueryParams
    $Names = $QP['entities']

    if (-not $Names) {
        return @{ StatusCode = 400; Body = @{ error = 'entities query param required (comma-separated)' } }
    }

    $EntityNames = @($Names -split ',')
    $Params      = @{ EntityNames = $EntityNames; Quiet = $true }

    if ($QP['minTier']) { $Params.MinTier = [int]$QP['minTier'] }

    try {
        $Result = Compare-SessionParticipation @Params
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetLeaderboard {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['type'])    { $Params.EntityType = $QP['type'] }
    if ($QP['top'])     { $Params.Top        = [int]$QP['top'] }
    if ($QP['minTier']) { $Params.MinTier    = [int]$QP['minTier'] }
    if ($QP['minDate']) { $Params.MinDate    = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate    = [datetime]::Parse($QP['maxDate']) }

    try {
        $Board = @(Get-SessionGraphLeaderboard @Params)
        return @{ StatusCode = 200; Body = @{ count = $Board.Count; items = $Board } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# CURRENCY & ECONOMY
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetCurrency {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['owner'])         { $Params.Owner          = $QP['owner'] }
    if ($QP['denomination'])  { $Params.Denomination   = $QP['denomination'] }
    if ($QP['includeVirtual'] -eq 'true')  { $Params.IncludeVirtual  = $true }
    if ($QP['includeInactive'] -eq 'true') { $Params.IncludeInactive = $true }
    if ($QP['activeOn'])      { $Params.ActiveOn       = [datetime]::Parse($QP['activeOn']) }
    if ($QP['showHistory'] -eq 'true')     { $Params.ShowHistory     = $true }
    if ($QP['asBaseUnit'] -eq 'true')      { $Params.AsBaseUnit      = $true }

    try {
        $Report = @(Get-CurrencyReport @Params)
        return @{ StatusCode = 200; Body = @{ count = $Report.Count; items = $Report } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetEconomicSnapshot {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['activeOn'])     { $Params.ActiveOn     = [datetime]::Parse($QP['activeOn']) }
    if ($QP['owner'])        { $Params.Owner        = $QP['owner'] }
    if ($QP['denomination']) { $Params.Denomination = $QP['denomination'] }
    if ($QP['top'])          { $Params.Top          = [int]$QP['top'] }

    try {
        $Snapshot = Get-EconomicSnapshot @Params
        return @{ StatusCode = 200; Body = $Snapshot }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetEconomicTimeline {
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams

    if (-not $QP['minDate'] -or -not $QP['maxDate']) {
        return @{ StatusCode = 400; Body = @{ error = 'minDate and maxDate query params required' } }
    }

    $Params = @{
        MinDate = [datetime]::Parse($QP['minDate'])
        MaxDate = [datetime]::Parse($QP['maxDate'])
        Quiet   = $true
    }

    if ($QP['entity'])       { $Params.Entity       = $QP['entity'] }
    if ($QP['denomination']) { $Params.Denomination = $QP['denomination'] }

    try {
        $Timeline = @(Get-EconomicTimeline @Params)
        return @{ StatusCode = 200; Body = @{ count = $Timeline.Count; items = $Timeline } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetTransactions {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['entity'])       { $Params.Entity       = $QP['entity'] }
    if ($QP['denomination']) { $Params.Denomination = $QP['denomination'] }
    if ($QP['minDate'])      { $Params.MinDate      = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate'])      { $Params.MaxDate      = [datetime]::Parse($QP['maxDate']) }

    try {
        $Ledger = @(Get-TransactionLedger @Params)
        return @{ StatusCode = 200; Body = @{ count = $Ledger.Count; items = $Ledger } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# NAME RESOLUTION
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiResolveName {
    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']

    $Result = Resolve-Name -Query $Name -Quiet
    if (-not $Result) {
        return @{ StatusCode = 404; Body = @{ error = "Could not resolve: $Name" } }
    }

    return @{ StatusCode = 200; Body = $Result }
}

# ═══════════════════════════════════════════════════════════════════════
# VALIDATION
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiValidatePU {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['year'])  { $Params.Year  = [int]$QP['year'] }
    if ($QP['month']) { $Params.Month = [int]$QP['month'] }
    if ($QP['minDate']) { $Params.MinDate = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate = [datetime]::Parse($QP['maxDate']) }

    try {
        $Results = @(Test-PlayerCharacterPUAssignment @Params)
        return @{ StatusCode = 200; Body = @{ count = $Results.Count; items = $Results } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiValidateCurrency {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['since']) { $Params.Since = [datetime]::Parse($QP['since']) }

    try {
        $Results = @(Test-CurrencyReconciliation @Params)
        return @{ StatusCode = 200; Body = @{ count = $Results.Count; items = $Results } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiValidateSessions {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['full'] -eq 'true') { $Params.Full  = $true }
    if ($QP['since'])           { $Params.Since = $QP['since'] }

    try {
        $Results = @(Test-SessionIntegrity @Params)
        return @{ StatusCode = 200; Body = @{ count = $Results.Count; items = $Results } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiValidateGraph {
    param([hashtable]$ApiContext)

    $Params = @{ Quiet = $true }

    try {
        $Results = @(Test-SessionGraphIntegrity @Params)
        return @{ StatusCode = 200; Body = @{ count = $Results.Count; items = $Results } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# REPORTS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetChangelog {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{}

    if ($QP['minDate'])  { $Params.MinDate    = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate'])  { $Params.MaxDate    = [datetime]::Parse($QP['maxDate']) }
    if ($QP['entity'])   { $Params.EntityName = $QP['entity'] }
    if ($QP['property']) { $Params.Property   = $QP['property'] }

    try {
        $Log = @(Get-ChangeLog @Params)
        return @{ StatusCode = 200; Body = @{ count = $Log.Count; items = $Log } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetDormancy {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['thresholdMonths'])            { $Params.ThresholdMonths = [int]$QP['thresholdMonths'] }
    if ($QP['type'])                       { $Params.Type            = $QP['type'] }
    if ($QP['includeDeleted'] -eq 'true')  { $Params.IncludeDeleted  = $true }

    try {
        $Report = @(Get-DormancyReport @Params)
        return @{ StatusCode = 200; Body = @{ count = $Report.Count; items = $Report } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetFrequency {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['minDate']) { $Params.MinDate = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate = [datetime]::Parse($QP['maxDate']) }

    try {
        $Trend = @(Get-SessionFrequencyTrend @Params)
        return @{ StatusCode = 200; Body = @{ count = $Trend.Count; items = $Trend } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetNarrators {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{}

    if ($QP['minDate'])        { $Params.MinDate        = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate'])        { $Params.MaxDate        = [datetime]::Parse($QP['maxDate']) }
    if ($QP['minOccurrences']) { $Params.MinOccurrences = [int]$QP['minOccurrences'] }
    if ($QP['unresolvedOnly'] -eq 'true') { $Params.UnresolvedOnly = $true }

    try {
        $Report = @(Get-NarratorReport @Params)
        return @{ StatusCode = 200; Body = @{ count = $Report.Count; items = $Report } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetLocations {
    param([hashtable]$ApiContext)

    # Return entities of type Lokacja as a location reference dataset
    $Entities = @(Get-Entity -Quiet | Where-Object { $_.Type -eq 'Lokacja' })

    return (Invoke-ApiEntityListQuery -ApiContext $ApiContext -Entities $Entities)
}

function Invoke-ApiGetLocationGraph {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['minDate']) { $Params.MinDate = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate = [datetime]::Parse($QP['maxDate']) }
    if ($QP['includeMovementEdges'] -eq 'true') { $Params.IncludeMovementEdges = $true }

    try {
        $Graph = Get-LocationGraph @Params
        return @{ StatusCode = 200; Body = $Graph }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetPULog {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['minDate']) { $Params.MinDate = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate = [datetime]::Parse($QP['maxDate']) }

    try {
        $Log = @(Get-PUAssignmentLog @Params)
        return @{ StatusCode = 200; Body = @{ count = $Log.Count; items = $Log } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetNotifications {
    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{}

    if ($QP['target'])    { $Params.Target    = $QP['target'] }
    if ($QP['directive']) { $Params.Directive = $QP['directive'] }
    if ($QP['minDate'])   { $Params.MinDate   = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate'])   { $Params.MaxDate   = [datetime]::Parse($QP['maxDate']) }

    try {
        $Log = @(Get-NotificationLog @Params)
        return @{ StatusCode = 200; Body = @{ count = $Log.Count; items = $Log } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

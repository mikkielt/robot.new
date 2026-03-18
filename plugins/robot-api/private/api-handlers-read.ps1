<#
    .SYNOPSIS
    Read-only REST API handler functions for the robot-api plugin.

    .DESCRIPTION
    This file defines handler functions that are dot-sourced into each worker
    runspace at startup. Each handler accepts a [hashtable]$ApiContext with
    PathParams, QueryParams, Body, Method, Path, TokenName, and TokenScopes,
    and returns a hashtable with StatusCode, Body, and optionally IncludeLabels.

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
                Invoke-ApiGetPULog, Invoke-ApiGetNotifications,
                Invoke-ApiGetDeliveryLog
    Parsing:    Invoke-ApiParseLog, Invoke-ApiSessionPreview

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
    <#
        .SYNOPSIS
        Returns paginated entity list with RSQL query, sort, and fieldset support.
    #>

    param([hashtable]$ApiContext)

    $QP       = $ApiContext.QueryParams
    $ActiveOn = $QP['activeOn']
    $Params   = @{ Quiet = $true }
    if ($ActiveOn) { $Params.ActiveOn = [datetime]::Parse($ActiveOn) }

    $Entities = @(Get-Entity @Params)

    return (Invoke-ApiEntityListQuery -ApiContext $ApiContext -Entities $Entities)
}

function Invoke-ApiGetEntity {
    <#
        .SYNOPSIS
        Returns a single entity by name, with fuzzy resolution fallback.
    #>

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
    <#
        .SYNOPSIS
        Returns temporal changelog entries for a named entity.
    #>

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
    <#
        .SYNOPSIS
        Returns property diff for an entity between two dates.
    #>

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
    <#
        .SYNOPSIS
        Returns enriched entity state with session-derived overrides.
    #>

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
    <#
        .SYNOPSIS
        Returns all players with character rosters and PU data.
    #>

    param([hashtable]$ApiContext)

    $Players = @(Get-Player)
    return @{ StatusCode = 200; Body = @{ count = $Players.Count; items = $Players } }
}

function Invoke-ApiGetPlayer {
    <#
        .SYNOPSIS
        Returns a single player by name.
    #>

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
    <#
        .SYNOPSIS
        Returns sessions with optional date filtering and format labels.
    #>

    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{}

    if ($QP['minDate']) { $Params.MinDate = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate']) { $Params.MaxDate = [datetime]::Parse($QP['maxDate']) }
    if ($QP['includeContent'] -eq 'true') { $Params.IncludeContent = $true }

    $Sessions = @(Get-Session @Params)

    foreach ($S in $Sessions) {
        # Flatten NarratorResult (C# object) into a serializable hashtable.
        # ApiSerializer cannot reflect on arbitrary C# classes and falls back
        # to .ToString() which yields "Robot.NarratorResult".
        $NR = $S.Narrator
        if ($null -ne $NR -and $NR -is [Robot.NarratorResult]) {
            $NarratorNames = @()
            if ($NR.Narrators) {
                $NarratorNames = @($NR.Narrators | ForEach-Object { $_.Name })
            }
            $S | Add-Member -NotePropertyName 'Narrator' -NotePropertyValue @{
                narrators  = $NarratorNames
                rawText    = $NR.RawText
                confidence = $NR.Confidence
                isCouncil  = $NR.IsCouncil
            } -Force
        }

        # Inject format labels if requested
        if ($QP['labels'] -eq 'true') {
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
    <#
        .SYNOPSIS
        Returns session participation profile for a named entity.
    #>

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
    <#
        .SYNOPSIS
        Compares session participation overlap across multiple entities.
    #>

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
    <#
        .SYNOPSIS
        Returns top entities ranked by session participation count.
    #>

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
    <#
        .SYNOPSIS
        Returns currency holdings with optional owner/denomination filters.
    #>

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
    <#
        .SYNOPSIS
        Returns point-in-time economic analysis with Gini coefficients.
    #>

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
    <#
        .SYNOPSIS
        Returns monthly economic trends between two dates.
    #>

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
    <#
        .SYNOPSIS
        Returns currency transaction ledger entries.
    #>

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
    <#
        .SYNOPSIS
        Resolves a name query to an entity via exact, alias, and fuzzy matching.
    #>

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
    <#
        .SYNOPSIS
        Validates PU assignment consistency for a date range.
    #>

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
    <#
        .SYNOPSIS
        Runs currency reconciliation checks.
    #>

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
    <#
        .SYNOPSIS
        Runs session integrity checks with optional full mode.
    #>

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
    <#
        .SYNOPSIS
        Validates session graph index integrity.
    #>

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
    <#
        .SYNOPSIS
        Returns entity change audit log with optional filters.
    #>

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
    <#
        .SYNOPSIS
        Returns inactive entity report based on dormancy threshold.
    #>

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
    <#
        .SYNOPSIS
        Returns session frequency trend data.
    #>

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
    <#
        .SYNOPSIS
        Returns narrator statistics and resolution status.
    #>

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
    <#
        .SYNOPSIS
        Returns location entities via the standard query pipeline.
    #>

    param([hashtable]$ApiContext)

    # Return entities of type Lokacja as a location reference dataset
    $Entities = @(Get-Entity -Quiet | Where-Object { $_.Type -eq 'Lokacja' })

    return (Invoke-ApiEntityListQuery -ApiContext $ApiContext -Entities $Entities)
}

function Invoke-ApiGetLocationGraph {
    <#
        .SYNOPSIS
        Returns location containment and movement topology.
    #>

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
    <#
        .SYNOPSIS
        Returns PU assignment processing history.
    #>

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
    <#
        .SYNOPSIS
        Returns notification audit log entries.
    #>

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

function Invoke-ApiGetDeliveryLog {
    <#
        .SYNOPSIS
        Returns Discord webhook delivery history.
    #>

    param([hashtable]$ApiContext)

    $QP     = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }

    if ($QP['operation'])  { $Params.Operation  = [string]$QP['operation'] }
    if ($QP['recipient'])  { $Params.Recipient  = [string]$QP['recipient'] }
    if ($QP['failedOnly'] -eq 'true') { $Params.FailedOnly = $true }
    if ($QP['minDate'])    { $Params.MinDate    = [datetime]::Parse($QP['minDate']) }
    if ($QP['maxDate'])    { $Params.MaxDate    = [datetime]::Parse($QP['maxDate']) }

    try {
        $Log = @(Get-DiscordDeliveryLog @Params)
        return @{ StatusCode = 200; Body = @{ count = $Log.Count; deliveryLog = $Log } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# LOCATIONS (enriched)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiGetLocationList {
    <#
        .SYNOPSIS
        Returns enriched location list via Get-LocationEntity.
    #>

    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Params = @{ Quiet = $true }
    if ($QP['includeMaps'] -eq 'true') { $Params.IncludeMaps = $true }
    if ($QP['parent'])     { $Params.Parent = $QP['parent'] }
    if ($QP['name'])       { $Params.Name = $QP['name'] }
    if ($QP['hasDoors'] -eq 'true') { $Params.HasDoors = $true }
    if ($QP['isExterior'] -eq 'true') { $Params.IsExterior = $true }
    if ($QP['includeInactive'] -eq 'true') { $Params.IncludeInactive = $true }
    if ($QP['includeDeleted'] -eq 'true') { $Params.IncludeDeleted = $true }

    try {
        $Locations = @(Get-LocationEntity @Params)
        return @{ StatusCode = 200; Body = @{ count = $Locations.Count; items = $Locations } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetLocation {
    <#
        .SYNOPSIS
        Returns a single location with full enrichment.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    try {
        $Locations = @(Get-LocationEntity -Name $Name -IncludeMaps -Quiet)
        $Match = @($Locations.Where({ [string]::Equals($_.EntityName, $Name, 'OrdinalIgnoreCase') }))
        if ($Match.Count -eq 0) {
            return @{ StatusCode = 404; Body = @{ error = "Location '$Name' not found" } }
        }
        $Result = $Match[0]
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetLocationContents {
    <#
        .SYNOPSIS
        Returns entities located at a given location.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    try {
        $Contents = @(Resolve-Entity -Location $Name -Quiet)
        return @{ StatusCode = 200; Body = @{ count = $Contents.Count; items = $Contents } }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetMaps {
    <#
        .SYNOPSIS
        Returns all Mapa entities via the standard query pipeline.
    #>

    param([hashtable]$ApiContext)

    $Entities = @(@(Get-Entity -Quiet).Where({ $_.Type -eq 'Mapa' }))
    return (Invoke-ApiEntityListQuery -ApiContext $ApiContext -Entities $Entities)
}

# ═══════════════════════════════════════════════════════════════════════
# PARSING
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiFetchLogContent {
    <#
        .SYNOPSIS
        Fetches raw log content for the given URLs. Checks disk cache (res/logs/)
        first, falls back to HTTP fetch if sidecar is not found.
        Self-contained: uses only .NET methods and Get-RepoRoot (exported).
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $B = $ApiContext.Body
    if (-not $B -or -not $B.urls) {
        return @{ StatusCode = 400; Body = @{ error = 'urls array required' } }
    }

    $Urls = @($B.urls)
    if ($Urls.Count -eq 0) {
        return @{ StatusCode = 200; Body = @{ items = @() } }
    }

    # Build log directory from exported Get-RepoRoot (no module-private deps)
    $RepoRoot = Get-RepoRoot
    $LogDir = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'logs')

    # Inline URL normalization (mirrors log-fetchhelpers.ps1 logic)
    $PbPattern = [regex]'^https?://(?:www\.)?pastebin\.com/(?!raw/)([A-Za-z0-9]+)/?$'
    $PbRawPattern = [regex]'^https?://(?:www\.)?pastebin\.com/raw/([A-Za-z0-9]+)/?$'
    $UnsafeChars = [regex]'[^A-Za-z0-9]'

    $Items = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Url in $Urls) {
        $UrlStr = [string]$Url
        try {
            # Normalize URL
            $Norm = $UrlStr.Trim().TrimEnd('/')
            $M = $PbRawPattern.Match($Norm)
            if ($M.Success) {
                $Norm = "https://pastebin.com/raw/$($M.Groups[1].Value)"
            } else {
                $M = $PbPattern.Match($Norm)
                if ($M.Success) {
                    $Norm = "https://pastebin.com/raw/$($M.Groups[1].Value)"
                } elseif ($Norm.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Norm = 'https://' + $Norm.Substring(7)
                }
            }

            # Build cache filename (strip protocol, remove non-alnum)
            $FName = $Norm
            if ($FName.StartsWith('https://')) { $FName = $FName.Substring(8) }
            elseif ($FName.StartsWith('http://')) { $FName = $FName.Substring(7) }
            $FName = $UnsafeChars.Replace($FName, '')
            $FilePath = [System.IO.Path]::Combine($LogDir, $FName)

            $Content = $null

            # Try disk cache first
            if ([System.IO.File]::Exists($FilePath)) {
                $Content = [System.IO.File]::ReadAllText($FilePath)
            }
            # Also check local (non-HTTP) paths under .robot/
            elseif (-not $Norm.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                $LocalPath = [System.IO.Path]::Combine($RepoRoot, '.robot', $UrlStr)
                if ([System.IO.File]::Exists($LocalPath)) {
                    $Content = [System.IO.File]::ReadAllText($LocalPath)
                }
            }

            # Fall back to HTTP fetch if no cache hit
            if ($null -eq $Content -and $Norm.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                $FailedPath = "$FilePath.failed"
                if (-not [System.IO.File]::Exists($FailedPath)) {
                    $Client = [System.Net.Http.HttpClient]::new()
                    $Client.Timeout = [System.TimeSpan]::FromSeconds(15)
                    [void]$Client.DefaultRequestHeaders.Add('User-Agent', 'Robot-PowerShell/1.0')
                    try {
                        $Resp = $Client.GetAsync($Norm).GetAwaiter().GetResult()
                        if ($Resp.IsSuccessStatusCode) {
                            $Content = $Resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                            # Cache to disk
                            if (-not [System.IO.Directory]::Exists($LogDir)) {
                                [void][System.IO.Directory]::CreateDirectory($LogDir)
                            }
                            [System.IO.File]::WriteAllText($FilePath, $Content)
                        }
                    } finally {
                        $Client.Dispose()
                    }
                }
            }

            $Items.Add([PSCustomObject]@{
                url     = $UrlStr
                content = $Content
                error   = $null
            })
        } catch {
            $Items.Add([PSCustomObject]@{
                url     = $UrlStr
                content = $null
                error   = $_.Exception.Message
            })
        }
    }

    return @{ StatusCode = 200; Body = @{ items = [PSCustomObject[]]$Items.ToArray() } }
}

function Invoke-ApiParseLog {
    <#
        .SYNOPSIS
        Parses raw log text into structured data via ConvertFrom-LogContent.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $B = $ApiContext.Body
    if (-not $B -or -not $B.content) {
        return @{ StatusCode = 400; Body = @{ error = 'content field required' } }
    }

    try {
        $Result = ConvertFrom-LogContent -Content ([string]$B.content)
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiSessionPreview {
    <#
        .SYNOPSIS
        Generates a Gen4 session markdown preview with location name validation.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.title -or -not $B.narrator -or -not $B.date) {
        return @{ StatusCode = 400; Body = @{ error = 'title, narrator, and date are required' } }
    }

    try {
        $ParsedDate = [datetime]::Parse([string]$B.date)
    } catch {
        return @{ StatusCode = 400; Body = @{ error = "Invalid date format: $($B.date)" } }
    }

    $Params = @{
        Date     = $ParsedDate
        Title    = [string]$B.title
        Narrator = [string]$B.narrator
    }

    if ($B.dateEnd) {
        try { $Params.DateEnd = [datetime]::Parse([string]$B.dateEnd) }
        catch { return @{ StatusCode = 400; Body = @{ error = "Invalid dateEnd format: $($B.dateEnd)" } } }
    }
    if ($B.locations)         { $Params.Locations         = @($B.locations) }
    if ($B.metadataNarrators) { $Params.MetadataNarrators = @($B.metadataNarrators) }
    if ($B.logs)              { $Params.Logs              = @($B.logs) }
    if ($B.content)           { $Params.Content           = [string]$B.content }

    if ($B.pu) {
        $Params.PU = @($B.pu).ForEach({
            [PSCustomObject]@{ Character = [string]$_.character; Value = [decimal]$_.value }
        })
    }

    if ($B.changes) {
        $Params.Changes = @($B.changes).ForEach({
            [PSCustomObject]@{
                EntityName = [string]$_.entityName
                Tags = @($_.tags).ForEach({
                    [PSCustomObject]@{ Tag = [string]$_.tag; Value = [string]$_.value }
                })
            }
        })
    }

    if ($B.intel) {
        $Params.Intel = @($B.intel).ForEach({
            [PSCustomObject]@{ RawTarget = [string]$_.rawTarget; Message = [string]$_.message }
        })
    }

    try {
        $Markdown = New-Session @Params

        # Validate location names
        $Warnings = [System.Collections.Generic.List[string]]::new()
        $ResolvedLocations = @()
        if ($B.locations) {
            $ResolvedLocations = @($B.locations).ForEach({
                $R = Resolve-Name -Query ([string]$_) -OwnerType 'Lokacja' -NoFuzzy
                if (-not $R) {
                    [void]$Warnings.Add("Location not found: $_")
                    [PSCustomObject]@{ query = [string]$_; resolved = $null; found = $false }
                } else {
                    [PSCustomObject]@{ query = [string]$_; resolved = $R.Name; found = $true }
                }
            })
        }

        return @{
            StatusCode = 200
            Body = @{
                markdown          = $Markdown
                resolvedLocations = $ResolvedLocations
                warnings          = @($Warnings)
            }
        }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiGetFiles {
    <#
        .SYNOPSIS
        Returns .md file paths relative to the repository root for path autocomplete.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $Root = Get-RepoRoot
    $Files = [System.IO.Directory]::GetFiles($Root, '*.md', [System.IO.SearchOption]::AllDirectories)

    $RelPaths = [System.Collections.Generic.List[string]]::new()
    $RootLen = $Root.Length + 1  # +1 for trailing separator

    foreach ($F in $Files) {
        # Skip hidden directories (.robot.new, .git, etc.)
        $Rel = $F.Substring($RootLen).Replace('\', '/')
        if ($Rel.StartsWith('.')) { continue }
        [void]$RelPaths.Add($Rel)
    }

    $RelPaths.Sort()

    return @{
        StatusCode = 200
        Body = @{
            files = $RelPaths.ToArray()
            count = $RelPaths.Count
        }
    }
}

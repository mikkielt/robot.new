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
    Resolution: Invoke-ApiResolveName, Invoke-ApiResolveBatch
    Validation: Invoke-ApiValidatePU, Invoke-ApiValidateCurrency,
                Invoke-ApiValidateSessions, Invoke-ApiValidateGraph
    Locations:  Invoke-ApiGetLocationList, Invoke-ApiGetLocation,
                Invoke-ApiGetLocationContents, Invoke-ApiGetMaps
    Reports:    Invoke-ApiGetChangelog, Invoke-ApiGetDormancy,
                Invoke-ApiGetFrequency, Invoke-ApiGetNarrators,
                Invoke-ApiGetLocations, Invoke-ApiGetLocationGraph,
                Invoke-ApiGetPULog, Invoke-ApiGetNotifications,
                Invoke-ApiGetDeliveryLog
    Parsing:    Invoke-ApiFetchLogContent, Invoke-ApiParseLog,
                Invoke-ApiSessionPreview
    Files:      Invoke-ApiGetFiles, Invoke-ApiGetFilesTree

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
        @($Page.Items).ForEach({
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

    $Match = @($Entities.Where({
        [string]::Equals($_.Name, $Name, 'OrdinalIgnoreCase') -or
        [string]::Equals($_.CN, $Name, 'OrdinalIgnoreCase')
    }))

    if ($Match.Count -eq 0) {
        $Resolved = Resolve-Name -Query $Name
        if ($Resolved) {
            $Match = @($Entities.Where({ $_.Name -eq $Resolved.Name }))
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
                $NarratorNames = @($NR.Narrators.ForEach('Name'))
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

    $Result = Resolve-Name -Query $Name
    if (-not $Result) {
        return @{ StatusCode = 404; Body = @{ error = "Could not resolve: $Name" } }
    }

    return @{ StatusCode = 200; Body = $Result }
}

function Invoke-ApiResolveBatch {
    <#
        .SYNOPSIS
        Resolves multiple name queries with scope-gated enrichment.
    #>

    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B -or -not $B.names) {
        return @{ StatusCode = 400; Body = @{ error = 'names array required' } }
    }
    $Names = @($B.names)
    if ($Names.Count -eq 0 -or $Names.Count -gt 100) {
        return @{ StatusCode = 400; Body = @{ error = 'names must contain 1-100 entries' } }
    }

    $Scopes = @($ApiContext.TokenScopes)
    $HasSessionRead = 'session:read' -in $Scopes
    $HasAdminRead   = 'admin:read'   -in $Scopes

    # Parse optional temporal context (session date for alias filtering)
    $ActiveOn = $null
    if ($B.activeOn) {
        try { $ActiveOn = [datetime]::Parse($B.activeOn) } catch {}
    }

    # Stage 1: Resolve all names (shared cache avoids repeated index rebuild)
    $ResolveCache = @{}
    $ResolveParams = @{ Cache = $ResolveCache }

    # When activeOn is provided, build a date-filtered name index so only
    # temporally-valid aliases are resolvable (e.g. expired aliases won't match)
    if ($ActiveOn) {
        $FilteredEntities = Get-Entity -ActiveOn $ActiveOn -Quiet
        $FilteredPlayers  = Get-Player
        $Idx = Get-NameIndex -Entities $FilteredEntities -Players $FilteredPlayers
        $ResolveParams.Index     = $Idx.Index
        $ResolveParams.StemIndex = $Idx.StemIndex
        $ResolveParams.BKTree    = $Idx.BKTree
    }

    $Resolved = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Track match stage: try NoFuzzy first (stages 1/2/2b = declension),
    # then full resolve (stage 3 = fuzzy). Exposed as matchStage in response.
    $MatchStages = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Separate cache for NoFuzzy to avoid negative caching blocking full resolve
    $NoFuzzyCache = @{}

    foreach ($Name in $Names) {
        $Key = [string]$Name
        $NoFuzzyResult = Resolve-Name -Query $Key @ResolveParams -NoFuzzy -Cache $NoFuzzyCache
        if ($NoFuzzyResult) {
            $Resolved[$Key] = $NoFuzzyResult
            # Stage 1 = exact, Stage 2 = declension — both are "confirmed" matches
            $MatchStages[$Key] = 2
        } else {
            # Resolve-Name stems the entire query as a unit, so multi-word inflected forms
            # (e.g. "Alabastrowego Hotelu") miss — stem each word independently to produce
            # a recombined form ("Alabastrow Hotel") that can match via the stem index
            $Words = $Key.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            $PerWordResult = $null
            if ($Words.Count -gt 1) {
                $Stemmed = ($Words.ForEach({ Get-DeclensionStem -Text $_ })) -join ' '
                if ($Stemmed -ne $Key) {
                    $PerWordResult = Resolve-Name -Query $Stemmed @ResolveParams
                }
            }
            if ($PerWordResult) {
                $Resolved[$Key] = $PerWordResult
                $MatchStages[$Key] = 2
            } else {
                $Result = Resolve-Name -Query $Key @ResolveParams -TopN 5
                $Resolved[$Key] = $Result
                $MatchStages[$Key] = if ($Result) { 3 } else { 0 }
            }
        }
    }

    # Stage 2: Load session graph index once for activity enrichment (scope-gated)
    $GraphStats = $null
    if ($HasSessionRead) {
        $GraphStats = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        try {
            $Config = Get-AdminConfig
            $IndexPath = [System.IO.Path]::Combine($Config.ResDir, 'session-graph', '_index.json')

            if ([System.IO.File]::Exists($IndexPath)) {
                $Index = Read-SessionGraphIndex -IndexPath $IndexPath

                # Single-pass scan: accumulate stats for all resolved names
                $ResolvedNames = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($R in $Resolved.Values) {
                    if ($R) { [void]$ResolvedNames.Add($R.Name) }
                }

                foreach ($Header in $Index.Keys) {
                    $Entry = $Index[$Header]
                    if (-not $Entry.ContainsKey('Participants') -or -not $Entry['Participants']) { continue }
                    $EntryDate = if ($Entry.ContainsKey('Date')) { $Entry['Date'] } else { $null }

                    foreach ($P in $Entry['Participants']) {
                        $PName = if ($P.ContainsKey('Name')) { $P['Name'] } else { $null }
                        if (-not $PName -or -not $ResolvedNames.Contains($PName)) { continue }

                        $PTier = if ($P.ContainsKey('Tier')) { [int]$P['Tier'] } else { 2 }
                        $PWeight = if ($P.ContainsKey('Weight')) { $P['Weight'] } else { $null }

                        if (-not $GraphStats.ContainsKey($PName)) {
                            $GraphStats[$PName] = @{
                                Sessions   = 0
                                LastActive = $null
                                Tier0      = 0; Tier1 = 0; Tier2 = 0
                                PUWeight   = 0.0
                                CoParts    = [System.Collections.Generic.Dictionary[string, int]]::new(
                                    [System.StringComparer]::OrdinalIgnoreCase)
                            }
                        }
                        $S = $GraphStats[$PName]
                        $S.Sessions++
                        $TierKey = "Tier$PTier"
                        if ($S.ContainsKey($TierKey)) { $S[$TierKey]++ }
                        if ($null -ne $PWeight) { $S.PUWeight += $PWeight }
                        if ($EntryDate -and (-not $S.LastActive -or $EntryDate -gt $S.LastActive)) {
                            $S.LastActive = $EntryDate
                        }

                        # Co-participants from same session (for admin enrichment)
                        if ($HasAdminRead) {
                            foreach ($CP in $Entry['Participants']) {
                                $CPName = if ($CP.ContainsKey('Name')) { $CP['Name'] } else { $null }
                                if (-not $CPName -or [string]::Equals($CPName, $PName, 'OrdinalIgnoreCase')) { continue }
                                if ($S.CoParts.ContainsKey($CPName)) { $S.CoParts[$CPName]++ }
                                else { $S.CoParts[$CPName] = 1 }
                            }
                        }
                    }
                }
            }
        } catch {
            # Non-fatal: return results without graph enrichment
            $GraphStats = $null
        }
    }

    # Stage 3: Build response objects with scope-gated fields
    $Results = @{}
    foreach ($KV in $Resolved.GetEnumerator()) {
        $Key = $KV.Key
        $R  = $KV.Value

        if (-not $R) { $Results[$Key] = $null; continue }

        # Base: always included (entity:read)
        $Stage = if ($MatchStages.ContainsKey($Key)) { $MatchStages[$Key] } else { 0 }
        $Entry = @{
            name       = $R.Name
            type       = if ($R.PSObject.Properties['Type']) { $R.Type } else { $null }
            status     = if ($R.PSObject.Properties['Status']) { $R.Status } else { 'Aktywny' }
            aliases    = @(if ($R.PSObject.Properties['Names']) { @($R.Names.Where({ -not [string]::Equals($_, $R.Name, 'OrdinalIgnoreCase') }).ForEach({ [string]$_ })) } else { @() })
            cn         = if ($R.PSObject.Properties['CN']) {
                if ($R.PSObject.Properties['Characters']) {
                    $MatchedChar = $R.Characters.Where({
                        [string]::Equals($_.Name, $Key, 'OrdinalIgnoreCase') -or
                        ($_.Aliases -and $_.Aliases.Where({ [string]::Equals($_, $Key, 'OrdinalIgnoreCase') }, 'First').Count -gt 0)
                    }, 'First')
                    if ($MatchedChar.Count -gt 0) { $MatchedChar[0].CN } else { $R.CN }
                } else { $R.CN }
            } elseif ($R.PSObject.Properties['Type'] -and $R.Name) {
                "$($R.Type)/$($R.Name)"
            } else { $null }
            matchStage = $Stage
            filePath   = if ($R.PSObject.Properties['FilePath']) { $R.FilePath }
                         elseif ($R.PSObject.Properties['Characters']) {
                             $MC = $R.Characters.Where({
                                 [string]::Equals($_.Name, $Key, 'OrdinalIgnoreCase') -or
                                 ($_.Aliases -and $_.Aliases.Where({ [string]::Equals($_, $Key, 'OrdinalIgnoreCase') }, 'First').Count -gt 0)
                             }, 'First')
                             if ($MC.Count -gt 0 -and $MC[0].PSObject.Properties['Path']) { $MC[0].Path } else { $null }
                         } else { $null }
        }

        if ($Stage -eq 3 -and $R.PSObject.Properties['Candidates']) {
            $Entry.candidates = @($R.Candidates.ForEach({
                @{ name = $_.Name; distance = $_.Distance }
            }))
        }

        # Enrichment: session:read scope
        if ($HasSessionRead -and $GraphStats -and $GraphStats.ContainsKey($R.Name)) {
            $GS = $GraphStats[$R.Name]
            $Entry.sessions   = $GS.Sessions
            $Entry.lastActive = $GS.LastActive
            $Entry.tiers      = @{ '0' = $GS.Tier0; '1' = $GS.Tier1; '2' = $GS.Tier2 }
        }

        # Enrichment: admin:read scope (PU weight + top 3 co-participants)
        if ($HasAdminRead -and $GraphStats -and $GraphStats.ContainsKey($R.Name)) {
            $GS = $GraphStats[$R.Name]
            $Entry.puWeight = [math]::Round($GS.PUWeight, 2)
            $CoPartArr = @($GS.CoParts.GetEnumerator())
            $Sorted = [System.Linq.Enumerable]::OrderByDescending(
                [object[]]$CoPartArr, [Func[object,int]]{ param($X) $X.Value })
            $Top3 = [System.Linq.Enumerable]::Take($Sorted, 3)
            $TopCoParts = @([System.Linq.Enumerable]::ToArray($Top3)).ForEach({ $_.Key })
            $Entry.coParticipants = $TopCoParts
        }

        $Results[$Key] = $Entry
    }

    return @{ StatusCode = 200; Body = @{ results = $Results } }
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
    $Entities = @(@(Get-Entity -Quiet).Where({ $_.Type -eq 'Lokacja' }))

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
    $LogDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res', 'logs')

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

            # Try direct relative path from repo root (e.g. res/logs/filename)
            if (-not $Norm.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                $DirectPath = [System.IO.Path]::Combine($RepoRoot, $UrlStr)
                if ([System.IO.File]::Exists($DirectPath)) {
                    $Content = [System.IO.File]::ReadAllText($DirectPath)
                }
            }

            # Try disk cache first
            if ($null -eq $Content -and [System.IO.File]::Exists($FilePath)) {
                $Content = [System.IO.File]::ReadAllText($FilePath)
            }
            # Also check local (non-HTTP) paths under .robot.local/
            if ($null -eq $Content -and -not $Norm.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                $LocalPath = [System.IO.Path]::Combine($RepoRoot, '.robot.local', $UrlStr)
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
        # Skip hidden directories (.robot.powershell, .git, etc.)
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

function Invoke-ApiGetFilesTree {
    <#
        .SYNOPSIS
        Returns .md file paths as a directory tree structure for path navigation.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $Root = Get-RepoRoot
    $Files = [System.IO.Directory]::GetFiles($Root, '*.md', [System.IO.SearchOption]::AllDirectories)
    $RootLen = $Root.Length + 1

    # Build tree as nested hashtables
    $Tree = @{ name = '/'; type = 'dir'; children = [System.Collections.Generic.List[object]]::new() }
    $DirLookup = @{ '' = $Tree }

    foreach ($F in $Files) {
        $Rel = $F.Substring($RootLen).Replace('\', '/')
        if ($Rel.StartsWith('.')) { continue }

        $Parts = $Rel.Split('/')
        $DirPath = ''

        # Ensure all parent directories exist in the tree
        for ($I = 0; $I -lt $Parts.Count - 1; $I++) {
            $ParentPath = $DirPath
            $DirPath = if ($DirPath.Length -eq 0) { $Parts[$I] } else { "$DirPath/$($Parts[$I])" }

            if (-not $DirLookup.ContainsKey($DirPath)) {
                $DirNode = @{
                    name     = $Parts[$I]
                    type     = 'dir'
                    children = [System.Collections.Generic.List[object]]::new()
                }
                $DirLookup[$ParentPath].children.Add($DirNode)
                $DirLookup[$DirPath] = $DirNode
            }
        }

        # Add file leaf
        $ParentDir = if ($Parts.Count -gt 1) {
            [string]::Join('/', $Parts[0..($Parts.Count - 2)])
        } else { '' }

        $DirLookup[$ParentDir].children.Add(@{
            name = $Parts[$Parts.Count - 1]
            type = 'file'
            path = $Rel
        })
    }

    return @{
        StatusCode = 200
        Body       = $Tree
    }
}

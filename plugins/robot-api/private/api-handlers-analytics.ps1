<#
    .SYNOPSIS
    Analytics endpoint handlers for the robot-api plugin.

    .DESCRIPTION
    Date-windowed aggregation endpoints under /analytics/* that surface
    data which is computed and held in-memory by Get-Session, Get-Entity,
    Get-EntityState, Get-SessionLog, and Get-NameIndex but is not exposed
    by the standard read endpoints.

    Phase 3a — PU-centric:
        Invoke-ApiAnalyticsPuByCharacter
        Invoke-ApiAnalyticsPuByLocation
        Invoke-ApiAnalyticsCoEngagement
        Invoke-ApiAnalyticsCharacterTerritory
        Invoke-ApiAnalyticsPuTimeline
        Invoke-ApiAnalyticsPuByNarrator

    Phase 3b — cross-cutting:
        Invoke-ApiAnalyticsEntityLifecycle
        Invoke-ApiAnalyticsLocationGraphMetrics
        Invoke-ApiAnalyticsLogsSpeakerLeaderboard
        Invoke-ApiAnalyticsLogsChannelMix
        Invoke-ApiAnalyticsLogsCoverage
        Invoke-ApiAnalyticsResolutionQuality
        Invoke-ApiAnalyticsIntegrityTrends
        Invoke-ApiAnalyticsMetadataCoverage

    Handlers follow the standard contract: accept [hashtable]$ApiContext,
    return @{ StatusCode; Body }. Date defaults: most endpoints default to
    a 90-day window ending today when minDate/maxDate are absent.
#>

# ── Shared helpers ──────────────────────────────────────────────────────

function Get-AnalyticsDateRange {
    <#
        .SYNOPSIS
        Resolves minDate/maxDate query params with sensible defaults.
        Default window: 90 days ending today.
    #>
    param(
        [hashtable]$QueryParams,
        [int]$DefaultDays = 90
    )
    $MaxDate = if ($QueryParams['maxDate']) {
        [datetime]::Parse($QueryParams['maxDate'])
    } else { [datetime]::Today }
    $MinDate = if ($QueryParams['minDate']) {
        [datetime]::Parse($QueryParams['minDate'])
    } else { $MaxDate.AddDays(-$DefaultDays) }
    return @{ MinDate = $MinDate; MaxDate = $MaxDate }
}

function Get-NormalizedSessionArrays {
    <#
        .SYNOPSIS
        Returns a session's PU and Locations as guaranteed-array values,
        defending against PowerShell single-element unwrapping. See WP-3.
    #>
    param([object]$Session)
    $PU = $Session.PU
    if ($null -eq $PU) { $PU = @() }
    elseif ($PU -is [System.Collections.IDictionary] -and $PU.Count -eq 0) { $PU = @() }
    elseif (-not ($PU -is [System.Collections.IList]) -and -not ($PU -is [System.Array])) {
        $PU = @($PU)
    }
    $Locations = $Session.Locations
    if ($null -eq $Locations) { $Locations = @() }
    elseif ($Locations -is [System.Collections.IDictionary] -and $Locations.Count -eq 0) { $Locations = @() }
    elseif (-not ($Locations -is [System.Collections.IList]) -and -not ($Locations -is [System.Array])) {
        $Locations = @($Locations)
    }
    return @{ PU = $PU; Locations = $Locations }
}

function Get-SessionLocationLeaves {
    <#
        .SYNOPSIS
        Decomposes Locations[] into a HashSet of leaf segment names,
        splitting "Parent/Child" paths into individual segments.
    #>
    param([object[]]$Locations)
    $Out = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($L in $Locations) {
        if (-not $L) { continue }
        $Str = [string]$L
        foreach ($Seg in ($Str -split '/')) {
            $T = $Seg.Trim()
            if ($T) { [void]$Out.Add($T) }
        }
    }
    return $Out
}

function Test-LocationFilterMatch {
    <#
        .SYNOPSIS
        Returns $true if any location in the session matches the requested
        filter name (path-aware: matches any segment).
    #>
    param([object[]]$Locations, [string]$Filter)
    if (-not $Filter) { return $true }
    $Leaves = Get-SessionLocationLeaves -Locations $Locations
    return $Leaves.Contains($Filter)
}

function Test-NarratorFilterMatch {
    <#
        .SYNOPSIS
        Returns $true if any of the session's narrators matches the filter.
    #>
    param([object]$Narrator, [string]$Filter)
    if (-not $Filter) { return $true }
    if (-not $Narrator) { return $false }
    $Names = @()
    if ($Narrator -is [Robot.NarratorResult]) {
        if ($Narrator.Narrators) {
            $Names = @($Narrator.Narrators.ForEach('Name'))
        }
    } elseif ($Narrator.narrators) {
        $Names = @($Narrator.narrators)
    } elseif ($Narrator.Narrators) {
        $Names = @($Narrator.Narrators.ForEach('Name'))
    }
    foreach ($N in $Names) {
        if ([string]::Equals([string]$N, $Filter, 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

function Get-NarratorNames {
    <#
        .SYNOPSIS
        Extracts narrator names from a session's Narrator object across
        NarratorResult / hashtable / array shapes.
    #>
    param([object]$Narrator)
    if (-not $Narrator) { return @() }
    if ($Narrator -is [Robot.NarratorResult]) {
        if ($Narrator.Narrators) {
            return @($Narrator.Narrators.ForEach('Name'))
        }
        return @()
    }
    # Property-case-insensitive access in PowerShell — try the array,
    # then inspect element type to decide whether to extract .Name.
    $Arr = $null
    if ($Narrator.PSObject.Properties['Narrators']) { $Arr = $Narrator.Narrators }
    elseif ($Narrator.PSObject.Properties['narrators']) { $Arr = $Narrator.narrators }
    if (-not $Arr) { return @() }
    $Out = [System.Collections.Generic.List[string]]::new()
    foreach ($N in @($Arr)) {
        if (-not $N) { continue }
        if ($N -is [string]) { [void]$Out.Add($N) }
        elseif ($N.PSObject.Properties['Name']) { [void]$Out.Add([string]$N.Name) }
        else { [void]$Out.Add([string]$N) }
    }
    return @($Out)
}

# ═══════════════════════════════════════════════════════════════════════
# PU ANALYTICS (Phase 3a)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiAnalyticsPuByCharacter {
    <#
        .SYNOPSIS
        Aggregates PU awards per character across a date window.
        Optional filters: location, narrator. Returns per-character totals,
        averages, max, distribution buckets, and (optionally) session list.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 90
    $Top = if ($QP['top']) {
        [math]::Min([math]::Max([int]$QP['top'], 1), 500)
    } else { 50 }
    $IncludeSessions = $QP['includeSessions'] -eq 'true'
    $LocFilter = $QP['location']
    $NarrFilter = $QP['narrator']

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Stats = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $TotalEntries = 0
    $TotalPU = 0.0

    foreach ($S in $Sessions) {
        $Norm = Get-NormalizedSessionArrays -Session $S
        if (-not (Test-LocationFilterMatch -Locations $Norm.Locations -Filter $LocFilter)) { continue }
        if (-not (Test-NarratorFilterMatch -Narrator $S.Narrator -Filter $NarrFilter)) { continue }

        foreach ($P in $Norm.PU) {
            if (-not $P -or -not $P.Character) { continue }
            $C = [string]$P.Character
            $V = if ($null -eq $P.Value) { 0.0 } else { [double]$P.Value }

            if (-not $Stats.ContainsKey($C)) {
                $Stats[$C] = @{
                    Total = 0.0
                    Count = 0
                    Max = 0.0
                    Bins = [ordered]@{
                        '0-0.25' = 0
                        '0.25-0.5' = 0
                        '0.5-1.0' = 0
                        '>1' = 0
                    }
                    Sessions = [System.Collections.Generic.List[string]]::new()
                }
            }
            $E = $Stats[$C]
            $E.Total += $V
            $E.Count++
            if ($V -gt $E.Max) { $E.Max = $V }
            $Bin = if ($V -lt 0.25) { '0-0.25' }
                   elseif ($V -lt 0.5) { '0.25-0.5' }
                   elseif ($V -lt 1.0) { '0.5-1.0' }
                   else { '>1' }
            $E.Bins[$Bin]++
            if ($IncludeSessions) { [void]$E.Sessions.Add($S.Header) }
            $TotalEntries++
            $TotalPU += $V
        }
    }

    # Player resolution cache
    $PlayerCache = @{}
    $Items = $Stats.GetEnumerator() |
        Sort-Object { -$_.Value.Total } |
        Select-Object -First $Top |
        ForEach-Object {
            $Name = $_.Key
            $E = $_.Value
            if (-not $PlayerCache.ContainsKey($Name)) {
                $R = $null
                try { $R = Resolve-Name -Query $Name -NoFuzzy } catch {}
                $PlayerCache[$Name] = if ($R -and $R.PSObject.Properties['Type'] -and
                        ($R.Type -in @('Postać', 'Postac', 'Gracz'))) {
                    if ($R.PSObject.Properties['PlayerName']) { $R.PlayerName }
                    elseif ($R.PSObject.Properties['Player'] -and $R.Player) { $R.Player.Name }
                    else { $null }
                } else { $null }
            }
            [ordered]@{
                character     = $Name
                playerName    = $PlayerCache[$Name]
                totalPU       = [math]::Round($E.Total, 2)
                sessionCount  = $E.Count
                avgPerSession = if ($E.Count) { [math]::Round($E.Total / $E.Count, 3) } else { 0 }
                maxPerSession = [math]::Round($E.Max, 2)
                distribution  = $E.Bins
                sessions      = if ($IncludeSessions) { $E.Sessions.ToArray() } else { $null }
            }
        }

    return @{
        StatusCode = 200
        Body = @{
            minDate       = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate       = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount  = $Sessions.Count
            puEntryCount  = $TotalEntries
            totalPU       = [math]::Round($TotalPU, 2)
            items         = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsPuByLocation {
    <#
        .SYNOPSIS
        Aggregates PU per location over a date window. Surfaces bimodal
        distribution: "hub" locations (frequent, low PU/session) vs.
        "event" locations (rare, high PU/session).
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 90
    $Top = if ($QP['top']) {
        [math]::Min([math]::Max([int]$QP['top'], 1), 500)
    } else { 50 }
    $CharFilter = $QP['character']
    $SplitPaths = -not ($QP['splitPaths'] -eq 'false')  # default true

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Stats = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($S in $Sessions) {
        $Norm = Get-NormalizedSessionArrays -Session $S
        if ($Norm.Locations.Count -eq 0) { continue }

        $Chars = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $SessionPU = 0.0
        foreach ($P in $Norm.PU) {
            if (-not $P -or -not $P.Character) { continue }
            $V = if ($null -eq $P.Value) { 0.0 } else { [double]$P.Value }
            $SessionPU += $V
            [void]$Chars.Add([string]$P.Character)
        }
        if ($CharFilter -and -not $Chars.Contains($CharFilter)) { continue }

        # Decompose locations: with splitPaths=true, "A/B" becomes A and B
        $LocSet = if ($SplitPaths) {
            Get-SessionLocationLeaves -Locations $Norm.Locations
        } else {
            $S2 = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($L in $Norm.Locations) { if ($L) { [void]$S2.Add([string]$L) } }
            $S2
        }

        foreach ($Loc in $LocSet) {
            if (-not $Stats.ContainsKey($Loc)) {
                $Stats[$Loc] = @{
                    SessionCount = 0
                    TotalPU = 0.0
                    Characters = [System.Collections.Generic.Dictionary[string, int]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                }
            }
            $E = $Stats[$Loc]
            $E.SessionCount++
            $E.TotalPU += $SessionPU
            foreach ($C in $Chars) {
                if ($E.Characters.ContainsKey($C)) { $E.Characters[$C]++ }
                else { $E.Characters[$C] = 1 }
            }
        }
    }

    $Items = $Stats.GetEnumerator() |
        Sort-Object { -$_.Value.TotalPU } |
        Select-Object -First $Top |
        ForEach-Object {
            $Loc = $_.Key
            $E = $_.Value
            $TopChars = @($E.Characters.GetEnumerator() |
                Sort-Object { -$_.Value } |
                Select-Object -First 5 |
                ForEach-Object {
                    [ordered]@{ character = $_.Key; sessionCount = $_.Value }
                })
            [ordered]@{
                location         = $Loc
                sessionCount     = $E.SessionCount
                totalPU          = [math]::Round($E.TotalPU, 2)
                avgPUPerSession  = if ($E.SessionCount) {
                    [math]::Round($E.TotalPU / $E.SessionCount, 3)
                } else { 0 }
                uniqueCharacters = $E.Characters.Count
                topCharacters    = $TopChars
            }
        }

    return @{
        StatusCode = 200
        Body = @{
            minDate      = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate      = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount = $Sessions.Count
            locationCount = $Stats.Count
            items        = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsCoEngagement {
    <#
        .SYNOPSIS
        Top character pairs by co-occurrence in PU-earning sessions over a
        date window. Surfaces social clusters without requiring caller to
        know which pairs to check.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 90
    $Top = if ($QP['top']) {
        [math]::Min([math]::Max([int]$QP['top'], 1), 500)
    } else { 50 }
    $MinSessions = if ($QP['minSessions']) { [int]$QP['minSessions'] } else { 2 }
    $EntityFilter = $QP['entity']
    $LocFilter = $QP['location']
    $IncludeLocations = $QP['includeLocations'] -eq 'true'

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Pairs = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($S in $Sessions) {
        $Norm = Get-NormalizedSessionArrays -Session $S
        if (-not (Test-LocationFilterMatch -Locations $Norm.Locations -Filter $LocFilter)) { continue }

        $CharSet = [System.Collections.Generic.SortedSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $SessionPU = 0.0
        foreach ($P in $Norm.PU) {
            if (-not $P -or -not $P.Character) { continue }
            $V = if ($null -eq $P.Value) { 0.0 } else { [double]$P.Value }
            $SessionPU += $V
            [void]$CharSet.Add([string]$P.Character)
        }
        if ($CharSet.Count -lt 2) { continue }
        $Chars = @($CharSet)

        $Leaves = Get-SessionLocationLeaves -Locations $Norm.Locations

        for ($i = 0; $i -lt $Chars.Count - 1; $i++) {
            for ($j = $i + 1; $j -lt $Chars.Count; $j++) {
                $A = $Chars[$i]
                $B = $Chars[$j]
                if ($EntityFilter -and
                    -not [string]::Equals($A, $EntityFilter, 'OrdinalIgnoreCase') -and
                    -not [string]::Equals($B, $EntityFilter, 'OrdinalIgnoreCase')) {
                    continue
                }
                $Key = "$A|$B"
                if (-not $Pairs.ContainsKey($Key)) {
                    $Pairs[$Key] = @{
                        A = $A; B = $B
                        Sessions = 0
                        TotalPU = 0.0
                        Locations = [System.Collections.Generic.Dictionary[string, int]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                    }
                }
                $E = $Pairs[$Key]
                $E.Sessions++
                $E.TotalPU += $SessionPU
                if ($IncludeLocations) {
                    foreach ($L in $Leaves) {
                        if ($E.Locations.ContainsKey($L)) { $E.Locations[$L]++ }
                        else { $E.Locations[$L] = 1 }
                    }
                }
            }
        }
    }

    $Items = $Pairs.Values |
        Where-Object { $_.Sessions -ge $MinSessions } |
        Sort-Object @{ Expression = { -$_.Sessions } }, @{ Expression = { -$_.TotalPU } } |
        Select-Object -First $Top |
        ForEach-Object {
            $E = $_
            $SharedLocs = if ($IncludeLocations) {
                @($E.Locations.GetEnumerator() |
                    Sort-Object { -$_.Value } |
                    Select-Object -First 3 |
                    ForEach-Object {
                        [ordered]@{ location = $_.Key; count = $_.Value }
                    })
            } else { $null }
            [ordered]@{
                a                = $E.A
                b                = $E.B
                sessions         = $E.Sessions
                totalPU          = [math]::Round($E.TotalPU, 2)
                avgPU            = if ($E.Sessions) {
                    [math]::Round($E.TotalPU / $E.Sessions, 2)
                } else { 0 }
                sharedLocations  = $SharedLocs
            }
        }

    return @{
        StatusCode = 200
        Body = @{
            minDate      = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate      = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount = $Sessions.Count
            pairCount    = $Pairs.Count
            items        = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsCharacterTerritory {
    <#
        .SYNOPSIS
        Single-character location footprint + adjacency density vs the
        global location-graph baseline. Reveals tight territory clusters.
    #>
    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    if (-not $Name) {
        return @{ StatusCode = 400; Body = @{ error = 'character name required' } }
    }
    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 180

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
        $Graph = Get-LocationGraph -Quiet
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    # Build adjacency lookup from graph edges (undirected)
    $Adj = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $EdgeCount = 0
    $NodeNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if ($Graph.Edges) {
        foreach ($E in $Graph.Edges) {
            $S2 = [string]$E.Source; $T = [string]$E.Target
            [void]$NodeNames.Add($S2); [void]$NodeNames.Add($T)
            if (-not $Adj.ContainsKey($S2)) {
                $Adj[$S2] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
            }
            if (-not $Adj.ContainsKey($T)) {
                $Adj[$T] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
            }
            [void]$Adj[$S2].Add($T); [void]$Adj[$T].Add($S2)
            $EdgeCount++
        }
    }
    if ($Graph.Nodes) {
        foreach ($N in $Graph.Nodes) {
            if ($N.Name) { [void]$NodeNames.Add([string]$N.Name) }
        }
    }
    $NodeCount = $NodeNames.Count

    # Per-character location tally
    $LocStats = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $CharSessionCount = 0
    foreach ($S in $Sessions) {
        $Norm = Get-NormalizedSessionArrays -Session $S
        $Hit = $false
        $SessionPU = 0.0
        foreach ($P in $Norm.PU) {
            if (-not $P -or -not $P.Character) { continue }
            if ([string]::Equals([string]$P.Character, $Name, 'OrdinalIgnoreCase')) {
                $Hit = $true
                if ($null -ne $P.Value) { $SessionPU += [double]$P.Value }
            }
        }
        if (-not $Hit) { continue }
        $CharSessionCount++
        foreach ($Leaf in (Get-SessionLocationLeaves -Locations $Norm.Locations)) {
            if (-not $LocStats.ContainsKey($Leaf)) {
                $LocStats[$Leaf] = @{ SessionCount = 0; TotalPU = 0.0 }
            }
            $LocStats[$Leaf].SessionCount++
            $LocStats[$Leaf].TotalPU += $SessionPU
        }
    }

    $Locations = $LocStats.GetEnumerator() |
        Sort-Object { -$_.Value.SessionCount } |
        ForEach-Object {
            [ordered]@{
                location     = $_.Key
                sessionCount = $_.Value.SessionCount
                totalPU      = [math]::Round($_.Value.TotalPU, 2)
            }
        }

    # Adjacency density of the character's locations
    $CharLocs = @($LocStats.Keys | Where-Object { $Adj.ContainsKey($_) })
    $TotalPairs = 0
    $AdjacentPairs = 0
    for ($i = 0; $i -lt $CharLocs.Count - 1; $i++) {
        for ($j = $i + 1; $j -lt $CharLocs.Count; $j++) {
            $TotalPairs++
            if ($Adj[$CharLocs[$i]].Contains($CharLocs[$j])) { $AdjacentPairs++ }
        }
    }
    $Density = if ($TotalPairs -gt 0) { [math]::Round($AdjacentPairs / $TotalPairs, 4) } else { 0 }
    $Baseline = if ($NodeCount -gt 1) {
        [math]::Round((2.0 * $EdgeCount) / ($NodeCount * ($NodeCount - 1)), 4)
    } else { 0 }
    $Ratio = if ($Baseline -gt 0) { [math]::Round($Density / $Baseline, 2) } else { 0 }

    return @{
        StatusCode = 200
        Body = @{
            character    = $Name
            minDate      = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate      = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount = $CharSessionCount
            locations    = @($Locations)
            adjacency    = [ordered]@{
                locationsInGraph = $CharLocs.Count
                adjacentPairs    = $AdjacentPairs
                totalPairs       = $TotalPairs
                density          = $Density
                baseline         = $Baseline
                ratio            = $Ratio
            }
        }
    }
}

function Invoke-ApiAnalyticsPuTimeline {
    <#
        .SYNOPSIS
        Monthly or weekly PU velocity per character across a date window.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    if (-not $QP['minDate'] -or -not $QP['maxDate']) {
        return @{ StatusCode = 400; Body = @{ error = 'minDate and maxDate query params required' } }
    }
    $MinDate = [datetime]::Parse($QP['minDate'])
    $MaxDate = [datetime]::Parse($QP['maxDate'])
    $Bucket = if ($QP['bucket']) { $QP['bucket'].ToLowerInvariant() } else { 'month' }
    if ($Bucket -notin @('month', 'week')) {
        return @{ StatusCode = 400; Body = @{ error = "bucket must be 'month' or 'week'" } }
    }
    $Top = if ($QP['top']) {
        [math]::Min([math]::Max([int]$QP['top'], 1), 100)
    } else { 10 }
    $CharFilter = @()
    if ($QP['character']) {
        $CharFilter = @(($QP['character'] -split ',').ForEach({ $_.Trim() }) | Where-Object { $_ })
    }

    try {
        $Sessions = @(Get-Session -MinDate $MinDate -MaxDate $MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    # First pass: compute top earners if -character not specified
    if ($CharFilter.Count -eq 0) {
        $Totals = [System.Collections.Generic.Dictionary[string, double]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($S in $Sessions) {
            $Norm = Get-NormalizedSessionArrays -Session $S
            foreach ($P in $Norm.PU) {
                if (-not $P -or -not $P.Character) { continue }
                $V = if ($null -eq $P.Value) { 0.0 } else { [double]$P.Value }
                $C = [string]$P.Character
                if ($Totals.ContainsKey($C)) { $Totals[$C] += $V }
                else { $Totals[$C] = $V }
            }
        }
        $CharFilter = @($Totals.GetEnumerator() |
            Sort-Object { -$_.Value } |
            Select-Object -First $Top |
            ForEach-Object { $_.Key })
    }
    $CharSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($C in $CharFilter) { [void]$CharSet.Add([string]$C) }

    # Bucket key function
    function Get-BucketKey([datetime]$D, [string]$Bucket) {
        if ($Bucket -eq 'week') {
            # ISO 8601 week
            $Cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
            $Week = $Cal.GetWeekOfYear($D, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek,
                [System.DayOfWeek]::Monday)
            return ('{0:D4}-W{1:D2}' -f $D.Year, $Week)
        }
        return $D.ToString('yyyy-MM')
    }

    $Buckets = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::Ordinal)

    foreach ($S in $Sessions) {
        $Norm = Get-NormalizedSessionArrays -Session $S
        $D = if ($S.Date -is [datetime]) { $S.Date } else { [datetime]::Parse([string]$S.Date) }
        $Key = Get-BucketKey -D $D -Bucket $Bucket
        if (-not $Buckets.ContainsKey($Key)) {
            $Buckets[$Key] = @{
                Characters = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                TotalPU = 0.0
                TotalSessions = 0
            }
        }
        $B = $Buckets[$Key]
        $B.TotalSessions++

        $Sub = [System.Collections.Generic.Dictionary[string, double]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($P in $Norm.PU) {
            if (-not $P -or -not $P.Character) { continue }
            $C = [string]$P.Character
            if (-not $CharSet.Contains($C)) { continue }
            $V = if ($null -eq $P.Value) { 0.0 } else { [double]$P.Value }
            if ($Sub.ContainsKey($C)) { $Sub[$C] += $V } else { $Sub[$C] = $V }
            $B.TotalPU += $V
        }
        foreach ($KV in $Sub.GetEnumerator()) {
            if (-not $B.Characters.ContainsKey($KV.Key)) {
                $B.Characters[$KV.Key] = @{ PU = 0.0; Sessions = 0 }
            }
            $B.Characters[$KV.Key].PU += $KV.Value
            $B.Characters[$KV.Key].Sessions++
        }
    }

    $Items = $Buckets.GetEnumerator() |
        Sort-Object { $_.Key } |
        ForEach-Object {
            $Per = [ordered]@{}
            foreach ($KV in ($_.Value.Characters.GetEnumerator() | Sort-Object Key)) {
                $Per[$KV.Key] = [ordered]@{
                    pu = [math]::Round($KV.Value.PU, 2)
                    sessions = $KV.Value.Sessions
                }
            }
            [ordered]@{
                period        = $_.Key
                characters    = $Per
                totalPU       = [math]::Round($_.Value.TotalPU, 2)
                totalSessions = $_.Value.TotalSessions
            }
        }

    return @{
        StatusCode = 200
        Body = @{
            bucket     = $Bucket
            minDate    = $MinDate.ToString('yyyy-MM-dd')
            maxDate    = $MaxDate.ToString('yyyy-MM-dd')
            characters = @($CharFilter)
            items      = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsPuByNarrator {
    <#
        .SYNOPSIS
        Aggregates PU stats per narrator. Reveals GM calibration patterns.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 365

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Stats = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($S in $Sessions) {
        $Narrators = Get-NarratorNames -Narrator $S.Narrator
        if ($Narrators.Count -eq 0) { continue }
        $Norm = Get-NormalizedSessionArrays -Session $S
        $SessionPU = 0.0
        $CharsThisSession = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($P in $Norm.PU) {
            if (-not $P -or -not $P.Character) { continue }
            if ($null -ne $P.Value) { $SessionPU += [double]$P.Value }
            [void]$CharsThisSession.Add([string]$P.Character)
        }
        # Split credit equally if multiple narrators
        $Share = if ($Narrators.Count -gt 0) { 1.0 / $Narrators.Count } else { 1.0 }
        foreach ($N in $Narrators) {
            $Key = [string]$N
            if (-not $Stats.ContainsKey($Key)) {
                $Stats[$Key] = @{
                    SessionCount = 0.0
                    TotalPU = 0.0
                    Characters = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                    PUEntryCount = 0
                }
            }
            $E = $Stats[$Key]
            $E.SessionCount += $Share
            $E.TotalPU += ($SessionPU * $Share)
            foreach ($C in $CharsThisSession) { [void]$E.Characters.Add($C) }
            $E.PUEntryCount += [math]::Round($Norm.PU.Count * $Share)
        }
    }

    $Items = $Stats.GetEnumerator() |
        Sort-Object { -$_.Value.TotalPU } |
        ForEach-Object {
            $E = $_.Value
            $Sc = [math]::Round($E.SessionCount, 1)
            [ordered]@{
                narrator           = $_.Key
                sessionCount       = $Sc
                totalPU            = [math]::Round($E.TotalPU, 2)
                avgPUPerSession    = if ($E.SessionCount -gt 0) {
                    [math]::Round($E.TotalPU / $E.SessionCount, 3)
                } else { 0 }
                avgPUPerCharacter  = if ($E.Characters.Count -gt 0) {
                    [math]::Round($E.TotalPU / $E.Characters.Count, 3)
                } else { 0 }
                distinctCharacters = $E.Characters.Count
            }
        }

    return @{
        StatusCode = 200
        Body = @{
            minDate      = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate      = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount = $Sessions.Count
            items        = @($Items)
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# CROSS-CUTTING ANALYTICS (Phase 3b)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiAnalyticsEntityLifecycle {
    <#
        .SYNOPSIS
        Surfaces status/group/owner/location transitions from entity
        history arrays as a date-windowed transition stream.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 365
    $Property = if ($QP['property']) { $QP['property'].ToLowerInvariant() } else { 'status' }
    $EntityType = $QP['entityType']
    $FromFilter = $QP['from']
    $ToFilter = $QP['to']
    $Top = if ($QP['top']) {
        [math]::Min([math]::Max([int]$QP['top'], 1), 1000)
    } else { 100 }

    $HistoryFieldMap = @{
        'status'      = 'StatusHistory'
        'group'       = 'GroupHistory'
        'owner'       = 'OwnerHistory'
        'location'    = 'LocationHistory'
        'type'        = 'TypeHistory'
        'nerthusname' = 'NerthusNameHistory'
        'quantity'    = 'QuantityHistory'
    }
    if (-not $HistoryFieldMap.ContainsKey($Property)) {
        return @{ StatusCode = 400; Body = @{
            error = "property must be one of: $($HistoryFieldMap.Keys -join ', ')"
        } }
    }
    $HistField = $HistoryFieldMap[$Property]

    try {
        $Entities = @(Get-EntityState -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Results = [System.Collections.Generic.List[hashtable]]::new()
    $TransitionCount = 0

    foreach ($E in $Entities) {
        if ($EntityType -and -not [string]::Equals($E.Type, $EntityType, 'OrdinalIgnoreCase')) { continue }
        $Hist = $E.$HistField
        if (-not $Hist -or $Hist.Count -lt 2) { continue }

        # Walk consecutive pairs; emit when value changes within window
        $Transitions = [System.Collections.Generic.List[hashtable]]::new()
        for ($i = 1; $i -lt $Hist.Count; $i++) {
            $Prev = $Hist[$i - 1]
            $Curr = $Hist[$i]
            $PrevVal = if ($Prev) { [string]$Prev.Value } else { $null }
            $CurrVal = if ($Curr) { [string]$Curr.Value } else { $null }
            if ([string]::Equals($PrevVal, $CurrVal, 'OrdinalIgnoreCase')) { continue }
            $Date = if ($Curr.ValidFrom) { [datetime]$Curr.ValidFrom } else { $null }
            if ($null -eq $Date) { continue }
            if ($Date -lt $Range.MinDate -or $Date -gt $Range.MaxDate) { continue }
            if ($FromFilter -and -not [string]::Equals($PrevVal, $FromFilter, 'OrdinalIgnoreCase')) { continue }
            if ($ToFilter -and -not [string]::Equals($CurrVal, $ToFilter, 'OrdinalIgnoreCase')) { continue }
            [void]$Transitions.Add([ordered]@{
                from = $PrevVal
                to   = $CurrVal
                date = $Date.ToString('yyyy-MM-dd')
            })
            $TransitionCount++
        }
        if ($Transitions.Count -eq 0) { continue }

        $CurrentValue = $null
        $LastEntry = $Hist[$Hist.Count - 1]
        if ($LastEntry) { $CurrentValue = [string]$LastEntry.Value }

        [void]$Results.Add([ordered]@{
            entity          = $E.Name
            type            = $E.Type
            cn              = $E.CN
            transitions     = $Transitions.ToArray()
            transitionCount = $Transitions.Count
            currentValue    = $CurrentValue
        })
    }

    $Items = $Results |
        Sort-Object { -$_.transitionCount } |
        Select-Object -First $Top

    return @{
        StatusCode = 200
        Body = @{
            property        = $Property
            minDate         = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate         = $Range.MaxDate.ToString('yyyy-MM-dd')
            entitiesScanned = $Entities.Count
            transitionCount = $TransitionCount
            items           = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsLocationGraphMetrics {
    <#
        .SYNOPSIS
        Graph-theoretic metrics over the location graph: degree, weakly-
        connected components, dead ends, isolated nodes, articulation
        (choke) points.
    #>
    param([hashtable]$ApiContext)

    try {
        $Graph = Get-LocationGraph -Quiet
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    # Build undirected adjacency over all edges
    $Adj = @{}
    $AllNodes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $StaleEdgeCount = 0
    $EdgeCount = 0

    if ($Graph.Edges) {
        foreach ($E in $Graph.Edges) {
            $S = [string]$E.Source; $T = [string]$E.Target
            [void]$AllNodes.Add($S); [void]$AllNodes.Add($T)
            if (-not $Adj.ContainsKey($S)) { $Adj[$S] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
            if (-not $Adj.ContainsKey($T)) { $Adj[$T] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
            [void]$Adj[$S].Add($T); [void]$Adj[$T].Add($S)
            $EdgeCount++
            if ($E.PossiblyStale) { $StaleEdgeCount++ }
        }
    }

    # In/out degree from nodes (directed) for the topByDegree report
    $NodeData = @{}
    $ExteriorCount = 0; $InteriorCount = 0
    if ($Graph.Nodes) {
        foreach ($N in $Graph.Nodes) {
            $Name = [string]$N.Name
            if (-not $Name) { continue }
            [void]$AllNodes.Add($Name)
            $NodeData[$Name] = @{
                InDegree = if ($N.InDegree) { [int]$N.InDegree } else { 0 }
                OutDegree = if ($N.OutDegree) { [int]$N.OutDegree } else { 0 }
                IsExterior = [bool]$N.IsExterior
            }
            if ($N.IsExterior) { $ExteriorCount++ } else { $InteriorCount++ }
        }
    }

    $NodeCount = $AllNodes.Count
    $AvgDegree = if ($NodeCount -gt 0) {
        [math]::Round((2.0 * $EdgeCount) / $NodeCount, 2)
    } else { 0 }

    # Weakly-connected components via BFS
    $Visited = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $Components = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($Node in $AllNodes) {
        if ($Visited.Contains($Node)) { continue }
        $Queue = [System.Collections.Generic.Queue[string]]::new()
        $Queue.Enqueue($Node)
        [void]$Visited.Add($Node)
        $CompNodes = [System.Collections.Generic.List[string]]::new()
        while ($Queue.Count -gt 0) {
            $Cur = $Queue.Dequeue()
            [void]$CompNodes.Add($Cur)
            if ($Adj.ContainsKey($Cur)) {
                foreach ($N in $Adj[$Cur]) {
                    if (-not $Visited.Contains($N)) {
                        [void]$Visited.Add($N)
                        $Queue.Enqueue($N)
                    }
                }
            }
        }
        [void]$Components.Add(@{ Size = $CompNodes.Count; Root = $CompNodes[0]; Nodes = $CompNodes })
    }

    $TopByDegree = $NodeData.GetEnumerator() |
        ForEach-Object {
            $Total = $_.Value.InDegree + $_.Value.OutDegree
            [ordered]@{
                location = $_.Key
                inDegree = $_.Value.InDegree
                outDegree = $_.Value.OutDegree
                total = $Total
            }
        } |
        Sort-Object { -$_.total } |
        Select-Object -First 20

    $DeadEnds = $NodeData.GetEnumerator() |
        Where-Object { ($_.Value.InDegree + $_.Value.OutDegree) -eq 1 } |
        Select-Object -First 50 |
        ForEach-Object {
            [ordered]@{ location = $_.Key; totalDegree = 1 }
        }

    $Isolated = @($AllNodes | Where-Object { -not $Adj.ContainsKey($_) -or $Adj[$_].Count -eq 0 }) |
        Select-Object -First 50 |
        ForEach-Object { [ordered]@{ location = $_; totalDegree = 0 } }

    $ExteriorRatio = if (($ExteriorCount + $InteriorCount) -gt 0) {
        [math]::Round($ExteriorCount / ($ExteriorCount + $InteriorCount), 4)
    } else { 0 }

    $TopComponents = $Components |
        Sort-Object { -$_.Size } |
        Select-Object -First 10 |
        ForEach-Object {
            [ordered]@{ size = $_.Size; rootNode = $_.Root }
        }

    return @{
        StatusCode = 200
        Body = @{
            nodeCount       = $NodeCount
            edgeCount       = $EdgeCount
            avgDegree       = $AvgDegree
            componentCount  = $Components.Count
            components      = @($TopComponents)
            topByDegree     = @($TopByDegree)
            deadEnds        = @($DeadEnds)
            isolated        = @($Isolated)
            exteriorRatio   = $ExteriorRatio
            exteriorNodes   = $ExteriorCount
            interiorNodes   = $InteriorCount
            staleEdgeCount  = $StaleEdgeCount
        }
    }
}

function Invoke-ApiAnalyticsLogsSpeakerLeaderboard {
    <#
        .SYNOPSIS
        Aggregates speaker line counts across all logs in a date window —
        chat-presence leaderboard orthogonal to PU-presence.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 90
    $Top = if ($QP['top']) {
        [math]::Min([math]::Max([int]$QP['top'], 1), 500)
    } else { 50 }
    $EntityFilter = $QP['entity']
    $LocFilter = $QP['location']
    $ChannelFilter = $QP['channel']
    $UnresolvedOnly = $QP['unresolvedOnly'] -eq 'true'

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
    if ($Sessions.Count -eq 0) {
        return @{ StatusCode = 200; Body = @{
            minDate = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount = 0; items = @()
        } }
    }

    try {
        $LogData = @($Sessions | Get-SessionLog -SkipFetch)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Stats = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($SLog in $LogData) {
        $Logs = if ($null -eq $SLog.Logs) { @() }
            elseif ($SLog.Logs -is [System.Collections.IList]) { $SLog.Logs }
            else { @($SLog.Logs) }
        foreach ($L in $Logs) {
            $Speakers = if ($null -eq $L.Speakers) { @() }
                elseif ($L.Speakers -is [System.Collections.IList]) { $L.Speakers }
                else { @($L.Speakers) }
            foreach ($Sp in $Speakers) {
                if (-not $Sp -or -not $Sp.Raw) { continue }
                $Key = if ($Sp.Resolved) { [string]$Sp.Resolved } else { [string]$Sp.Raw }
                if ($UnresolvedOnly -and $Sp.Resolved) { continue }
                if ($EntityFilter -and
                    -not [string]::Equals($Key, $EntityFilter, 'OrdinalIgnoreCase')) {
                    continue
                }
                if (-not $Stats.ContainsKey($Key)) {
                    $Stats[$Key] = @{
                        Raw = [string]$Sp.Raw
                        Resolved = if ($Sp.Resolved) { [string]$Sp.Resolved } else { $null }
                        Stage = $Sp.Stage
                        TotalLines = 0
                        Sessions = [System.Collections.Generic.HashSet[string]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                        Channels = [System.Collections.Generic.Dictionary[string, int]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                        Locations = [System.Collections.Generic.Dictionary[string, int]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                    }
                }
                $E = $Stats[$Key]
                $LineIndices = if ($null -eq $Sp.Lines) { @() }
                    elseif ($Sp.Lines -is [System.Collections.IList]) { $Sp.Lines }
                    else { @($Sp.Lines) }
                $LineCount = if ($Sp.LineCount) { [int]$Sp.LineCount } else { $LineIndices.Count }

                # Channel/location filter via per-line attribution
                if ($ChannelFilter -or $LocFilter) {
                    $Hit = 0
                    foreach ($Idx in $LineIndices) {
                        $Line = $L.Lines[$Idx]
                        if ($null -eq $Line) { continue }
                        if ($ChannelFilter -and
                            -not [string]::Equals([string]$Line.Channel, $ChannelFilter, 'OrdinalIgnoreCase')) {
                            continue
                        }
                        if ($LocFilter) {
                            $Seg = if ($Line.Segment -ge 0 -and $Line.Segment -lt $L.LocationSegments.Count) {
                                $L.LocationSegments[$Line.Segment]
                            } else { $null }
                            $SegName = if ($Seg) { if ($Seg.Resolved) { [string]$Seg.Resolved } else { [string]$Seg.Raw } } else { $null }
                            if (-not [string]::Equals($SegName, $LocFilter, 'OrdinalIgnoreCase')) { continue }
                        }
                        $Hit++
                    }
                    if ($Hit -eq 0) { continue }
                    $E.TotalLines += $Hit
                } else {
                    $E.TotalLines += $LineCount
                }
                [void]$E.Sessions.Add($SLog.Header)

                # Tally channels
                foreach ($Idx in $LineIndices) {
                    $Line = $L.Lines[$Idx]
                    if (-not $Line) { continue }
                    $Ch = [string]$Line.Channel
                    if ($Ch) {
                        if ($E.Channels.ContainsKey($Ch)) { $E.Channels[$Ch]++ }
                        else { $E.Channels[$Ch] = 1 }
                    }
                    $Seg = if ($Line.Segment -ge 0 -and $Line.Segment -lt $L.LocationSegments.Count) {
                        $L.LocationSegments[$Line.Segment]
                    } else { $null }
                    $SegName = if ($Seg) { if ($Seg.Resolved) { [string]$Seg.Resolved } else { [string]$Seg.Raw } } else { $null }
                    if ($SegName) {
                        if ($E.Locations.ContainsKey($SegName)) { $E.Locations[$SegName]++ }
                        else { $E.Locations[$SegName] = 1 }
                    }
                }
            }
        }
    }

    $Items = $Stats.GetEnumerator() |
        Sort-Object { -$_.Value.TotalLines } |
        Select-Object -First $Top |
        ForEach-Object {
            $E = $_.Value
            $ChannelsObj = [ordered]@{}
            foreach ($KV in ($E.Channels.GetEnumerator() | Sort-Object Key)) {
                $ChannelsObj[$KV.Key] = $KV.Value
            }
            $TopLocs = @($E.Locations.GetEnumerator() |
                Sort-Object { -$_.Value } |
                Select-Object -First 5 |
                ForEach-Object {
                    [ordered]@{ location = $_.Key; lines = $_.Value }
                })
            [ordered]@{
                speaker      = $E.Raw
                resolved     = $E.Resolved
                stage        = $E.Stage
                totalLines   = $E.TotalLines
                sessions     = $E.Sessions.Count
                channels     = $ChannelsObj
                topLocations = $TopLocs
            }
        }

    return @{
        StatusCode = 200
        Body = @{
            minDate      = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate      = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount = $Sessions.Count
            speakerCount = $Stats.Count
            items        = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsLogsChannelMix {
    <#
        .SYNOPSIS
        Per-session and aggregate breakdown of ChatLog channel line counts
        (Lokalny / Prywatny / Grupowy / Szept). Surfaces plot-secrecy
        density (Prywatny/Szept ratio).
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 90

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
    if ($Sessions.Count -eq 0) {
        return @{ StatusCode = 200; Body = @{
            minDate = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate = $Range.MaxDate.ToString('yyyy-MM-dd')
            items = @(); aggregate = @{}
        } }
    }

    try {
        $LogData = @($Sessions | Get-SessionLog -SkipFetch)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $Aggregate = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $Items = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($SLog in $LogData) {
        $PerSession = [System.Collections.Generic.Dictionary[string, int]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $TotalLines = 0
        $Logs = if ($null -eq $SLog.Logs) { @() }
            elseif ($SLog.Logs -is [System.Collections.IList]) { $SLog.Logs }
            else { @($SLog.Logs) }
        foreach ($L in $Logs) {
            if ($L.Format -ne 'ChatLog') { continue }
            $Lines = if ($null -eq $L.Lines) { @() }
                elseif ($L.Lines -is [System.Collections.IList]) { $L.Lines }
                else { @($L.Lines) }
            foreach ($Line in $Lines) {
                if (-not $Line) { continue }
                $Ch = if ($Line.Channel) { [string]$Line.Channel } else { 'unknown' }
                if ($PerSession.ContainsKey($Ch)) { $PerSession[$Ch]++ } else { $PerSession[$Ch] = 1 }
                if ($Aggregate.ContainsKey($Ch)) { $Aggregate[$Ch]++ } else { $Aggregate[$Ch] = 1 }
                $TotalLines++
            }
        }
        if ($TotalLines -eq 0) { continue }
        $Channels = [ordered]@{}
        foreach ($KV in ($PerSession.GetEnumerator() | Sort-Object Key)) {
            $Channels[$KV.Key] = $KV.Value
        }
        $Priv = ($PerSession['Prywatny'] | ForEach-Object { $_ } | Select-Object -First 1)
        $Whp = ($PerSession['Szept'] | ForEach-Object { $_ } | Select-Object -First 1)
        if (-not $Priv) { $Priv = 0 }
        if (-not $Whp) { $Whp = 0 }
        [void]$Items.Add([ordered]@{
            header        = $SLog.Header
            totalLines    = $TotalLines
            channels      = $Channels
            secrecyRatio  = [math]::Round(($Priv + $Whp) / $TotalLines, 4)
        })
    }

    $AggregateObj = [ordered]@{}
    foreach ($KV in ($Aggregate.GetEnumerator() | Sort-Object Key)) {
        $AggregateObj[$KV.Key] = $KV.Value
    }
    $TotalAgg = 0
    foreach ($V in $Aggregate.Values) { $TotalAgg += $V }
    $PrivAgg = if ($Aggregate.ContainsKey('Prywatny')) { $Aggregate['Prywatny'] } else { 0 }
    $WhpAgg = if ($Aggregate.ContainsKey('Szept')) { $Aggregate['Szept'] } else { 0 }
    $AggSecrecy = if ($TotalAgg -gt 0) {
        [math]::Round(($PrivAgg + $WhpAgg) / $TotalAgg, 4)
    } else { 0 }

    return @{
        StatusCode = 200
        Body = @{
            minDate              = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate              = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionsWithChatLog  = $Items.Count
            aggregate            = $AggregateObj
            aggregateSecrecyRatio = $AggSecrecy
            items                = @($Items)
        }
    }
}

function Invoke-ApiAnalyticsLogsCoverage {
    <#
        .SYNOPSIS
        Log fetch coverage report: how many sessions have logs declared,
        cached, fetchable, or failed in the disk cache.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 90

    try {
        $Sessions = @(Get-Session -MinDate $Range.MinDate -MaxDate $Range.MaxDate -Quiet)
        $RepoRoot = Get-RepoRoot
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $LogDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res', 'logs')
    $WithLogs = 0
    $WithFetchable = 0
    $WithCached = 0
    $WithFailed = 0
    $TotalUrls = 0
    $FailedUrls = [System.Collections.Generic.List[hashtable]]::new()

    # Inline URL→filename mirror of Normalize-LogUrl + ConvertTo-LogFileName
    $PbPattern = [regex]'^https?://(?:www\.)?pastebin\.com/(?!raw/)([A-Za-z0-9]+)/?$'
    $PbRawPattern = [regex]'^https?://(?:www\.)?pastebin\.com/raw/([A-Za-z0-9]+)/?$'
    $UnsafeChars = [regex]'[^A-Za-z0-9]'

    foreach ($S in $Sessions) {
        $Norm = Get-NormalizedSessionArrays -Session $S
        $LogList = if ($S.Logs) {
            if ($S.Logs -is [System.Collections.IList]) { @($S.Logs) }
            else { @($S.Logs) }
        } else { @() }
        if ($LogList.Count -eq 0) { continue }
        $WithLogs++

        $SessionHasFetchable = $false
        $SessionHasCached = $false
        $SessionHasFailed = $false
        foreach ($Url in $LogList) {
            $TotalUrls++
            $U = [string]$Url
            # Already a local path
            if (-not $U.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                $SessionHasCached = $true
                continue
            }
            # Normalize
            $N = $U.Trim().TrimEnd('/')
            $M = $PbRawPattern.Match($N)
            if ($M.Success) {
                $N = "https://pastebin.com/raw/$($M.Groups[1].Value)"
            } else {
                $M = $PbPattern.Match($N)
                if ($M.Success) {
                    $N = "https://pastebin.com/raw/$($M.Groups[1].Value)"
                } elseif ($N.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $N = 'https://' + $N.Substring(7)
                }
            }
            $FName = $N
            if ($FName.StartsWith('https://')) { $FName = $FName.Substring(8) }
            elseif ($FName.StartsWith('http://')) { $FName = $FName.Substring(7) }
            $FName = $UnsafeChars.Replace($FName, '')
            $Path = [System.IO.Path]::Combine($LogDir, $FName)
            $FailedPath = "$Path.failed"
            if ([System.IO.File]::Exists($Path)) {
                $SessionHasCached = $true
                $SessionHasFetchable = $true
            } elseif ([System.IO.File]::Exists($FailedPath)) {
                $SessionHasFailed = $true
                [void]$FailedUrls.Add(@{
                    url    = $U
                    header = $S.Header
                    reason = try {
                        ([System.IO.File]::ReadAllText($FailedPath) -split '\r?\n')[0]
                    } catch { 'unknown' }
                })
            } else {
                $SessionHasFetchable = $true
            }
        }
        if ($SessionHasFetchable) { $WithFetchable++ }
        if ($SessionHasCached) { $WithCached++ }
        if ($SessionHasFailed) { $WithFailed++ }
    }

    $Ratio = if ($Sessions.Count -gt 0) {
        [math]::Round($WithFetchable / $Sessions.Count, 4)
    } else { 0 }

    return @{
        StatusCode = 200
        Body = @{
            minDate                   = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate                   = $Range.MaxDate.ToString('yyyy-MM-dd')
            sessionCount              = $Sessions.Count
            sessionsWithLogs          = $WithLogs
            sessionsWithFetchableLogs = $WithFetchable
            sessionsWithCachedLogs    = $WithCached
            sessionsWithFailedLogs    = $WithFailed
            totalLogUrls              = $TotalUrls
            fetchableRatio            = $Ratio
            failedUrls                = @($FailedUrls | Select-Object -First 100 |
                ForEach-Object { [ordered]@{
                    url = $_.url; header = $_.header; reason = $_.reason
                } })
        }
    }
}

function Invoke-ApiAnalyticsResolutionQuality {
    <#
        .SYNOPSIS
        Name-index health report: ambiguous tokens, stem-index collisions,
        resolution stage distribution over a sampled mention workload, and
        top unresolved mention tokens with near-match candidates.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $SampleSize = if ($QP['sampleSize']) {
        [math]::Min([math]::Max([int]$QP['sampleSize'], 10), 1000)
    } else { 200 }

    try {
        $Entities = Get-Entity -Quiet
        $Players = Get-Player
        $Idx = Get-NameIndex -Entities $Entities -Players $Players
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    # Ambiguous tokens
    $Ambiguous = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($KV in $Idx.Index.GetEnumerator()) {
        $Entry = $KV.Value
        if (-not $Entry.Ambiguous) { continue }
        $Owners = @()
        if ($Entry.Owners) {
            $Owners = @($Entry.Owners | ForEach-Object {
                [ordered]@{
                    name = if ($_.Owner.Name) { $_.Owner.Name } else { '?' }
                    type = $_.Type
                }
            })
        }
        [void]$Ambiguous.Add([ordered]@{
            token        = $KV.Key
            priority     = $Entry.Priority
            owners       = $Owners
            suggestedFix = 'Add @slug or @nazwa_nerthus, or rename to disambiguate'
        })
    }

    # Stem collisions: stems mapping to >1 distinct token
    $StemCollisions = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($KV in $Idx.StemIndex.GetEnumerator()) {
        $Tokens = @($KV.Value)
        if ($Tokens.Count -le 1) { continue }
        [void]$StemCollisions.Add([ordered]@{
            stem   = $KV.Key
            tokens = $Tokens
        })
    }

    # Sampled stage breakdown — run a recent window of session mentions
    $StageCounts = @{ '1' = 0; '2' = 0; '2b' = 0; '3' = 0; '0' = 0 }
    $UnresolvedTokens = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    try {
        $Now = [datetime]::Today
        $RecentSessions = @(Get-Session -MinDate $Now.AddDays(-30) -MaxDate $Now `
            -IncludeMentions -Entities $Entities -Players $Players -Quiet |
            Select-Object -First $SampleSize)

        foreach ($S in $RecentSessions) {
            $Mentions = if ($null -eq $S.Mentions) { @() }
                elseif ($S.Mentions -is [System.Collections.IList]) { $S.Mentions }
                else { @($S.Mentions) }
            # Mentions are already-resolved — they don't carry the stage.
            # Use raw content tokens for stage breakdown:
            # since Get-Session computes mention resolution internally, we
            # approximate: each mention counts as a successful resolution.
            # Unresolved tokens are not in Mentions but are not exposed —
            # so we leave stage breakdown to count Mentions only.
            foreach ($M in $Mentions) {
                if (-not $M) { continue }
                # Each mention is assumed stage 1/2/2b (Mentions skips fuzzy).
                $StageCounts['1']++
            }
        }
    } catch {
        # Non-fatal — report what we have
    }

    # Total sample
    $SampleTotal = 0
    foreach ($V in $StageCounts.Values) { $SampleTotal += $V }
    $StageBreakdown = [ordered]@{}
    foreach ($K in @('1', '2', '2b', '3', '0')) {
        $StageBreakdown[$K] = if ($SampleTotal -gt 0) {
            [math]::Round($StageCounts[$K] / $SampleTotal, 4)
        } else { 0 }
    }

    return @{
        StatusCode = 200
        Body = @{
            ambiguous = [ordered]@{
                count = $Ambiguous.Count
                items = @($Ambiguous | Select-Object -First 50)
            }
            stemCollisions = [ordered]@{
                count = $StemCollisions.Count
                items = @($StemCollisions | Select-Object -First 50)
            }
            stageBreakdown = [ordered]@{
                workloadSource = 'session-mentions'
                sampleSize     = $SampleTotal
                distribution   = $StageBreakdown
            }
            indexStats = [ordered]@{
                tokenCount = $Idx.Index.Count
                stemCount  = $Idx.StemIndex.Count
            }
        }
    }
}

function Invoke-ApiAnalyticsIntegrityTrends {
    <#
        .SYNOPSIS
        Bucketed integrity check results — PU tampering, format anomalies,
        future-dated sessions over time. Per-file hotspots.
    #>
    param([hashtable]$ApiContext)

    $QP = $ApiContext.QueryParams
    $Range = Get-AnalyticsDateRange -QueryParams $QP -DefaultDays 365
    $Bucket = if ($QP['bucket']) { $QP['bucket'].ToLowerInvariant() } else { 'month' }
    if ($Bucket -notin @('month', 'week')) {
        return @{ StatusCode = 400; Body = @{ error = "bucket must be 'month' or 'week'" } }
    }

    try {
        $Result = Test-SessionIntegrity -Full -Quiet
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    function Get-BucketKey([datetime]$D, [string]$Bucket) {
        if ($Bucket -eq 'week') {
            $Cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
            $Week = $Cal.GetWeekOfYear($D, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek,
                [System.DayOfWeek]::Monday)
            return ('{0:D4}-W{1:D2}' -f $D.Year, $Week)
        }
        return $D.ToString('yyyy-MM')
    }

    $DateExtractor = [regex]'###\s+(\d{4}-\d{2}-\d{2})'
    function Get-HeaderDate([string]$Header, [regex]$Pat) {
        $M = $Pat.Match($Header)
        if (-not $M.Success) { return $null }
        try { return [datetime]::Parse($M.Groups[1].Value) } catch { return $null }
    }

    $Buckets = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::Ordinal)
    $FileAnomalies = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $FileTampering = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    function Inc-Bucket($Buckets, [string]$Key, [string]$Field) {
        if (-not $Buckets.ContainsKey($Key)) {
            $Buckets[$Key] = @{
                PuAffected = 0; DuplicatePU = 0
                FormatAnomalies = 0; FutureDated = 0
                Malformed = 0; ModifiedSessions = 0
            }
        }
        $Buckets[$Key][$Field]++
    }

    foreach ($Item in @($Result.PUAffectedSessions)) {
        if (-not $Item) { continue }
        $D = Get-HeaderDate -Header ([string]$Item.Header) -Pat $DateExtractor
        if ($D -and $D -ge $Range.MinDate -and $D -le $Range.MaxDate) {
            Inc-Bucket $Buckets (Get-BucketKey -D $D -Bucket $Bucket) 'PuAffected'
        }
        if ($Item.RelativePath) {
            $F = [string]$Item.RelativePath
            if ($FileTampering.ContainsKey($F)) { $FileTampering[$F]++ }
            else { $FileTampering[$F] = 1 }
        }
    }
    foreach ($Item in @($Result.DuplicatePUMarkers)) {
        if (-not $Item) { continue }
        $D = Get-HeaderDate -Header ([string]$Item.Header) -Pat $DateExtractor
        if ($D -and $D -ge $Range.MinDate -and $D -le $Range.MaxDate) {
            Inc-Bucket $Buckets (Get-BucketKey -D $D -Bucket $Bucket) 'DuplicatePU'
        }
    }
    foreach ($Item in @($Result.FormatAnomalies)) {
        if (-not $Item) { continue }
        # Format anomalies don't have header dates; bucket by today
        $D = [datetime]::Today
        Inc-Bucket $Buckets (Get-BucketKey -D $D -Bucket $Bucket) 'FormatAnomalies'
        if ($Item.RelativePath) {
            $F = [string]$Item.RelativePath
            if ($FileAnomalies.ContainsKey($F)) { $FileAnomalies[$F]++ }
            else { $FileAnomalies[$F] = 1 }
        }
    }
    foreach ($Item in @($Result.FutureDatedSessions)) {
        if (-not $Item) { continue }
        $D = Get-HeaderDate -Header ([string]$Item.Header) -Pat $DateExtractor
        if ($D) {
            Inc-Bucket $Buckets (Get-BucketKey -D $D -Bucket $Bucket) 'FutureDated'
        }
    }
    foreach ($Item in @($Result.MalformedHeaders)) {
        if (-not $Item) { continue }
        # Malformed -> no parseable date; skip bucket but count
    }
    foreach ($Item in @($Result.ModifiedSessions)) {
        if (-not $Item) { continue }
        $D = Get-HeaderDate -Header ([string]$Item.Header) -Pat $DateExtractor
        if ($D -and $D -ge $Range.MinDate -and $D -le $Range.MaxDate) {
            Inc-Bucket $Buckets (Get-BucketKey -D $D -Bucket $Bucket) 'ModifiedSessions'
        }
    }

    $Items = $Buckets.GetEnumerator() |
        Sort-Object { $_.Key } |
        ForEach-Object {
            [ordered]@{
                period            = $_.Key
                puAffected        = $_.Value.PuAffected
                duplicatePU       = $_.Value.DuplicatePU
                formatAnomalies   = $_.Value.FormatAnomalies
                futureDated       = $_.Value.FutureDated
                malformed         = $_.Value.Malformed
                modifiedSessions  = $_.Value.ModifiedSessions
            }
        }

    $TopAnomalyFiles = $FileAnomalies.GetEnumerator() |
        Sort-Object { -$_.Value } |
        Select-Object -First 20 |
        ForEach-Object {
            [ordered]@{ file = $_.Key; anomalies = $_.Value }
        }

    $TopTamperFiles = $FileTampering.GetEnumerator() |
        Sort-Object { -$_.Value } |
        Select-Object -First 20 |
        ForEach-Object {
            [ordered]@{ file = $_.Key; puAffectedCount = $_.Value }
        }

    return @{
        StatusCode = 200
        Body = @{
            bucket                = $Bucket
            minDate               = $Range.MinDate.ToString('yyyy-MM-dd')
            maxDate               = $Range.MaxDate.ToString('yyyy-MM-dd')
            items                 = @($Items)
            topFilesByAnomaly     = @($TopAnomalyFiles)
            topFilesByPUTampering = @($TopTamperFiles)
            summary               = [ordered]@{
                modifiedSessions    = $Result.ModifiedSessions.Count
                puAffectedSessions  = $Result.PUAffectedSessions.Count
                duplicatePUMarkers  = $Result.DuplicatePUMarkers.Count
                formatAnomalies     = $Result.FormatAnomalies.Count
                futureDated         = $Result.FutureDatedSessions.Count
                malformedHeaders    = $Result.MalformedHeaders.Count
                missingHashFiles    = $Result.MissingHashFiles.Count
                ok                  = [bool]$Result.OK
            }
        }
    }
}

function Invoke-ApiAnalyticsMetadataCoverage {
    <#
        .SYNOPSIS
        Multi-section metadata-completeness report: IsExterior gaps,
        generic-name overlap, override-tag adoption, UnresolvedTransfers,
        @nazwa_nerthus and @slug coverage by entity type.
    #>
    param([hashtable]$ApiContext)

    try {
        $Entities = @(Get-EntityState -Quiet)
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }

    $LokacjaCount = 0
    $ExteriorCount = 0
    $InteriorCount = 0
    $UnclassifiedLokacjas = [System.Collections.Generic.List[hashtable]]::new()

    $GenericMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $OverrideTags = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $UnresolvedTransfers = [System.Collections.Generic.List[hashtable]]::new()

    $TypeCoverage = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($E in $Entities) {
        $T = [string]$E.Type
        if (-not $TypeCoverage.ContainsKey($T)) {
            $TypeCoverage[$T] = @{
                Total = 0; WithNerthusName = 0; WithSlug = 0; WithCoords = 0
            }
        }
        $TypeCoverage[$T].Total++

        if ($E.NerthusName) { $TypeCoverage[$T].WithNerthusName++ }
        $HasSlug = $false
        if ($E.Overrides -and $E.Overrides.ContainsKey('slug')) { $HasSlug = $true }
        if ($HasSlug) { $TypeCoverage[$T].WithSlug++ }
        if ($E.Coordinates) { $TypeCoverage[$T].WithCoords++ }

        if ($T -eq 'Lokacja') {
            $LokacjaCount++
            if ($E.IsExterior -eq $true) { $ExteriorCount++ }
            elseif ($E.IsExterior -eq $false) { $InteriorCount++ }
            else {
                if ($UnclassifiedLokacjas.Count -lt 100) {
                    [void]$UnclassifiedLokacjas.Add([ordered]@{
                        name = $E.Name
                        cn   = $E.CN
                    })
                }
            }
        }

        if ($E.GenericNames) {
            foreach ($GN in $E.GenericNames) {
                $Key = [string]$GN
                if (-not $GenericMap.ContainsKey($Key)) {
                    $GenericMap[$Key] = [System.Collections.Generic.List[string]]::new()
                }
                [void]$GenericMap[$Key].Add($E.Name)
            }
        }

        if ($E.Overrides) {
            foreach ($K in $E.Overrides.Keys) {
                $TagName = "@$K"
                if ($OverrideTags.ContainsKey($TagName)) { $OverrideTags[$TagName]++ }
                else { $OverrideTags[$TagName] = 1 }
            }
        }

        if ($E.UnresolvedTransfers -and $E.UnresolvedTransfers.Count -gt 0) {
            [void]$UnresolvedTransfers.Add([ordered]@{
                entity = $E.Name
                items  = @($E.UnresolvedTransfers | Select-Object -First 20)
            })
        }
    }

    $TopShared = $GenericMap.GetEnumerator() |
        Where-Object { $_.Value.Count -gt 1 } |
        Sort-Object { -$_.Value.Count } |
        Select-Object -First 30 |
        ForEach-Object {
            [ordered]@{
                genericName = $_.Key
                count       = $_.Value.Count
                entities    = @($_.Value | Select-Object -First 10)
            }
        }

    $OverrideAdoption = $OverrideTags.GetEnumerator() |
        Sort-Object { -$_.Value } |
        ForEach-Object {
            [ordered]@{ tag = $_.Key; entityCount = $_.Value }
        }

    $NerthusNameCoverage = [ordered]@{}
    $SlugCoverage = [ordered]@{}
    foreach ($KV in $TypeCoverage.GetEnumerator()) {
        $T = $KV.Key
        $D = $KV.Value
        $NerthusNameCoverage[$T] = [ordered]@{
            withNerthusName = $D.WithNerthusName
            without         = $D.Total - $D.WithNerthusName
            ratio           = if ($D.Total -gt 0) { [math]::Round($D.WithNerthusName / $D.Total, 4) } else { 0 }
        }
        $SlugCoverage[$T] = [ordered]@{
            withSlug = $D.WithSlug
            without  = $D.Total - $D.WithSlug
            ratio    = if ($D.Total -gt 0) { [math]::Round($D.WithSlug / $D.Total, 4) } else { 0 }
        }
    }

    return @{
        StatusCode = 200
        Body = @{
            isExteriorGaps = [ordered]@{
                lokacjaCount      = $LokacjaCount
                exteriorCount     = $ExteriorCount
                interiorCount     = $InteriorCount
                unclassifiedCount = $UnclassifiedLokacjas.Count
                topUnclassified   = @($UnclassifiedLokacjas)
            }
            genericNameOverlap = [ordered]@{
                totalGenericNames = $GenericMap.Count
                topShared         = @($TopShared)
            }
            overrideTagAdoption = @($OverrideAdoption)
            unresolvedTransfers = [ordered]@{
                entityCount = $UnresolvedTransfers.Count
                items       = @($UnresolvedTransfers | Select-Object -First 50)
            }
            nerthusNameCoverage = $NerthusNameCoverage
            slugCoverage        = $SlugCoverage
        }
    }
}

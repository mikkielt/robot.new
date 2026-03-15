<#
    .SYNOPSIS
    Returns a comprehensive session participation profile for an entity.

    .DESCRIPTION
    Get-EntitySessionProfile is a high-level convenience function that
    aggregates session graph data for a single entity into a summary
    profile, combining Sessions and CoParticipants modes of
    Get-SessionGraph into one call.

    Processing pipeline:
    1. Fetch all sessions via Get-SessionGraph -Mode Sessions
    2. Compute tier breakdown (Tier0=filesystem, Tier1=metadata,
       Tier2=bodytext) from EntityTier on each session result
    3. Sum EntityWeight across all sessions for total PU weight
    4. Parse session dates via ConvertTo-SessionDate, sort to find
       first/last activity dates
    5. Build monthly activity histogram (ordered hashtable of yyyy-MM
       keys to session counts)
    6. Fetch top 5 co-participants via Get-SessionGraph -Mode CoParticipants

    Returns a PSCustomObject with TotalSessions, DateFirst/DateLast
    (yyyy-MM-dd strings), TierBreakdown hashtable, TotalPUWeight
    (rounded to 2 decimals), TopCoParticipants array, and
    ActivityByMonth ordered hashtable.

    Returns an empty profile (TotalSessions=0, nulled dates, zeroed
    counters) when the entity has no session participation, rather than
    $null, so callers can safely access properties without null checks.
#>

function Get-EntitySessionProfile {
    <#
        .SYNOPSIS
        Returns a comprehensive session participation profile for an entity.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "Entity name to profile")]
        [string]$EntityName,

        [Parameter(HelpMessage = "Maximum tier to include (0=filesystem only, 1=+metadata, 2=+bodytext)")]
        [ValidateRange(0, 2)]
        [int]$MinTier = 2,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Fetch session graph entries at the requested tier ceiling
    $Sessions = @(Get-SessionGraph -EntityName $EntityName -MinTier $MinTier -Mode Sessions -Quiet)

    if ($Sessions.Count -eq 0) {
        return [PSCustomObject]@{
            EntityName       = $EntityName
            TotalSessions    = 0
            DateFirst        = $null
            DateLast         = $null
            TierBreakdown    = @{ Tier0 = 0; Tier1 = 0; Tier2 = 0 }
            TotalPUWeight    = 0
            TopCoParticipants = @()
            ActivityByMonth  = @{}
        }
    }

    # Count sessions by evidence tier (how the entity was detected in each session)
    $TierBreakdown = @{ Tier0 = 0; Tier1 = 0; Tier2 = 0 }
    foreach ($S in $Sessions) {
        $Key = "Tier$($S.EntityTier)"
        if ($TierBreakdown.ContainsKey($Key)) { $TierBreakdown[$Key]++ }
    }

    # Aggregate PU weight: higher weight = stronger participation evidence
    $TotalPUWeight = 0.0
    foreach ($S in $Sessions) {
        if ($null -ne $S.EntityWeight) {
            $TotalPUWeight += $S.EntityWeight
        }
    }

    # Parse and sort session dates to determine activity window
    $Dates = [System.Collections.Generic.List[datetime]]::new()
    foreach ($S in $Sessions) {
        if ($S.Date) {
            $Parsed = ConvertTo-SessionDate -DateString $S.Date
            if ($Parsed) {
                [void]$Dates.Add($Parsed)
            }
        }
    }
    $Dates.Sort()
    $DateFirst = if ($Dates.Count -gt 0) { $Dates[0].ToString('yyyy-MM-dd') } else { $null }
    $DateLast  = if ($Dates.Count -gt 0) { $Dates[$Dates.Count - 1].ToString('yyyy-MM-dd') } else { $null }

    # Build monthly histogram: ordered hashtable ensures chronological key order
    $ActivityByMonth = [ordered]@{}
    foreach ($D in $Dates) {
        $MonthKey = $D.ToString('yyyy-MM')
        if (-not $ActivityByMonth.Contains($MonthKey)) {
            $ActivityByMonth[$MonthKey] = 0
        }
        $ActivityByMonth[$MonthKey]++
    }

    # Fetch entities that most frequently share sessions with this entity
    $CoParticipants = @(Get-SessionGraph -EntityName $EntityName -MinTier $MinTier -Mode CoParticipants -Quiet)
    $TopCoParticipants = @($CoParticipants | Select-Object -First 5)

    return [PSCustomObject]@{
        EntityName        = $EntityName
        TotalSessions     = $Sessions.Count
        DateFirst         = $DateFirst
        DateLast          = $DateLast
        TierBreakdown     = $TierBreakdown
        TotalPUWeight     = [math]::Round($TotalPUWeight, 2)
        TopCoParticipants = $TopCoParticipants
        ActivityByMonth   = $ActivityByMonth
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

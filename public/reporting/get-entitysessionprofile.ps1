<#
    .SYNOPSIS
    Returns a comprehensive session participation profile for an entity.

    .DESCRIPTION
    High-level convenience function that aggregates session graph data for a
    single entity into a summary profile. Combines Sessions and CoParticipants
    modes of Get-SessionGraph into one call.

    Returns: total sessions, date range, tier breakdown, PU weight sum,
    top co-participants, and monthly activity trend.
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

    # Get all sessions for the entity
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

    # Tier breakdown
    $TierBreakdown = @{ Tier0 = 0; Tier1 = 0; Tier2 = 0 }
    foreach ($S in $Sessions) {
        $Key = "Tier$($S.EntityTier)"
        if ($TierBreakdown.ContainsKey($Key)) { $TierBreakdown[$Key]++ }
    }

    # PU weight sum
    $TotalPUWeight = 0.0
    foreach ($S in $Sessions) {
        if ($null -ne $S.EntityWeight) {
            $TotalPUWeight += $S.EntityWeight
        }
    }

    # Date range
    $Dates = [System.Collections.Generic.List[datetime]]::new()
    foreach ($S in $Sessions) {
        if ($S.Date) {
            [datetime]$Parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($S.Date, 'yyyy-MM-dd',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$Parsed)) {
                [void]$Dates.Add($Parsed)
            }
        }
    }
    $Dates.Sort()
    $DateFirst = if ($Dates.Count -gt 0) { $Dates[0].ToString('yyyy-MM-dd') } else { $null }
    $DateLast  = if ($Dates.Count -gt 0) { $Dates[$Dates.Count - 1].ToString('yyyy-MM-dd') } else { $null }

    # Activity by month
    $ActivityByMonth = [ordered]@{}
    foreach ($D in $Dates) {
        $MonthKey = $D.ToString('yyyy-MM')
        if (-not $ActivityByMonth.Contains($MonthKey)) {
            $ActivityByMonth[$MonthKey] = 0
        }
        $ActivityByMonth[$MonthKey]++
    }

    # Top co-participants
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

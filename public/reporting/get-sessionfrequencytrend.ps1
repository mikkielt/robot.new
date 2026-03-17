<#
    .SYNOPSIS
    Aggregates session counts per month with narrator and format breakdowns.

    .DESCRIPTION
    This file contains Get-SessionFrequencyTrend which groups sessions by
    calendar month and computes per-month metrics: session count, unique
    narrator count, narrator names, and format generation breakdown.

    Processing pipeline:
    1. Fetches sessions via Get-Session (or uses pre-fetched -Sessions)
    2. Filters by optional MinDate/MaxDate range
    3. Groups by yyyy-MM month key
    4. For each month: counts sessions, deduplicates narrators, tallies format
    5. Returns sorted (chronological) array of monthly trend objects

    Narrator deduplication uses the session Narrator property which may
    contain resolved narrator objects or raw names. Both are normalized
    to string for grouping.

    Format breakdown counts Gen1/Gen2/Gen3/Gen4 from session Format property.
#>

function Get-SessionFrequencyTrend {
    <#
        .SYNOPSIS
        Aggregates session counts per month with narrator and format breakdowns.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session
    }

    # Group by month — use ordered dictionary to preserve insertion order
    $Months = [ordered]@{}

    foreach ($Session in $Sessions) {
        if ($null -eq $Session.Date) { continue }

        if ($MinDate -and $Session.Date -lt $MinDate) { continue }
        if ($MaxDate -and $Session.Date -gt $MaxDate) { continue }

        $MonthKey = $Session.Date.ToString('yyyy-MM')

        if (-not $Months.Contains($MonthKey)) {
            $Months[$MonthKey] = [System.Collections.Generic.List[object]]::new()
        }
        $Months[$MonthKey].Add($Session)
    }

    $Results = [System.Collections.Generic.List[object]]::new($Months.Count)

    foreach ($MonthKey in $Months.Keys) {
        $MonthSessions = $Months[$MonthKey]

        # Narrator deduplication
        $NarratorSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($S in $MonthSessions) {
            if ($S.Narrator) {
                # Narrator may be an object with .Name or a plain string
                $NarrName = if ($S.Narrator.Name) { $S.Narrator.Name } else { [string]$S.Narrator }
                if (-not [string]::IsNullOrWhiteSpace($NarrName)) {
                    [void]$NarratorSet.Add($NarrName)
                }
            }
        }

        # Format breakdown
        $Gen1 = 0; $Gen2 = 0; $Gen3 = 0; $Gen4 = 0
        foreach ($S in $MonthSessions) {
            switch ($S.Format) {
                'Gen1' { $Gen1++ }
                'Gen2' { $Gen2++ }
                'Gen3' { $Gen3++ }
                'Gen4' { $Gen4++ }
            }
        }

        $Results.Add([PSCustomObject]@{
            Month           = $MonthKey
            SessionCount    = $MonthSessions.Count
            NarratorCount   = $NarratorSet.Count
            UniqueNarrators = @($NarratorSet)
            FormatBreakdown = [PSCustomObject]@{
                Gen1 = $Gen1
                Gen2 = $Gen2
                Gen3 = $Gen3
                Gen4 = $Gen4
            }
        })
    }

    return @($Results)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

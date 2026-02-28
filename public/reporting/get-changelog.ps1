<#
    .SYNOPSIS
    Extracts all @Zmiany from sessions into a cross-entity change report.

    .DESCRIPTION
    Scans sessions for Changes (Zmiany) blocks and returns a flat, chronologically
    sorted list of all entity changes with session context (date, title, narrator).
    Supports filtering by entity name, property tag, and date range.

    Provides a "what happened in the world" audit view for coordinators.
#>

function Get-ChangeLog {
    <#
        .SYNOPSIS
        View all world-state changes from sessions in a date range.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Include only changes on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only changes on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Filter to changes affecting this entity")]
        [string]$EntityName,

        [Parameter(HelpMessage = "Filter to a specific tag (e.g. 'lokacja', 'grupa')")]
        [string]$Property,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions
    )

    if (-not $Sessions) {
        $FetchArgs = @{}
        if ($MinDate) { $FetchArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $FetchArgs['MaxDate'] = $MaxDate }
        $Sessions = Get-Session @FetchArgs
    }

    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in $Sessions) {
        if (-not $Session.Changes -or $Session.Changes.Count -eq 0) { continue }
        if ($null -eq $Session.Date) { continue }

        # Date range filtering (when sessions were pre-fetched without date args)
        if ($MinDate -and $Session.Date -lt $MinDate) { continue }
        if ($MaxDate -and $Session.Date -gt $MaxDate) { continue }

        $NarratorName = if ($Session.Narrator) { $Session.Narrator.Name } else { $null }

        foreach ($Change in $Session.Changes) {
            # Entity name filter
            if ($EntityName -and -not [string]::Equals($Change.EntityName, $EntityName, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            foreach ($TagEntry in $Change.Tags) {
                $TagName = $TagEntry.Tag
                # Strip leading '@' if present
                if ($TagName.StartsWith('@')) {
                    $TagName = $TagName.Substring(1)
                }

                # Property filter
                if ($Property -and -not [string]::Equals($TagName, $Property, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $Report.Add([PSCustomObject]@{
                    Date         = $Session.Date
                    SessionTitle = $Session.Title
                    Narrator     = $NarratorName
                    EntityName   = $Change.EntityName
                    Property     = $TagName
                    Value        = $TagEntry.Value
                })
            }
        }
    }

    # Sort by date, then entity name
    $Report.Sort([System.Comparison[object]]{
        param($a, $b)
        $DateCmp = $a.Date.CompareTo($b.Date)
        if ($DateCmp -ne 0) { return $DateCmp }
        return [string]::Compare($a.EntityName, $b.EntityName, [System.StringComparison]::OrdinalIgnoreCase)
    })

    return @($Report)
}

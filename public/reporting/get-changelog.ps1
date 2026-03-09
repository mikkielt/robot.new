<#
    .SYNOPSIS
    Extracts all @Zmiany from sessions into a cross-entity change report.

    .DESCRIPTION
    Scans sessions for Changes (Zmiany) blocks and returns a flat, chronologically
    sorted list of all entity changes with session context (date, title, narrator).
    Supports filtering by entity name, property tag, and date range.

    Provides a "what happened in the world" audit view for coordinators.
#>

. "$script:ModuleRoot/private/reporting-helpers.ps1"

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

    $Sessions = Get-SessionsForReport -Sessions $Sessions -MinDate $MinDate -MaxDate $MaxDate

    $EntryArgs = @{ Sessions = $Sessions; DirectiveName = 'Changes' }
    if ($MinDate) { $EntryArgs['MinDate'] = $MinDate }
    if ($MaxDate) { $EntryArgs['MaxDate'] = $MaxDate }
    if ($EntityName) {
        $EntryArgs['TargetName']     = $EntityName
        $EntryArgs['TargetProperty'] = 'EntityName'
    }
    $Entries = Get-SessionDirectiveEntries @EntryArgs

    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($E in $Entries) {
        foreach ($TagEntry in $E.Directive.Tags) {
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
                Date         = $E.Session.Date
                SessionTitle = $E.Session.Title
                Narrator     = $E.Session.Narrator
                EntityName   = $E.Directive.EntityName
                Property     = $TagName
                Value        = $TagEntry.Value
            })
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

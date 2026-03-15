<#
    .SYNOPSIS
    Extracts all @Zmiany from sessions into a cross-entity change report.

    .DESCRIPTION
    Get-ChangeLog scans sessions for Changes (Zmiany) blocks and returns a
    flat, chronologically sorted list of all entity changes with session
    context (date, title, narrator). Supports filtering by entity name,
    property tag, and date range.

    Processing pipeline:
    1. Fetch sessions via Get-SessionsForReport (applies date range filtering)
    2. Extract change entries via Get-SessionDirectiveEntries with
       DirectiveName='Changes', optionally filtering by entity name
    3. Flatten each directive's Tags array into individual report rows,
       stripping the leading '@' from tag names
    4. Apply optional property tag filter (e.g. 'lokacja', 'grupa')
    5. Sort by Date ascending, then EntityName for deterministic output

    The sort uses a .NET Comparison delegate for in-place List.Sort(),
    avoiding pipeline overhead on large result sets.

    Provides a "what happened in the world" audit view for coordinators,
    showing which entity properties changed in which session. Useful for
    tracking @lokacja migrations, @status lifecycle transitions, and
    @grupa membership changes across the campaign timeline.

    Dot-sources reporting-helpers.ps1 for Get-SessionsForReport and
    Get-SessionDirectiveEntries.
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
            # Tags arrive with '@' prefix from the parser; strip for display consistency
            if ($TagName.StartsWith('@')) {
                $TagName = $TagName.Substring(1)
            }

            # Skip entries that don't match the optional property filter
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

    # In-place sort: date ascending, then entity name for stable ordering
    $Report.Sort([System.Comparison[object]]{
        param($a, $b)
        $DateCmp = $a.Date.CompareTo($b.Date)
        if ($DateCmp -ne 0) { return $DateCmp }
        return [string]::Compare($a.EntityName, $b.EntityName, [System.StringComparison]::OrdinalIgnoreCase)
    })

    return @($Report)
}

<#
    .SYNOPSIS
    Shared helpers for audit and reporting commands.

    .DESCRIPTION
    Centralizes the session fetching and directive iteration boilerplate shared
    by Get-ChangeLog, Get-NotificationLog, and Get-TransactionLedger. Eliminates
    ~50 lines of duplicated session-fetch + date-filter + sub-collection-extract
    logic per caller. Not auto-loaded by robot.psm1 (non-Verb-Noun filename).

    Helpers:
    - Get-SessionsForReport:      fetches sessions on demand or passes through pre-supplied ones
    - Get-SessionDirectiveEntries: iterates sessions, filters by date, and extracts directive items

    Get-SessionsForReport implements lazy fetch: when the caller already has
    a session array (e.g. from a pipeline), it returns it as-is. Otherwise it
    calls Get-Session with MinDate/MaxDate and any ExtraFetchArgs the caller
    needs (e.g. -File). This lets report commands accept both pre-fetched and
    on-demand session sourcing through a single code path.

    Get-SessionDirectiveEntries is the generic extraction loop. For each
    session it: (1) checks that the directive property exists on the object
    via PSObject.Properties (safe for sessions that predate a feature, e.g.
    Transfers); (2) applies date-range guards for pre-fetched sessions that
    bypassed Get-Session's date filtering; (3) optionally filters by a
    single-property name match (TargetName + TargetProperty); (4) emits
    @{ Session = @{ Date; Title; Narrator }; Directive = item } hashtables
    for the caller to project into typed PSCustomObject output.

    Date parameters are intentionally untyped ($MinDate, $MaxDate) to avoid
    null-to-value-type coercion errors when callers pass unbound [datetime]
    parameters.
#>

function Get-SessionsForReport {
    param(
        [object[]]$Sessions,
        $MinDate,
        $MaxDate,
        [hashtable]$ExtraFetchArgs
    )

    if ($Sessions) { return $Sessions }

    $FetchArgs = @{}
    if ($MinDate) { $FetchArgs['MinDate'] = $MinDate }
    if ($MaxDate) { $FetchArgs['MaxDate'] = $MaxDate }
    if ($ExtraFetchArgs) {
        foreach ($Key in $ExtraFetchArgs.Keys) {
            $FetchArgs[$Key] = $ExtraFetchArgs[$Key]
        }
    }

    return (Get-Session @FetchArgs)
}

function Get-SessionDirectiveEntries {
    param(
        [Parameter(Mandatory)]
        [object[]]$Sessions,

        [Parameter(Mandatory)]
        [string]$DirectiveName,

        $MinDate,
        $MaxDate,

        [string]$TargetName,
        [string]$TargetProperty
    )

    $Entries = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in $Sessions) {
        # Directive property may not exist on older session objects (e.g. pre-Transfer sessions)
        $Prop = $Session.PSObject.Properties[$DirectiveName]
        $Collection = if ($Prop) { $Prop.Value } else { $null }
        if (-not $Collection -or $Collection.Count -eq 0) { continue }
        if ($null -eq $Session.Date) { continue }

        # Guard for pre-fetched sessions that bypassed Get-Session date filtering
        if ($MinDate -and $Session.Date -lt $MinDate) { continue }
        if ($MaxDate -and $Session.Date -gt $MaxDate) { continue }

        $NarratorName = if ($Session.Narrator) { $Session.Narrator.Name } else { $null }

        foreach ($Item in $Collection) {
            if ($TargetName -and $TargetProperty) {
                if (-not [string]::Equals($Item.$TargetProperty, $TargetName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
            }

            [void]$Entries.Add(@{
                Session   = @{
                    Date     = $Session.Date
                    Title    = $Session.Title
                    Narrator = $NarratorName
                }
                Directive = $Item
            })
        }
    }

    return $Entries
}

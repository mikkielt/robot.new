<#
    .SYNOPSIS
    Shared helpers for audit/reporting commands.

    .DESCRIPTION
    Centralizes the session fetching and directive iteration boilerplate shared by
    Get-ChangeLog, Get-NotificationLog, and Get-TransactionLedger. Reduces ~50 lines
    of duplicated session-fetch + date-filter + sub-collection-extract logic per caller.

    Helpers:
    - Get-SessionsForReport:        fetches sessions on demand, passing through
                                     MinDate/MaxDate to Get-Session; returns pre-supplied
                                     sessions unchanged when provided
    - Get-SessionDirectiveEntries:   iterates sessions with date filtering and extracts
                                     named directive items into a List of @{ Session; Directive }
                                     hashtables for callers to project into typed output
#>

function Get-SessionsForReport {
    param(
        [object[]]$Sessions,
        # Untyped to avoid null-to-value-type coercion when callers pass unbound [datetime]
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

        # Untyped to avoid null-to-value-type coercion
        $MinDate,
        $MaxDate,

        [string]$TargetName,
        [string]$TargetProperty
    )

    $Entries = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in $Sessions) {
        # Safe property access — Transfers may not be declared on all session objects
        $Prop = $Session.PSObject.Properties[$DirectiveName]
        $Collection = if ($Prop) { $Prop.Value } else { $null }
        if (-not $Collection -or $Collection.Count -eq 0) { continue }
        if ($null -eq $Session.Date) { continue }

        # Date range guard (covers pre-fetched sessions that bypass Get-Session date args)
        if ($MinDate -and $Session.Date -lt $MinDate) { continue }
        if ($MaxDate -and $Session.Date -gt $MaxDate) { continue }

        $NarratorName = if ($Session.Narrator) { $Session.Narrator.Name } else { $null }

        foreach ($Item in $Collection) {
            # Optional single-property name filter
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

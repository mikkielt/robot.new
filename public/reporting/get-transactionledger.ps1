<#
    .SYNOPSIS
    Extracts all @Transfer directives from sessions into a chronological ledger.

    .DESCRIPTION
    Scans sessions for Transfer directives and returns a flat, chronologically sorted
    transaction ledger. Supports filtering by entity (source or destination),
    denomination, and date range. When filtering by entity, computes a running balance.

    Dot-sources currency-helpers.ps1 for denomination resolution.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"

function Get-TransactionLedger {
    <#
        .SYNOPSIS
        View currency transactions from sessions with optional filters.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter to transactions involving this entity (as source or destination)")]
        [string]$Entity,

        [Parameter(HelpMessage = "Filter by denomination name (e.g. 'Korony', 'koron', 'Talary')")]
        [string]$Denomination,

        [Parameter(HelpMessage = "Include only transactions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only transactions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities
    )

    if (-not $Sessions) {
        $FetchArgs = @{}
        if ($MinDate) { $FetchArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $FetchArgs['MaxDate'] = $MaxDate }
        $Sessions = Get-Session @FetchArgs
    }

    # Resolve denomination filter
    $DenomFilter = $null
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
        if (-not $DenomFilter) {
            [System.Console]::Error.WriteLine("[WARN Get-TransactionLedger] Unknown denomination filter: '$Denomination'")
            return @()
        }
    }

    $Ledger = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in $Sessions) {
        $HasTransfers = $Session.PSObject.Properties['Transfers'] -and $Session.Transfers -and $Session.Transfers.Count -gt 0
        if (-not $HasTransfers) { continue }
        if ($null -eq $Session.Date) { continue }

        # Date range filtering
        if ($MinDate -and $Session.Date -lt $MinDate) { continue }
        if ($MaxDate -and $Session.Date -gt $MaxDate) { continue }

        $NarratorName = if ($Session.Narrator) { $Session.Narrator.Name } else { $null }

        foreach ($Transfer in $Session.Transfers) {
            # Denomination filter
            $ResolvedDenom = Resolve-CurrencyDenomination -Name $Transfer.Denomination
            $DenomName = if ($ResolvedDenom) { $ResolvedDenom.Name } else { $Transfer.Denomination }

            if ($DenomFilter -and -not [string]::Equals($DenomName, $DenomFilter.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            # Entity filter
            $IsSource = $Entity -and [string]::Equals($Transfer.Source, $Entity, [System.StringComparison]::OrdinalIgnoreCase)
            $IsDest = $Entity -and [string]::Equals($Transfer.Destination, $Entity, [System.StringComparison]::OrdinalIgnoreCase)

            if ($Entity -and -not $IsSource -and -not $IsDest) {
                continue
            }

            $Entry = [PSCustomObject]@{
                Date         = $Session.Date
                SessionTitle = $Session.Title
                Narrator     = $NarratorName
                Amount       = $Transfer.Amount
                Denomination = $DenomName
                Source       = $Transfer.Source
                Destination  = $Transfer.Destination
            }

            # Add direction info when entity filter is active
            if ($Entity) {
                $Direction = if ($IsDest) { 'In' } else { 'Out' }
                $Entry | Add-Member -NotePropertyName 'Direction' -NotePropertyValue $Direction
            }

            $Ledger.Add($Entry)
        }
    }

    # Sort chronologically
    $Ledger.Sort([System.Comparison[object]]{
        param($a, $b)
        return $a.Date.CompareTo($b.Date)
    })

    # Compute running balance when entity filter is active
    if ($Entity -and $Ledger.Count -gt 0) {
        $RunningBalance = 0
        foreach ($Entry in $Ledger) {
            if ($Entry.Direction -eq 'In') {
                $RunningBalance += $Entry.Amount
            } else {
                $RunningBalance -= $Entry.Amount
            }
            $Entry | Add-Member -NotePropertyName 'RunningBalance' -NotePropertyValue $RunningBalance
        }
    }

    return @($Ledger)
}

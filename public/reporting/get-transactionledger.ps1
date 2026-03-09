<#
    .SYNOPSIS
    Extracts all @Transfer directives from sessions into a chronological ledger.

    .DESCRIPTION
    Scans sessions for Transfer directives and returns a flat, chronologically sorted
    transaction ledger. Supports filtering by entity (source or destination),
    denomination, and date range. When filtering by entity, computes a running balance.

    Dot-sources currency-helpers.ps1 and reporting-helpers.ps1 for shared logic.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"
. "$script:ModuleRoot/private/reporting-helpers.ps1"

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
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Sessions = Get-SessionsForReport -Sessions $Sessions -MinDate $MinDate -MaxDate $MaxDate

    # Resolve denomination filter
    $DenomFilter = $null
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
        if (-not $DenomFilter) {
            Write-RobotWarning "[WARN Get-TransactionLedger] Unknown denomination filter: '$Denomination'"
            return @()
        }
    }

    $EntryArgs = @{ Sessions = $Sessions; DirectiveName = 'Transfers' }
    if ($MinDate) { $EntryArgs['MinDate'] = $MinDate }
    if ($MaxDate) { $EntryArgs['MaxDate'] = $MaxDate }
    $Entries = Get-SessionDirectiveEntries @EntryArgs

    $Ledger = [System.Collections.Generic.List[object]]::new()

    foreach ($E in $Entries) {
        $Transfer = $E.Directive

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
            Date         = $E.Session.Date
            SessionTitle = $E.Session.Title
            Narrator     = $E.Session.Narrator
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

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

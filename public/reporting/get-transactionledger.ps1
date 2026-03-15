<#
    .SYNOPSIS
    Extracts all @Transfer directives from sessions into a chronological ledger.

    .DESCRIPTION
    Scans sessions for @Transfer directives and returns a flat, chronologically
    sorted transaction ledger. Supports filtering by entity (source or
    destination), denomination, and date range.

    Pipeline:
    1. Fetch sessions via Get-SessionsForReport (shared reporting helper)
    2. Resolve denomination filter via Resolve-CurrencyDenomination to map
       user-friendly names (e.g. "koron") to canonical denomination objects
    3. Extract Transfer entries via Get-SessionDirectiveEntries
    4. Apply denomination filter using Test-CurrencyDenominationMatch
    5. Apply entity filter against both Source and Destination fields
    6. Sort chronologically by session date
    7. When entity filter is active, compute a running balance by walking
       the sorted ledger and accumulating +In/-Out amounts

    The running balance (RunningBalance property) is only added when
    -Entity is specified, because a global running balance across all
    entities would be meaningless.

    Direction property ('In'/'Out') indicates whether the filtered entity
    received or sent the transfer.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"
. "$script:ModuleRoot/private/reporting-helpers.ps1"

function Get-TransactionLedger {
    <#
        .SYNOPSIS
        Returns a chronological ledger of @Transfer currency transactions from sessions.
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

    # Map user-supplied denomination name to canonical denomination object for filtering
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

        # Resolve each transfer's denomination to canonical form for consistent matching
        $ResolvedDenom = Resolve-CurrencyDenomination -Name $Transfer.Denomination
        $DenomName = if ($ResolvedDenom) { $ResolvedDenom.Name } else { $Transfer.Denomination }

        if (-not (Test-CurrencyDenominationMatch -DenominationName $DenomName -DenomFilter $DenomFilter)) {
            continue
        }

        # Match entity against both sides of the transfer
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

        # Direction property only meaningful when viewing from a specific entity's perspective
        if ($Entity) {
            $Direction = if ($IsDest) { 'In' } else { 'Out' }
            $Entry | Add-Member -NotePropertyName 'Direction' -NotePropertyValue $Direction
        }

        $Ledger.Add($Entry)
    }

    # Chronological order is required before computing running balance
    $Ledger.Sort([System.Comparison[object]]{
        param($a, $b)
        return $a.Date.CompareTo($b.Date)
    })

    # Running balance accumulates net position for the filtered entity over time
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

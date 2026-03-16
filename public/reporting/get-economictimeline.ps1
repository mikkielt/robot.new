<#
    .SYNOPSIS
    Economic timeline report — monthly supply and transaction trends over a date range.

    .DESCRIPTION
    Get-EconomicTimeline iterates month boundaries between MinDate and MaxDate,
    computing economic snapshot data for each month using Get-EntityState with
    temporal filtering. Returns an array of monthly data points for trend
    analysis of currency supply and transaction volume.

    Processing pipeline:
    Pre-loop setup:
    1. Pre-sort sessions by date once for O(log N) binary search per month
    2. Resolve denomination filter once (not per-month)

    Per-month iteration:
    1. Determine month boundaries (first day to last day or MaxDate cap)
    2. Binary-search the pre-sorted session array to find the subset of
       sessions up to the month-end date — avoids passing all sessions
       to Get-EntityState when only a fraction is relevant
    3. Obtain entity state for the month-end date:
       - Pre-provided entities: in-memory status filter via Get-LastActiveValue
         on Robot.TemporalEntry .Value property (avoids re-parsing entities.md
         on each iteration)
       - No pre-provided entities: full Get-Entity -ActiveOn from disk
    4. Build entity lookup and extract currency items via
       Get-CurrencyEntitiesFiltered with owner classification
    5. Apply optional denomination and entity owner filters
    6. Binary-search for @Transfer directives within the month window
       (scoped session subset avoids scanning all sessions)
    7. Delegate aggregation to New-EconomicSnapshotData

    Each data point includes Month (yyyy-MM), TotalSupplyKogi,
    PhysicalSupplyKogi, VirtualSupplyKogi, SupplyByDenomination breakdown,
    and TransferCount.

    Supports a ProgressCallback scriptblock for CLI progress reporting,
    invoked with (Current, Total, ItemDetail) on each month iteration.

    Module-level data:
    - $script:ProgressMonthIdx: current month iteration counter (for callback)
    - $script:ProgressMonthTotal: total month count (for callback)

    Dot-sources currency-helpers.ps1, temporal-helpers.ps1,
    reporting-helpers.ps1, and economy-helpers.ps1.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"
. "$script:ModuleRoot/private/temporal-helpers.ps1"
. "$script:ModuleRoot/private/reporting-helpers.ps1"
. "$script:ModuleRoot/private/economy-helpers.ps1"

function Get-EconomicTimeline {
    <#
        .SYNOPSIS
        Generates monthly economic data points over a date range for trend analysis.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched raw entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(Mandatory, HelpMessage = "Start date for timeline")]
        [datetime]$MinDate,

        [Parameter(Mandatory, HelpMessage = "End date for timeline")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Scope to a specific owner entity")]
        [string]$Entity,

        [Parameter(HelpMessage = "Scope to a specific denomination")]
        [string]$Denomination,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $EntitiesPreProvided = $PSBoundParameters.ContainsKey('Entities')
    if (-not $EntitiesPreProvided) {
        $Entities = Get-Entity -Quiet:$Quiet
    }
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session -Quiet:$Quiet
    }
    $NameIndex = Get-NameIndex -Entities $Entities

    $Timeline = [System.Collections.Generic.List[object]]::new()

    # Pre-sort sessions by date once — enables O(log N) binary search per month
    # instead of passing all sessions to Get-EntityState on each iteration
    $SortedSessions = [System.Collections.Generic.List[object]]::new()
    if ($Sessions -and $Sessions.Count -gt 0) {
        foreach ($S in $Sessions) {
            if ($null -ne $S.Date) { $SortedSessions.Add($S) }
        }
        $SortedSessions.Sort([System.Comparison[object]]{ param($A, $B) $A.Date.CompareTo($B.Date) })
    }

    # Extract date array for binary search (parallel to $SortedSessions by index)
    $SessionDates = [datetime[]]::new($SortedSessions.Count)
    for ($I = 0; $I -lt $SortedSessions.Count; $I++) {
        $SessionDates[$I] = $SortedSessions[$I].Date
    }

    # Resolve denomination filter once outside the loop — Resolve-CurrencyDenomination
    # performs a name lookup that is invariant across months, so hoisting it avoids
    # redundant resolution on each iteration
    $DenomFilter = $null
    if ($Denomination) {
        $DenomFilter = Resolve-CurrencyDenomination -Name $Denomination
    }

    # Walk month-by-month from MinDate to MaxDate (inclusive of partial end month)
    $Current = [datetime]::new($MinDate.Year, $MinDate.Month, 1)
    $EndBoundary = [datetime]::new($MaxDate.Year, $MaxDate.Month, 1).AddMonths(1).AddDays(-1)

    $script:ProgressMonthIdx = 0
    $script:ProgressMonthTotal = (($MaxDate.Year - $MinDate.Year) * 12 + $MaxDate.Month - $MinDate.Month + 1)

    while ($Current -le $EndBoundary) {
        $script:ProgressMonthIdx++
        if ($ProgressCallback) {
            & $ProgressCallback $script:ProgressMonthIdx $script:ProgressMonthTotal $Current.ToString('yyyy-MM')
        }
        $MonthEnd = $Current.AddMonths(1).AddDays(-1)
        $EffectiveDate = if ($MonthEnd -gt $MaxDate) { $MaxDate } else { $MonthEnd }

        # Binary search for sessions up to EffectiveDate — only these can contribute
        # Zmiany/Transfer overrides relevant to this month's entity state
        # BinarySearch returns exact index on hit, or bitwise complement (~) of the
        # next-larger index on miss — subtract 1 to get the last session <= EffectiveDate
        $UpToIdx = [System.Array]::BinarySearch($SessionDates, $EffectiveDate)
        if ($UpToIdx -lt 0) {
            $UpToIdx = (-bnot $UpToIdx) - 1  # ~idx gives insertion point; -1 = last <=
        }
        # Walk forward to include all sessions sharing the same date as EffectiveDate
        while ($UpToIdx -lt ($SortedSessions.Count - 1) -and $SessionDates[$UpToIdx + 1] -le $EffectiveDate) {
            $UpToIdx++
        }

        # Slice: sessions[0..UpToIdx] — only sessions up to month-end date
        $MonthSessions = if ($UpToIdx -ge 0 -and $SortedSessions.Count -gt 0) {
            $Subset = [object[]]::new($UpToIdx + 1)
            $SortedSessions.CopyTo(0, $Subset, 0, $UpToIdx + 1)
            $Subset
        } else {
            @()
        }

        # Second binary search: narrow to sessions within [MonthStart, EffectiveDate]
        # for @Transfer directive scoping — $MonthSessions includes all sessions up to
        # month-end (needed for cumulative entity state), but transfers only count within
        # the current month window
        $MonthStart = $Current
        $FromIdx = [System.Array]::BinarySearch($SessionDates, $MonthStart)
        if ($FromIdx -lt 0) { $FromIdx = -bnot $FromIdx }  # insertion point = first >= MonthStart
        # Walk backward to include all sessions sharing the same date as MonthStart
        while ($FromIdx -gt 0 -and $SessionDates[$FromIdx - 1] -ge $MonthStart) {
            $FromIdx--
        }
        $MonthWindowSessions = if ($FromIdx -le $UpToIdx -and $SortedSessions.Count -gt 0 -and $UpToIdx -ge 0) {
            $WindowLen = $UpToIdx - $FromIdx + 1
            $WindowSubset = [object[]]::new($WindowLen)
            $SortedSessions.CopyTo($FromIdx, $WindowSubset, 0, $WindowLen)
            $WindowSubset
        } else {
            @()
        }

        if ($EntitiesPreProvided) {
            # Filter in-memory by status history rather than re-parsing entities.md
            # from disk on each month iteration — avoids repeated file I/O
            $MonthEntities = foreach ($E in $Entities) {
                $Status = Get-LastActiveValue -History $E.StatusHistory -PropertyName 'Value' -ActiveOn $EffectiveDate
                if ($Status -eq 'Usunięty') { continue }
                $E
            }
            $MonthEntities = @($MonthEntities)
        } else {
            # Full disk parse with temporal filtering when no pre-provided entities
            $MonthEntities = Get-Entity -ActiveOn $EffectiveDate -Quiet
            if (-not $MonthEntities) { $MonthEntities = @() }
        }

        # Pass only sessions up to month-end — later sessions cannot contribute
        # overrides visible at EffectiveDate, reducing Get-EntityState work
        $MonthState = @()
        if ($MonthEntities.Count -gt 0) {
            $MonthState = @(Get-EntityState -Entities $MonthEntities -Sessions $MonthSessions -NameIndex $NameIndex -ActiveOn $EffectiveDate -Quiet)
        }
        if (-not $MonthState) { $MonthState = @() }

        # Multi-name lookup for owner type classification (Physical vs Virtual)
        $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($E in $MonthState) {
            foreach ($Name in $E.Names) {
                if (-not $EntityLookup.ContainsKey($Name)) {
                    $EntityLookup[$Name] = $E
                }
            }
        }

        # Extract currency items with owner classification for this month's state
        $CurrencyItems = @()
        if ($MonthState.Count -gt 0) {
            $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $MonthState -IncludeInactive -EntityLookup $EntityLookup
        }
        if (-not $CurrencyItems) { $CurrencyItems = @() }

        # Narrow to user-specified denomination or entity owner scope
        if ($DenomFilter) {
            $Filtered = [System.Collections.Generic.List[object]]::new()
            foreach ($Item in $CurrencyItems) {
                if ($Item.Denomination.Name -eq $DenomFilter.Name) { $Filtered.Add($Item) }
            }
            $CurrencyItems = @($Filtered)
        }
        if ($Entity) {
            $Filtered = [System.Collections.Generic.List[object]]::new()
            foreach ($Item in $CurrencyItems) {
                if ($Item.Owner -and [string]::Equals($Item.Owner, $Entity, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Filtered.Add($Item)
                }
            }
            $CurrencyItems = @($Filtered)
        }

        # Scope @Transfer directives to this month's date window using pre-sliced subset
        $TransferEntries = @()
        if ($MonthWindowSessions.Count -gt 0) {
            $TransferEntries = @(Get-SessionDirectiveEntries -Sessions $MonthWindowSessions -DirectiveName 'Transfers' -MinDate $MonthStart -MaxDate $EffectiveDate)
        }

        # Delegate aggregation (supply split, Gini, transfer count) to economy-helpers
        $Data = New-EconomicSnapshotData -CurrencyItems $CurrencyItems -TransferEntries $TransferEntries

        $Timeline.Add([PSCustomObject]@{
            Month                = $Current.ToString('yyyy-MM')
            TotalSupplyKogi      = $Data.TotalSupplyKogi
            PhysicalSupplyKogi   = $Data.PhysicalSupplyKogi
            VirtualSupplyKogi    = $Data.VirtualSupplyKogi
            SupplyByDenomination = $Data.SupplyByDenomination
            TransferCount        = $Data.TransactionVolume
        })

        $Current = $Current.AddMonths(1)
    }

    return @($Timeline)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

<#
    .SYNOPSIS
    Detects dormant entities based on configurable inactivity threshold.

    .DESCRIPTION
    This file contains Get-DormancyReport which identifies entities with no
    recent activity. Activity is determined from:
    (a) Most recent ValidFrom across all history lists (property changes)
    (b) Session graph index participant records (session mentions)
    (c) Entity creation date (earliest ValidFrom across histories)

    The session graph index (_index.json) is used when available to include
    session mention dates. When the graph index is unavailable or stale,
    falls back to property-change dates only and emits a warning.

    Status defaults: excludes Usunięty by default (use -IncludeDeleted).
    Entities with null Status are treated as Aktywny.

    Entities with no history data at all are included as dormant with
    LastActivity = $null and DaysDormant based on current date.
#>

function Get-DormancyReport {
    <#
        .SYNOPSIS
        Detects dormant entities based on configurable inactivity threshold.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Months of inactivity to qualify as dormant")]
        [int]$ThresholdMonths = 6,

        [Parameter(HelpMessage = "Filter by entity type")]
        [string]$Type,

        [Parameter(HelpMessage = "Include Usunięty entities")]
        [switch]$IncludeDeleted,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity or Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-EntityState
    }

    $CutoffDate = [DateTime]::Now.AddMonths(-$ThresholdMonths)

    # Build session graph last-seen map: EntityName -> latest session date
    $SessionLastSeen = [System.Collections.Generic.Dictionary[string, datetime]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Try loading session graph index for session mention dates
    $GraphIndexPath = $null
    try {
        $RepoRoot = Get-RepoRoot
        $GraphIndexPath = Join-Path $RepoRoot '.session-graph' '_index.json'
    } catch { }

    $GraphLoaded = $false
    if ($GraphIndexPath -and [System.IO.File]::Exists($GraphIndexPath)) {
        try {
            $JsonContent = [System.IO.File]::ReadAllText($GraphIndexPath)
            $GraphIndex = $JsonContent | ConvertFrom-Json
            foreach ($Prop in $GraphIndex.PSObject.Properties) {
                $Entry = $Prop.Value
                $EntryDate = $null
                if ($Entry.Date) {
                    [void][datetime]::TryParseExact($Entry.Date, 'yyyy-MM-dd',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$EntryDate)
                }
                if ($null -eq $EntryDate) { continue }

                if ($Entry.Participants) {
                    foreach ($P in $Entry.Participants) {
                        $PName = $P.Name
                        if (-not $PName) { continue }
                        if (-not $SessionLastSeen.ContainsKey($PName) -or $EntryDate -gt $SessionLastSeen[$PName]) {
                            $SessionLastSeen[$PName] = $EntryDate
                        }
                    }
                }
            }
            $GraphLoaded = $true
        } catch {
            Write-RobotWarning "[WARN Get-DormancyReport] Failed to load session graph index: $($_.Exception.Message)"
        }
    }

    if (-not $GraphLoaded) {
        Write-RobotWarning "[WARN Get-DormancyReport] Session graph index not available — using property-change dates only"
    }

    $Results = [System.Collections.Generic.List[object]]::new()

    # History list names to scan for activity dates
    $HistoryArrays = @(
        'LocationHistory', 'DoorHistory', 'TypeHistory', 'OwnerHistory',
        'GroupHistory', 'StatusHistory', 'QuantityHistory',
        'FilePathHistory', 'NerthusNameHistory'
    )

    foreach ($Entity in $Entities) {
        # Status gate
        $EntityStatus = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        if ([string]::Equals($EntityStatus, 'Usunięty', [System.StringComparison]::OrdinalIgnoreCase) -and -not $IncludeDeleted) { continue }

        # Type filter
        if ($Type) {
            if (-not $Entity.Type -or -not [string]::Equals($Entity.Type, $Type, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Find latest and earliest ValidFrom across all history lists
        $LastDate = $null
        $EarliestDate = $null
        $LastSource = 'Creation'

        foreach ($ArrayName in $HistoryArrays) {
            $History = $Entity.$ArrayName
            if (-not $History -or $History.Count -eq 0) { continue }

            foreach ($Entry in $History) {
                $VF = $Entry.ValidFrom
                if ($null -eq $VF) { continue }

                if ($null -eq $LastDate -or $VF -gt $LastDate) {
                    $LastDate = $VF
                    $LastSource = 'PropertyChange'
                }
                if ($null -eq $EarliestDate -or $VF -lt $EarliestDate) {
                    $EarliestDate = $VF
                }
            }
        }

        # Check session graph for more recent activity
        if ($SessionLastSeen.ContainsKey($Entity.Name)) {
            $SessionDate = $SessionLastSeen[$Entity.Name]
            if ($null -eq $LastDate -or $SessionDate -gt $LastDate) {
                $LastDate = $SessionDate
                $LastSource = 'SessionMention'
            }
        }

        # Determine dormancy
        if ($null -ne $LastDate -and $LastDate -ge $CutoffDate) { continue }

        $DaysDormant = if ($null -ne $LastDate) {
            [int][math]::Floor(([DateTime]::Now - $LastDate).TotalDays)
        } else {
            [int][math]::Floor(([DateTime]::Now - [DateTime]::MinValue).TotalDays)
        }

        $Results.Add([PSCustomObject]@{
            Name         = $Entity.Name
            Type         = $Entity.Type
            Status       = $EntityStatus
            LastActivity = $LastDate
            DaysDormant  = $DaysDormant
            CreatedOn    = $EarliestDate
            LastSource   = $LastSource
        })
    }

    # Sort by DaysDormant descending (most dormant first)
    $Results.Sort([System.Comparison[object]]{ param($a, $b) $b.DaysDormant.CompareTo($a.DaysDormant) })

    return @($Results)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

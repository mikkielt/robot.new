<#
    .SYNOPSIS
    Returns a unified chronological timeline of all changes for a single entity.

    .DESCRIPTION
    Get-EntityHistory collects all temporal history arrays from a single
    entity and merges them into a flat, chronologically sorted timeline.

    Merged history arrays:
    - LocationHistory (@lokacja), StatusHistory (@status),
      GroupHistory (@grupa), OwnerHistory (@należy_do),
      TypeHistory (@typ), DoorHistory (@drzwi), QuantityHistory (@ilość)

    Processing pipeline:
    1. Fetch entities via Get-EntityState if not pre-provided
    2. Resolve entity by primary Name, then fall back to alias scanning
       via the Names collection (covers @alias, @generyczne_nazwy matches)
    3. Iterate the HistoryMappings table to extract entries from each
       history array, applying optional MinDate/MaxDate range filter
    4. Sort the merged timeline with nulls-first ordering (entries without
       ValidFrom represent initial/default state from entity declaration)

    The HistoryMappings table maps each history array to its display
    name (Polish) and the .Value property from Robot.TemporalEntry objects.
    This allows uniform iteration without per-array special-casing.

    The sort uses a .NET Comparison delegate for in-place List.Sort().
    Null dates sort before all dated entries, representing the entity's
    initial state at declaration time.
#>

function Get-EntityHistory {
    <#
        .SYNOPSIS
        View the full change timeline for a single entity.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "Entity name to look up")]
        [string]$Name,

        [Parameter(HelpMessage = "Include only changes on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only changes on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session (passed to Get-EntityState)")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $Entities) {
        $FetchArgs = @{}
        if ($Sessions) { $FetchArgs['Sessions'] = $Sessions }
        $Entities = Get-EntityState @FetchArgs
    }

    # First try exact primary name match, then scan alias collections
    $Entity = $null
    foreach ($E in $Entities) {
        if ([string]::Equals($E.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Entity = $E
            break
        }
    }

    if (-not $Entity) {
        # Fall back to alias scanning (covers @alias and @generyczne_nazwy)
        foreach ($E in $Entities) {
            if ($E.Names) {
                foreach ($N in $E.Names) {
                    if ([string]::Equals($N, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $Entity = $E
                        break
                    }
                }
            }
            if ($Entity) { break }
        }
    }

    if (-not $Entity) {
        Write-RobotWarning "[WARN Get-EntityHistory] Entity '$Name' not found"
        return @()
    }

    $Timeline = [System.Collections.Generic.List[object]]::new()

    # Map each history array to its Polish display label and the property holding the value
    $HistoryMappings = @(
        @{ Array = 'LocationHistory'; Display = 'Lokacja';     Prop = 'Value' }
        @{ Array = 'StatusHistory';   Display = 'Status';      Prop = 'Value' }
        @{ Array = 'GroupHistory';    Display = 'Grupa';       Prop = 'Value' }
        @{ Array = 'OwnerHistory';   Display = 'Właściciel';  Prop = 'Value' }
        @{ Array = 'TypeHistory';    Display = 'Typ';         Prop = 'Value' }
        @{ Array = 'DoorHistory';    Display = 'Drzwi';       Prop = 'Value' }
        @{ Array = 'QuantityHistory'; Display = 'Ilość';      Prop = 'Value' }
    )

    foreach ($Mapping in $HistoryMappings) {
        $History = $Entity.($Mapping.Array)
        if (-not $History -or $History.Count -eq 0) { continue }

        foreach ($Entry in $History) {
            if ($MinDate -and $Entry.ValidFrom -and $Entry.ValidFrom -lt $MinDate) { continue }
            if ($MaxDate -and $Entry.ValidFrom -and $Entry.ValidFrom -gt $MaxDate) { continue }

            $Timeline.Add([PSCustomObject]@{
                Date     = $Entry.ValidFrom
                DateEnd  = $Entry.ValidTo
                Property = $Mapping.Display
                Value    = $Entry.($Mapping.Prop)
            })
        }
    }

    # Null dates (initial state from entity declaration) sort before dated entries
    $Timeline.Sort([System.Comparison[object]]{
        param($a, $b)
        if ($null -eq $a.Date -and $null -eq $b.Date) { return 0 }
        if ($null -eq $a.Date) { return -1 }
        if ($null -eq $b.Date) { return 1 }
        return $a.Date.CompareTo($b.Date)
    })

    return @($Timeline)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

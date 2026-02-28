<#
    .SYNOPSIS
    Returns a unified chronological timeline of all changes for a single entity.

    .DESCRIPTION
    Given an entity name, collects all temporal history arrays (LocationHistory,
    StatusHistory, GroupHistory, OwnerHistory, TypeHistory, DoorHistory,
    QuantityHistory) and merges them into a flat, chronologically sorted timeline.

    Supports optional date range filtering. Uses Get-EntityState for pre-fetching
    if entities are not provided.
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
        [object[]]$Sessions
    )

    if (-not $Entities) {
        $FetchArgs = @{}
        if ($Sessions) { $FetchArgs['Sessions'] = $Sessions }
        $Entities = Get-EntityState @FetchArgs
    }

    # Find entity by name (case-insensitive)
    $Entity = $null
    foreach ($E in $Entities) {
        if ([string]::Equals($E.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Entity = $E
            break
        }
    }

    if (-not $Entity) {
        # Try matching against Names list (aliases)
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
        [System.Console]::Error.WriteLine("[WARN Get-EntityHistory] Entity '$Name' not found")
        return @()
    }

    $Timeline = [System.Collections.Generic.List[object]]::new()

    # Property mapping: HistoryArray → (DisplayName, ValueProperty)
    $HistoryMappings = @(
        @{ Array = 'LocationHistory'; Display = 'Lokacja';     Prop = 'Location'  }
        @{ Array = 'StatusHistory';   Display = 'Status';      Prop = 'Status'    }
        @{ Array = 'GroupHistory';    Display = 'Grupa';       Prop = 'Group'     }
        @{ Array = 'OwnerHistory';   Display = 'Właściciel';  Prop = 'OwnerName' }
        @{ Array = 'TypeHistory';    Display = 'Typ';         Prop = 'Type'      }
        @{ Array = 'DoorHistory';    Display = 'Drzwi';       Prop = 'Location'  }
        @{ Array = 'QuantityHistory'; Display = 'Ilość';      Prop = 'Quantity'  }
    )

    foreach ($Mapping in $HistoryMappings) {
        $History = $Entity.($Mapping.Array)
        if (-not $History -or $History.Count -eq 0) { continue }

        foreach ($Entry in $History) {
            # Date range filtering
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

    # Sort: nulls first, then ascending by Date
    $Timeline.Sort([System.Comparison[object]]{
        param($a, $b)
        if ($null -eq $a.Date -and $null -eq $b.Date) { return 0 }
        if ($null -eq $a.Date) { return -1 }
        if ($null -eq $b.Date) { return 1 }
        return $a.Date.CompareTo($b.Date)
    })

    return @($Timeline)
}

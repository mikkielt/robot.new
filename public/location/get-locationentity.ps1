<#
    .SYNOPSIS
    Queries Lokacja (and optionally Mapa) entities with filtering and enrichment.

    .DESCRIPTION
    This file contains Get-LocationEntity which wraps Get-EntityState output
    with location-specific enrichment logic.

    Processing pipeline:
    1. Fetches entities via Get-EntityState (or uses pre-fetched -Entities)
    2. Builds reverse lookups: parent→children, location→entity count, name→entity
    3. Filters to Lokacja entities (or Lokacja+Mapa with -IncludeMaps) with
       status/name/parent/hasDoors/isExterior gates
    4. Enriches each entity with Children, DoorTargets, IsExterior (from computed
       Entity.IsExterior when available, falling back to coordinates check),
       HierarchicalPath, EntityCount, NerthusName, MapData (Overrides extraction),
       ExteriorParent (nearest exterior ancestor via @lokacja chain walk), and
       QualifiedPath ("ExteriorParent/Name" for interior locations)
    5. Returns enriched PSCustomObject array

    Uses Get-EntityState (not Get-Entity) because CN (hierarchical path) is only
    available on resolved entity state objects.

    By default excludes Usunięty entities (use -IncludeDeleted).
    By default excludes Nieaktywny entities (use -IncludeInactive).
#>

function Get-LocationEntity {
    <#
        .SYNOPSIS
        Queries Lokacja (and optionally Mapa) entities with optional filtering and enrichment.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by entity name (substring, case-insensitive)")]
        [string]$Name,

        [Parameter(HelpMessage = "Filter by parent location name (exact, case-insensitive)")]
        [string]$Parent,

        [Parameter(HelpMessage = "Only return locations with door connections")]
        [switch]$HasDoors,

        [Parameter(HelpMessage = "Only return exterior locations (have coordinates)")]
        [switch]$IsExterior,

        [Parameter(HelpMessage = "Filter by status value")]
        [string]$Status,

        [Parameter(HelpMessage = "Include Nieaktywny entities")]
        [switch]$IncludeInactive,

        [Parameter(HelpMessage = "Include Usunięty entities")]
        [switch]$IncludeDeleted,

        [Parameter(HelpMessage = "Include Mapa entities alongside Lokacja")]
        [switch]$IncludeMaps,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-EntityState -Quiet
    }

    # Build reverse lookup: parent -> children (location/map entities only)
    $ChildrenOf = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    # Build entity count at location (non-location entities)
    $EntityCountAt = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    # Entity name lookup for door target resolution
    $EntityByName = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($E in $Entities) {
        if ($E.Name -and -not $EntityByName.ContainsKey($E.Name)) { $EntityByName[$E.Name] = $E }
        if ($E.Location) {
            if ($E.Type -eq 'Lokacja' -or $E.Type -eq 'Mapa') {
                if (-not $ChildrenOf.ContainsKey($E.Location)) {
                    $ChildrenOf[$E.Location] = [System.Collections.Generic.List[object]]::new()
                }
                $ChildrenOf[$E.Location].Add($E)
            } else {
                if (-not $EntityCountAt.ContainsKey($E.Location)) { $EntityCountAt[$E.Location] = 0 }
                $EntityCountAt[$E.Location]++
            }
        }
    }

    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($E in $Entities) {
        # Type gate
        if ($IncludeMaps) {
            if ($E.Type -ne 'Lokacja' -and $E.Type -ne 'Mapa') { continue }
        } else {
            if ($E.Type -ne 'Lokacja') { continue }
        }
        # Status gates
        $EStatus = if ($E.Status) { $E.Status } else { 'Aktywny' }
        if ([string]::Equals($EStatus, 'Usunięty', 'OrdinalIgnoreCase') -and -not $IncludeDeleted) { continue }
        if ([string]::Equals($EStatus, 'Nieaktywny', 'OrdinalIgnoreCase') -and -not $IncludeInactive) { continue }
        if ($Status -and -not [string]::Equals($EStatus, $Status, 'OrdinalIgnoreCase')) { continue }
        # Name filter (substring)
        if ($Name -and $E.Name.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        # Parent filter (exact)
        if ($Parent -and (-not $E.Location -or -not [string]::Equals($E.Location, $Parent, 'OrdinalIgnoreCase'))) { continue }
        # HasDoors filter
        $HasDoorsProp = ($E.PSObject.Properties['Doors'] -and $E.Doors -and $E.Doors.Count -gt 0)
        if ($HasDoors -and -not $HasDoorsProp) { continue }
        # IsExterior filter — use computed IsExterior from Get-Entity post-parse;
        # fall back to coordinates check for entities without the property
        $IsExt = if ($E.PSObject.Properties['IsExterior'] -and $null -ne $E.IsExterior) {
            $E.IsExterior -eq $true
        } else {
            ($E.PSObject.Properties['Coordinates'] -and $null -ne $E.Coordinates)
        }
        if ($IsExterior -and -not $IsExt) { continue }

        # Enrich: children
        $Children = if ($ChildrenOf.ContainsKey($E.Name)) { @($ChildrenOf[$E.Name]) } else { @() }
        # Enrich: door targets
        $DoorTargets = @()
        if ($HasDoorsProp) {
            $DoorTargets = @(foreach ($D in $E.Doors) {
                if ($EntityByName.ContainsKey($D)) { $EntityByName[$D] } else { [PSCustomObject]@{ Name = $D; Resolved = $false } }
            })
        }
        # Enrich: entity count at this location
        $EntCount = if ($EntityCountAt.ContainsKey($E.Name)) { $EntityCountAt[$E.Name] } else { 0 }
        # Enrich: NerthusName
        $NerthusNameVal = if ($E.PSObject.Properties['NerthusName']) { $E.NerthusName } else { $null }
        # Enrich: map-specific data from Overrides (C1 fix: @slug, @url, @url_nerthus, @wymiary stored in Overrides)
        $MapData = $null
        if ($E.Type -eq 'Mapa' -and $E.PSObject.Properties['Overrides'] -and $E.Overrides) {
            $MapData = [PSCustomObject]@{
                Slug       = if ($E.Overrides.ContainsKey('slug'))        { $E.Overrides['slug'] }        else { $null }
                Url        = if ($E.Overrides.ContainsKey('url'))         { $E.Overrides['url'] }         else { $null }
                UrlNerthus = if ($E.Overrides.ContainsKey('url_nerthus')) { $E.Overrides['url_nerthus'] } else { $null }
                Dimensions = if ($E.Overrides.ContainsKey('wymiary'))    { $E.Overrides['wymiary'] }     else { $null }
            }
        }

        # Enrich: ExteriorParent and QualifiedPath for interior locations
        $ExtParent = $null
        $QPath = $null
        if (-not $IsExt -and $E.Location) {
            $WalkVisited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            [void]$WalkVisited.Add($E.Name)
            $WalkCurrent = $E
            while ($true) {
                $WalkParentName = $WalkCurrent.Location
                if (-not $WalkParentName) { break }
                if (-not $WalkVisited.Add($WalkParentName)) { break }
                if ($EntityByName.ContainsKey($WalkParentName)) {
                    $WalkParentEnt = $EntityByName[$WalkParentName]
                    $WalkParentIsExt = if ($WalkParentEnt.PSObject.Properties['IsExterior'] -and $null -ne $WalkParentEnt.IsExterior) {
                        $WalkParentEnt.IsExterior -eq $true
                    } else {
                        ($WalkParentEnt.PSObject.Properties['Coordinates'] -and $null -ne $WalkParentEnt.Coordinates)
                    }
                    if ($WalkParentIsExt) {
                        $ExtParent = $WalkParentEnt.Name
                        $QPath = "$($WalkParentEnt.Name)/$($E.Name)"
                        break
                    }
                    $WalkCurrent = $WalkParentEnt
                } else {
                    break
                }
            }
        }

        $Results.Add([PSCustomObject]@{
            Entity           = $E
            EntityName       = $E.Name
            Type             = $E.Type
            Parent           = $E.Location
            Children         = $Children
            ChildCount       = $Children.Count
            DoorTargets      = $DoorTargets
            DoorCount        = $DoorTargets.Count
            IsExterior       = $IsExt
            Coordinates      = $E.Coordinates
            HierarchicalPath = $E.CN
            NerthusName      = $NerthusNameVal
            EntityCount      = $EntCount
            Status           = $EStatus
            MapData          = $MapData
            ExteriorParent   = $ExtParent
            QualifiedPath    = $QPath
        })
    }

    return @($Results)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

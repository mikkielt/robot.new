<#
    .SYNOPSIS
    Cross-references Robot Lokacja entities with nerthusaddon map data.

    .DESCRIPTION
    Compares entities that have @margonemid overrides against the map IDs
    found in nerthusaddon's maps.json. Reports coverage status:
    - Covered:   entity has @margonemid matching maps.json IDs
    - Gaps:      entity has @margonemid but no addon map for that ID
    - Orphans:   maps.json entries with no matching entity @margonemid
    - Unlinked:  Lokacja entities without any @margonemid
    - Seasonal coverage per location

    Dot-sources nerthusaddon-helpers.ps1 for helper functions.
#>

# Load helpers
. "$PSScriptRoot/../private/nerthusaddon-helpers.ps1"

function Get-NerthusLocationReport {
    <#
        .SYNOPSIS
        Cross-references entities with nerthusaddon map data.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override path to maps.json file")]
        [string]$MapsJsonPath,

        [Parameter(HelpMessage = "Pre-fetched entity data from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-PluginConfig -PluginName 'nerthusaddon-integration'

    if (-not $MapsJsonPath) {
        $MapsJsonPath = Get-NerthusAddonMapsJsonPath -Config $Config
        if (-not $MapsJsonPath) {
            throw "NerthusAddonPath not configured. Set ROBOT_NERTHUSADDON_PATH or add to local.config.psd1."
        }
    }

    # Load addon maps
    $AddonData = Read-NerthusAddonMapsJson -Path $MapsJsonPath
    if (-not $AddonData) {
        throw "Failed to load nerthusaddon maps.json from '$MapsJsonPath'."
    }

    # Build lookup: mapId -> list of seasons
    $AddonMapIds = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new()
    foreach ($SeasonProp in $AddonData | Get-Member -MemberType NoteProperty) {
        $Season = $SeasonProp.Name
        $SeasonMaps = $AddonData.$Season
        foreach ($MapProp in $SeasonMaps | Get-Member -MemberType NoteProperty) {
            $MapId = [int]$MapProp.Name
            if (-not $AddonMapIds.ContainsKey($MapId)) {
                $AddonMapIds[$MapId] = [System.Collections.Generic.List[string]]::new()
            }
            [void]$AddonMapIds[$MapId].Add($Season)
        }
    }

    # Load entities if not provided
    if (-not $Entities) {
        $Entities = Get-Entity -Quiet
    }

    # Filter to Lokacja entities
    $Locations = $Entities | Where-Object { $_.Type -eq 'Lokacja' }

    $Covered  = [System.Collections.Generic.List[object]]::new()
    $Gaps     = [System.Collections.Generic.List[object]]::new()
    $Unlinked = [System.Collections.Generic.List[object]]::new()

    # Track which addon IDs are matched
    $MatchedAddonIds = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($Loc in $Locations) {
        $MargonemIds = @()
        if ($Loc.Overrides -and $Loc.Overrides.ContainsKey('margonemid')) {
            $MargonemIds = @($Loc.Overrides['margonemid'] | ForEach-Object {
                $Parsed = $_.Text
                if ($Parsed -match '^\d+$') { [int]$Parsed }
            })
        }

        if ($MargonemIds.Count -eq 0) {
            [void]$Unlinked.Add([PSCustomObject]@{
                EntityName = $Loc.Name
                CN         = $Loc.CN
                Status     = 'Unlinked'
            })
            continue
        }

        foreach ($Mid in $MargonemIds) {
            if ($AddonMapIds.ContainsKey($Mid)) {
                [void]$MatchedAddonIds.Add($Mid)
                [void]$Covered.Add([PSCustomObject]@{
                    EntityName = $Loc.Name
                    CN         = $Loc.CN
                    MargonemId = $Mid
                    Seasons    = $AddonMapIds[$Mid].ToArray()
                    Status     = 'Covered'
                })
            } else {
                [void]$Gaps.Add([PSCustomObject]@{
                    EntityName = $Loc.Name
                    CN         = $Loc.CN
                    MargonemId = $Mid
                    Status     = 'Gap'
                })
            }
        }
    }

    # Find orphan addon IDs (no matching entity)
    $Orphans = [System.Collections.Generic.List[object]]::new()
    foreach ($KV in $AddonMapIds.GetEnumerator()) {
        if (-not $MatchedAddonIds.Contains($KV.Key)) {
            [void]$Orphans.Add([PSCustomObject]@{
                MargonemId = $KV.Key
                Seasons    = $KV.Value.ToArray()
                Status     = 'Orphan'
            })
        }
    }

    return [PSCustomObject]@{
        Covered      = $Covered.ToArray()
        Gaps         = $Gaps.ToArray()
        Orphans      = $Orphans.ToArray()
        Unlinked     = $Unlinked.ToArray()
        CoveredCount = $Covered.Count
        GapCount     = $Gaps.Count
        OrphanCount  = $Orphans.Count
        UnlinkedCount = $Unlinked.Count
        TotalAddonMaps = $AddonMapIds.Count
    }

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

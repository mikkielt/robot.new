<#
    .SYNOPSIS
    Cross-references Lokacja entities with MargoWorld maps.json data.

    .DESCRIPTION
    Matches entities by @margonemid overrides to maps.json IDs.
    Reports:
    - Mapped:       entity has @margonemid matching a maps.json entry
    - Unmapped:     entity has @margonemid but no maps.json entry
    - Unregistered: maps.json entries with no matching entity @margonemid
    - NoId:         Lokacja entities without any @margonemid

    Identifies multi-floor groups that should be single entities.
    Identifies ambiguous groups (same base name, different physical locations)
    and enriches unregistered entries with UrlContext and DisambiguatedName.

    Dot-sources margoworld-helpers.ps1 for helper functions.
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"

function Get-MargoWorldLocationReport {
    <#
        .SYNOPSIS
        Cross-references Lokacja entities with MargoWorld maps.json data.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override path to maps.json registry")]
        [string]$MapsJsonPath,

        [Parameter(HelpMessage = "Pre-fetched entity data from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-PluginConfig -PluginName 'margoworld-datasource'

    if (-not $MapsJsonPath) {
        $MapsJsonPath = Get-MargoWorldMapsJsonPath -Config $Config
        if (-not $MapsJsonPath) {
            throw "MapsJsonPath not resolved. Set in local.config.psd1 or ensure .robot/res/ exists."
        }
    }

    # Load maps.json
    $RegistryData = Read-MargoWorldMapsJson -Path $MapsJsonPath
    if (-not $RegistryData -or -not $RegistryData.maps) {
        throw "Failed to load maps.json from '$MapsJsonPath' or file has no 'maps' array."
    }

    # Build map ID -> registry entry lookup
    $RegistryById = [System.Collections.Generic.Dictionary[int, object]]::new()
    foreach ($MapEntry in $RegistryData.maps) {
        $RegistryById[$MapEntry.id] = $MapEntry
    }

    # Load entities if not provided
    if (-not $Entities) {
        $Entities = Get-Entity -Quiet
    }

    $Locations = $Entities | Where-Object { $_.Type -eq 'Lokacja' }

    $Mapped       = [System.Collections.Generic.List[object]]::new()
    $Unmapped     = [System.Collections.Generic.List[object]]::new()
    $NoId         = [System.Collections.Generic.List[object]]::new()
    $MatchedRegIds = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($Loc in $Locations) {
        $MargonemIds = @()
        if ($Loc.Overrides -and $Loc.Overrides.ContainsKey('margonemid')) {
            $MargonemIds = @($Loc.Overrides['margonemid'] | ForEach-Object {
                $Parsed = $_.Text
                if ($Parsed -match '^\d+$') { [int]$Parsed }
            })
        }

        if ($MargonemIds.Count -eq 0) {
            [void]$NoId.Add([PSCustomObject]@{
                EntityName = $Loc.Name
                CN         = $Loc.CN
                Status     = 'NoId'
            })
            continue
        }

        foreach ($Mid in $MargonemIds) {
            if ($RegistryById.ContainsKey($Mid)) {
                [void]$MatchedRegIds.Add($Mid)
                $RegEntry = $RegistryById[$Mid]
                [void]$Mapped.Add([PSCustomObject]@{
                    EntityName  = $Loc.Name
                    CN          = $Loc.CN
                    MargonemId  = $Mid
                    RegistryName = $RegEntry.name
                    RegistryUrl  = $RegEntry.url
                    Status       = 'Mapped'
                })
            } else {
                [void]$Unmapped.Add([PSCustomObject]@{
                    EntityName = $Loc.Name
                    CN         = $Loc.CN
                    MargonemId = $Mid
                    Status     = 'Unmapped'
                })
            }
        }
    }

    # Find unregistered maps (in registry but no entity references them)
    $Unregistered = [System.Collections.Generic.List[object]]::new()
    foreach ($KV in $RegistryById.GetEnumerator()) {
        if (-not $MatchedRegIds.Contains($KV.Key)) {
            $BaseName = Get-MapBaseName -Name $KV.Value.name
            $UrlCtx = Get-UrlLocationContext -Url $KV.Value.url
            $DisName = if ($UrlCtx) { "$BaseName ($UrlCtx)" } else { $BaseName }
            [void]$Unregistered.Add([PSCustomObject]@{
                MargonemId        = $KV.Key
                RegistryName      = $KV.Value.name
                RegistryUrl       = $KV.Value.url
                BaseName          = $BaseName
                UrlContext         = $UrlCtx
                DisambiguatedName = $DisName
                Status            = 'Unregistered'
            })
        }
    }

    # Identify multi-floor groups among unregistered
    $FloorGroups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($U in $Unregistered) {
        if (-not $FloorGroups.ContainsKey($U.BaseName)) {
            $FloorGroups[$U.BaseName] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$FloorGroups[$U.BaseName].Add($U)
    }

    $MultiFloorCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($KV in $FloorGroups.GetEnumerator()) {
        if ($KV.Value.Count -gt 1) {
            [void]$MultiFloorCandidates.Add([PSCustomObject]@{
                BaseName = $KV.Key
                MapCount = $KV.Value.Count
                MapIds   = @($KV.Value | ForEach-Object { $_.MargonemId })
            })
        }
    }

    # Identify ambiguous groups: same base name maps to different physical locations (different URL contexts)
    $AmbiguousGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($KV in $FloorGroups.GetEnumerator()) {
        $UrlContexts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Entry in $KV.Value) {
            if ($Entry.UrlContext) {
                [void]$UrlContexts.Add($Entry.UrlContext)
            }
        }
        if ($UrlContexts.Count -gt 1) {
            [void]$AmbiguousGroups.Add([PSCustomObject]@{
                BaseName    = $KV.Key
                MapCount    = $KV.Value.Count
                UrlContexts = @($UrlContexts)
                MapIds      = @($KV.Value | ForEach-Object { $_.MargonemId })
            })
        }
    }

    return [PSCustomObject]@{
        Mapped               = $Mapped.ToArray()
        Unmapped             = $Unmapped.ToArray()
        Unregistered         = $Unregistered.ToArray()
        NoId                 = $NoId.ToArray()
        MultiFloorCandidates = $MultiFloorCandidates.ToArray()
        AmbiguousGroups      = $AmbiguousGroups.ToArray()
        MappedCount          = $Mapped.Count
        UnmappedCount        = $Unmapped.Count
        UnregisteredCount    = $Unregistered.Count
        NoIdCount            = $NoId.Count
        AmbiguousGroupCount  = $AmbiguousGroups.Count
        TotalRegistryMaps    = $RegistryById.Count
    }

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

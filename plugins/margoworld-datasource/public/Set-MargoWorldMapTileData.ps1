<#
    .SYNOPSIS
    Enriches maps.json entries with tile dimensions and outerior flag.

    .DESCRIPTION
    Fetches each CDN PNG header via HTTP Range request to determine tile
    dimensions (tileWidth, tileHeight) for ALL maps. Scrapes the /world minimap
    page to determine which maps are exterior (outerior: true) vs interior
    (outerior: false). Merges this data into maps.json.

    Dot-sources margoworld-helpers.ps1 for helper functions.
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"

function Set-MargoWorldMapTileData {
    <#
        .SYNOPSIS
        Enriches maps.json with tile dimensions for all maps and marks outerior flag.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(HelpMessage = "Pre-fetched /world minimap data from ConvertFrom-MargoWorldMap")]
        [object[]]$WorldMapData,

        [Parameter(HelpMessage = "Skip entries that already have tileWidth and tileHeight")]
        [switch]$DiffOnly,

        [Parameter(HelpMessage = "Show progress to stdout")]
        [switch]$ShowProgress,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-PluginConfig -PluginName 'margoworld-datasource'
    $MargoWorldDomain = if ($Config.MargoWorldDomain) { $Config.MargoWorldDomain } else { 'https://margoworld.pl' }
    $CoordPadding = if ($Config.CoordPadding) { [int]$Config.CoordPadding } else { 7 }

    # ── Step 1: Load maps.json ──
    $JsonPath = Get-MargoWorldMapsJsonPath -Config $Config
    if (-not $JsonPath -or -not [System.IO.File]::Exists($JsonPath)) {
        Write-RobotWarning "[WARN Set-MargoWorldMapTileData] maps.json not found at '$JsonPath'"
        return $null
    }

    $Registry = Read-MargoWorldMapsJson -Path $JsonPath
    if (-not $Registry -or -not $Registry.maps) {
        Write-RobotWarning "[WARN Set-MargoWorldMapTileData] maps.json is empty or invalid"
        return $null
    }

    # ── Step 2: Get world minimap data (for outerior detection) ──
    $WorldData = $WorldMapData
    if (-not $WorldData) {
        try {
            if ($ShowProgress) {
                Write-Host "  Pobieranie minimapy /world..."
            }
            $Html = Invoke-RestMethod -Method GET -Uri "$MargoWorldDomain/world" -UseBasicParsing
            $WorldData = ConvertFrom-MargoWorldMap -Html $Html -Padding $CoordPadding
        } catch {
            Write-RobotWarning "[WARN Set-MargoWorldMapTileData] Failed to fetch /world: $_"
            return $null
        }
    }

    # ── Step 3: Build lookup of exterior map IDs ──
    $WorldById = [System.Collections.Generic.Dictionary[int, object]]::new()
    foreach ($W in $WorldData) {
        $WorldById[$W.Id] = $W
    }

    # ── Step 4: Identify maps to process (all maps, optionally skip those with dimensions) ──
    $ToProcess = [System.Collections.Generic.List[object]]::new()
    foreach ($MapEntry in $Registry.maps) {
        if ($DiffOnly) {
            $HasTileWidth  = ($null -ne $MapEntry.tileWidth -and $MapEntry.tileWidth -gt 0)
            $HasTileHeight = ($null -ne $MapEntry.tileHeight -and $MapEntry.tileHeight -gt 0)
            if ($HasTileWidth -and $HasTileHeight) {
                continue
            }
        }

        [void]$ToProcess.Add($MapEntry)
    }

    $TotalMaps = $Registry.maps.Count
    $OuteriorCount = 0
    foreach ($MapEntry in $Registry.maps) {
        if ($WorldById.ContainsKey([int]$MapEntry.id)) { $OuteriorCount++ }
    }
    $SkippedCount = $TotalMaps - $ToProcess.Count

    if ($ShowProgress) {
        Write-Host "  Mapy w rejestrze: $TotalMaps, Outerior: $OuteriorCount, Do przetworzenia: $($ToProcess.Count)"
    }

    # ── Step 5: Fetch PNG dimensions for all maps ──
    $EnrichedCount = 0
    $FailedCount = 0
    $Results = [System.Collections.Generic.List[object]]::new()
    $Failed = [System.Collections.Generic.List[object]]::new()

    $HttpClient = [System.Net.Http.HttpClient]::new()
    try {
        $ProcessedIdx = 0
        foreach ($MapEntry in $ToProcess) {
            $ProcessedIdx++
            $MapId = [int]$MapEntry.id
            $MapUrl = $MapEntry.url

            if ($ShowProgress -and $ProcessedIdx % 10 -eq 0) {
                Write-Host "  Przetwarzanie: $ProcessedIdx / $($ToProcess.Count)..."
            }

            if ([string]::IsNullOrWhiteSpace($MapUrl)) {
                $FailedCount++
                [void]$Failed.Add([PSCustomObject]@{ Id = $MapId; Name = $MapEntry.name; Url = $MapUrl })
                continue
            }

            $TileDims = Get-PngTileDimensions -Url $MapUrl -HttpClient $HttpClient
            if (-not $TileDims) {
                $FailedCount++
                [void]$Failed.Add([PSCustomObject]@{ Id = $MapId; Name = $MapEntry.name; Url = $MapUrl })
                Write-RobotWarning "[WARN Set-MargoWorldMapTileData] Failed to get PNG dimensions for map $MapId ($($MapEntry.name))"
                continue
            }

            $IsOuterior = $WorldById.ContainsKey($MapId)
            $EnrichedCount++
            [void]$Results.Add([PSCustomObject]@{
                Id         = $MapId
                Name       = $MapEntry.name
                Outerior   = $IsOuterior
                TileWidth  = [int]$TileDims.TileWidth
                TileHeight = [int]$TileDims.TileHeight
                WidthPx    = $TileDims.WidthPx
                HeightPx   = $TileDims.HeightPx
            })
        }
    } finally {
        $HttpClient.Dispose()
    }

    # ── Step 6: Merge into maps.json ──
    $EnrichedById = [System.Collections.Generic.Dictionary[int, object]]::new()
    foreach ($R in $Results) {
        $EnrichedById[$R.Id] = $R
    }

    $UpdatedMaps = [System.Collections.Generic.List[object]]::new()
    foreach ($MapEntry in $Registry.maps) {
        $MapId = [int]$MapEntry.id
        $IsOuterior = $WorldById.ContainsKey($MapId)

        if ($EnrichedById.ContainsKey($MapId)) {
            $Enriched = $EnrichedById[$MapId]

            # Build updated entry preserving existing properties
            $Updated = [PSCustomObject]@{
                id          = $MapEntry.id
                name        = $MapEntry.name
                url         = $MapEntry.url
                lastChecked = $MapEntry.lastChecked
                outerior    = $IsOuterior
                tileWidth   = $Enriched.TileWidth
                tileHeight  = $Enriched.TileHeight
            }
            [void]$UpdatedMaps.Add($Updated)
        } else {
            # Pass through with outerior flag added (preserve existing tile data if any)
            $Updated = [PSCustomObject]@{
                id          = $MapEntry.id
                name        = $MapEntry.name
                url         = $MapEntry.url
                lastChecked = $MapEntry.lastChecked
                outerior    = $IsOuterior
                tileWidth   = $MapEntry.tileWidth
                tileHeight  = $MapEntry.tileHeight
            }
            [void]$UpdatedMaps.Add($Updated)
        }
    }

    $UpdatedRegistry = [PSCustomObject]@{
        lastUpdated = $Registry.lastUpdated
        maps        = @($UpdatedMaps)
    }

    # ── Step 7: Write ──
    if ($PSCmdlet.ShouldProcess($JsonPath, "Update $($UpdatedMaps.Count) map entries with tile data and outerior flag")) {
        Write-MargoWorldMapsJson -Data $UpdatedRegistry -Path $JsonPath
    }

    return [PSCustomObject]@{
        TotalMaps      = $TotalMaps
        OuteriorCount  = $OuteriorCount
        EnrichedCount  = $EnrichedCount
        SkippedCount   = $SkippedCount
        FailedCount    = $FailedCount
        Results        = @($Results)
        Failed         = @($Failed)
    }

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

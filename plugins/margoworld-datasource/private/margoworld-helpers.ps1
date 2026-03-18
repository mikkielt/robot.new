<#
    .SYNOPSIS
    Internal helpers for the margoworld-datasource plugin.

    .DESCRIPTION
    Non-exported helper functions for parsing MargoWorld.pl HTML pages,
    reading/writing maps.json registry files, grouping multi-floor
    locations by base name, and migrating legacy maps.md to maps.json.

    Helpers:
    - Get-MargoWorldMapsJsonPath:  resolves maps.json path from plugin config
    - Read-MargoWorldMapsJson:     reads and validates maps.json registry
    - Write-MargoWorldMapsJson:    writes maps.json registry (UTF-8 no BOM)
    - ConvertFrom-MargoWorldList:  parses /world/list HTML into map entries
    - ConvertFrom-MargoWorldDetail: parses /world/view/{id} HTML for CDN URL
    - ConvertFrom-MargoWorldMap:   parses /world minimap HTML for tile coordinates
    - Get-MapBaseName:             strips floor/room/direction suffixes from map name (9 iterative patterns)
    - ConvertFrom-MapsMarkdown:    parses legacy maps.md into maps.json-compatible structure
    - Get-UrlLocationContext:      extracts location slug from CDN URL for disambiguation
    - ConvertFrom-PngHeaderBytes:  parses PNG IHDR to extract pixel dimensions and tile counts
    - Get-PngTileDimensions:       fetches PNG header via HTTP Range request for tile dimensions
    - Close-TemporalTag:           closes an open-ended temporal tag line by inserting a ValidTo date
#>

# Import canonical location regex patterns from core module
. "$PSScriptRoot/../../../private/location-helpers.ps1"

# Precompiled patterns for legacy maps.md parsing
$script:MWDateGroupPattern = [regex]::new(
    '^-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s*(.*):\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:MWEntryLinePattern = [regex]::new(
    '^\s+-\s*Id:\s*(\d+);\s*Nazwa:\s*(.+?),\s*Url:\s*(.+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Precompiled patterns for URL location context extraction
$script:MWUrlVersionPattern = [regex]::new(
    '\.\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:MWUrlSuffixPattern = [regex]::new(
    '[-.]?(?:p|s)\d+',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Regex for extracting map links from /world/list HTML
$script:MWListLinkPattern = [regex]::new(
    '<a\s+href="/world/view/(\d+)/([^"]+)"[^>]*>([^<]+)</a>',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# Regex for extracting CDN image URL from /world/view page
$script:MWDetailImagePattern = [regex]::new(
    'href="(https?://[^"]*garmory-cdn[^"]*obrazki/miasta/[^"]+)"',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# Regex for extracting positioned map links from /world minimap page
# Matches: <a href="/world/view/{id}/slug" data-tip="Name" [optional attrs] style="left: Xpx; top: Ypx; ...">
$script:MWWorldMapPattern = [regex]::new(
    '<a\s+href="/world/view/(\d+)/[^"]*"\s+data-tip="([^"]+)"\s+[^>]*?style="[^"]*left:\s*([\d.]+)px;\s*top:\s*([\d.]+)px;[^"]*"',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Resolves maps.json path: explicit config -> ResDir fallback
function Get-MargoWorldMapsJsonPath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if ($Config.MapsJsonPath) {
        return $Config.MapsJsonPath
    }

    # Fall back to Get-AdminConfig .ResDir + maps.json
    try {
        $AdminConfig = Get-AdminConfig
        if ($AdminConfig.ResDir) {
            return [System.IO.Path]::Combine($AdminConfig.ResDir, 'maps.json')
        }
    } catch { }

    return $null
}

# Reads maps.json registry. Returns parsed object or $null.
function Read-MargoWorldMapsJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }

    try {
        $JsonText = [System.IO.File]::ReadAllText($Path)
        $Data = $JsonText | ConvertFrom-Json
        return $Data
    } catch {
        Write-RobotWarning "[WARN margoworld-helpers] Failed to parse maps.json at '$Path': $_"
        return $null
    }
}

# Writes maps.json registry. UTF-8 no BOM.
function Write-MargoWorldMapsJson {
    param(
        [Parameter(Mandatory)]
        [object]$Data,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $JsonText = $Data | ConvertTo-Json -Depth 4
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $JsonText, $Utf8NoBom)
}

# Parses /world/list HTML page to extract map entries.
# Returns List of PSCustomObject with Id, Name, Slug.
function ConvertFrom-MargoWorldList {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $Results = [System.Collections.Generic.List[object]]::new()
    $Matches = $script:MWListLinkPattern.Matches($Html)

    foreach ($M in $Matches) {
        [void]$Results.Add([PSCustomObject]@{
            Id   = [int]$M.Groups[1].Value
            Slug = $M.Groups[2].Value
            Name = [System.Net.WebUtility]::HtmlDecode($M.Groups[3].Value)
        })
    }

    return $Results
}

# Parses /world/view/{id} HTML to extract CDN image URL.
# Returns URL string or $null.
function ConvertFrom-MargoWorldDetail {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $Match = $script:MWDetailImagePattern.Match($Html)
    if ($Match.Success) {
        return $Match.Groups[1].Value
    }

    return $null
}

# Strips floor, room, direction, difficulty, and named subarea suffixes from map name.
# Applied iteratively until stable to handle compounds like "p.2 - Sala Magicznego Błota".
# Safety: Named subarea requires " - " (space-dash-space), so "Karka-han" is unaffected.
function Get-MapBaseName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $Result = $Name
    do {
        $Prev = $Result
        $Result = $script:LocDifficultyPattern.Replace($Result, '')
        $Result = $script:LocFloorPattern.Replace($Result, '')
        $Result = $script:LocRoomSuffixPattern.Replace($Result, '')
        $Result = $script:LocSalaPattern.Replace($Result, '')
        $Result = $script:LocNamedSalaPattern.Replace($Result, '')
        $Result = $script:LocDirectionPattern.Replace($Result, '')
        $Result = $script:LocPietroPattern.Replace($Result, '')
        $Result = $script:LocPiwnicaPattern.Replace($Result, '')
        $Result = $script:LocNamedSubareaPattern.Replace($Result, '')
    } while ($Result -ne $Prev)

    return $Result
}

# Parses legacy maps.md format into maps.json-compatible structure.
# Deduplicates by ID (latest group entry wins). Returns $null for missing file.
function ConvertFrom-MapsMarkdown {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }

    $Lines = [System.IO.File]::ReadAllLines($Path)
    $MapById = [System.Collections.Generic.Dictionary[int, object]]::new()
    $CurrentDate = $null

    foreach ($Line in $Lines) {
        $GroupMatch = $script:MWDateGroupPattern.Match($Line)
        if ($GroupMatch.Success) {
            $CurrentDate = $GroupMatch.Groups[1].Value
            continue
        }

        $EntryMatch = $script:MWEntryLinePattern.Match($Line)
        if ($EntryMatch.Success -and $CurrentDate) {
            $Id   = [int]$EntryMatch.Groups[1].Value
            $Name = $EntryMatch.Groups[2].Value.Trim()
            $Url  = $EntryMatch.Groups[3].Value.Trim()

            # Latest group wins on ID collision (overwrites earlier)
            $MapById[$Id] = [PSCustomObject]@{
                id          = $Id
                name        = $Name
                url         = $Url
                lastChecked = $CurrentDate
            }
        }
    }

    if ($MapById.Count -eq 0) {
        return $null
    }

    # Sort by ID for deterministic output
    $SortedMaps = $MapById.Values | Sort-Object -Property id

    return [PSCustomObject]@{
        lastUpdated = $CurrentDate
        maps        = @($SortedMaps)
    }
}

# Extracts a short location slug from CDN URL for disambiguation.
# Example: "https://cdn/obrazki/miasta/torneg-umbar-top.2.png" -> "torneg-umbar"
# Returns $null for empty/invalid URLs.
function Get-UrlLocationContext {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    try {
        $Uri = [System.Uri]::new($Url)
        $FileName = [System.IO.Path]::GetFileNameWithoutExtension($Uri.AbsolutePath)
    } catch {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        return $null
    }

    # Strip version suffix (.N at end)
    $FileName = $script:MWUrlVersionPattern.Replace($FileName, '')

    # Strip floor/room markers (p1, s2, -p1, .s2, etc.)
    $FileName = $script:MWUrlSuffixPattern.Replace($FileName, '')

    # Truncate to first 2-3 hyphen-separated segments
    $Segments = $FileName -split '-'
    $TakeCount = [System.Math]::Min($Segments.Count, 3)

    # Drop trailing known noise segments (top, bot, left, right, etc.)
    $NoiseWords = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('top', 'bot', 'bottom', 'left', 'right', 'mid', 'center'),
        [System.StringComparer]::OrdinalIgnoreCase)

    while ($TakeCount -gt 1 -and $NoiseWords.Contains($Segments[$TakeCount - 1])) {
        $TakeCount--
    }

    $Result = ($Segments[0..($TakeCount - 1)]) -join '-'

    if ([string]::IsNullOrWhiteSpace($Result)) {
        return $null
    }

    return $Result
}

# Parses /world minimap HTML to extract positioned map elements with pixel coordinates.
# Converts pixel positions to tile coordinates using TileSize and Padding offset.
# Returns List of PSCustomObject with Id, Name, LeftPx, TopPx, TileX, TileY.
function ConvertFrom-MargoWorldMap {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html,

        [Parameter(HelpMessage = "Tile size in pixels")]
        [int]$TileSize = 32,

        [Parameter(HelpMessage = "Tile offset padding")]
        [int]$Padding = 7
    )

    $Results = [System.Collections.Generic.List[object]]::new()

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $Results
    }

    $Matches = $script:MWWorldMapPattern.Matches($Html)

    foreach ($M in $Matches) {
        $Id = [int]$M.Groups[1].Value
        $RawName = $M.Groups[2].Value
        $Name = [System.Net.WebUtility]::HtmlDecode($RawName)

        $LeftPx = 0.0
        $TopPx  = 0.0
        if (-not [double]::TryParse($M.Groups[3].Value, [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$LeftPx)) {
            continue
        }
        if (-not [double]::TryParse($M.Groups[4].Value, [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$TopPx)) {
            continue
        }

        $TileX = [System.Math]::Floor($LeftPx / $TileSize) + $Padding
        $TileY = [System.Math]::Floor($TopPx / $TileSize)  + $Padding

        [void]$Results.Add([PSCustomObject]@{
            Id     = $Id
            Name   = $Name
            LeftPx = $LeftPx
            TopPx  = $TopPx
            TileX  = [int]$TileX
            TileY  = [int]$TileY
        })
    }

    return $Results
}

# Parses PNG IHDR chunk from raw bytes to extract pixel dimensions and tile counts.
# Validates PNG signature (89 50 4E 47) and requires minimum 24 bytes.
# Returns PSCustomObject with WidthPx, HeightPx, TileWidth, TileHeight or $null on failure.
function ConvertFrom-PngHeaderBytes {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(HelpMessage = "Tile size in pixels")]
        [int]$TileSize = 32
    )

    # Need at least 24 bytes: 8 (signature) + 4 (IHDR length) + 4 (IHDR type) + 4 (width) + 4 (height)
    if ($Bytes.Count -lt 24) {
        return $null
    }

    # Validate PNG signature: 89 50 4E 47 (first 4 bytes)
    if ($Bytes[0] -ne 0x89 -or $Bytes[1] -ne 0x50 -or $Bytes[2] -ne 0x4E -or $Bytes[3] -ne 0x47) {
        return $null
    }

    # IHDR width: big-endian uint32 at offset 16
    $WidthPx = ([int]$Bytes[16] -shl 24) -bor ([int]$Bytes[17] -shl 16) -bor ([int]$Bytes[18] -shl 8) -bor [int]$Bytes[19]
    # IHDR height: big-endian uint32 at offset 20
    $HeightPx = ([int]$Bytes[20] -shl 24) -bor ([int]$Bytes[21] -shl 16) -bor ([int]$Bytes[22] -shl 8) -bor [int]$Bytes[23]

    if ($WidthPx -le 0 -or $HeightPx -le 0 -or $TileSize -le 0) {
        return $null
    }

    return [PSCustomObject]@{
        WidthPx    = $WidthPx
        HeightPx   = $HeightPx
        TileWidth  = [System.Math]::Floor($WidthPx / $TileSize)
        TileHeight = [System.Math]::Floor($HeightPx / $TileSize)
    }
}

# Fetches PNG header via HTTP Range request and returns tile dimensions.
# Uses HttpClient for connection reuse across batch fetches.
# Returns same object as ConvertFrom-PngHeaderBytes, or $null on failure.
function Get-PngTileDimensions {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(HelpMessage = "Tile size in pixels")]
        [int]$TileSize = 32,

        [Parameter(HelpMessage = "Reusable HttpClient for batch operations")]
        [System.Net.Http.HttpClient]$HttpClient
    )

    $OwnClient = $false
    if (-not $HttpClient) {
        $HttpClient = [System.Net.Http.HttpClient]::new()
        $OwnClient = $true
    }

    try {
        $Request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Get, $Url)
        $Request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 31)

        $Response = $HttpClient.SendAsync($Request).GetAwaiter().GetResult()

        # Accept both 206 (partial) and 200 (full image)
        if ($Response.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent -and
            $Response.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
            return $null
        }

        $AllBytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()

        # We only need the first 24 bytes
        if ($AllBytes.Count -lt 24) {
            return $null
        }

        $HeaderBytes = if ($AllBytes.Count -gt 32) {
            $AllBytes[0..31]
        } else {
            $AllBytes
        }

        return ConvertFrom-PngHeaderBytes -Bytes $HeaderBytes -TileSize $TileSize
    }
    catch {
        return $null
    }
    finally {
        if ($OwnClient -and $HttpClient) {
            $HttpClient.Dispose()
        }
    }
}

# Closes an open-ended temporal tag line by inserting a ValidTo date.
# Handles three cases:
#   "@koordynaty: 10, 5 (2020-01:)"    → "@koordynaty: 10, 5 (2020-01:2024-06)"
#   "@koordynaty: 10, 5"               → "@koordynaty: 10, 5 (:2024-06)"
#   "@koordynaty: 10, 5 (2020-01:2023-12)" → unchanged (already closed)
function Close-TemporalTag {
    param(
        [Parameter(Mandatory)]
        [string]$Line,

        [Parameter(Mandatory)]
        [string]$ValidTo
    )

    # Pattern: open-ended temporal suffix "(YYYY-MM:)" at end of line
    $OpenEndedPattern = '\((\d{4}-\d{2}):\)\s*$'
    # Pattern: already-closed temporal suffix "(YYYY-MM:YYYY-MM)" at end of line
    $ClosedPattern = '\(\d{4}-\d{2}:\d{4}-\d{2}\)\s*$'

    # Already closed → return unchanged
    if ($Line -match $ClosedPattern) {
        return $Line
    }

    # Open-ended → insert ValidTo
    if ($Line -match $OpenEndedPattern) {
        return $Line -replace '\((\d{4}-\d{2}):\)\s*$', "(`$1:$ValidTo)"
    }

    # No temporal suffix → append (:ValidTo)
    return "$($Line.TrimEnd()) (:$ValidTo)"
}

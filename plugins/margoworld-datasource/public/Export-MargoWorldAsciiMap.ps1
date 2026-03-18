<#
    .SYNOPSIS
    Exports an ASCII world map from maps.json tile data.

    .DESCRIPTION
    Reads maps.json and renders a bordered ASCII rectangle for each map that has
    tileX, tileY, tileWidth, tileHeight data. Each character cell represents one
    tile. Smaller maps are drawn on top of larger ones so labels remain visible.

    Dot-sources margoworld-helpers.ps1 for Read-MargoWorldMapsJson and
    Get-MargoWorldMapsJsonPath.
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"

function Export-MargoWorldAsciiMap {
    <#
        .SYNOPSIS
        Renders an ASCII world map from maps.json tile data and saves to file.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Output file path (default: {ResDir}/world-map.txt)")]
        [string]$Path,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # ── Step 1: Load maps.json ──
    $Config = Get-PluginConfig -PluginName 'margoworld-datasource'
    $JsonPath = Get-MargoWorldMapsJsonPath -Config $Config
    if (-not $JsonPath -or -not [System.IO.File]::Exists($JsonPath)) {
        Write-RobotWarning "[WARN Export-MargoWorldAsciiMap] maps.json not found at '$JsonPath'"
        return $null
    }

    $Registry = Read-MargoWorldMapsJson -Path $JsonPath
    if (-not $Registry -or -not $Registry.maps) {
        Write-RobotWarning "[WARN Export-MargoWorldAsciiMap] maps.json is empty or invalid"
        return $null
    }

    # ── Step 2: Filter to entries with all 4 tile fields ──
    $Maps = [System.Collections.Generic.List[object]]::new()
    foreach ($MapEntry in $Registry.maps) {
        if ($null -eq $MapEntry.tileX -or $null -eq $MapEntry.tileY -or
            $null -eq $MapEntry.tileWidth -or $null -eq $MapEntry.tileHeight) {
            continue
        }
        $W = [int]$MapEntry.tileWidth
        $H = [int]$MapEntry.tileHeight
        if ($W -lt 2 -or $H -lt 2) { continue }

        [void]$Maps.Add([PSCustomObject]@{
            Name   = [string]$MapEntry.name
            X      = [int]$MapEntry.tileX
            Y      = [int]$MapEntry.tileY
            W      = $W
            H      = $H
            Area   = $W * $H
        })
    }

    if ($Maps.Count -eq 0) {
        Write-RobotWarning "[WARN Export-MargoWorldAsciiMap] No maps with tile data found"
        return $null
    }

    # ── Step 3: Compute grid bounds ──
    $MinX = [int]::MaxValue
    $MinY = [int]::MaxValue
    $MaxX = [int]::MinValue
    $MaxY = [int]::MinValue

    foreach ($M in $Maps) {
        if ($M.X -lt $MinX) { $MinX = $M.X }
        if ($M.Y -lt $MinY) { $MinY = $M.Y }
        $Right  = $M.X + $M.W
        $Bottom = $M.Y + $M.H
        if ($Right -gt $MaxX)  { $MaxX = $Right }
        if ($Bottom -gt $MaxY) { $MaxY = $Bottom }
    }

    $GridW = $MaxX - $MinX
    $GridH = $MaxY - $MinY

    # ── Step 4: Allocate 2D char grid ──
    $Grid = [char[][]]::new($GridH)
    for ($Row = 0; $Row -lt $GridH; $Row++) {
        $Grid[$Row] = [char[]]::new($GridW)
        for ($Col = 0; $Col -lt $GridW; $Col++) {
            $Grid[$Row][$Col] = ' '
        }
    }

    # ── Step 5: Draw maps (sorted by area descending — larger maps first) ──
    $Sorted = $Maps | Sort-Object -Property Area -Descending

    foreach ($M in $Sorted) {
        $Ox = $M.X - $MinX
        $Oy = $M.Y - $MinY
        $W  = $M.W
        $H  = $M.H

        # Draw border
        # Top-left corner
        $Grid[$Oy][$Ox] = '+'
        # Top-right corner
        $Grid[$Oy][$Ox + $W - 1] = '+'
        # Bottom-left corner
        $Grid[$Oy + $H - 1][$Ox] = '+'
        # Bottom-right corner
        $Grid[$Oy + $H - 1][$Ox + $W - 1] = '+'

        # Top and bottom edges
        for ($Col = 1; $Col -lt ($W - 1); $Col++) {
            $Grid[$Oy][$Ox + $Col] = '-'
            $Grid[$Oy + $H - 1][$Ox + $Col] = '-'
        }

        # Left and right edges
        for ($Row = 1; $Row -lt ($H - 1); $Row++) {
            $Grid[$Oy + $Row][$Ox] = '|'
            $Grid[$Oy + $Row][$Ox + $W - 1] = '|'
        }

        # Fill interior with spaces (clear any underlying content)
        for ($Row = 1; $Row -lt ($H - 1); $Row++) {
            for ($Col = 1; $Col -lt ($W - 1); $Col++) {
                $Grid[$Oy + $Row][$Ox + $Col] = ' '
            }
        }

        # Write map name centered in interior
        $InteriorW = $W - 2
        $InteriorH = $H - 2
        if ($InteriorW -gt 0 -and $InteriorH -gt 0) {
            $Label = $M.Name
            if ($Label.Length -gt $InteriorW) {
                $Label = $Label.Substring(0, $InteriorW)
            }

            $LabelRow = $Oy + 1 + [System.Math]::Floor($InteriorH / 2)
            $LabelCol = $Ox + 1 + [System.Math]::Floor(($InteriorW - $Label.Length) / 2)

            for ($i = 0; $i -lt $Label.Length; $i++) {
                $Grid[$LabelRow][$LabelCol + $i] = $Label[$i]
            }
        }
    }

    # ── Step 6: Write to file ──
    if (-not $Path) {
        try {
            $AdminConfig = Get-AdminConfig
            if ($AdminConfig.ResDir) {
                $Path = [System.IO.Path]::Combine($AdminConfig.ResDir, 'world-map.txt')
            }
        } catch { }

        if (-not $Path) {
            Write-RobotWarning "[WARN Export-MargoWorldAsciiMap] Could not resolve output path"
            return $null
        }
    }

    $Sb = [System.Text.StringBuilder]::new($GridW * $GridH)
    for ($Row = 0; $Row -lt $GridH; $Row++) {
        $Line = [string]::new($Grid[$Row]).TrimEnd()
        [void]$Sb.AppendLine($Line)
    }

    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Sb.ToString(), $Utf8NoBom)

    return $Path

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

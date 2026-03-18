<#
    .SYNOPSIS
    Internal helpers for the nerthusaddon-integration plugin.

    .DESCRIPTION
    Non-exported helper functions for parsing nerthusaddon maps.json data
    and grouping multi-floor locations.

    Helpers:
    - Read-NerthusAddonMapsJson:    reads and validates maps.json from addon repo
    - Group-NerthusAddonFloors:     groups map entries by base name (strips floor suffixes)
    - Get-NerthusAddonMapsJsonPath: resolves full path to maps.json from plugin config
#>

# Regex for stripping floor suffixes like "p.1", "p.2", etc.
$script:FloorSuffixPattern = [regex]::new(
    '\s+p\.\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Resolves the full path to maps.json from plugin config
function Get-NerthusAddonMapsJsonPath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if (-not $Config.NerthusAddonPath) {
        return $null
    }

    $AddonPath = $Config.NerthusAddonPath
    $RelPath   = if ($Config.MapsJsonRelPath) { $Config.MapsJsonRelPath } else { 'res/configs/maps.json' }

    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($AddonPath, $RelPath))
}

# Reads and parses maps.json from the nerthusaddon repository.
# Returns a hashtable with season keys mapping to hashtables of { numericId -> imagePath }.
# Returns $null on failure.
function Read-NerthusAddonMapsJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        Write-RobotWarning "[WARN nerthusaddon-helpers] maps.json not found at '$Path'"
        return $null
    }

    try {
        $JsonText = [System.IO.File]::ReadAllText($Path)
        $Data = $JsonText | ConvertFrom-Json
        return $Data
    } catch {
        Write-RobotWarning "[WARN nerthusaddon-helpers] Failed to parse maps.json at '$Path': $_"
        return $null
    }
}

# Groups map entries by base name, stripping floor suffixes (e.g. "p.1", "p.2").
# Input: array of PSCustomObject with Id, Season, ImagePath properties.
# Returns: hashtable of BaseName -> List of entries.
function Group-NerthusAddonFloors {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $Groups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Entry in $Entries) {
        $BaseName = $script:FloorSuffixPattern.Replace($Entry.Name, '')

        if (-not $Groups.ContainsKey($BaseName)) {
            $Groups[$BaseName] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$Groups[$BaseName].Add($Entry)
    }

    return $Groups
}

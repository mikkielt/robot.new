<#
    .SYNOPSIS
    Parses nerthusaddon maps.json into structured map objects.

    .DESCRIPTION
    Reads the maps.json file from the local nerthusaddon repository.
    The JSON structure is: { season: { numericId: "imagePath" } }.
    Returns structured objects with Id, Name, Season, ImagePath, BaseName.

    Dot-sources nerthusaddon-helpers.ps1 for Read-NerthusAddonMapsJson and
    Group-NerthusAddonFloors.
#>

# Load helpers
. "$PSScriptRoot/../private/nerthusaddon-helpers.ps1"

function Import-NerthusAddonMaps {
    <#
        .SYNOPSIS
        Parses nerthusaddon maps.json into structured map objects.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override path to maps.json file")]
        [string]$Path,

        [Parameter(HelpMessage = "Group results by base name (strips floor suffixes)")]
        [switch]$GroupByFloor
    )

    $Config = Get-PluginConfig -PluginName 'nerthusaddon-integration'

    if (-not $Path) {
        $Path = Get-NerthusAddonMapsJsonPath -Config $Config
        if (-not $Path) {
            throw "NerthusAddonPath not configured. Set ROBOT_NERTHUSADDON_PATH or add to local.config.psd1."
        }
    }

    $Data = Read-NerthusAddonMapsJson -Path $Path
    if (-not $Data) {
        return @()
    }

    # Parse { season: { numericId: "imagePath" } } structure
    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($SeasonProp in $Data | Get-Member -MemberType NoteProperty) {
        $Season = $SeasonProp.Name
        $SeasonMaps = $Data.$Season

        foreach ($MapProp in $SeasonMaps | Get-Member -MemberType NoteProperty) {
            $MapId     = $MapProp.Name
            $ImagePath = $SeasonMaps.$MapId

            [void]$Results.Add([PSCustomObject]@{
                Id        = [int]$MapId
                Season    = $Season
                ImagePath = $ImagePath
                Name      = $null   # Populated by cross-ref with entities or MargoWorld
                BaseName  = $null   # Populated by Group-NerthusAddonFloors
            })
        }
    }

    if ($GroupByFloor -and $Results.Count -gt 0) {
        return Group-NerthusAddonFloors -Entries $Results
    }

    return $Results
}

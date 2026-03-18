<#
    .SYNOPSIS
    Parses map data from maps.json or legacy maps.md into structured map objects.

    .DESCRIPTION
    Reads the local maps.json file (or legacy maps.md via -SourcePath) and returns
    structured objects with Id, Name, Url, LastChecked, FloorNumber, BaseName.
    Groups multi-floor locations by stripping floor/room/direction suffixes.

    When -DisambiguateNames is specified, entries that share the same BaseName
    but have different physical locations (different URLs) receive a
    DisambiguatedName property with URL-derived context appended.

    Dot-sources margoworld-helpers.ps1 for Read-MargoWorldMapsJson,
    ConvertFrom-MapsMarkdown, Get-MapBaseName, and Get-UrlLocationContext.
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"

function Get-MargoWorldMapList {
    <#
        .SYNOPSIS
        Parses map data from maps.json or legacy maps.md into structured map objects.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override path to maps.json registry")]
        [string]$Path,

        [Parameter(HelpMessage = "Path to maps.md or maps.json (auto-detect by extension)")]
        [string]$SourcePath,

        [Parameter(HelpMessage = "Group results by base name")]
        [switch]$GroupByFloor,

        [Parameter(HelpMessage = "Append URL context to ambiguous base names")]
        [switch]$DisambiguateNames,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Resolve data source
    $Data = $null

    if ($SourcePath) {
        $Ext = [System.IO.Path]::GetExtension($SourcePath)
        if ([string]::Equals($Ext, '.md', [System.StringComparison]::OrdinalIgnoreCase)) {
            $Data = ConvertFrom-MapsMarkdown -Path $SourcePath
        } else {
            $Data = Read-MargoWorldMapsJson -Path $SourcePath
        }
    } elseif ($Path) {
        $Data = Read-MargoWorldMapsJson -Path $Path
    } else {
        $Config = Get-PluginConfig -PluginName 'margoworld-datasource'
        $ResolvedPath = Get-MargoWorldMapsJsonPath -Config $Config
        if (-not $ResolvedPath) {
            throw "MapsJsonPath not resolved. Set in local.config.psd1 or ensure .robot/res/ exists."
        }
        $Data = Read-MargoWorldMapsJson -Path $ResolvedPath
    }

    if (-not $Data) {
        return @()
    }

    $Results = [System.Collections.Generic.List[object]]::new()

    # Regex for floor number extraction
    $FloorPattern = [regex]::new('p\.(\d+)$')

    foreach ($MapEntry in $Data.maps) {
        $FloorNum  = $null
        $FloorMatch = $FloorPattern.Match($MapEntry.name)
        if ($FloorMatch.Success) {
            $FloorNum = [int]$FloorMatch.Groups[1].Value
        }

        $BaseName = Get-MapBaseName -Name $MapEntry.name

        [void]$Results.Add([PSCustomObject]@{
            Id          = $MapEntry.id
            Name        = $MapEntry.name
            Url         = $MapEntry.url
            LastChecked = $MapEntry.lastChecked
            FloorNumber = $FloorNum
            BaseName    = $BaseName
        })
    }

    # Disambiguation: append URL context to entries with ambiguous base names
    if ($DisambiguateNames) {
        # Group by BaseName
        $ByBase = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Entry in $Results) {
            if (-not $ByBase.ContainsKey($Entry.BaseName)) {
                $ByBase[$Entry.BaseName] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$ByBase[$Entry.BaseName].Add($Entry)
        }

        foreach ($KV in $ByBase.GetEnumerator()) {
            $Group = $KV.Value

            # Check if entries sharing the same Name have different URLs
            $NameGroups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($E in $Group) {
                if (-not $NameGroups.ContainsKey($E.Name)) {
                    $NameGroups[$E.Name] = [System.Collections.Generic.List[object]]::new()
                }
                [void]$NameGroups[$E.Name].Add($E)
            }

            $IsAmbiguous = $false
            foreach ($NG in $NameGroups.GetEnumerator()) {
                if ($NG.Value.Count -gt 1) {
                    $UrlSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($Item in $NG.Value) {
                        [void]$UrlSet.Add($Item.Url)
                    }
                    if ($UrlSet.Count -gt 1) {
                        $IsAmbiguous = $true
                        break
                    }
                }
            }

            if ($IsAmbiguous -or $Group.Count -gt 1) {
                foreach ($E in $Group) {
                    $UrlCtx = Get-UrlLocationContext -Url $E.Url
                    $E | Add-Member -NotePropertyName 'UrlContext' -NotePropertyValue $UrlCtx -Force
                    if ($UrlCtx) {
                        $E | Add-Member -NotePropertyName 'DisambiguatedName' -NotePropertyValue "$($E.BaseName) ($UrlCtx)" -Force
                    } else {
                        $E | Add-Member -NotePropertyName 'DisambiguatedName' -NotePropertyValue $E.BaseName -Force
                    }
                }
            }
        }
    }

    if ($GroupByFloor) {
        $Groups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Entry in $Results) {
            if (-not $Groups.ContainsKey($Entry.BaseName)) {
                $Groups[$Entry.BaseName] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$Groups[$Entry.BaseName].Add($Entry)
        }

        return $Groups
    }

    return $Results

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

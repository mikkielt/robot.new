<#
    .SYNOPSIS
    Exports entity location data for nerthusaddon consumption.

    .DESCRIPTION
    Exports Lokacja entities with their @margonemid mappings, Nerthus names,
    and @drzwi connections in a format suitable for nerthusaddon integration.
    Output is an array of PSCustomObjects with entity metadata.

    Dot-sources nerthusaddon-helpers.ps1 for helper functions.
#>

# Load helpers
. "$PSScriptRoot/../private/nerthusaddon-helpers.ps1"

function Export-NerthusLocationData {
    <#
        .SYNOPSIS
        Exports entity location data for nerthusaddon consumption.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity data from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Export format")]
        [ValidateSet('Objects', 'Json')]
        [string]$Format = 'Objects',

        [Parameter(HelpMessage = "Output file path (only for Json format)")]
        [string]$OutputPath,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Load entities if not provided
    if (-not $Entities) {
        $Entities = Get-Entity -Quiet
    }

    # Filter to Lokacja entities
    $Locations = $Entities | Where-Object { $_.Type -eq 'Lokacja' }

    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($Loc in $Locations) {
        # Extract @margonemid values
        $MargonemIds = @()
        if ($Loc.Overrides -and $Loc.Overrides.ContainsKey('margonemid')) {
            $MargonemIds = @($Loc.Overrides['margonemid'] | ForEach-Object {
                $Parsed = $_.Text
                if ($Parsed -match '^\d+$') { [int]$Parsed }
            })
        }

        # Extract door connections
        $Doors = @()
        if ($Loc.Doors) {
            $Doors = @($Loc.Doors)
        }

        # Extract NerthusName if available
        $NerthusName = $null
        if ($Loc.NerthusName) {
            $NerthusName = $Loc.NerthusName
        }

        [void]$Results.Add([PSCustomObject]@{
            Name         = $Loc.Name
            CN           = $Loc.CN
            NerthusName  = $NerthusName
            MargonemIds  = $MargonemIds
            Doors        = $Doors
            Location     = $Loc.Location
            Status       = $Loc.Status
        })
    }

    if ($Format -eq 'Json') {
        $JsonOutput = $Results | ConvertTo-Json -Depth 4
        if ($OutputPath) {
            $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($OutputPath, $JsonOutput, $Utf8NoBom)
            Write-Verbose "Exported $($Results.Count) locations to '$OutputPath'"
            return
        }
        return $JsonOutput
    }

    return $Results

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

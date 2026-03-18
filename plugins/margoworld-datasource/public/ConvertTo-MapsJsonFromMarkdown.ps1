<#
    .SYNOPSIS
    Migrates legacy maps.md to maps.json format.

    .DESCRIPTION
    Exported migration function that reads a legacy maps.md file via
    ConvertFrom-MapsMarkdown and writes the result as maps.json via
    Write-MargoWorldMapsJson.

    Dot-sources margoworld-helpers.ps1 for ConvertFrom-MapsMarkdown
    and Write-MargoWorldMapsJson.
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"

function ConvertTo-MapsJsonFromMarkdown {
    <#
        .SYNOPSIS
        Migrates legacy maps.md to maps.json format.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Path to the source maps.md file")]
        [string]$SourcePath,

        [Parameter(HelpMessage = "Path to the destination maps.json file (default: sibling of SourcePath)")]
        [string]$DestinationPath,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $DestinationPath) {
        $SourceDir = [System.IO.Path]::GetDirectoryName($SourcePath)
        $DestinationPath = [System.IO.Path]::Combine($SourceDir, 'maps.json')
    }

    $Data = ConvertFrom-MapsMarkdown -Path $SourcePath
    if (-not $Data) {
        return [PSCustomObject]@{
            SourcePath      = $SourcePath
            DestinationPath = $DestinationPath
            EntriesRead     = 0
            EntriesWritten  = 0
            LastUpdated     = $null
            Success         = $false
        }
    }

    $EntriesRead = $Data.maps.Count

    if ($PSCmdlet.ShouldProcess($DestinationPath, "Write $EntriesRead map entries from '$SourcePath'")) {
        Write-MargoWorldMapsJson -Data $Data -Path $DestinationPath

        return [PSCustomObject]@{
            SourcePath      = $SourcePath
            DestinationPath = $DestinationPath
            EntriesRead     = $EntriesRead
            EntriesWritten  = $EntriesRead
            LastUpdated     = $Data.lastUpdated
            Success         = $true
        }
    }

    return [PSCustomObject]@{
        SourcePath      = $SourcePath
        DestinationPath = $DestinationPath
        EntriesRead     = $EntriesRead
        EntriesWritten  = 0
        LastUpdated     = $Data.lastUpdated
        Success         = $false
    }

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

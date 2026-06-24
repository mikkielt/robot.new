<#
    .SYNOPSIS
    Returns the dry-run preview for a migration.

    .DESCRIPTION
    Dispatches to the migration's Get-MigrationPreview function (mandatory per
    WP-2 manifest validation). Reads are pure: previews never write data and
    never hit the network unless RequiresNetwork=$true AND -AllowNetworkInPreview
    is passed; otherwise the network-dependent fields surface as empty arrays
    plus a Warnings[] entry.
#>

function Get-MigrationPreview {
    <#
        .SYNOPSIS
        Returns the dry-run preview for a migration.

        .PARAMETER Version
        Effective version (e.g. '21.3.7' or '21.3.7+plugin-foo.1').

        .PARAMETER AllowNetworkInPreview
        Permits network-dependent previews to actually probe the network.

        .PARAMETER Format
        Object (default), Markdown (CLI-friendly), or Json (REST).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [switch]$AllowNetworkInPreview,
        [ValidateSet('Object','Markdown','Json')] [string]$Format = 'Object',
        [string]$RepoRoot
    )

    $Catalog = Get-MigrationCatalog -RepoRoot $RepoRoot
    $Target = $Catalog | Where-Object { $_.Version -eq $Version -and $_.Validation.OK } | Select-Object -First 1
    if (-not $Target) {
        $Ex = [System.ArgumentException]::new("No valid migration with version '$Version' is discoverable.")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Version)
        $PSCmdlet.ThrowTerminatingError($Err)
    }

    $ResolvedRoot = if ($RepoRoot) { $RepoRoot } else { Get-RepoRoot }
    $Config = @{
        RepoRoot = $ResolvedRoot
        ResDir   = [System.IO.Path]::Combine($ResolvedRoot, '.robot.local', 'res')
        AllowNetworkInPreview = [bool]$AllowNetworkInPreview
    }

    $Preview = & {
        param($Sp, $Cfg)
        . $Sp
        if (-not (Get-Command 'Get-MigrationPreview' -ErrorAction SilentlyContinue)) {
            throw "migrate.ps1 did not export Get-MigrationPreview."
        }
        return Get-MigrationPreview -Config $Cfg
    } $Target.ScriptPath $Config

    # If the migration declares RequiresNetwork and the caller did not opt-in,
    # blank file/diff fields and surface a Warning so REST consumers see the
    # degraded preview without having to inspect the manifest separately.
    if ($Target.RequiresNetwork -and -not $AllowNetworkInPreview) {
        $Warnings = [System.Collections.Generic.List[string]]::new()
        if ($Preview.PSObject.Properties['Warnings'] -and $Preview.Warnings) {
            foreach ($W in $Preview.Warnings) { [void]$Warnings.Add($W) }
        }
        [void]$Warnings.Add("Network required for accurate preview; pass -AllowNetworkInPreview to enable.")
        $Preview = [PSCustomObject]@{
            Migration            = if ($Preview.PSObject.Properties['Migration']) { $Preview.Migration } else { $Target.Id }
            EstimatedDurationSec = if ($Preview.PSObject.Properties['EstimatedDurationSec']) { $Preview.EstimatedDurationSec } else { $Target.EstimatedDurationSec }
            FilesToModify        = @()
            FilesToCreate        = @()
            FilesToDelete        = @()
            EntityCountsBefore   = @{}
            EntityCountsAfter    = @{}
            SampleDiffs          = @()
            Warnings             = @($Warnings)
            NetworkRequired      = $true
            SourceUnchanged      = $false
        }
    }

    switch ($Format) {
        'Object'   { return $Preview }
        'Json'     { return ($Preview | ConvertTo-Json -Depth 10) }
        'Markdown' { return Format-MigrationPreviewMarkdown -Preview $Preview -Migration $Target }
    }
}

function Format-MigrationPreviewMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Preview,
        [Parameter(Mandatory)] [object]$Migration
    )
    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.AppendLine("## Migration $($Migration.Id)")
    [void]$Sb.AppendLine("")
    [void]$Sb.AppendLine("- Estimated duration: $($Preview.EstimatedDurationSec) s")
    [void]$Sb.AppendLine("- Network required: $($Preview.NetworkRequired)")
    if ($Preview.PSObject.Properties['SourceUnchanged']) {
        [void]$Sb.AppendLine("- Source unchanged: $($Preview.SourceUnchanged)")
    }
    [void]$Sb.AppendLine("")
    [void]$Sb.AppendLine("### Files")
    [void]$Sb.AppendLine("| Action | Path |")
    [void]$Sb.AppendLine("|---|---|")
    foreach ($F in @($Preview.FilesToCreate)) { [void]$Sb.AppendLine("| create | $F |") }
    foreach ($F in @($Preview.FilesToModify)) { [void]$Sb.AppendLine("| modify | $F |") }
    foreach ($F in @($Preview.FilesToDelete)) { [void]$Sb.AppendLine("| delete | $F |") }
    if (@($Preview.Warnings).Count -gt 0) {
        [void]$Sb.AppendLine("")
        [void]$Sb.AppendLine("### Warnings")
        foreach ($W in $Preview.Warnings) { [void]$Sb.AppendLine("- $W") }
    }
    return $Sb.ToString()
}

<#
    .SYNOPSIS
    Writes a migration artifact JSON file.

    .DESCRIPTION
    Counterpart of Get-MigrationArtifact. Used by Inspect migrations to emit
    artifacts and by the REST surface to accept operator edits.

    The destination is <repo>/.robot.local/migration-artifacts/<source-id>/<name>.json.
    Writes are atomic via Save-JsonStateFile (temp + .bak rotation).

    Helpers consumed:
    - Write-MigrationArtifactFile (private/migration/migration-artifact.ps1)
#>

function Set-MigrationArtifact {
    <#
        .SYNOPSIS
        Writes a migration artifact atomically.

        .PARAMETER SourceMigration
        The migration id (Version-Slug, e.g. '0.3.0-validate-parity-inspect')
        the artifact belongs to.

        .PARAMETER Name
        The artifact name (without ".json" suffix). Becomes the filename.

        .PARAMETER Value
        The data to serialize. Hashtable / PSCustomObject / Array, all supported
        by ConvertTo-Json.

        .PARAMETER Depth
        Override JSON serialization depth (default 10).

        .PARAMETER RepoRoot
        Override the repo root used to locate the artifact directory.
        Defaults to Get-RepoRoot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, HelpMessage = 'Migration id the artifact belongs to.')]
        [string]$SourceMigration,

        [Parameter(Mandatory, HelpMessage = 'Artifact name without .json suffix.')]
        [string]$Name,

        [Parameter(Mandatory, HelpMessage = 'Data to serialize.')]
        $Value,

        [Parameter(HelpMessage = 'JSON serialization depth (default 10).')]
        [int]$Depth = 10,

        [Parameter(HelpMessage = 'Repo-root override; defaults to Get-RepoRoot.')]
        [string]$RepoRoot
    )

    if (-not $PSCmdlet.ShouldProcess("artifact '$Name' for migration '$SourceMigration'", 'Write')) {
        return
    }

    $Path = Write-MigrationArtifactFile `
        -MigrationId $SourceMigration `
        -Name $Name `
        -Value $Value `
        -Depth $Depth `
        -RepoRoot $RepoRoot
    return [PSCustomObject]@{
        SourceMigration = $SourceMigration
        Name            = $Name
        Path            = $Path
    }
}

<#
    .SYNOPSIS
    Reads a migration artifact JSON file.

    .DESCRIPTION
    Artifacts are the operator-editable handoff between Inspect → Transform
    migration pairs. An Inspect migration writes structured JSON to
    <repo>/.robot.local/migration-artifacts/<source-id>/<name>.json; the
    operator inspects (and optionally edits) via REST or directly on disk;
    the Transform sibling reads via this cmdlet.

    Helpers consumed:
    - Read-MigrationArtifactFile (private/migration/migration-artifact.ps1)
#>

function Get-MigrationArtifact {
    <#
        .SYNOPSIS
        Reads a migration artifact and returns the parsed JSON.

        .PARAMETER SourceMigration
        The migration id (Version-Slug, e.g. '0.3.0-validate-parity-inspect')
        that produced the artifact.

        .PARAMETER Name
        The artifact name (without ".json" suffix).

        .PARAMETER RepoRoot
        Override the repo root used to locate the artifact directory.
        Defaults to Get-RepoRoot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, HelpMessage = 'Migration id that produced the artifact (Version-Slug).')]
        [string]$SourceMigration,

        [Parameter(Mandatory, HelpMessage = 'Artifact name without .json suffix.')]
        [string]$Name,

        [Parameter(HelpMessage = 'Repo-root override; defaults to Get-RepoRoot.')]
        [string]$RepoRoot
    )

    $Parsed = Read-MigrationArtifactFile -MigrationId $SourceMigration -Name $Name -RepoRoot $RepoRoot
    if ($null -eq $Parsed) {
        $Ex = [System.IO.FileNotFoundException]::new(
            "Migration artifact '$Name' for migration '$SourceMigration' not found. " +
            "Run the producing migration first.")
        $ErrRec = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationArtifactNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            "$SourceMigration/$Name")
        $PSCmdlet.ThrowTerminatingError($ErrRec)
    }
    return $Parsed
}

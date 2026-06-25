<#
    .SYNOPSIS
    Returns the ConfigSchema declaration for a migration.

    .DESCRIPTION
    Reads the migration manifest via Get-MigrationCatalog (cached) and surfaces
    its ConfigSchema block. The schema is the contract the dashboard renders as
    a form: each field declares Type, Default, Description, Required. The shape
    is identical to what manifest authors write — Resolve-MigrationConfigSchema
    normalises omitted Type/Description/Required so consumers don't need to
    handle absence.

    Helpers consumed:
    - Get-MigrationCatalog          (private/migration/migration-loader.ps1)
    - Resolve-MigrationConfigSchema (private/migration/migration-config.ps1)

    Used by:
    - REST endpoint GET /migrations/<v>/config-schema (plugins/robot-api)
    - Dashboard form generator
    - Invoke-Migration runtime (defaults merge before apply)
#>

function Get-MigrationConfigSchema {
    <#
        .SYNOPSIS
        Returns the ConfigSchema for a migration version.

        .PARAMETER Version
        The migration version (e.g. '0.1.1' or '21.3.7+plugin-foo.1').

        .PARAMETER RepoRoot
        Override the repo root used to locate operator-local migrations.
        Defaults to Get-RepoRoot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, HelpMessage = 'Migration version to query.')]
        [string]$Version,

        [Parameter(HelpMessage = 'Repo-root override; defaults to Get-RepoRoot.')]
        [string]$RepoRoot
    )

    $Catalog = Get-MigrationCatalog -RepoRoot $RepoRoot
    $Entry = $null
    foreach ($M in $Catalog) {
        if ([string]::Equals($M.Version, $Version, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Entry = $M
            break
        }
    }
    if (-not $Entry) {
        $Ex = [System.InvalidOperationException]::new(
            "No migration found for version '$Version'. " +
            "Use Get-Migration to list available versions.")
        $ErrRec = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Version)
        $PSCmdlet.ThrowTerminatingError($ErrRec)
    }

    $Schema = Resolve-MigrationConfigSchema -Manifest $Entry.Manifest
    return [PSCustomObject]@{
        Version = $Version
        Slug    = $Entry.Slug
        Fields  = $Schema
    }
}

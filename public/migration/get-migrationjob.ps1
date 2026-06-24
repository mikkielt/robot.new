<#
    .SYNOPSIS
    Returns status of a migration background job (WP-8).
#>

function Get-MigrationJob {
    <#
        .SYNOPSIS
        Wraps GET /migrations/jobs/{id}. Lists active jobs without -Id.

        .DESCRIPTION
        Until WP-8 lands, returns an empty list (no jobs to track). Once the
        WP-8 worker pool ships, this cmdlet will surface job status, progress,
        and accumulated log buffer.
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [switch]$All
    )

    if (Get-Command 'Get-ApiMigrationJob' -ErrorAction SilentlyContinue) {
        if ($Id) { return Get-ApiMigrationJob -Id $Id }
        return Get-ApiMigrationJob -All:$All
    }

    if ($Id) { return $null }
    return @()
}

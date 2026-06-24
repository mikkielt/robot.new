<#
    .SYNOPSIS
    Cache-format migration fast path (WP-9).

    .DESCRIPTION
    Auto-applies discovered migrations whose AffectsCategories includes 'Cache'
    on module load. No schema lock, no schema.json write, no operator preview —
    cache state is per-machine and rebuildable on failure.

    Origin filter: only Module and Plugin:* migrations qualify for the fast
    path. OperatorLocal cache migrations are rejected (auto-applying unvetted
    operator-local PowerShell on every module load is a foot-gun).

    Record file: <repo>/.robot.local/.cache/migrations.json
#>

function Resolve-CacheMigrationStatePath {
    [CmdletBinding()] param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
    return [System.IO.Path]::Combine($RepoRoot, '.robot.local', '.cache', 'migrations.json')
}

function Get-CacheMigrationApplied {
    [CmdletBinding()] param([string]$RepoRoot)
    $Path = Resolve-CacheMigrationStatePath -RepoRoot $RepoRoot
    $Raw = Read-JsonStateFile -Path $Path
    if (-not $Raw) { return @{} }
    $H = @{}
    if ($Raw.applied) {
        foreach ($Prop in $Raw.applied.PSObject.Properties) {
            $H[$Prop.Name] = [string]$Prop.Value
        }
    }
    return $H
}

function Test-CacheMigrationApplied {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Migration,
        [string]$RepoRoot
    )
    $Applied = Get-CacheMigrationApplied -RepoRoot $RepoRoot
    return $Applied.ContainsKey($Migration.Id)
}

function Set-CacheMigrationApplied {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object]$Migration,
        [string]$RepoRoot
    )
    $Applied = Get-CacheMigrationApplied -RepoRoot $RepoRoot
    $Applied[$Migration.Id] = [datetime]::UtcNow.ToString('o')
    $Path = Resolve-CacheMigrationStatePath -RepoRoot $RepoRoot
    if (-not $PSCmdlet.ShouldProcess($Path, "Record cache migration '$($Migration.Id)' as applied")) { return }
    $Data = [ordered]@{
        schemaFileVersion = 1
        applied           = $Applied
    }
    Save-JsonStateFile -Path $Path -Data $Data
}

function Invoke-CacheMigrations {
    <#
        .SYNOPSIS
        Applies all unapplied cache-category migrations on module load.

        .DESCRIPTION
        Called from Robot.PowerShell.psm1 after the WP-5 schema gate but only
        when we are inside a real repo (Mode != 'Unknown'). Failure of any
        single cache migration is non-fatal: log a warning and fall back to
        Clear-ParseCaches (current cache-version-bump behavior).
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)

    if (-not (Get-Command 'Get-MigrationCatalog' -ErrorAction SilentlyContinue)) {
        return
    }
    try {
        $Catalog = Get-MigrationCatalog -RepoRoot $RepoRoot
    } catch {
        return
    }
    $CacheMigrations = $Catalog | Where-Object {
        $_.Validation.OK -and
        $_.AffectsCategories -contains 'Cache' -and
        $_.Origin -ne 'OperatorLocal'
    }
    foreach ($M in $CacheMigrations) {
        if (Test-CacheMigrationApplied -Migration $M -RepoRoot $RepoRoot) { continue }
        try {
            # Cache migrations declare a self-contained Invoke-CacheMigration
            # function (no -Config required). The plain migrate.ps1 still has
            # to satisfy WP-2 manifest validation (Get-MigrationPreview /
            # Invoke-Migration), but the cache fast path invokes a different
            # entry point so cache-only logic stays out of the chain path.
            & {
                param($Sp)
                . $Sp
                if (Get-Command 'Invoke-CacheMigration' -ErrorAction SilentlyContinue) {
                    Invoke-CacheMigration
                } else {
                    # Fallback: invoke the standard Invoke-Migration with a
                    # minimal config so simple cache migrations work without
                    # a separate entry point.
                    Invoke-Migration -Config @{ RepoRoot = $RepoRoot }
                }
            } $M.ScriptPath
            Set-CacheMigrationApplied -Migration $M -RepoRoot $RepoRoot
        } catch {
            Write-RobotWarning "Cache migration '$($M.Id)' failed: $($_.Exception.Message). Wiping cache as fallback."
            if (Get-Command 'Clear-ParseCaches' -ErrorAction SilentlyContinue) {
                try { Clear-ParseCaches } catch { }
            }
        }
    }
}

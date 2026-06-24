<#
    .SYNOPSIS
    Returns the repository's current schema version and history.

    .DESCRIPTION
    Reads .robot.local/schema.json via Read-JsonStateFile (with .bak recovery)
    and returns a PSCustomObject describing the current schema state. When the
    file is missing, fabricates a 0.0.0 record with Exists=$false so callers
    on fresh repos do not need to special-case absence.

    Helpers consumed:
    - Read-JsonStateFile (private/admin-state.ps1)
    - Resolve-SchemaPath (private/migration/migration-version.ps1)
#>

function Get-SchemaVersion {
    <#
        .SYNOPSIS
        Reads the repository's schema version pointer and history.

        .PARAMETER Raw
        Returns the raw parsed object from schema.json instead of the formatted
        PSCustomObject projection. For plugin consumption.

        .PARAMETER RepoRoot
        Override the repo root used to locate schema.json. Defaults to Get-RepoRoot.
    #>
    [CmdletBinding()]
    param(
        [switch]$Raw,
        [string]$RepoRoot
    )

    $Path = Resolve-SchemaPath -RepoRoot $RepoRoot
    $Raw_ = Read-JsonStateFile -Path $Path

    if ($Raw) { return $Raw_ }

    if (-not $Raw_) {
        return [PSCustomObject]@{
            Current             = '0.0.0'
            MajorName           = ''
            AppliedAt           = $null
            AppliedBy           = $null
            AppliedMigrationId  = $null
            LockedBy            = $null
            LockedAt            = $null
            LockStale           = $false
            History             = @()
            FilePath            = $Path
            Exists              = $false
        }
    }

    $Stale = $false
    if ($Raw_.lockedAt) {
        $Stale = Test-SchemaLockStale -SchemaState $Raw_
    }

    return [PSCustomObject]@{
        Current             = $Raw_.current
        MajorName           = if ($Raw_.majorName) { $Raw_.majorName } else { '' }
        AppliedAt           = $Raw_.appliedAt
        AppliedBy           = $Raw_.appliedBy
        AppliedMigrationId  = if ($Raw_.appliedMigrationId) { $Raw_.appliedMigrationId } else { $null }
        LockedBy            = $Raw_.lockedBy
        LockedAt            = $Raw_.lockedAt
        LockStale           = $Stale
        History             = if ($Raw_.history) { @($Raw_.history) } else { @() }
        FilePath            = $Path
        Exists              = $true
    }
}

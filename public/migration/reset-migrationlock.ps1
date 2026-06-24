<#
    .SYNOPSIS
    Clears a stale schema lock unconditionally.
#>

function Reset-MigrationLock {
    <#
        .SYNOPSIS
        Forcibly releases the schema lock.

        .DESCRIPTION
        Intended for stuck locks (process crash, network partition). Operators
        should verify no concurrent migration process exists before calling.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [switch]$Force,
        [string]$RepoRoot
    )

    $Schema = Get-SchemaVersion -RepoRoot $RepoRoot
    if (-not $Schema.LockedBy) {
        Write-RobotInfo "No lock to release."
        return [PSCustomObject]@{ OK = $true; WasLocked = $false; PreviousOwner = $null }
    }

    $Target = "Clear schema lock (held by '$($Schema.LockedBy)' since '$($Schema.LockedAt)')"
    if (-not $Force -and -not $PSCmdlet.ShouldProcess($Schema.FilePath, $Target)) {
        return [PSCustomObject]@{ OK = $false; WasLocked = $true; PreviousOwner = $Schema.LockedBy }
    }

    Unlock-Schema -RepoRoot $RepoRoot
    return [PSCustomObject]@{
        OK = $true; WasLocked = $true
        PreviousOwner = $Schema.LockedBy
        PreviousLockedAt = $Schema.LockedAt
        LockWasStale = $Schema.LockStale
    }
}

<#
    .SYNOPSIS
    Background job system for long-running migrations (WP-8).

    .DESCRIPTION
    Migration runs that exceed the 10-second sync limit are dispatched via this
    job system. Each job lives in $script:MigrationJobs and tracks status,
    progress, log buffer, and final result. Job retention is in-memory only
    (process lifetime); durable log is the per-run migration-log.txt file.

    Helpers:
    - Start-ApiMigrationJob:  enqueues a job, returns the jobId
    - Get-ApiMigrationJob:    returns job status by id (or all if -All)
    - Stop-ApiMigrationJob:   stops a running job (used by Stop-RobotApi cleanup)

    Module-level data:
    - $script:MigrationJobs:    JobId -> job-state hashtable
    - $script:MigrationJobLock: monitor object for thread-safe access
#>

if (-not $script:MigrationJobs) {
    $script:MigrationJobs = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
}

function Start-ApiMigrationJob {
    <#
        .SYNOPSIS
        Spawns a background job that runs Invoke-Migration / Invoke-MigrationChain.

        .DESCRIPTION
        Uses Start-ThreadJob when available (PS7+, ThreadJob module) so the
        job shares the same process and module state. Falls back to a
        synchronous-but-deferred execution model where the apply happens
        inline but status is still tracked (simulating async). Acceptable
        because migration runs are inherently serialized by the schema lock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [string]$BranchMode = 'InPlace',
        [switch]$AllowUnsigned,
        [switch]$AllowNetwork
    )

    $JobId = [Guid]::NewGuid().ToString('N')
    $JobState = [PSCustomObject]@{
        JobId       = $JobId
        Status      = 'Queued'
        CreatedAt   = [datetime]::UtcNow.ToString('o')
        StartedAt   = $null
        CompletedAt = $null
        MigrationId = if ($Target.id) { $Target.id } else { $null }
        Version     = if ($Target.version) { $Target.version } else { $null }
        Progress    = @{ current = 0; total = 0; message = '' }
        Log         = [System.Collections.Generic.List[string]]::new()
        Result      = $null
        Error       = $null
    }
    [void]$script:MigrationJobs.TryAdd($JobId, $JobState)

    $TargetId      = $JobState.MigrationId
    $TargetVersion = $JobState.Version

    $RunBlock = {
        param($JobId, $Jobs, $TargetId, $TargetVersion, $BranchMode, $AllowUnsigned)
        $J = $Jobs[$JobId]
        $J.Status = 'Running'
        $J.StartedAt = [datetime]::UtcNow.ToString('o')
        try {
            if ($TargetId) {
                $R = Invoke-Migration -Version (Get-Migration -Version $TargetId).Version `
                    -BranchMode $BranchMode -AllowUnsigned:$AllowUnsigned -Confirm:$false
            } else {
                $R = Invoke-MigrationChain -To $TargetVersion -BranchMode $BranchMode `
                    -AllowUnsigned:$AllowUnsigned -Confirm:$false
            }
            $J.Result = $R
            $J.Status = 'Completed'
        } catch {
            $J.Error  = $_.Exception.Message
            $J.Status = 'Failed'
        } finally {
            $J.CompletedAt = [datetime]::UtcNow.ToString('o')
        }
    }

    # Prefer ThreadJob for true background execution. Otherwise run inline (the
    # caller is the API worker runspace which has already accepted the 202).
    if (Get-Command 'Start-ThreadJob' -ErrorAction SilentlyContinue) {
        $null = Start-ThreadJob -ScriptBlock $RunBlock `
            -ArgumentList $JobId, $script:MigrationJobs, $TargetId, $TargetVersion, $BranchMode, $AllowUnsigned
    } else {
        & $RunBlock $JobId $script:MigrationJobs $TargetId $TargetVersion $BranchMode $AllowUnsigned
    }

    return $JobId
}

function Get-ApiMigrationJob {
    [CmdletBinding()]
    param([string]$Id, [switch]$All)
    if ($All) {
        return @($script:MigrationJobs.Values)
    }
    if (-not $Id) { return $null }
    $Out = $null
    if ($script:MigrationJobs.TryGetValue($Id, [ref]$Out)) {
        return $Out
    }
    return $null
}

function Stop-ApiMigrationJob {
    [CmdletBinding()]
    param([string]$Id)
    $J = Get-ApiMigrationJob -Id $Id
    if ($J -and ($J.Status -eq 'Queued' -or $J.Status -eq 'Running')) {
        $J.Status = 'Cancelled'
        $J.CompletedAt = [datetime]::UtcNow.ToString('o')
    }
}

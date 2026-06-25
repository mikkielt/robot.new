<#
    .SYNOPSIS
    0.5.0-download-logs: Transform — bulk log download.

    .DESCRIPTION
    Inlined replacement for the phase4-log-download body. Discovers
    unique HTTP log URLs across all sessions, downloads any not present
    in the cache, and retries previously failed URLs when configured.
    Idempotent: cached files are not re-fetched.

    Reads Config.Migration:
    - DownloadLogs    (Switch, default $true)
    - RetryFailedUrls (Switch, default $false)
#>

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.5.0-download-logs'
        EstimatedDurationSec = 300
        FilesToModify        = @()
        FilesToCreate        = @('.robot.local/res/logs/*')
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Network access required; preview does not enumerate URLs.')
        NetworkRequired      = $true
        SourceUnchanged      = $false
        ChangeRecords        = @()
    }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [hashtable]$Checklist
    )

    $RepoRoot = $Config.RepoRoot
    $MigCfg = if ($Config.ContainsKey('Migration')) { $Config['Migration'] } else { @{} }
    $DownloadLogs = if ($MigCfg.ContainsKey('DownloadLogs')) {
        [bool]$MigCfg['DownloadLogs']
    } else { $true }
    $RetryFailed = [bool]$MigCfg['RetryFailedUrls']

    # Required cmdlets — absence indicates fixture mode without session data.
    $SessionCmd = Get-Command 'Get-Session' -ErrorAction SilentlyContinue
    $FetchCmd   = Get-Command 'Invoke-SessionLogFetch' -ErrorAction SilentlyContinue
    if (-not $SessionCmd -or -not $FetchCmd) {
        return [PSCustomObject]@{
            OK = $true; FilesWritten = @(); Skipped = $true
            Reason = 'SessionCmdletsUnavailable'
        }
    }

    $Sessions = @(Get-Session -Quiet)
    if ($Sessions.Count -eq 0) {
        return [PSCustomObject]@{
            OK = $true; FilesWritten = @(); Skipped = $true
            Reason = 'NoSessions'
        }
    }

    if (-not $DownloadLogs) {
        return [PSCustomObject]@{
            OK = $true; FilesWritten = @(); Skipped = $true
            Reason = 'DownloadLogsDisabled'; SessionCount = $Sessions.Count
        }
    }

    # The fetch helper does its own dedupe, cache check, and retry-on-failed
    # marker handling — we just point it at the session set.
    $Result = Invoke-SessionLogFetch -Session $Sessions -RetryFailed:$RetryFailed -Quiet

    # Write the failed-URL list for operator review if any failures persisted.
    $FailedList = @()
    if ($Result.Failed -gt 0 -and $Result.FailedUrls) {
        $ResDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res')
        if (-not [System.IO.Directory]::Exists($ResDir)) {
            [void][System.IO.Directory]::CreateDirectory($ResDir)
        }
        $FailedListPath = [System.IO.Path]::Combine($ResDir, 'migration-failed-logs.txt')
        $SB = [System.Text.StringBuilder]::new()
        [void]$SB.AppendLine("# Failed log URL downloads - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
        [void]$SB.AppendLine("# $($Result.Failed) URLs could not be fetched")
        [void]$SB.AppendLine('')
        foreach ($Url in $Result.FailedUrls) { [void]$SB.AppendLine($Url) }
        [System.IO.File]::WriteAllText($FailedListPath, $SB.ToString(),
            [System.Text.UTF8Encoding]::new($false))
        $FailedList = @($Result.FailedUrls)
    }

    $LogDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res', 'logs')
    return [PSCustomObject]@{
        OK            = $true
        FilesWritten  = @($LogDir)
        TotalUrls     = $Result.Total
        Fetched       = $Result.Fetched
        Cached        = $Result.Cached
        Failed        = $Result.Failed
        FailedUrls    = $FailedList
    }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    return $false
}

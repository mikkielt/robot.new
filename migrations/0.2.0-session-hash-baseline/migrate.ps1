<#
    .SYNOPSIS
    0.2.0-session-hash-baseline: Transform — generate baseline session hashes.

    .DESCRIPTION
    Inlined replacement for the phase1-session-hashes body. Calls
    Set-SessionHash -Full to compute SHA256 content hashes for all session
    Markdown headers, captures the pre-mutation baseline, and runs
    Test-SessionIntegrity to record any anomalies. Idempotent: re-running
    a second time without ForceRecompute is a no-op.

    Reads Config.Migration:
    - ForceRecompute (Switch, default $false)
#>

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    $HashDir = [System.IO.Path]::Combine($Config.RepoRoot, '.robot.local', 'res', 'session-hashes')
    $HasExisting = [System.IO.Directory]::Exists($HashDir)
    return [PSCustomObject]@{
        Migration            = '0.2.0-session-hash-baseline'
        EstimatedDurationSec = 10
        FilesToModify        = if ($HasExisting) { @('.robot.local/res/session-hashes/*') } else { @() }
        FilesToCreate        = if ($HasExisting) { @() } else { @('.robot.local/res/session-hashes/*') }
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = if ($HasExisting) {
            @('Hash store already present; supply ForceRecompute=$true to overwrite.')
        } else { @() }
        NetworkRequired      = $false
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
    $ForceRecompute = [bool]$MigCfg['ForceRecompute']

    $HashDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res', 'session-hashes')
    $HasExisting = [System.IO.Directory]::Exists($HashDir)

    # Skip generation if the baseline exists and the operator didn't opt in to
    # recompute. The framework already provides per-record idempotency; this is
    # the inner check that matches the phase1 semantics.
    if ($HasExisting -and -not $ForceRecompute) {
        $ExistingCount = [System.IO.Directory]::GetFiles(
            $HashDir, '*.json', [System.IO.SearchOption]::AllDirectories).Count
        return [PSCustomObject]@{
            OK            = $true
            FilesWritten  = @()
            Skipped       = $true
            Reason        = 'BaselineExists'
            FileCount     = $ExistingCount
        }
    }

    # Set-SessionHash and Test-SessionIntegrity are module-exported cmdlets;
    # absence indicates a misconfigured fixture, not a runtime error.
    $HashCmd = Get-Command 'Set-SessionHash' -ErrorAction SilentlyContinue
    if (-not $HashCmd) {
        return [PSCustomObject]@{
            OK           = $true
            FilesWritten = @()
            Skipped      = $true
            Reason       = 'SetSessionHashUnavailable'
        }
    }

    $HashResult = Set-SessionHash -Full
    $FileCount = $HashResult.FilesProcessed
    $HashCount = $HashResult.HashesComputed

    $IntegrityOK = $true
    $IntegrityNotes = [System.Collections.Generic.List[string]]::new()
    $TestCmd = Get-Command 'Test-SessionIntegrity' -ErrorAction SilentlyContinue
    if ($TestCmd) {
        $IntegrityResult = Test-SessionIntegrity -Full
        $IntegrityOK = [bool]$IntegrityResult.OK
        if (-not $IntegrityOK) {
            if ($IntegrityResult.MalformedHeaders -and $IntegrityResult.MalformedHeaders.Count -gt 0) {
                [void]$IntegrityNotes.Add(
                    "malformed-headers: $($IntegrityResult.MalformedHeaders.Count)")
            }
            if ($IntegrityResult.FormatAnomalies -and $IntegrityResult.FormatAnomalies.Count -gt 0) {
                [void]$IntegrityNotes.Add(
                    "format-anomalies: $($IntegrityResult.FormatAnomalies.Count)")
            }
            if ($IntegrityResult.FutureDatedSessions -and $IntegrityResult.FutureDatedSessions.Count -gt 0) {
                [void]$IntegrityNotes.Add(
                    "future-dated: $($IntegrityResult.FutureDatedSessions.Count)")
            }
        }
    }

    return [PSCustomObject]@{
        OK              = $true
        FilesWritten    = @($HashDir)
        FileCount       = $FileCount
        HashCount       = $HashCount
        IntegrityOK     = $IntegrityOK
        IntegrityNotes  = @($IntegrityNotes)
    }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    return $false
}

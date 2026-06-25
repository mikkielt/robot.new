<#
    .SYNOPSIS
    0.1.2-commit-bootstrap: Commit — stage + commit the bootstrap output.

    .DESCRIPTION
    Calls Invoke-MigrationCommit with Config-supplied message. The helper
    no-ops if there is no diff, so this migration is safely idempotent.

    Reads Config.Migration:
    - CommitMessage (String, default 'Bootstrap entities.md from Gracze.md')
    - SkipCommit    (Switch, default $false) — fixture-mode escape hatch
#>

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.1.2-commit-bootstrap'
        EstimatedDurationSec = 2
        FilesToModify        = @('.git/HEAD')
        FilesToCreate        = @()
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Wraps git add + git commit. Pass SkipCommit=$true to no-op.')
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

    $MigCfg = if ($Config.ContainsKey('Migration')) { $Config['Migration'] } else { @{} }
    $SkipCommit = [bool]$MigCfg['SkipCommit']

    # Auto-skip when the repo is not a git working copy (fixture mode, fresh
    # tests). The operator can force a commit by initializing git first or
    # opt-out explicitly via Config.SkipCommit.
    $GitDir = [System.IO.Path]::Combine($Config.RepoRoot, '.git')
    $IsGitRepo = [System.IO.Directory]::Exists($GitDir) -or [System.IO.File]::Exists($GitDir)
    if ($SkipCommit -or -not $IsGitRepo) {
        $Reason = if ($SkipCommit) { 'SkipCommit' } else { 'NotAGitRepo' }
        return [PSCustomObject]@{
            OK = $true; FilesWritten = @(); Skipped = $true; Reason = $Reason
        }
    }

    $Message = if ($MigCfg.ContainsKey('CommitMessage') -and -not [string]::IsNullOrWhiteSpace([string]$MigCfg['CommitMessage'])) {
        [string]$MigCfg['CommitMessage']
    } else {
        'Bootstrap entities.md from Gracze.md'
    }

    $Result = Invoke-MigrationCommit -Message $Message -RepoRoot $Config.RepoRoot -Confirm:$false
    return [PSCustomObject]@{
        OK            = [bool]$Result.OK
        FilesWritten  = @()
        CommitSha     = $Result.Sha
        CommitSkipped = [bool]$Result.Skipped
        CommitReason  = $Result.Reason
    }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    return $false
}

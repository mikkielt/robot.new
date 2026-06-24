<#
    .SYNOPSIS
    Branching modes for migration runs (WP-6).

    .DESCRIPTION
    Non-exported helpers consumed by public/migration/invoke-migration.ps1.
    Three modes:
      InPlace        — apply to working tree, leave dirty (default for REST/scripts)
      Branch         — create migration/<name>, apply, commit, leave checked out
      BranchAndMerge — Branch + ff-merge back into original branch on success

    Helpers:
    - Test-WorkingTreeDirty: wraps git status --porcelain
    - Enter-MigrationBranch: creates + checks out migration branch from HEAD
    - Save-MigrationCommit:  stages all under repo root and commits with metadata
    - Exit-MigrationBranch:  optional ff-merge back into original branch

    Module-level data:
    - $script:MigrationBranchContext: records original branch for Exit
#>

$script:MigrationBranchContext = $null

function Invoke-GitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string[]]$Args,
        [switch]$IgnoreError
    )
    $Proc = [System.Diagnostics.Process]::new()
    $Proc.StartInfo.FileName = 'git'
    $Proc.StartInfo.WorkingDirectory = $RepoRoot
    foreach ($A in $Args) { [void]$Proc.StartInfo.ArgumentList.Add($A) }
    $Proc.StartInfo.UseShellExecute = $false
    $Proc.StartInfo.RedirectStandardOutput = $true
    $Proc.StartInfo.RedirectStandardError = $true
    $Proc.StartInfo.CreateNoWindow = $true
    try {
        [void]$Proc.Start()
        $Stdout = $Proc.StandardOutput.ReadToEnd()
        $Stderr = $Proc.StandardError.ReadToEnd()
        $Proc.WaitForExit()
        $Code = $Proc.ExitCode
        if ($Code -ne 0 -and -not $IgnoreError) {
            throw "git $($Args -join ' ') failed (exit $Code): $Stderr"
        }
        return [PSCustomObject]@{ ExitCode = $Code; Stdout = $Stdout; Stderr = $Stderr }
    } finally {
        $Proc.Dispose()
    }
}

function Test-WorkingTreeDirty {
    <#
        .SYNOPSIS
        Returns $true if git status --porcelain has any output. $false when git is
        unavailable (test repo, set via Set-RepoRoot to a non-git dir).
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
    if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($RepoRoot, '.git'))) {
        return $false
    }
    try {
        $R = Invoke-GitCommand -RepoRoot $RepoRoot -Args @('status', '--porcelain') -IgnoreError
        if ($R.ExitCode -ne 0) { return $false }
        return -not [string]::IsNullOrWhiteSpace($R.Stdout)
    } catch {
        return $false
    }
}

function Enter-MigrationBranch {
    <#
        .SYNOPSIS
        Creates a new branch from FromRef and checks it out. Records original.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$BranchName,
        [string]$FromRef = 'HEAD',
        [string]$RepoRoot
    )
    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }

    $OriginalBranch = (Invoke-GitCommand -RepoRoot $RepoRoot -Args @('rev-parse','--abbrev-ref','HEAD')).Stdout.Trim()
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, "Create + checkout branch '$BranchName' from '$FromRef'")) {
        return
    }
    [void](Invoke-GitCommand -RepoRoot $RepoRoot -Args @('checkout','-b',$BranchName,$FromRef))
    $script:MigrationBranchContext = [PSCustomObject]@{
        OriginalBranch = $OriginalBranch
        BranchName     = $BranchName
        RepoRoot       = $RepoRoot
    }
}

function Save-MigrationCommit {
    <#
        .SYNOPSIS
        Stages all changes under repo root and creates a structured commit.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object]$RunResult,
        [Parameter(Mandatory)] [string]$MigrationId,
        [string]$RepoRoot
    )
    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
    if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($RepoRoot, '.git'))) {
        Write-RobotWarning "Save-MigrationCommit: not a git repo at '$RepoRoot'; skipping commit."
        return
    }

    $Status = (Invoke-GitCommand -RepoRoot $RepoRoot -Args @('status','--porcelain')).Stdout
    if ([string]::IsNullOrWhiteSpace($Status)) {
        Write-RobotInfo "Save-MigrationCommit: no changes to commit for '$MigrationId'."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, "Stage + commit migration '$MigrationId'")) { return }

    [void](Invoke-GitCommand -RepoRoot $RepoRoot -Args @('add','-A'))

    $User = if ($env:ROBOT_USER) { $env:ROBOT_USER } else { $env:USERNAME }
    if (-not $User) { $User = $env:USER }
    if (-not $User) { $User = 'unknown' }

    $From = if ($RunResult.PSObject.Properties['SchemaFrom']) { $RunResult.SchemaFrom } else { '(prior)' }
    $To   = if ($RunResult.PSObject.Properties['SchemaTo'])   { $RunResult.SchemaTo   } else { '(current)' }
    $FilesModified = if ($RunResult.FilesWritten) { @($RunResult.FilesWritten).Count } else { 0 }

    $Msg = @"
migrate: $MigrationId

Migration-Id: $MigrationId
Schema-From: $From
Schema-To: $To
Files-Modified: $FilesModified
Applied-By: $User
"@
    [void](Invoke-GitCommand -RepoRoot $RepoRoot -Args @('commit','-m',$Msg,'--allow-empty'))
}

function Exit-MigrationBranch {
    <#
        .SYNOPSIS
        Restores the original branch (LeaveCheckedOut) or ff-merges back (MergeBack).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('LeaveCheckedOut','MergeBack')] [string]$Mode = 'LeaveCheckedOut',
        [string]$RepoRoot
    )
    $Ctx = $script:MigrationBranchContext
    if (-not $Ctx) {
        Write-RobotWarning "Exit-MigrationBranch: no migration branch context recorded; no-op."
        return
    }
    if (-not $RepoRoot) { $RepoRoot = $Ctx.RepoRoot }
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, "Exit migration branch (Mode=$Mode)")) { return }

    if ($Mode -eq 'LeaveCheckedOut') {
        $script:MigrationBranchContext = $null
        return
    }

    # MergeBack: switch to original, --ff-only merge migration branch, delete it.
    [void](Invoke-GitCommand -RepoRoot $RepoRoot -Args @('checkout',$Ctx.OriginalBranch))
    $R = Invoke-GitCommand -RepoRoot $RepoRoot -Args @('merge','--ff-only',$Ctx.BranchName) -IgnoreError
    if ($R.ExitCode -ne 0) {
        Write-RobotWarning ("Exit-MigrationBranch: --ff-only merge refused " +
            "('$($Ctx.OriginalBranch)' diverged from '$($Ctx.BranchName)'). " +
            "Branch left for manual resolution.")
        $script:MigrationBranchContext = $null
        return
    }
    [void](Invoke-GitCommand -RepoRoot $RepoRoot -Args @('branch','-d',$Ctx.BranchName) -IgnoreError)
    $script:MigrationBranchContext = $null
}

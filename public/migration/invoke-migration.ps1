<#
    .SYNOPSIS
    Apply a single migration by version.
#>

function Invoke-Migration {
    <#
        .SYNOPSIS
        Applies a single migration end-to-end.

        .DESCRIPTION
        Default execution is blocking: acquires the schema lock, validates the
        prerequisite chain matches the migration's Requires, dispatches to
        Invoke-MigrationInternal, releases the lock, returns MigrationRunResult.

        -AsJob dispatches to the WP-8 background job system (POST
        /migrations/jobs under the hood). Until WP-8 lands, -AsJob throws
        NotImplemented.

        .PARAMETER Version
        Effective version of the migration to apply (e.g. '21.3.7' or
        '21.3.7+plugin-foo.1').

        .PARAMETER BranchMode
        InPlace | Branch | BranchAndMerge. Branch modes delegate to the WP-6
        migration-branch helpers.

        .PARAMETER AllowUnsigned
        Required to apply OperatorLocal-origin migrations.

        .PARAMETER AsJob
        Dispatch via the background job system instead of blocking.

        .PARAMETER RepoRoot
        Override repo root for testing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [ValidateSet('InPlace','Branch','BranchAndMerge')] [string]$BranchMode = 'InPlace',
        [switch]$AllowUnsigned,
        [switch]$AsJob,
        [string]$RepoRoot
    )

    if ($AsJob) {
        $Ex = [System.NotImplementedException]::new(
            "Background job dispatch is provided by WP-8; not yet available.")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'AsJobNotYetImplemented',
            [System.Management.Automation.ErrorCategory]::NotImplemented, $null)
        $PSCmdlet.ThrowTerminatingError($Err)
    }

    $Catalog = Get-MigrationCatalog -RepoRoot $RepoRoot
    $Target = $Catalog | Where-Object { $_.Version -eq $Version -and $_.Validation.OK } | Select-Object -First 1
    if (-not $Target) {
        $Ex = [System.ArgumentException]::new("No valid migration with version '$Version' is discoverable.")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Version)
        $PSCmdlet.ThrowTerminatingError($Err)
    }

    $Schema = Get-SchemaVersion -RepoRoot $RepoRoot
    if ($Target.Requires) {
        $Cmp = Compare-SchemaVersion $Schema.Current $Target.Requires
        if ($Cmp -lt 0) {
            $Ex = [System.InvalidOperationException]::new(
                "Migration '$($Target.Id)' requires version '$($Target.Requires)' but current schema is '$($Schema.Current)'.")
            $Err = [System.Management.Automation.ErrorRecord]::new(
                $Ex, 'PrerequisiteNotMet',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $Target)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
    }

    # Branch mode (WP-6) — InPlace short-circuits; other modes delegate.
    if ($BranchMode -ne 'InPlace' -and (Get-Command 'Enter-MigrationBranch' -ErrorAction SilentlyContinue)) {
        $BranchName = "migration/$($Target.Slug)-$($Target.Version)"
        Enter-MigrationBranch -BranchName $BranchName -RepoRoot $RepoRoot
    } elseif ($BranchMode -eq 'InPlace' -and (Get-Command 'Test-WorkingTreeDirty' -ErrorAction SilentlyContinue)) {
        if (Test-WorkingTreeDirty -RepoRoot $RepoRoot) {
            $Ex = [System.InvalidOperationException]::new(
                "Working tree is dirty. Use BranchMode 'Branch' or stash changes before InPlace apply.")
            $Err = [System.Management.Automation.ErrorRecord]::new(
                $Ex, 'WorkingTreeDirty',
                [System.Management.Automation.ErrorCategory]::ResourceBusy, $null)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
    }

    $LockOwner = "$env:USERNAME@$([System.Net.Dns]::GetHostName())/$PID"
    if (-not $LockOwner.StartsWith('@')) { } else { $LockOwner = "robot/$PID" }
    Lock-Schema -LockOwner $LockOwner -RepoRoot $RepoRoot
    try {
        $ResolvedRoot = if ($RepoRoot) { $RepoRoot } else { Get-RepoRoot }
        $Config = @{
            RepoRoot = $ResolvedRoot
            ResDir   = [System.IO.Path]::Combine($ResolvedRoot, '.robot.local', 'res')
        }
        Initialize-MigrationLog -RepoRoot $Config.RepoRoot

        $Result = Invoke-MigrationInternal -Migration $Target -Config $Config `
            -AllowUnsigned:$AllowUnsigned -RepoRoot $RepoRoot

        Flush-MigrationLog
        if ($BranchMode -ne 'InPlace' -and (Get-Command 'Save-MigrationCommit' -ErrorAction SilentlyContinue)) {
            Save-MigrationCommit -RunResult $Result -MigrationId $Target.Id -RepoRoot $RepoRoot
            if ($BranchMode -eq 'BranchAndMerge' -and (Get-Command 'Exit-MigrationBranch' -ErrorAction SilentlyContinue)) {
                Exit-MigrationBranch -Mode MergeBack -RepoRoot $RepoRoot
            }
        }

        return $Result
    } finally {
        Unlock-Schema -RepoRoot $RepoRoot
    }
}

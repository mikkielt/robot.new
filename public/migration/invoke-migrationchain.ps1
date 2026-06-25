<#
    .SYNOPSIS
    Apply a chain of migrations from the current schema version to a target.
#>

function Invoke-MigrationChain {
    <#
        .SYNOPSIS
        Applies the migration chain from FromVersion (default: current) to ToVersion.

        .DESCRIPTION
        Resolves the chain via Resolve-MigrationChain, acquires the schema lock
        ONCE for the entire chain (per-migration lock churn would expose race
        windows between migrations). On any per-migration failure, stops the
        chain, releases the lock, surfaces the failed run result, and leaves
        the schema pointer at the last successfully-applied migration.

        .PARAMETER To
        Effective version to advance to. 'latest' picks the highest Module-origin
        migration.

        .PARAMETER Config
        Hashtable keyed by migration version (or 'Version-Slug' id) with the
        Config payload for that migration. Migrations whose key is absent
        receive an empty Config (defaults only).

        .PARAMETER Overrides
        Hashtable keyed by migration version (or 'Version-Slug' id) with the
        per-ChangeRecord Override payload (CC-N9) for that migration.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$From,
        [Parameter(Mandatory)] [string]$To,
        [hashtable]$Config,
        [hashtable]$Overrides,
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

    $Chain = Resolve-MigrationChain -FromVersion $From -ToVersion $To -RepoRoot $RepoRoot
    if (-not $Chain -or $Chain.Count -eq 0) {
        return [PSCustomObject]@{
            OK = $true; Applied = @(); Skipped = @(); Failed = $null
            FromVersion = $From; ToVersion = $To
        }
    }

    if ($BranchMode -ne 'InPlace' -and (Get-Command 'Enter-MigrationBranch' -ErrorAction SilentlyContinue)) {
        $BranchName = "migration/$(if ($From) { $From } else { 'auto' })-to-$To"
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
    Lock-Schema -LockOwner $LockOwner -RepoRoot $RepoRoot
    $Applied = [System.Collections.Generic.List[object]]::new()
    $Skipped = [System.Collections.Generic.List[object]]::new()
    $Failed = $null
    try {
        $ResolvedRoot = if ($RepoRoot) { $RepoRoot } else { Get-RepoRoot }
        $RuntimeConfig = @{
            RepoRoot = $ResolvedRoot
            ResDir   = [System.IO.Path]::Combine($ResolvedRoot, '.robot.local', 'res')
        }
        Initialize-MigrationLog -RepoRoot $RuntimeConfig.RepoRoot

        foreach ($M in $Chain) {
            # Partition operator-supplied Config/Overrides across the chain by
            # migration version or full id. Migrations whose key is absent
            # apply with defaults only.
            $PerMigConfig = $null
            $PerMigOverrides = $null
            if ($Config) {
                if ($Config.ContainsKey($M.Version)) { $PerMigConfig = $Config[$M.Version] }
                elseif ($Config.ContainsKey($M.Id)) { $PerMigConfig = $Config[$M.Id] }
            }
            if ($Overrides) {
                if ($Overrides.ContainsKey($M.Version)) { $PerMigOverrides = $Overrides[$M.Version] }
                elseif ($Overrides.ContainsKey($M.Id)) { $PerMigOverrides = $Overrides[$M.Id] }
            }
            try {
                $R = Invoke-MigrationInternal -Migration $M -Config $RuntimeConfig `
                    -MigrationConfig $PerMigConfig -MigrationOverrides $PerMigOverrides `
                    -AllowUnsigned:$AllowUnsigned -RepoRoot $RepoRoot
                if ($R.Skipped) {
                    [void]$Skipped.Add($R)
                } else {
                    [void]$Applied.Add($R)
                }
            } catch {
                $Failed = [PSCustomObject]@{
                    MigrationId = $M.Id
                    Error       = $_.Exception.Message
                }
                break
            }
        }

        Flush-MigrationLog

        if ($BranchMode -ne 'InPlace' -and (Get-Command 'Save-MigrationCommit' -ErrorAction SilentlyContinue)) {
            $Last = if ($Applied.Count -gt 0) { $Applied[-1] } else { $null }
            if ($Last) {
                Save-MigrationCommit -RunResult $Last -MigrationId $Last.MigrationId -RepoRoot $RepoRoot
            }
            if ($BranchMode -eq 'BranchAndMerge' -and $null -eq $Failed -and
                (Get-Command 'Exit-MigrationBranch' -ErrorAction SilentlyContinue)) {
                Exit-MigrationBranch -Mode MergeBack -RepoRoot $RepoRoot
            }
        }

        return [PSCustomObject]@{
            OK          = ($null -eq $Failed)
            Applied     = @($Applied)
            Skipped     = @($Skipped)
            Failed      = $Failed
            FromVersion = $From
            ToVersion   = $To
        }
    } finally {
        Unlock-Schema -RepoRoot $RepoRoot
    }
}

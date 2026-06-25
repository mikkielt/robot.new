<#
    .SYNOPSIS
    Standardized git commit helper for Commit-archetype migrations.

    .DESCRIPTION
    Non-exported helper consumed by Commit-archetype migrations' migrate.ps1
    (Phases C-K). Provides a single uniform code path for migration commits:

    - No-ops when there is no diff (idempotency contract CC-N3).
    - Refuses writes to Gracze.md unless the caller explicitly opts in via
      -AllowsGraczeWrite (the sole permitted opt-in is migration
      1.0.2-freeze-gracze; manifest declares AllowsGraczeWrite = $true).
    - Honours framework BranchMode implicitly: the commit lands wherever HEAD
      is pointed at the moment, which is what BranchMode set up.

    Helpers:
    - Invoke-MigrationCommit:  the public-facing internal entrypoint;
      callers pass -Message and optionally -Files / -AllowsGraczeWrite.
    - Test-MigrationDiffPresent: returns $true when `git diff --cached --quiet`
      reports staged changes; used by the helper to decide whether to commit.

    Module-level data: none.

    Design:
    - The helper takes -RepoRoot for testability; production callers omit it
      and the helper resolves via Get-RepoRoot.
    - Commit output is captured (stderr → stdout merge) so failures can be
      surfaced as structured ErrorRecords instead of leaking raw git output.

    Dependencies: Get-RepoRoot (private/get-reporoot.ps1).
#>

function Test-MigrationDiffPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string[]]$Files
    )

    # Ask git itself for the dirty file list. With staged + unstaged inputs we
    # need both: --cached covers post-add state, plain diff covers
    # unstaged. The helper stages before checking so a single --cached
    # pass suffices, but staging happens in the caller post-Test.
    $Args = @('-C', $RepoRoot, 'status', '--porcelain', '--')
    if ($Files -and $Files.Count -gt 0) { $Args += $Files }
    $Output = & git @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Ex = [System.InvalidOperationException]::new(
            "git status failed: $Output")
        throw $Ex
    }
    if ([string]::IsNullOrWhiteSpace([string]$Output)) { return $false }
    return $true
}

function Invoke-MigrationCommit {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, HelpMessage = 'Commit message.')]
        [string]$Message,

        [Parameter(HelpMessage = 'Explicit file list to add. Defaults to operation-context accumulator.')]
        [string[]]$Files,

        [Parameter(HelpMessage = 'Opt-in for Gracze.md writes; permitted only in 1.0.2-freeze-gracze.')]
        [switch]$AllowsGraczeWrite,

        [Parameter(HelpMessage = 'Repo-root override; defaults to Get-RepoRoot.')]
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-RepoRoot
    }

    # ── File list resolution ──────────────────────────────────────────────
    $TargetFiles = $null
    if ($Files -and $Files.Count -gt 0) {
        $TargetFiles = @($Files)
    } elseif ($script:OpFiles -and $script:OpFiles.Count -gt 0) {
        $TargetFiles = @($script:OpFiles)
    } else {
        # Empty file list — Commit-archetype migrations may expect to add
        # whatever predecessors left in the working tree. We allow this
        # explicitly by passing -A.
        $TargetFiles = $null
    }

    # ── Gracze.md guard ───────────────────────────────────────────────────
    if ($TargetFiles) {
        foreach ($F in $TargetFiles) {
            $Name = [System.IO.Path]::GetFileName($F)
            if ([string]::Equals($Name, 'Gracze.md', [System.StringComparison]::OrdinalIgnoreCase) -and -not $AllowsGraczeWrite) {
                $Ex = [System.InvalidOperationException]::new(
                    "Invoke-MigrationCommit refused to add 'Gracze.md' — only the " +
                    "1.0.2-freeze-gracze migration is permitted (declare AllowsGraczeWrite in manifest).")
                $ErrRec = [System.Management.Automation.ErrorRecord]::new(
                    $Ex, 'MigrationCommitGraczeRefused',
                    [System.Management.Automation.ErrorCategory]::PermissionDenied, $F)
                throw $ErrRec
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess("repo at '$RepoRoot'", "git commit -m '$Message'")) {
        return [PSCustomObject]@{ OK = $true; Skipped = $true; Reason = 'WhatIf' }
    }

    # ── Stage ────────────────────────────────────────────────────────────
    $AddArgs = @('-C', $RepoRoot, 'add')
    if ($TargetFiles) {
        foreach ($F in $TargetFiles) { $AddArgs += $F }
    } else {
        $AddArgs += '-A'
    }
    $AddOutput = & git @AddArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Ex = [System.InvalidOperationException]::new("git add failed: $AddOutput")
        $ErrRec = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationCommitAddFailed',
            [System.Management.Automation.ErrorCategory]::InvalidOperation, $AddArgs)
        throw $ErrRec
    }

    # ── Idempotency: skip if no diff ─────────────────────────────────────
    $DiffOutput = & git -C $RepoRoot diff --cached --name-only 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Ex = [System.InvalidOperationException]::new("git diff --cached failed: $DiffOutput")
        throw $Ex
    }
    if ([string]::IsNullOrWhiteSpace([string]$DiffOutput)) {
        return [PSCustomObject]@{
            OK      = $true
            Skipped = $true
            Reason  = 'NoDiff'
        }
    }

    # ── Commit ───────────────────────────────────────────────────────────
    $CommitOutput = & git -C $RepoRoot commit -m $Message 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Ex = [System.InvalidOperationException]::new("git commit failed: $CommitOutput")
        $ErrRec = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationCommitFailed',
            [System.Management.Automation.ErrorCategory]::InvalidOperation, $Message)
        throw $ErrRec
    }

    $Sha = (& git -C $RepoRoot rev-parse HEAD 2>&1).Trim()
    return [PSCustomObject]@{
        OK         = $true
        Skipped    = $false
        Sha        = $Sha
        Message    = $Message
        FilesAdded = if ($TargetFiles) { $TargetFiles } else { @('<all>') }
    }
}

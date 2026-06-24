<#
    .SYNOPSIS
    Migration runtime — lock acquisition, per-migration record/checklist,
    plugin hook integration, source-hash idempotency, schema-pointer advance.

    .DESCRIPTION
    Non-exported helper functions consumed by public/migration/invoke-migration.ps1
    and public/migration/invoke-migrationchain.ps1. Loaded once at module-init via
    the CC-1 dot-source block in Robot.PowerShell.psm1.

    Per-migration lifecycle (per WP-3 step list, with hook ordering swap from
    the validation review):
      1. Resolve target chain.
      2. Acquire schema lock for the duration of the run.
      3. For each migration:
         3.1 Load/init per-migration record (hooks need this).
         3.2 Fire BeforeMigration hook with record payload.
         3.3 OnlyIfSourceChanged: hash source; skip if unchanged.
         3.4 Dot-source migrate.ps1 (already AST-validated per CC-3) and
             call Test-MigrationApplied with the checklist if defined.
         3.5 Invoke-Migration with the progress callback + checklist.
         3.6 Drain accumulators via New-OperationResult.
         3.7 Set-SchemaVersion to advance the pointer.
         3.8 Fire AfterMigration hook with the post-apply record.
      4. Release lock in finally.

    State file: <repo>/.robot.local/res/migration-state.json (renamed shape
    from legacy Phases dict; legacy is auto-converted by the permanent
    compatibility shim).

    Module-level data:
    - $script:MigrationStateCache: per-process catch for record reads
#>

$script:MigrationStateCache = $null
$script:LegacyShimWarned    = $false

# admin-state.ps1 dependency (Save/Read-JsonStateFile) is dot-sourced from
# migration-version.ps1 already; no re-source needed here.

function Resolve-MigrationStateFile {
    [CmdletBinding()] param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
    return [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res', 'migration-state.json')
}

# ── State Load (with legacy shim) ───────────────────────────────────────────

function Get-MigrationStateFile {
    <#
        .SYNOPSIS
        Loads the migration-state.json file with legacy shim applied.

        .DESCRIPTION
        The legacy format used a Phases dict keyed by "0".."8". The new shape
        uses migrations dict keyed by migration ID. The shim maps each legacy
        phase into a synthetic record under "0.X.0-<slug>" so partial legacy
        runs resume cleanly under the framework. Shim is permanent per the
        Validation Findings table; emits a one-shot info note on first encounter.
    #>
    [CmdletBinding()] param([string]$RepoRoot)

    $Path = Resolve-MigrationStateFile -RepoRoot $RepoRoot
    $Raw = Read-JsonStateFile -Path $Path

    if (-not $Raw) {
        return [PSCustomObject]@{
            FilePath          = $Path
            SchemaFileVersion = 3
            Migrations        = @{}
        }
    }

    $Migrations = @{}
    if ($Raw.migrations) {
        # New shape — copy entries as-is into a fresh hashtable so callers can mutate.
        foreach ($Prop in $Raw.migrations.PSObject.Properties) {
            $Migrations[$Prop.Name] = ConvertTo-PlainDict -InputObject $Prop.Value
        }
    } elseif ($Raw.Phases) {
        # Legacy shape — synthesize records for the framework.
        if (-not $script:LegacyShimWarned) {
            Write-RobotInfo ("Legacy migration-state.json shape detected; up-converted in memory. " +
                "Re-save with Save-MigrationStateFile to make the conversion durable.")
            $script:LegacyShimWarned = $true
        }
        $LegacyMap = @{
            '0' = '0.1.0-bootstrap-entities'
            '1' = '0.2.0-session-hash-baseline'
            '2' = '0.3.0-validate-parity'
            '3' = '0.4.0-import-locations'
            '4' = '0.5.0-download-logs'
            '5' = '0.6.0-upgrade-session-formats'
            '6' = '0.7.0-infer-doors'
            '7' = '0.8.0-enroll-currency-csv'
            '8' = '1.0.0-cutover-yellow-threat'
        }
        foreach ($Prop in $Raw.Phases.PSObject.Properties) {
            $K = $Prop.Name
            if (-not $LegacyMap.ContainsKey($K)) { continue }
            $V = $Prop.Value
            $Checklist = @{}
            if ($V.Checklist) {
                foreach ($CP in $V.Checklist.PSObject.Properties) {
                    $Checklist[$CP.Name] = $CP.Value
                }
            }
            $Migrations[$LegacyMap[$K]] = @{
                status      = if ($V.Status) { $V.Status } else { 'NotStarted' }
                startedAt   = if ($V.StartedAt) { $V.StartedAt } else { $null }
                completedAt = if ($V.CompletedAt) { $V.CompletedAt } else { $null }
                checklist   = $Checklist
            }
        }
    }

    return [PSCustomObject]@{
        FilePath          = $Path
        SchemaFileVersion = if ($Raw.schemaFileVersion) { [int]$Raw.schemaFileVersion } else { 3 }
        Migrations        = $Migrations
    }
}

function Save-MigrationStateFile {
    <#
        .SYNOPSIS
        Persists the in-memory state to disk via atomic temp+bak swap.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object]$State,
        [string]$RepoRoot
    )
    $Path = Resolve-MigrationStateFile -RepoRoot $RepoRoot
    if (-not $PSCmdlet.ShouldProcess($Path, "Save migration state")) { return }

    $Data = [ordered]@{
        schemaFileVersion = 3
        migrations        = $State.Migrations
    }
    Save-JsonStateFile -Path $Path -Data $Data
}

function ConvertTo-PlainDict {
    # PSCustomObject (from ConvertFrom-Json) -> hashtable; recurse children.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $H = @{}
        foreach ($P in $InputObject.PSObject.Properties) {
            $H[$P.Name] = ConvertTo-PlainDict -InputObject $P.Value
        }
        return $H
    }
    return $InputObject
}

# ── Per-Migration Record Access ─────────────────────────────────────────────

function Get-MigrationRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [string]$RepoRoot
    )
    $State = Get-MigrationStateFile -RepoRoot $RepoRoot
    if ($State.Migrations.ContainsKey($MigrationId)) {
        return $State.Migrations[$MigrationId]
    }
    return $null
}

function Set-MigrationRecord {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [Parameter(Mandatory)] [hashtable]$Record,
        [string]$RepoRoot
    )
    $State = Get-MigrationStateFile -RepoRoot $RepoRoot
    $State.Migrations[$MigrationId] = $Record
    Save-MigrationStateFile -State $State -RepoRoot $RepoRoot
}

function Set-MigrationChecklistItem {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [Parameter(Mandatory)] [string]$Item,
        $Value = $true,
        [string]$RepoRoot
    )
    $State = Get-MigrationStateFile -RepoRoot $RepoRoot
    if (-not $State.Migrations.ContainsKey($MigrationId)) {
        $State.Migrations[$MigrationId] = @{
            status = 'InProgress'; startedAt = [datetime]::UtcNow.ToString('o')
            checklist = @{}
        }
    }
    if (-not $State.Migrations[$MigrationId].ContainsKey('checklist')) {
        $State.Migrations[$MigrationId].checklist = @{}
    } elseif ($State.Migrations[$MigrationId].checklist -isnot [hashtable]) {
        # Shim path: legacy record may have @{} object that already is one; idempotent.
        $H = @{}
        foreach ($K in $State.Migrations[$MigrationId].checklist.Keys) {
            $H[$K] = $State.Migrations[$MigrationId].checklist[$K]
        }
        $State.Migrations[$MigrationId].checklist = $H
    }
    $State.Migrations[$MigrationId].checklist[$Item] = $Value
    Save-MigrationStateFile -State $State -RepoRoot $RepoRoot
}

# ── Single-Migration Apply ──────────────────────────────────────────────────

function Invoke-MigrationInternal {
    <#
        .SYNOPSIS
        Applies a single migration end-to-end, honoring lock/hook/preview/skip rules.

        .DESCRIPTION
        Caller (Invoke-Migration/Invoke-MigrationChain) is responsible for
        already holding the schema lock; this function does NOT acquire the
        lock itself. That keeps chain runs from rotating locks per-migration
        and lets the public cmdlets surface lock errors consistently.

        Returns MigrationRunResult { OK, MigrationId, Skipped, Reason, Duration,
        FilesWritten, OperationResult, Warnings, Errors }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object]$Migration,
        [Parameter(Mandatory)] [hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [switch]$AllowUnsigned,
        [string]$RepoRoot
    )

    $Id = $Migration.Id
    $Start = Get-Date
    $Warnings = [System.Collections.Generic.List[string]]::new()
    $Errors   = [System.Collections.Generic.List[string]]::new()
    $FilesWritten = @()

    if ($Migration.Origin -eq 'OperatorLocal' -and -not $AllowUnsigned) {
        $Ex = [System.InvalidOperationException]::new(
            "Migration '$Id' is operator-local and unsigned. Pass -AllowUnsigned " +
            "to confirm you have reviewed migrate.ps1.")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'UnsignedMigrationBlocked',
            [System.Management.Automation.ErrorCategory]::SecurityError, $Migration)
        $PSCmdlet.ThrowTerminatingError($Err)
    }

    # Step 3.1 — load/init record before firing hooks (per validation finding #13)
    $Record = Get-MigrationRecord -MigrationId $Id -RepoRoot $RepoRoot
    if (-not $Record) {
        $Record = @{
            status    = 'InProgress'
            startedAt = [datetime]::UtcNow.ToString('o')
            checklist = @{}
        }
        Set-MigrationRecord -MigrationId $Id -Record $Record -RepoRoot $RepoRoot
    }

    $HookContext = @{
        Migration = $Migration
        Record    = $Record
        Config    = $Config
        Phase     = 'BeforeMigration'
    }

    # Step 3.2 — BeforeMigration hook
    if (Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue) {
        try {
            Invoke-PluginHook -Operation 'Migration' -Phase 'BeforeMigration' -Context $HookContext
        } catch {
            $Ex = [System.InvalidOperationException]::new(
                "BeforeMigration hook rejected '$Id': $($_.Exception.Message)")
            $Err = [System.Management.Automation.ErrorRecord]::new(
                $Ex, 'BeforeMigrationRejected',
                [System.Management.Automation.ErrorCategory]::OperationStopped, $Migration)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
    }

    # Step 3.3 — OnlyIfSourceChanged (WP-10 source-hash idempotency)
    $SkipForSourceUnchanged = $false
    if ($Migration.OnlyIfSourceChanged -and $Migration.SourceHashScript) {
        $Hash = Get-MigrationSourceHash -Migration $Migration -Config $Config
        if ($Hash -and $Record.sourceHash -and $Hash -eq $Record.sourceHash) {
            $SkipForSourceUnchanged = $true
            Write-MigrationLog -MigrationId $Id -Summary "Source unchanged (hash $Hash); skipping."
        }
    }

    if ($SkipForSourceUnchanged) {
        $Record.status = 'Completed'
        $Record.completedAt = [datetime]::UtcNow.ToString('o')
        Set-MigrationRecord -MigrationId $Id -Record $Record -RepoRoot $RepoRoot

        # AfterMigration still fires on skip so observers can record the no-op.
        if (Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue) {
            $HookContext.Phase = 'AfterMigration'
            $HookContext.Record = $Record
            try { Invoke-PluginHook -Operation 'Migration' -Phase 'AfterMigration' -Context $HookContext } catch { }
        }
        return [PSCustomObject]@{
            OK = $true; MigrationId = $Id; Skipped = $true
            Reason = 'source-unchanged'
            Duration = (Get-Date) - $Start
            FilesWritten = @(); OperationResult = $null
            Warnings = @($Warnings); Errors = @()
        }
    }

    # Step 3.4 — dot-source migrate.ps1 in isolated scope, check Test-MigrationApplied
    if (-not $PSCmdlet.ShouldProcess($Migration.Path, "Apply migration '$Id'")) {
        return [PSCustomObject]@{
            OK = $true; MigrationId = $Id; Skipped = $true; Reason = 'whatif'
            Duration = (Get-Date) - $Start; FilesWritten = @(); OperationResult = $null
            Warnings = @($Warnings); Errors = @()
        }
    }

    $ScriptPath = $Migration.ScriptPath
    if (-not [System.IO.File]::Exists($ScriptPath)) {
        throw "migrate.ps1 not found at '$ScriptPath'."
    }

    # Run the migration script in a child scope so its functions don't leak into
    # the module namespace. & { ...; . $ScriptPath; ... } returns the function
    # outputs that we explicitly request.
    $RunResult = & {
        param($Sp, $Cfg, $Cb, $Rec, $Sup)
        . $Sp
        $Applied = $false
        if (Get-Command 'Test-MigrationApplied' -ErrorAction SilentlyContinue) {
            $Applied = [bool](Test-MigrationApplied -Checklist $Rec.checklist)
        }
        if ($Applied) {
            return [PSCustomObject]@{ Skipped = $true; Reason = 'already-applied'; Inner = $null }
        }
        $ShouldProcessFlag = @{}
        if ($Sup) { $ShouldProcessFlag['Confirm'] = $false }
        $Inner = Invoke-Migration -Config $Cfg -ProgressCallback $Cb -Checklist $Rec.checklist @ShouldProcessFlag
        return [PSCustomObject]@{ Skipped = $false; Reason = $null; Inner = $Inner }
    } $ScriptPath $Config $ProgressCallback $Record $true

    if ($RunResult.Skipped) {
        $Record.status = 'Completed'
        $Record.completedAt = [datetime]::UtcNow.ToString('o')
        Set-MigrationRecord -MigrationId $Id -Record $Record -RepoRoot $RepoRoot
        Write-MigrationLog -MigrationId $Id -Summary "Already applied; skipping."
    } else {
        # Step 3.6 — drain operation context if present
        $OperationResult = $null
        if (Get-Command 'New-OperationResult' -ErrorAction SilentlyContinue) {
            try { $OperationResult = New-OperationResult } catch { $OperationResult = $null }
        }

        if ($RunResult.Inner -and $RunResult.Inner.PSObject.Properties['FilesWritten']) {
            $FilesWritten = @($RunResult.Inner.FilesWritten)
        }

        $Record.status = 'Completed'
        $Record.completedAt = [datetime]::UtcNow.ToString('o')
        if ($Migration.OnlyIfSourceChanged -and $Migration.SourceHashScript) {
            $NewHash = Get-MigrationSourceHash -Migration $Migration -Config $Config
            if ($NewHash) { $Record.sourceHash = $NewHash }
        }
        if ($OperationResult) {
            $Record.operationResult = $OperationResult
        }
        Set-MigrationRecord -MigrationId $Id -Record $Record -RepoRoot $RepoRoot
    }

    # Step 3.7 — advance schema pointer (no-op for cache-only migrations per WP-9)
    if ($Migration.AffectsCategories -notcontains 'Cache' -or
        ($Migration.AffectsCategories.Count -gt 1)) {
        Set-SchemaVersion -Version $Migration.Version -MajorName $Migration.MajorName `
            -MigrationId $Id -RepoRoot $RepoRoot
    }

    # Step 3.8 — AfterMigration hook
    if (Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue) {
        $HookContext.Phase = 'AfterMigration'
        $HookContext.Record = $Record
        try {
            Invoke-PluginHook -Operation 'Migration' -Phase 'AfterMigration' -Context $HookContext
        } catch {
            [void]$Warnings.Add("AfterMigration hook error: $($_.Exception.Message)")
        }
    }

    Write-MigrationLog -MigrationId $Id -Summary "Applied in $((((Get-Date) - $Start).TotalSeconds).ToString('F2'))s."

    return [PSCustomObject]@{
        OK             = $true
        MigrationId    = $Id
        Skipped        = $RunResult.Skipped
        Reason         = $RunResult.Reason
        Duration       = (Get-Date) - $Start
        FilesWritten   = $FilesWritten
        OperationResult = $RunResult.Inner
        Warnings       = @($Warnings)
        Errors         = @($Errors)
    }
}

# ── Source Hash Resolution (WP-10) ──────────────────────────────────────────

function Get-MigrationSourceHash {
    <#
        .SYNOPSIS
        Invokes the migration's SourceHashScript and returns the SHA256 string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Migration,
        [Parameter(Mandatory)] [hashtable]$Config
    )

    $ScriptRel = $Migration.SourceHashScript
    if (-not $ScriptRel) { return $null }
    $ScriptPath = [System.IO.Path]::Combine($Migration.Path, $ScriptRel)
    if (-not [System.IO.File]::Exists($ScriptPath)) {
        Write-RobotWarning "SourceHashScript not found at '$ScriptPath'; treating as changed."
        return $null
    }
    try {
        # Invoke the script as a command (not dot-source) so its top-level
        # `return $value` produces the hash exactly once. Dot-sourcing would
        # leak the script's local functions and double-emit the return value.
        $Hash = & $ScriptPath -Config $Config 2>&1 | Select-Object -Last 1
        return [string]$Hash
    } catch {
        Write-RobotWarning "SourceHashScript failed: $($_.Exception.Message); treating as changed."
        return $null
    }
}

# ── Test-MigrationApplied default (migrations may override) ─────────────────

function Test-MigrationAppliedDefault {
    # Default: a migration with at least one truthy checklist item is considered
    # applied. Migrations override by exporting their own Test-MigrationApplied.
    [CmdletBinding()] param([hashtable]$Checklist)
    if (-not $Checklist -or $Checklist.Count -eq 0) { return $false }
    foreach ($V in $Checklist.Values) { if ($V) { return $true } }
    return $false
}

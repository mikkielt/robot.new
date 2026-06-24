<#
    .SYNOPSIS
    Schema version store for the versioned migration framework.

    .DESCRIPTION
    Non-exported helper functions consumed by public/migration/*.ps1 cmdlets
    and the migration runtime. Loaded once at module-init via the CC-1
    dot-source block in Robot.PowerShell.psm1 (filename is not Verb-Noun so
    Phase 1 auto-loader skips it).

    Helpers:
    - Resolve-SchemaPath:     repo-relative path to .robot.local/schema.json
    - Set-SchemaVersion:      atomic write that appends prior current to history
    - Lock-Schema:            acquires exclusive lock for a migration run
    - Unlock-Schema:          releases the lock
    - Test-SchemaLockStale:   true when lockedAt exceeds the configured TTL
    - Compare-SchemaVersion:  hand-rolled SemVer comparator with composite
                              ("21.3.7+plugin-foo.1") support
    - Test-MajorNameDrift:    detects mismatched majorName across same MAJOR

    Module-level data:
    - $script:LockTtlMinutes: stale-lock TTL in minutes (default 60, overridable
      via local.config.psd1 key MigrationLockTtlMinutes)
    - $script:KnownMajorNames: registry of MAJOR -> name as observed in history,
      populated lazily by Test-MajorNameDrift

    Persistence is delegated to private/admin-state.ps1's Save-JsonStateFile /
    Read-JsonStateFile (atomic temp+bak swap, crash-safe).

    The schema.json shape:

        {
          "schemaFileVersion": 1,
          "current": "0.0.0",
          "majorName": "",
          "appliedAt": "...",
          "appliedBy": "...",
          "lockedBy": null,
          "lockedAt": null,
          "history": [
            { "version": "...", "majorName": "...", "migrationId": "...",
              "appliedAt": "...", "appliedBy": "..." }
          ]
        }
#>

$script:LockTtlMinutes = $null
$script:KnownMajorNames = $null

# admin-state.ps1 provides Save-JsonStateFile / Read-JsonStateFile (atomic temp+bak
# swap, crash-safe). It is not auto-loaded by Phase 1 (non-Verb-Noun filename), so
# we dot-source it here at module-init time when CC-1 loads us. Idempotent — other
# callers' on-demand dot-sources are harmless redefinitions.
$AdminStatePath = [System.IO.Path]::Combine($script:ModuleRoot, 'private', 'admin-state.ps1')
if ([System.IO.File]::Exists($AdminStatePath)) {
    . $AdminStatePath
}

# ── Path Resolution ─────────────────────────────────────────────────────────

function Resolve-SchemaPath {
    <#
        .SYNOPSIS
        Returns the absolute path to .robot.local/schema.json for the current repo.
    #>
    [CmdletBinding()] param([string]$RepoRoot)

    if (-not $RepoRoot) {
        $RepoRoot = Get-RepoRoot
    }
    return [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'schema.json')
}

# ── Lock TTL Resolution ──────────────────────────────────────────────────────

function Get-LockTtlMinutes {
    if ($null -ne $script:LockTtlMinutes) {
        return $script:LockTtlMinutes
    }
    $script:LockTtlMinutes = 60
    try {
        $LocalCfgPath = [System.IO.Path]::Combine($script:ModuleRoot, 'local.config.psd1')
        if ([System.IO.File]::Exists($LocalCfgPath)) {
            $LocalCfg = Import-PowerShellDataFile -Path $LocalCfgPath
            if ($LocalCfg.MigrationLockTtlMinutes) {
                $script:LockTtlMinutes = [int]$LocalCfg.MigrationLockTtlMinutes
            }
        }
    } catch {
        # Non-fatal: defaults to 60 if local.config.psd1 is malformed
    }
    return $script:LockTtlMinutes
}

# ── Atomic Pointer Update ───────────────────────────────────────────────────

function Set-SchemaVersion {
    <#
        .SYNOPSIS
        Updates the schema version pointer atomically. Must be called inside a lock.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$MajorName,
        [Parameter(Mandatory)] [string]$MigrationId,
        [string]$AppliedBy,
        [string]$RepoRoot
    )

    if (-not $AppliedBy) {
        $AppliedBy = if ($env:ROBOT_USER) { $env:ROBOT_USER } else { $env:USERNAME }
        if (-not $AppliedBy) { $AppliedBy = $env:USER }      # POSIX fallback
        if (-not $AppliedBy) { $AppliedBy = 'unknown' }
    }

    $Path = Resolve-SchemaPath -RepoRoot $RepoRoot
    if (-not $PSCmdlet.ShouldProcess($Path, "Set schema version to $Version")) {
        return
    }

    $Existing = Read-JsonStateFile -Path $Path
    $Timestamp = [datetime]::UtcNow.ToString('o')

    $History = [System.Collections.Generic.List[object]]::new()
    $LockedBy = $null
    $LockedAt = $null

    if ($Existing) {
        if ($Existing.history) {
            foreach ($Entry in @($Existing.history)) { [void]$History.Add($Entry) }
        }
        # Skip the fabricated 0.0.0 placeholder Lock-Schema writes on a fresh
        # repo (appliedMigrationId is empty when nothing has actually applied).
        # Real migrations always carry a migrationId, so this discrimination
        # is precise and doesn't lose meaningful history.
        $PriorHasReality = $Existing.current -and $Existing.current -ne $Version -and
            $Existing.appliedMigrationId
        if ($PriorHasReality) {
            [void]$History.Add([ordered]@{
                version     = $Existing.current
                majorName   = if ($Existing.majorName) { $Existing.majorName } else { '' }
                migrationId = if ($Existing.appliedMigrationId) { $Existing.appliedMigrationId } else { '' }
                appliedAt   = if ($Existing.appliedAt) { $Existing.appliedAt } else { '' }
                appliedBy   = if ($Existing.appliedBy) { $Existing.appliedBy } else { '' }
            })
        }
        # Preserve existing lock (Set is called inside Lock; Unlock-Schema does the clearing)
        $LockedBy = $Existing.lockedBy
        $LockedAt = $Existing.lockedAt
    }

    $Data = [ordered]@{
        schemaFileVersion   = 1
        current             = $Version
        majorName           = $MajorName
        appliedAt           = $Timestamp
        appliedBy           = $AppliedBy
        appliedMigrationId  = $MigrationId
        lockedBy            = $LockedBy
        lockedAt            = $LockedAt
        history             = @($History)
    }

    Save-JsonStateFile -Path $Path -Data $Data
}

# ── Lock Acquisition / Release ──────────────────────────────────────────────

function Lock-Schema {
    <#
        .SYNOPSIS
        Acquires the exclusive schema lock. Refuses if already locked.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$LockOwner,
        [switch]$Force,
        [string]$RepoRoot
    )

    $Path = Resolve-SchemaPath -RepoRoot $RepoRoot
    $Existing = Read-JsonStateFile -Path $Path

    if ($Existing -and $Existing.lockedBy -and -not $Force) {
        $Stale = Test-SchemaLockStale -SchemaState $Existing
        if ($Stale) {
            Write-RobotWarning ("Lock held by $($Existing.lockedBy) since $($Existing.lockedAt) " +
                "exceeds TTL of $(Get-LockTtlMinutes) min — likely stale; clear via " +
                "Reset-MigrationLock or DELETE /schema/lock.")
        }
        $Ex = [System.InvalidOperationException]::new(
            "Schema lock held by '$($Existing.lockedBy)' since '$($Existing.lockedAt)'.")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'SchemaLocked',
            [System.Management.Automation.ErrorCategory]::ResourceBusy, $Path)
        $PSCmdlet.ThrowTerminatingError($Err)
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Acquire schema lock for '$LockOwner'")) {
        return
    }

    $Now = [datetime]::UtcNow.ToString('o')

    if ($Existing) {
        $Data = [ordered]@{
            schemaFileVersion   = if ($Existing.schemaFileVersion) { $Existing.schemaFileVersion } else { 1 }
            current             = if ($Existing.current) { $Existing.current } else { '0.0.0' }
            majorName           = if ($Existing.majorName) { $Existing.majorName } else { '' }
            appliedAt           = if ($Existing.appliedAt) { $Existing.appliedAt } else { '' }
            appliedBy           = if ($Existing.appliedBy) { $Existing.appliedBy } else { '' }
            appliedMigrationId  = if ($Existing.appliedMigrationId) { $Existing.appliedMigrationId } else { '' }
            lockedBy            = $LockOwner
            lockedAt            = $Now
            history             = if ($Existing.history) { @($Existing.history) } else { @() }
        }
    } else {
        # Fresh repo — fabricate 0.0.0 with the lock applied
        $Data = [ordered]@{
            schemaFileVersion   = 1
            current             = '0.0.0'
            majorName           = ''
            appliedAt           = ''
            appliedBy           = ''
            appliedMigrationId  = ''
            lockedBy            = $LockOwner
            lockedAt            = $Now
            history             = @()
        }
    }

    Save-JsonStateFile -Path $Path -Data $Data
}

function Unlock-Schema {
    <#
        .SYNOPSIS
        Releases the schema lock unconditionally.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$RepoRoot)

    $Path = Resolve-SchemaPath -RepoRoot $RepoRoot
    $Existing = Read-JsonStateFile -Path $Path
    if (-not $Existing) {
        return     # nothing to unlock; absence is a no-op
    }
    if (-not $Existing.lockedBy) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "Release schema lock")) {
        return
    }

    $Data = [ordered]@{
        schemaFileVersion   = if ($Existing.schemaFileVersion) { $Existing.schemaFileVersion } else { 1 }
        current             = if ($Existing.current) { $Existing.current } else { '0.0.0' }
        majorName           = if ($Existing.majorName) { $Existing.majorName } else { '' }
        appliedAt           = if ($Existing.appliedAt) { $Existing.appliedAt } else { '' }
        appliedBy           = if ($Existing.appliedBy) { $Existing.appliedBy } else { '' }
        appliedMigrationId  = if ($Existing.appliedMigrationId) { $Existing.appliedMigrationId } else { '' }
        lockedBy            = $null
        lockedAt            = $null
        history             = if ($Existing.history) { @($Existing.history) } else { @() }
    }

    Save-JsonStateFile -Path $Path -Data $Data
}

function Test-SchemaLockStale {
    <#
        .SYNOPSIS
        Returns $true when lockedAt exceeds the configured TTL.
    #>
    [CmdletBinding()]
    param(
        [object]$SchemaState,
        [string]$RepoRoot
    )

    if (-not $SchemaState) {
        $Path = Resolve-SchemaPath -RepoRoot $RepoRoot
        $SchemaState = Read-JsonStateFile -Path $Path
        if (-not $SchemaState) { return $false }
    }
    if (-not $SchemaState.lockedAt) { return $false }

    try {
        # ConvertFrom-Json may auto-convert ISO timestamps to [datetime] with
        # kind=Local; if so, ToUniversalTime() applies the correct offset.
        # For raw strings, DateTimeOffset.Parse honors the "Z" suffix without
        # timezone-dependent fallback. Both paths land on a UTC datetime.
        if ($SchemaState.lockedAt -is [datetime]) {
            $LockedAtUtc = $SchemaState.lockedAt.ToUniversalTime()
        } else {
            $LockedAtUtc = [System.DateTimeOffset]::Parse(
                [string]$SchemaState.lockedAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            ).UtcDateTime
        }
    } catch {
        return $false       # unparseable timestamp — treat as fresh, not stale
    }

    $Age = [datetime]::UtcNow - $LockedAtUtc
    return $Age.TotalMinutes -gt (Get-LockTtlMinutes)
}

# ── Version Comparison ──────────────────────────────────────────────────────

function Compare-SchemaVersion {
    <#
        .SYNOPSIS
        Returns -1/0/1 by SemVer numeric ordering with composite-tag support.

        .DESCRIPTION
        Hand-rolled comparator. [System.Version] would silently drop the
        "+plugin-foo.1" suffix and treat 21.3.7 and 21.3.7+foo.1 as equal.
        Parsing rule: split on '+' for core / build tag; split core on '.'
        and compare part-by-part as integers. Presence-of-build outranks
        absence-of-build; two builds compare by string ordinal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$A,
        [Parameter(Mandatory)] [string]$B
    )

    $PartsA = $A.Split('+', 2)
    $PartsB = $B.Split('+', 2)

    $CoreA = $PartsA[0].Split('.')
    $CoreB = $PartsB[0].Split('.')

    $Max = [Math]::Max($CoreA.Count, $CoreB.Count)
    for ($I = 0; $I -lt $Max; $I++) {
        $Va = if ($I -lt $CoreA.Count) { [int]$CoreA[$I] } else { 0 }
        $Vb = if ($I -lt $CoreB.Count) { [int]$CoreB[$I] } else { 0 }
        if ($Va -lt $Vb) { return -1 }
        if ($Va -gt $Vb) { return  1 }
    }

    $HasBuildA = $PartsA.Count -gt 1
    $HasBuildB = $PartsB.Count -gt 1
    if (-not $HasBuildA -and -not $HasBuildB) { return 0 }
    if (-not $HasBuildA) { return -1 }      # 21.3.7 < 21.3.7+foo.1
    if (-not $HasBuildB) { return  1 }
    # CompareOrdinal returns the actual char-diff value; normalize to -1/0/1
    # so callers can compare with `-eq -1` / `-eq 1` reliably.
    $Cmp = [string]::CompareOrdinal($PartsA[1], $PartsB[1])
    if ($Cmp -lt 0) { return -1 }
    if ($Cmp -gt 0) { return  1 }
    return 0
}

# ── Major-Name Drift ────────────────────────────────────────────────────────

function Test-MajorNameDrift {
    <#
        .SYNOPSIS
        Returns drift info when a known prior MAJOR carried a different name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ProposedName,
        [string]$RepoRoot
    )

    $Major = ($Version.Split('+')[0]).Split('.')[0]

    if ($null -eq $script:KnownMajorNames) {
        $script:KnownMajorNames = @{}
        $Path = Resolve-SchemaPath -RepoRoot $RepoRoot
        $State = Read-JsonStateFile -Path $Path
        if ($State) {
            if ($State.history) {
                foreach ($Entry in @($State.history)) {
                    if ($Entry.version -and $Entry.majorName) {
                        $M = ($Entry.version.Split('+')[0]).Split('.')[0]
                        if (-not $script:KnownMajorNames.ContainsKey($M)) {
                            $script:KnownMajorNames[$M] = $Entry.majorName
                        }
                    }
                }
            }
            if ($State.current -and $State.majorName) {
                $M = ($State.current.Split('+')[0]).Split('.')[0]
                if (-not $script:KnownMajorNames.ContainsKey($M)) {
                    $script:KnownMajorNames[$M] = $State.majorName
                }
            }
        }
    }

    if ($script:KnownMajorNames.ContainsKey($Major)) {
        $Known = $script:KnownMajorNames[$Major]
        if ($Known -and $ProposedName -and -not [string]::Equals($Known, $ProposedName, 'Ordinal')) {
            return [PSCustomObject]@{
                Drift      = $true
                Major      = $Major
                KnownName  = $Known
                Proposed   = $ProposedName
            }
        }
    }
    return [PSCustomObject]@{ Drift = $false; Major = $Major }
}

# Tests reset the cache between runs to avoid contamination
function Clear-KnownMajorNameCache {
    $script:KnownMajorNames = $null
}

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.2.0-session-hash-baseline'
        EstimatedDurationSec = 10
        FilesToModify        = @()
        FilesToCreate        = @()
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Preview is structural — exact file list determined at apply time.')
        NetworkRequired      = $false
        SourceUnchanged      = $false
    }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [hashtable]$Checklist
    )
    # Delegate to the legacy Phase 1 implementation for semantic-identity parity.
    $LegacyDir = [System.IO.Path]::Combine($Config.RepoRoot, '.robot.powershell', 'migration')
    if (-not [System.IO.Directory]::Exists($LegacyDir)) {
        $LegacyDir = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'migration')
    }
    . (Join-Path $LegacyDir 'migration-shared.ps1')
    . (Join-Path $LegacyDir 'migration-state.ps1')
    . (Join-Path $LegacyDir 'migration-ui.ps1')
    . (Join-Path $LegacyDir 'phase1-session-hashes.ps1')
    Invoke-MigrationPhase1
    return [PSCustomObject]@{ OK = $true; FilesWritten = @() }
}

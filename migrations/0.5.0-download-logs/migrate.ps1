function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.5.0-download-logs'
        EstimatedDurationSec = 300
        FilesToModify        = @()
        FilesToCreate        = @()
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Preview is structural — exact file list determined at apply time.')
        NetworkRequired      = $true
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
    # Delegate to the legacy Phase 4 implementation for semantic-identity parity.
    $LegacyDir = [System.IO.Path]::Combine($Config.RepoRoot, '.robot.powershell', 'migration')
    if (-not [System.IO.Directory]::Exists($LegacyDir)) {
        $LegacyDir = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'migration')
    }
    . (Join-Path $LegacyDir 'migration-shared.ps1')
    . (Join-Path $LegacyDir 'migration-state.ps1')
    . (Join-Path $LegacyDir 'migration-ui.ps1')
    . (Join-Path $LegacyDir 'phase4-log-download.ps1')
    Invoke-MigrationPhase4
    return [PSCustomObject]@{ OK = $true; FilesWritten = @() }
}

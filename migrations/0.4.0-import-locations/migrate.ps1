<#
    .SYNOPSIS
    0.4.0-import-locations: bridge stub — placeholder until phase decomposition lands.

    .DESCRIPTION
    Placeholder body that returns Skipped=$true to advance the schema pointer
    without invoking the placeholder for Phase 3 (location import) phase code. The corresponding
    phase decomposition (Inspect/Transform/Commit micro-migrations) will replace
    this body in a follow-up session per the implementation plan.

    This stub exists so the Robot.PowerShell/migration/ directory can be
    deleted (WP-N1) without breaking the chain. Operators running the chain to
    later versions see this migration as Skipped='PipelineRetired'.
#>

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.4.0-import-locations'
        EstimatedDurationSec = 1
        FilesToModify        = @()
        FilesToCreate        = @()
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Phase decomposition pending; this migration is a placeholder.')
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
    return [PSCustomObject]@{
        OK = $true
        FilesWritten = @()
        Skipped = $true
        Reason = 'PipelineRetired'
    }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    return $false
}

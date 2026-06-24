function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration = '0.3.0-baz'; EstimatedDurationSec = 1
        FilesToModify = @(); FilesToCreate = @(); FilesToDelete = @()
        EntityCountsBefore = @{}; EntityCountsAfter = @{}
        SampleDiffs = @(); Warnings = @()
        NetworkRequired = $false; SourceUnchanged = $false
    }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(Mandatory)][hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [hashtable]$Checklist
    )
    return [PSCustomObject]@{ OK = $true; FilesWritten = @() }
}

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{
        Migration            = '0.1.0-foo'
        EstimatedDurationSec = 1
        FilesToModify        = @()
        FilesToCreate        = @()
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @()
        NetworkRequired      = $false
        SourceUnchanged      = $false
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

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    if (-not $Checklist) { return $false }
    return [bool]$Checklist['done']
}

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    $SchemaPath = [System.IO.Path]::Combine($Config.RepoRoot, '.robot.local', 'schema.json')
    $Exists = [System.IO.File]::Exists($SchemaPath)
    return [PSCustomObject]@{
        Migration            = '0.0.0-initialize-schema'
        EstimatedDurationSec = 1
        FilesToModify        = @()
        FilesToCreate        = if ($Exists) { @() } else { @($SchemaPath) }
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = if ($Exists) { @('schema.json already exists; migration is a no-op.') } else { @() }
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
    # Pointer write itself is done by the runtime via Set-SchemaVersion after
    # this returns. Nothing else to do for initialize-schema.
    return [PSCustomObject]@{ OK = $true; FilesWritten = @() }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    # Idempotent: the runtime's Set-SchemaVersion is itself idempotent; never skip.
    return $false
}

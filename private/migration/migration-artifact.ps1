<#
    .SYNOPSIS
    Migration artifact path resolution and atomic I/O.

    .DESCRIPTION
    Non-exported helpers consumed by public/migration/get-migrationartifact.ps1,
    public/migration/set-migrationartifact.ps1, and the migration runtime.
    Loaded once at module-init via the CC-1 dot-source block in
    Robot.PowerShell.psm1.

    Helpers:
    - Resolve-MigrationArtifactDir:    returns the directory holding artifacts
                                       for a given migration id under
                                       <repo>/.robot.local/migration-artifacts/<id>/
    - Resolve-MigrationArtifactPath:   appends "<name>.json" to the artifact dir
    - Read-MigrationArtifactFile:      thin wrapper around Read-JsonStateFile
    - Write-MigrationArtifactFile:     thin wrapper around Save-JsonStateFile;
                                       creates the migration-artifacts subtree
                                       on demand.
    - Save-MigrationPreviewCache:      writes the most-recent ChangeRecords[]
                                       for a migration to .preview-cache.json
                                       so WP-A3 can validate Override keys.

    Design:
    - Artifact filenames map 1:1 to a kebab-case name; the runtime appends
      ".json" so callers never spell the extension.
    - The artifact dir lives under .robot.local (the operator-local config
      space; gitignored by convention). Artifacts are operator-editable
      between Inspect → Transform pairs.
    - The preview cache uses a leading-dot filename (".preview-cache.json")
      so dashboard listings of operator-editable artifacts can filter it out
      cheaply (single-character prefix test).

    Dependencies: private/admin-state.ps1 (Save-JsonStateFile, Read-JsonStateFile).
#>

function Resolve-MigrationArtifactDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-RepoRoot
    }
    $Dir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'migration-artifacts', $MigrationId)
    return $Dir
}

function Resolve-MigrationArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [Parameter(Mandatory)] [string]$Name,
        [string]$RepoRoot
    )

    $Dir = Resolve-MigrationArtifactDir -MigrationId $MigrationId -RepoRoot $RepoRoot
    return [System.IO.Path]::Combine($Dir, "$Name.json")
}

function Read-MigrationArtifactFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [Parameter(Mandatory)] [string]$Name,
        [string]$RepoRoot
    )

    $Path = Resolve-MigrationArtifactPath -MigrationId $MigrationId -Name $Name -RepoRoot $RepoRoot
    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }
    return Read-JsonStateFile -Path $Path
}

function Write-MigrationArtifactFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value,
        [int]$Depth = 10,
        [string]$RepoRoot
    )

    $Path = Resolve-MigrationArtifactPath -MigrationId $MigrationId -Name $Name -RepoRoot $RepoRoot
    Save-JsonStateFile -Path $Path -Data $Value -Depth $Depth
    return $Path
}

function Save-MigrationPreviewCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MigrationId,
        [Parameter(Mandatory)] [object[]]$ChangeRecords,
        [string]$RepoRoot
    )

    # Persist the OverrideKey list so WP-A3 can validate Override hashtables
    # against keys the migration's last preview actually emitted.
    $Keys = [System.Collections.Generic.List[string]]::new()
    foreach ($Record in $ChangeRecords) {
        if ($null -eq $Record) { continue }
        $Key = $null
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains('OverrideKey')) { $Key = $Record['OverrideKey'] }
        } else {
            $OverrideKeyProperty = $Record.PSObject.Properties['OverrideKey']
            if ($OverrideKeyProperty) { $Key = $OverrideKeyProperty.Value }
        }
        if (-not [string]::IsNullOrWhiteSpace($Key)) {
            [void]$Keys.Add([string]$Key)
        }
    }

    $Cache = [PSCustomObject]@{
        MigrationId        = $MigrationId
        Generated          = (Get-Date).ToString('o')
        ChangeRecordCount  = $ChangeRecords.Count
        OverrideKeys       = @($Keys)
    }
    return Write-MigrationArtifactFile `
        -MigrationId $MigrationId `
        -Name '.preview-cache' `
        -Value $Cache `
        -RepoRoot $RepoRoot
}

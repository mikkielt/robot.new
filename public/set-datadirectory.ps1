<#
    .SYNOPSIS
    Overrides or resets the data directory used as the lore repository root.

    .DESCRIPTION
    By default, Get-RepoRoot locates the lore repository by walking upward from the
    module directory looking for a .git folder. Set-DataDirectory allows overriding
    that detection with an explicit path, or resetting back to the default git-based
    discovery.

    When -Path is given, subsequent calls to Get-RepoRoot return that path instead
    of performing git traversal. The data manifest cache is also cleared so that
    Find-DataManifest re-checks the fixed path from the new root on next use.

    When -Reset is given, the override is removed and Get-RepoRoot reverts to its
    standard .git-based detection logic. The manifest cache is cleared as well.
#>

function Set-DataDirectory {
    <#
        .SYNOPSIS
        Sets or resets the data directory override for the lore repository root.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = "Path", HelpMessage = "Absolute path to the directory to use as the data root")]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = "Reset", HelpMessage = "Clear the override and revert to git-based detection")]
        [switch]$Reset
    )

    if ($PSCmdlet.ParameterSetName -eq "Path") {
        if (-not [System.IO.Directory]::Exists($Path)) {
            throw "Directory not found: '$Path'"
        }
        $script:DataDirectoryOverride = [System.IO.Path]::GetFullPath($Path)
    } else {
        $script:DataDirectoryOverride = $null
    }

    # Clear cached data manifest so it re-scans from the new root
    $script:CachedManifest = $null
    $script:CachedManifestDir = $null
}

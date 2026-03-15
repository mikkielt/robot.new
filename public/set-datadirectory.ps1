<#
    .SYNOPSIS
    Overrides or resets the data directory used as the lore repository root.

    .DESCRIPTION
    By default, Get-RepoRoot locates the lore repository by walking upward from the
    module directory looking for a .git folder. Set-DataDirectory allows overriding
    that detection with an explicit path, or resetting back to the default git-based
    discovery.

    Module-level data:
    - $DataDirectoryOverride: stores the explicit path override (or $null when reset)
    - $CachedManifest / $CachedManifestDir: cleared on both -Path and -Reset so that
      Find-DataManifest re-scans from the new root on next use

    When -Path is given, subsequent calls to Get-RepoRoot return that path instead
    of performing git traversal. Useful for tests that point at a fixture directory,
    or for scenarios where the module is loaded outside a git repository.

    When -Reset is given, the override is removed and Get-RepoRoot reverts to its
    standard .git-based detection logic.
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

    # Invalidate manifest cache — next Find-DataManifest call will re-scan
    $script:CachedManifest = $null
    $script:CachedManifestDir = $null
}

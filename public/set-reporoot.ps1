<#
    .SYNOPSIS
    Overrides or resets the repository root used by the lore module.

    .DESCRIPTION
    By default, Get-RepoRoot locates the lore repository by walking upward from the
    module directory looking for a .git folder. Set-RepoRoot allows overriding
    that detection with an explicit path, or resetting back to the default git-based
    discovery.

    Module-level data:
    - $RepoRootOverride: stores the explicit path override (or $null when reset)
    - $CachedManifest / $CachedManifestDir: cleared on both -Path and -Reset so that
      Find-DataManifest re-scans from the new root on next use

    When -Path is given, subsequent calls to Get-RepoRoot return that path instead
    of performing git traversal. Useful for tests that point at a fixture directory,
    or for scenarios where the module is loaded outside a git repository.

    When -Reset is given, the override is removed and Get-RepoRoot reverts to its
    standard .git-based detection logic.
#>

function Set-RepoRoot {
    <#
        .SYNOPSIS
        Sets or resets the repository root override for the lore repository.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = "Path", HelpMessage = "Absolute path to the directory to use as the repository root")]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = "Reset", HelpMessage = "Clear the override and revert to git-based detection")]
        [switch]$Reset
    )

    if ($PSCmdlet.ParameterSetName -eq "Path") {
        if (-not [System.IO.Directory]::Exists($Path)) {
            throw "Directory not found: '$Path'"
        }
        $script:RepoRootOverride = [System.IO.Path]::GetFullPath($Path)
    } else {
        $script:RepoRootOverride = $null
    }

    # Invalidate manifest cache — next Find-DataManifest call will re-scan
    $script:CachedManifest = $null
    $script:CachedManifestDir = $null
}

<#
    .SYNOPSIS
    Locates the root directory of the lore repository that contains this module.

    .DESCRIPTION
    This file contains Get-RepoRoot and Get-ParentRepoRoot.

    Helpers:
    - Get-ParentRepoRoot: locates the parent repository root when this module is a
      Git submodule, walking past the submodule boundary to the enclosing repo.
      Used by manifest discovery (Find-DataManifest).

    Module-level data:
    - $DataDirectoryOverride: when set by Set-DataDirectory, Get-RepoRoot returns
      this path instead of performing git traversal
    - $CachedRepoRoot: memoized result of the upward .git search, cleared when
      Set-DataDirectory is called

    Get-RepoRoot traverses the directory tree upward from the module's parent directory,
    looking for a .git subdirectory or file. Returns the first ancestor that contains one.
    Throws if no repository is found before reaching the filesystem root.

    Starts from the module's own location (via $script:ModuleRoot set by robot.psm1)
    rather than the process working directory. This guarantees the result is always the
    enclosing lore repository — even when the module lives inside a Git submodule whose
    .git entry is a file (gitlink), not a directory.

    Fallback: if no ancestor has .git, checks whether the module directory itself is a
    repo root (standalone checkout, e.g. CI pipelines). This handles the case where the
    module is cloned directly rather than as a submodule.

    Used by every other function in the module to resolve repo-relative paths.
#>

function Get-RepoRoot {
    <#
        .SYNOPSIS
        Finds the root directory of the lore repository containing this module.
    #>
    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override the module directory for testing. Defaults to `$script:ModuleRoot set at import time.")]
        [string]$ModuleRoot,

        [Parameter(HelpMessage = "Return `$null instead of throwing when no repository is found.")]
        [switch]$Optional
    )

    # Set-DataDirectory override takes precedence over git traversal
    if ($script:DataDirectoryOverride) {
        return $script:DataDirectoryOverride
    }

    # Memoized — avoid repeated filesystem traversal on every caller invocation
    if (-not $ModuleRoot -and $script:CachedRepoRoot) {
        return $script:CachedRepoRoot
    }

    if (-not $ModuleRoot) {
        $ModuleRoot = $script:ModuleRoot
    }
    if (-not $ModuleRoot) {
        if ($Optional) { return $null }
        throw "Module root not resolved. Load the robot module via Import-Module before calling Get-RepoRoot."
    }

    # Start from parent of module dir — the module is always a child of the lore repo
    $CurrentDir = [System.IO.Path]::GetDirectoryName($ModuleRoot)
    if (-not $CurrentDir) {
        throw "Module directory '$ModuleRoot' has no parent directory."
    }

    while ($CurrentDir -ne [System.IO.Path]::GetPathRoot($CurrentDir)) {
        if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($CurrentDir, ".git"))) {
            $script:CachedRepoRoot = $CurrentDir
            return $CurrentDir
        }
        $CurrentDir = [System.IO.Path]::GetDirectoryName($CurrentDir)
    }

    # Standalone checkout fallback (CI pipelines where the module is the repo itself)
    $GitPath = [System.IO.Path]::Combine($ModuleRoot, ".git")
    if ([System.IO.Directory]::Exists($GitPath) -or [System.IO.File]::Exists($GitPath)) {
        $script:CachedRepoRoot = $ModuleRoot
        return $ModuleRoot
    }

    if ($Optional) { return $null }
    throw "No git repository found in any parent of the module directory '$ModuleRoot'."
}

function Get-ParentRepoRoot {
    <#
        .SYNOPSIS
        Finds the root directory of the parent repository when this module is a submodule.
    #>
    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override the repo root for testing. Defaults to Get-RepoRoot result.")]
        [string]$RepoRoot
    )

    if (-not $RepoRoot) {
        $RepoRoot = Get-RepoRoot
    }

    # Walk past the submodule boundary to find the enclosing parent repo
    $CurrentDir = [System.IO.Path]::GetDirectoryName($RepoRoot)
    if (-not $CurrentDir) {
        return $null
    }

    while ($CurrentDir -ne [System.IO.Path]::GetPathRoot($CurrentDir)) {
        $GitPath = [System.IO.Path]::Combine($CurrentDir, ".git")
        if ([System.IO.Directory]::Exists($GitPath) -or [System.IO.File]::Exists($GitPath)) {
            return $CurrentDir
        }
        $CurrentDir = [System.IO.Path]::GetDirectoryName($CurrentDir)
    }

    return $null
}

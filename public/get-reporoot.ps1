<#
    .SYNOPSIS
    Locates the root directory of the lore repository that contains this module.

    .DESCRIPTION
    Traverses the directory tree upward from the module's parent directory, looking for
    a .git subdirectory. Returns the first ancestor that contains one. Throws if no
    repository is found before reaching the filesystem root.

    Starts from the module's own location (via $script:ModuleRoot set by robot.psm1)
    rather than the process working directory. This guarantees the result is always the
    enclosing lore repository - even when the module lives inside a Git submodule whose
    .git entry is a file, not a directory.

    Used by every other function in the module to resolve repo-relative paths.

    Also contains Get-ParentRepoRoot which locates the parent repository root when
    the module lives inside a Git submodule. Walks past the submodule boundary to find
    the enclosing repository. Used by manifest discovery (Find-DataManifest).
#>

function Get-RepoRoot {
    <#
        .SYNOPSIS
        Finds the root directory of the lore repository containing this module.
    #>
    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Override the module directory for testing. Defaults to `$script:ModuleRoot set at import time.")]
        [string]$ModuleRoot
    )

    if (-not $ModuleRoot) {
        $ModuleRoot = $script:ModuleRoot
    }
    if (-not $ModuleRoot) {
        throw "Module root not resolved. Load the robot module via Import-Module before calling Get-RepoRoot."
    }

    # Start from the parent of the module directory - the module is always
    # a child of the lore repo (whether as a submodule or plain subdirectory).
    $CurrentDir = [System.IO.Path]::GetDirectoryName($ModuleRoot)
    if (-not $CurrentDir) {
        throw "Module directory '$ModuleRoot' has no parent directory."
    }

    while ($CurrentDir -ne [System.IO.Path]::GetPathRoot($CurrentDir)) {
        if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($CurrentDir, ".git"))) {
            return $CurrentDir
        }
        $CurrentDir = [System.IO.Path]::GetDirectoryName($CurrentDir)
    }
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

    # Walk up from the repo root itself. If this repo is a submodule,
    # its parent directory (or an ancestor) contains the enclosing .git directory.
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

<#
    .SYNOPSIS
    Locates the root directory of the lore repository that contains this module.

    .DESCRIPTION
    Traverses the directory tree upward from the module's parent directory, looking for
    a .git subdirectory. Returns the first ancestor that contains one. Throws if no
    repository is found before reaching the filesystem root.

    Starts from the module's own location (via $script:ModuleRoot set by robot.psm1)
    rather than the process working directory. This guarantees the result is always the
    enclosing lore repository — even when the module lives inside a Git submodule whose
    .git entry is a file, not a directory.

    Used by every other function in the module to resolve repo-relative paths.
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

    # Start from the parent of the module directory — the module is always
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

<#
    .SYNOPSIS
    Locates the root directory of the enclosing Git repository.

    .DESCRIPTION
    Traverses the directory tree upward from the process working directory, looking for
    a .git subdirectory. Returns the first ancestor that contains one. Throws if no
    repository is found before reaching the filesystem root.

    Used by every other function in the module to resolve repo-relative paths.
    Uses .NET System.IO for traversal (not Get-Location) so the result is independent
    of PowerShell's per-runspace working directory — important when running inside
    RunspacePool workers where $PWD may differ.
#>

function Get-RepoRoot {
    <#
        .SYNOPSIS
        Finds the root directory of the git repository containing the current working directory.
    #>

    $CurrentDir = [System.IO.Directory]::GetCurrentDirectory()
    while ($CurrentDir -ne [System.IO.Path]::GetPathRoot($CurrentDir)) {
        if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($CurrentDir, ".git"))) {
            return $CurrentDir
        }
        $CurrentDir = [System.IO.Path]::GetDirectoryName($CurrentDir)
    }
    throw "No git repository found in any parent directory."
}

<#
    .SYNOPSIS
    Shared helper for enumerating repository files with exclusion filtering.

    .DESCRIPTION
    Non-exported helper consumed by Get-Session and Get-HashableFiles via
    dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1 (non-Verb-Noun filename).

    Get-RepoFiles enumerates all files matching a glob pattern under a root
    directory, then applies a four-layer exclusion filter:
    1. Dot-directory components — any path segment starting with '.' is
       excluded (.git, .robot.local, .robot.powershell, etc.)
    2. Module directory — $script:ModuleRoot (the Robot.PowerShell submodule
       tree) is auto-excluded to prevent scanning devdocs, tests, and
       templates as lore data
    3. Set-RepoRoot redirect — when the search root differs from the module's
       physical parent (e.g. API workers or tests pointing at a fixture dir),
       the module's leaf directory name under the search root is also excluded
       to handle the submodule copy that appears in the redirected location
    4. User-specified directories — caller-provided $ExcludeDirectory paths
       are resolved to absolute prefixes and filtered

    The function builds all exclusion prefixes once, then filters the full
    file list in a single pass using StartsWith prefix matching. Dot-directory
    filtering uses per-component scanning since dot segments can appear at
    any depth.

    Helpers:
    - Get-RepoFiles: enumerates files in the repository with four-layer
      exclusion filtering (dot-directories, module directory, redirect copy,
      user-specified directories)

    Module-level data:
    - $script:ModuleRoot: used to auto-exclude the module's own directory tree
      and to detect redirect-copy scenarios under the search root
#>

function Get-RepoFiles {
    <#
        .SYNOPSIS
        Enumerates repository files matching a pattern with dot-directory and module exclusion.
    #>
    param(
        [Parameter(Mandatory, HelpMessage = "Root directory of the repository")]
        [string]$RepoRoot,

        [Parameter(HelpMessage = "File glob pattern to match")]
        [string]$Pattern = '*.md',

        [Parameter(HelpMessage = "Additional directories to exclude")]
        [string[]]$ExcludeDirectory
    )

    $Sep = [System.IO.Path]::DirectorySeparatorChar
    $ResolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $RootNorm = $ResolvedRoot.TrimEnd($Sep) + $Sep
    $AllFiles = [System.IO.Directory]::GetFiles(
        $ResolvedRoot, $Pattern, [System.IO.SearchOption]::AllDirectories)

    # Build exclusion prefix list
    $ExcludePrefixes = [System.Collections.Generic.List[string]]::new()

    # Exclude $script:ModuleRoot (the submodule directory)
    if ($script:ModuleRoot) {
        $ModNorm = [System.IO.Path]::GetFullPath($script:ModuleRoot).TrimEnd($Sep) + $Sep
        if ($ModNorm.StartsWith($RootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ExcludePrefixes.Add($ModNorm)
        }
        # Handle Set-RepoRoot redirect: module leaf name copy in search dir
        $ModLeaf = [System.IO.Path]::GetFileName($script:ModuleRoot.TrimEnd($Sep))
        $ModInRoot = [System.IO.Path]::Combine($ResolvedRoot, $ModLeaf) + $Sep
        if (-not $ModInRoot.Equals($ModNorm, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Directory]::Exists($ModInRoot.TrimEnd($Sep))) {
            $ExcludePrefixes.Add($ModInRoot)
        }
    }

    # User-specified exclusions
    if ($ExcludeDirectory) {
        foreach ($Dir in $ExcludeDirectory) {
            if ([System.IO.Directory]::Exists($Dir)) {
                $ExcludePrefixes.Add(
                    [System.IO.Path]::GetFullPath($Dir).TrimEnd($Sep) + $Sep)
            }
        }
    }

    $Result = [System.Collections.Generic.List[string]]::new()
    foreach ($FilePath in $AllFiles) {
        # Exclude dot-directory components (.git, .robot.local, .robot.powershell)
        $RelPath = $FilePath.Substring($RootNorm.Length)
        $Parts = $RelPath.Split(
            [char[]]@([char]'\', [char]'/'),
            [System.StringSplitOptions]::RemoveEmptyEntries)
        $Skip = $false
        for ($I = 0; $I -lt $Parts.Length - 1; $I++) {
            if ($Parts[$I].StartsWith('.')) { $Skip = $true; break }
        }
        if ($Skip) { continue }

        # Check prefix exclusions
        foreach ($Prefix in $ExcludePrefixes) {
            if ($FilePath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Skip = $true; break
            }
        }
        if (-not $Skip) { [void]$Result.Add($FilePath) }
    }

    return $Result
}

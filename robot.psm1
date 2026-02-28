<#
    .SYNOPSIS
    Module loader for Robot - PowerShell functions for Nerthus repository lore and metadata processing.

    .DESCRIPTION
    Auto-discovers and dot-sources all Verb-Noun .ps1 files in the module directory, exporting them
    as module functions. Non-Verb-Noun scripts (e.g. parse-markdownfile.ps1) are left unloaded -
    they are consumed on demand by the functions that need them.

    Assumes the working directory is inside the Nerthus Git repository containing Markdown files
    with structured information about players, characters, sessions, and entities.

    Core design principles:
    - No external modules or dependencies - only Git and PowerShell
    - Compatible with PowerShell 5.1 (Windows) and 7.0+ (Core)
    - .NET methods for file I/O, string manipulation, and process execution (performance + cross-platform)
    - No tools beyond Git and PowerShell
#>

$ModuleRoot = $PSScriptRoot

# Discover all .ps1 files using .NET I/O - avoid Get-ChildItem for performance
# Use AllDirectories so function files living in subfolders are found as well.
$FunctionFiles = [System.IO.Directory]::GetFiles($ModuleRoot, '*.ps1', [System.IO.SearchOption]::AllDirectories)

# Verb-Noun pattern regex for exported functions (case-insensitive)
$VerbNounPattern = [regex]::new('^(Get|Set|New|Remove|Resolve|Test|Invoke|Send)-\w+$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$ExportedFunctions = [System.Collections.Generic.List[string]]::new()

foreach ($FilePath in $FunctionFiles) {
    $FileName = [System.IO.Path]::GetFileName($FilePath)

    # Skip the module file itself and core.ps1 (case-insensitive)
    if ($FileName -ieq 'robot.psm1' -or $FileName -ieq 'core.ps1') { continue }

    # Derive function name from filename - avoids expensive Get-ChildItem Function: diffing
    $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

    # Only dot-source files whose name matches the Verb-Noun convention;
    # other .ps1 files (e.g. helper scripts) are loaded on demand, not at import.
    if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }

    try {
        . "$FilePath"
    }
    catch {
        [System.Console]::Error.WriteLine("Failed to load function file '$FileName': $_")
        continue
    }

    $ExportedFunctions.Add($FuncName)
}

if ($ExportedFunctions.Count -gt 0) {
    Export-ModuleMember -Function $ExportedFunctions
}

<#
    .SYNOPSIS
    Session integrity hashing helpers - compute, store, and compare SHA256
    content hashes for Markdown file headers.

    .DESCRIPTION
    Non-exported helper functions consumed by Set-SessionHash and
    Test-SessionIntegrity via dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Get-ContentHash:        SHA256 hash of whitespace-stripped content
    - Get-FileHeaderHashes:   compute hash map for all headers in a parsed Markdown file
    - Read-SessionHashFile:   load stored hashes from a JSON sidecar file
    - Write-SessionHashFile:  persist hash map to a JSON sidecar file
    - Read-SessionHashMeta:   load operational metadata (_meta.json)
    - Write-SessionHashMeta:  persist operational metadata
    - Get-HashableFiles:      enumerate .md files respecting exclusion rules
    - Get-RelativeHashPath:   compute repo-relative path with forward slashes

    Module-level data:
    - $script:WSPattern:  precompiled whitespace stripping regex (PowerShell fallback path)
    - $script:UTF8NoBOM:  shared UTF-8 no BOM encoding instance for all hash/JSON I/O

    Hash algorithm:
    - Concatenate the full header line (e.g. "### 2024-06-15, Title, Narrator")
      with the section body text (until next header or EOF)
    - Strip ALL whitespace characters (spaces, tabs, CR, LF)
    - Encode the result as UTF-8 (no BOM)
    - Compute SHA256 and return as lowercase hex string

    This normalization ensures formatting-only changes (extra blank lines,
    trailing spaces) do not cause false positives while genuine content
    changes are detected.

    Persistence uses JSON sidecar files alongside the original .md files,
    stored in the hash directory (.robot/hashes/). Each .md file maps to
    a .json sidecar with the same repo-relative path. A _meta.json file
    tracks operational metadata (last update timestamps, format version).

    All JSON I/O uses Robot.JsonHelper (System.Text.Json) when available,
    with ConvertTo-Json/ConvertFrom-Json as a PowerShell fallback.
    Hashing uses Robot.ContentHasher (ArrayPool-based zero-alloc) when
    available, with SHA256.Create() as a fallback.
#>

# Shared repo file enumeration helper (dot-directory + module exclusion)
. "$PSScriptRoot/repo-filehelpers.ps1"

# C# types: Robot.ContentHasher (lib/ContentHasher.cs), Robot.JsonHelper (lib/JsonHelper.cs)
# Compiled centrally in Robot.PowerShell.psm1 at module import time.

# Precompiled whitespace stripping pattern
$script:WSPattern = [regex]::new('\s+', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Shared UTF-8 no BOM encoding instance
$script:UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

# Compute SHA256 hash of whitespace-stripped content.
# Input is the raw concatenation of header line + body text.
# Returns lowercase 64-char hex string.
function Get-ContentHash {
    param(
        [Parameter(Mandatory, HelpMessage = "Raw content to hash (header + body)")]
        [AllowEmptyString()]
        [string]$Content
    )

    # C# path: single-pass whitespace strip + UTF-8 encode + SHA256, zero-alloc via ArrayPool
    if (([System.Management.Automation.PSTypeName]'Robot.ContentHasher').Type) {
        return [Robot.ContentHasher]::Hash($Content)
    }

    # PowerShell fallback
    $Stripped = $script:WSPattern.Replace($Content, '')
    $Bytes = $script:UTF8NoBOM.GetBytes($Stripped)

    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $HashBytes = $SHA256.ComputeHash($Bytes)
    } finally {
        $SHA256.Dispose()
    }

    return [System.BitConverter]::ToString($HashBytes).Replace('-', '').ToLowerInvariant()
}

# Compute hash map for all headers in a single parsed Markdown file.
# Takes a result object from Get-Markdown (with .Sections, each having .Header and .Content).
# Returns Dictionary[string,string] keyed by full header line (e.g. "### Title").
function Get-FileHeaderHashes {
    param(
        [Parameter(Mandatory, HelpMessage = "Parsed Markdown result from Get-Markdown")]
        [object]$MarkdownResult
    )

    $Hashes = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Section in $MarkdownResult.Sections) {
        if ($null -eq $Section.Header) { continue }

        # Reconstruct the full header line: "## Text" or "### Text" etc.
        $HeaderLine = ('#' * $Section.Header.Level) + ' ' + $Section.Header.Text

        # Content = header line + section body (Content is text between this header and next)
        $FullContent = $HeaderLine + "`n" + $Section.Content

        $Hash = Get-ContentHash -Content $FullContent
        $Hashes[$HeaderLine] = $Hash
    }

    return $Hashes
}

# Read stored hashes from a JSON sidecar file.
# Returns Dictionary[string,string] with OrdinalIgnoreCase comparer.
# Returns empty dictionary if file does not exist or is corrupt.
function Read-SessionHashFile {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to the .json hash file")]
        [string]$JsonPath
    )

    $Result = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    if (-not [System.IO.File]::Exists($JsonPath)) {
        return $Result
    }

    try {
        # C# path: System.Text.Json with direct Dictionary<string,string> output
        if (([System.Management.Automation.PSTypeName]'Robot.JsonHelper').Type) {
            return [Robot.JsonHelper]::ReadAsStringDictionary($JsonPath)
        }

        # PowerShell fallback
        $RawJson = [System.IO.File]::ReadAllText($JsonPath, $script:UTF8NoBOM)
        $Parsed = $RawJson | ConvertFrom-Json
        foreach ($Prop in $Parsed.PSObject.Properties) {
            $Result[$Prop.Name] = $Prop.Value
        }
    } catch {
        Write-RobotWarning "[WARN Read-SessionHashFile] Failed to parse '$JsonPath': $_"
    }

    return $Result
}

# Write hash map to a JSON sidecar file.
# Creates parent directories as needed. Keys are sorted for deterministic output.
function Write-SessionHashFile {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to the .json hash file")]
        [string]$JsonPath,

        [Parameter(Mandatory, HelpMessage = "Header-to-hash dictionary")]
        [System.Collections.Generic.Dictionary[string, string]]$Hashes
    )

    # C# path: sorted serialization with native JSON writer
    if (([System.Management.Automation.PSTypeName]'Robot.JsonHelper').Type) {
        [Robot.JsonHelper]::WriteSortedJson($JsonPath, $Hashes, 1)
        return
    }

    # PowerShell fallback
    $Dir = [System.IO.Path]::GetDirectoryName($JsonPath)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    # Sort keys for deterministic output
    $Ordered = [ordered]@{}
    $SortedKeys = [System.Collections.Generic.List[string]]::new($Hashes.Keys)
    $SortedKeys.Sort([System.StringComparer]::Ordinal)
    foreach ($Key in $SortedKeys) {
        $Ordered[$Key] = $Hashes[$Key]
    }

    $Json = $Ordered | ConvertTo-Json -Depth 1
    [System.IO.File]::WriteAllText($JsonPath, $Json, $script:UTF8NoBOM)
}

# Read operational metadata from _meta.json.
# Returns hashtable with LastFullUpdate, LastIncrementalUpdate, Version.
function Read-SessionHashMeta {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to _meta.json")]
        [string]$MetaPath
    )

    $Defaults = @{
        LastFullUpdate        = $null
        LastIncrementalUpdate = $null
        Version               = 1
    }

    if (-not [System.IO.File]::Exists($MetaPath)) {
        return $Defaults
    }

    try {
        # C# path: System.Text.Json (no DateTime auto-conversion)
        if (([System.Management.Automation.PSTypeName]'Robot.JsonHelper').Type) {
            $Parsed = [Robot.JsonHelper]::ReadAsHashtable($MetaPath)
        } else {
            # PowerShell fallback — use -AsHashtable to prevent DateTime conversion
            $RawJson = [System.IO.File]::ReadAllText($MetaPath, $script:UTF8NoBOM)
            $Parsed = $RawJson | ConvertFrom-Json -AsHashtable
        }

        if ($Parsed.ContainsKey('LastFullUpdate') -and $null -ne $Parsed['LastFullUpdate']) {
            $Defaults['LastFullUpdate'] = [string]$Parsed['LastFullUpdate']
        }
        if ($Parsed.ContainsKey('LastIncrementalUpdate') -and $null -ne $Parsed['LastIncrementalUpdate']) {
            $Defaults['LastIncrementalUpdate'] = [string]$Parsed['LastIncrementalUpdate']
        }
        if ($Parsed.ContainsKey('Version') -and $null -ne $Parsed['Version']) {
            $Defaults['Version'] = $Parsed['Version']
        }
    } catch {
        Write-RobotWarning "[WARN Read-SessionHashMeta] Failed to parse '$MetaPath': $_"
    }

    return $Defaults
}

# Write operational metadata to _meta.json.
function Write-SessionHashMeta {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to _meta.json")]
        [string]$MetaPath,

        [Parameter(Mandatory, HelpMessage = "Metadata hashtable")]
        [hashtable]$Meta
    )

    # C# path: sorted serialization with native JSON writer
    if (([System.Management.Automation.PSTypeName]'Robot.JsonHelper').Type) {
        [Robot.JsonHelper]::WriteSortedJson($MetaPath, $Meta, 1)
        return
    }

    # PowerShell fallback
    $Dir = [System.IO.Path]::GetDirectoryName($MetaPath)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Json = $Meta | ConvertTo-Json -Depth 1
    [System.IO.File]::WriteAllText($MetaPath, $Json, $script:UTF8NoBOM)
}

# Enumerate all .md files in the repository, respecting exclusion rules.
# Excludes: dot directories, Nerthus/ subdirectory, module directory, user-specified dirs.
# Delegates shared exclusion logic to Get-RepoFiles (repo-filehelpers.ps1),
# then applies the domain-specific Nerthus/ subdirectory exclusion.
function Get-HashableFiles {
    param(
        [Parameter(Mandatory, HelpMessage = "Root directory of the lore repository")]
        [string]$RepoRoot,

        [Parameter(HelpMessage = "Additional directories to exclude")]
        [string[]]$ExcludeDirectory
    )

    $Sep = [System.IO.Path]::DirectorySeparatorChar
    $ResolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $RootNorm = $ResolvedRoot.TrimEnd($Sep) + $Sep

    $BaseFiles = Get-RepoFiles -RepoRoot $RepoRoot -Pattern '*.md' -ExcludeDirectory $ExcludeDirectory

    # Domain-specific: exclude Nerthus/ subdirectory (not handled by Get-RepoFiles)
    $Result = [System.Collections.Generic.List[string]]::new()
    foreach ($FilePath in $BaseFiles) {
        $RelPath = $FilePath.Substring($RootNorm.Length)
        $Parts = $RelPath.Split(
            [char[]]@([char]'\', [char]'/'),
            [System.StringSplitOptions]::RemoveEmptyEntries)
        $Skip = $false
        for ($I = 0; $I -lt $Parts.Length - 1; $I++) {
            if ([string]::Equals($Parts[$I], 'Nerthus', [System.StringComparison]::OrdinalIgnoreCase)) {
                $Skip = $true
                break
            }
        }
        if (-not $Skip) { [void]$Result.Add($FilePath) }
    }

    return $Result
}

# Compute repo-relative path with forward slashes.
# Used to determine the JSON sidecar file path within the hash store.
function Get-RelativeHashPath {
    param(
        [Parameter(Mandatory, HelpMessage = "Absolute file path")]
        [string]$FilePath,

        [Parameter(Mandatory, HelpMessage = "Repository root directory")]
        [string]$RepoRoot
    )

    $Sep = [System.IO.Path]::DirectorySeparatorChar
    $ResolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $RepoRootNorm = $ResolvedRoot.TrimEnd($Sep) + $Sep
    $ResolvedFile = [System.IO.Path]::GetFullPath($FilePath)

    if (-not $ResolvedFile.StartsWith($RepoRootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $ResolvedFile.Replace('\', '/')
    }

    return $ResolvedFile.Substring($RepoRootNorm.Length).Replace('\', '/')
}

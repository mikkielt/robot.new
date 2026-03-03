<#
    .SYNOPSIS
    Session integrity hashing helpers - compute, store, and compare SHA256
    content hashes for Markdown file headers.

    .DESCRIPTION
    Non-exported helper functions consumed by Set-SessionHash and
    Test-SessionIntegrity via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Get-ContentHash:        SHA256 hash of whitespace-stripped content
    - Get-FileHeaderHashes:   compute hash map for all headers in a parsed Markdown file
    - Read-SessionHashFile:   load stored hashes from a JSON sidecar file
    - Write-SessionHashFile:  persist hash map to a JSON sidecar file
    - Read-SessionHashMeta:   load operational metadata (_meta.json)
    - Write-SessionHashMeta:  persist operational metadata
    - Get-HashableFiles:      enumerate .md files respecting exclusion rules
    - Get-RelativeHashPath:   compute repo-relative path with forward slashes

    Hash algorithm:
    - Concatenate the full header line (e.g. "### 2024-06-15, Title, Narrator")
      with the section body text (until next header or EOF)
    - Strip ALL whitespace characters (spaces, tabs, CR, LF)
    - Encode the result as UTF-8 (no BOM)
    - Compute SHA256 and return as lowercase hex string

    This normalization ensures formatting-only changes (extra blank lines,
    trailing spaces) do not cause false positives while genuine content
    changes are detected.
#>

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
        $RawJson = [System.IO.File]::ReadAllText($MetaPath, $script:UTF8NoBOM)
        # Use -AsHashtable to prevent automatic DateTime conversion of ISO 8601 strings
        $Parsed = $RawJson | ConvertFrom-Json -AsHashtable
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

    $Dir = [System.IO.Path]::GetDirectoryName($MetaPath)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Json = $Meta | ConvertTo-Json -Depth 1
    [System.IO.File]::WriteAllText($MetaPath, $Json, $script:UTF8NoBOM)
}

# Enumerate all .md files in the repository, respecting exclusion rules.
# Excludes: dot directories, Nerthus/ subdirectory, module directory, user-specified dirs.
function Get-HashableFiles {
    param(
        [Parameter(Mandatory, HelpMessage = "Root directory of the lore repository")]
        [string]$RepoRoot,

        [Parameter(HelpMessage = "Additional directories to exclude")]
        [string[]]$ExcludeDirectory
    )

    $Sep = [System.IO.Path]::DirectorySeparatorChar
    # Resolve symlinks (macOS /var -> /private/var) for consistent prefix matching
    $ResolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $RepoRootNorm = $ResolvedRoot.TrimEnd($Sep) + $Sep
    $AllFiles = [System.IO.Directory]::GetFiles($ResolvedRoot, "*.md", [System.IO.SearchOption]::AllDirectories)

    # Build exclusion prefixes
    $ExcludePrefixes = [System.Collections.Generic.List[string]]::new()

    # Exclude dot directories (any directory component starting with '.')
    # and Nerthus/ subdirectory — handled per-file below via component scan

    # Exclude user-specified directories
    if ($ExcludeDirectory) {
        foreach ($Dir in $ExcludeDirectory) {
            if ([System.IO.Directory]::Exists($Dir)) {
                $ExcludePrefixes.Add($Dir.TrimEnd($Sep) + $Sep)
            }
        }
    }

    $Result = [System.Collections.Generic.List[string]]::new()

    foreach ($FilePath in $AllFiles) {
        # Get the relative path from repo root
        if (-not $FilePath.StartsWith($RepoRootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $RelPath = $FilePath.Substring($RepoRootNorm.Length)

        # Split into directory components and check each
        $Skip = $false
        $Parts = $RelPath.Split([char[]]@([char]'\', [char]'/'), [System.StringSplitOptions]::RemoveEmptyEntries)

        # Check directory components (all except the filename)
        for ($i = 0; $i -lt $Parts.Length - 1; $i++) {
            $Part = $Parts[$i]
            # Exclude dot directories
            if ($Part.StartsWith('.')) {
                $Skip = $true
                break
            }
            # Exclude Nerthus/ subdirectory
            if ([string]::Equals($Part, 'Nerthus', [System.StringComparison]::OrdinalIgnoreCase)) {
                $Skip = $true
                break
            }
        }

        if ($Skip) { continue }

        # Check user-specified exclusion prefixes
        foreach ($Prefix in $ExcludePrefixes) {
            if ($FilePath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Skip = $true
                break
            }
        }

        if (-not $Skip) {
            [void]$Result.Add($FilePath)
        }
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

<#
    .SYNOPSIS
    Computes and stores SHA256 content hashes for all headers in repository
    Markdown files, enabling session integrity verification.

    .DESCRIPTION
    This file contains Set-SessionHash, which builds a hash store mirroring
    the repository's Markdown file structure inside {ResDir}/session-hashes/.

    For each .md file, a corresponding .json sidecar is created containing
    a dictionary of header text -> SHA256 hash (of whitespace-stripped content).

    Supports two modes:
    - Full (-Full): scans all eligible .md files in the repository
    - Incremental (default): uses Get-GitChangeLog to find changed files

    Exclusions (applied automatically):
    - Dot directories (.git/, .robot/, .robot.new/)
    - Nerthus/ subdirectory
    - User-specified directories via -ExcludeDirectory

    Helpers:
    - Dot-sources private/session-hashhelpers.ps1 for hashing primitives
    - Dot-sources private/admin-config.ps1 for ResDir resolution
#>

function Set-SessionHash {
    <#
        .SYNOPSIS
        Computes and stores content hashes for all headers in repository Markdown files.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')] param(
        [Parameter(HelpMessage = "Recompute hashes for all files, not just changed ones")]
        [switch]$Full,

        [Parameter(HelpMessage = "Limit to specific file path(s)")]
        [string[]]$File,

        [Parameter(HelpMessage = "Only process files changed since this date (for incremental mode)")]
        [string]$Since,

        [Parameter(HelpMessage = "Directories to exclude from scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Load helpers
    if (-not (Get-Command 'Get-ContentHash' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/session-hashhelpers.ps1"
    }
    if (-not (Get-Command 'Get-AdminConfig' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/admin-config.ps1"
    }

    $Config = Get-AdminConfig
    $RepoRoot = $Config.RepoRoot
    $HashDir = [System.IO.Path]::Combine($Config.ResDir, 'session-hashes')
    $MetaPath = [System.IO.Path]::Combine($HashDir, '_meta.json')

    # Determine which files to process
    $FilesToProcess = [System.Collections.Generic.List[string]]::new()

    if ($File) {
        # Explicit file list
        foreach ($F in $File) {
            $FullPath = if ([System.IO.Path]::IsPathRooted($F)) { $F } else {
                [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepoRoot, $F))
            }
            if ([System.IO.File]::Exists($FullPath)) {
                [void]$FilesToProcess.Add($FullPath)
            } else {
                Write-RobotWarning "[WARN Set-SessionHash] File not found: '$FullPath'"
            }
        }
    } elseif ($Full) {
        # Full scan
        $FilesToProcess = Get-HashableFiles -RepoRoot $RepoRoot -ExcludeDirectory $ExcludeDirectory
    } else {
        # Incremental: use git changelog to find changed files
        $MinDateStr = $Since
        if (-not $MinDateStr) {
            $Meta = Read-SessionHashMeta -MetaPath $MetaPath
            $MinDateStr = $Meta['LastIncrementalUpdate']
        }

        $UseFullScan = $false
        if ($MinDateStr) {
            try {
                $GitArgs = @{ NoPatch = $true }
                $GitArgs['MinDate'] = $MinDateStr
                $GitLog = Get-GitChangeLog @GitArgs

                $ChangedFiles = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase
                )

                foreach ($Commit in $GitLog) {
                    foreach ($CF in $Commit.Files) {
                        if ($null -eq $CF.Path) { continue }
                        if (-not $CF.Path.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                        $AbsPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepoRoot, $CF.Path))
                        if ([System.IO.File]::Exists($AbsPath)) {
                            [void]$ChangedFiles.Add($AbsPath)
                        }
                    }
                }

                # Filter to hashable files only
                $AllHashable = [System.Collections.Generic.HashSet[string]]::new(
                    (Get-HashableFiles -RepoRoot $RepoRoot -ExcludeDirectory $ExcludeDirectory),
                    [System.StringComparer]::OrdinalIgnoreCase
                )

                foreach ($CF in $ChangedFiles) {
                    if ($AllHashable.Contains($CF)) {
                        [void]$FilesToProcess.Add($CF)
                    }
                }
            } catch {
                Write-RobotWarning "[WARN Set-SessionHash] Git changelog failed: $_. Falling back to full scan."
                $UseFullScan = $true
            }
        } else {
            # No previous timestamp — full scan needed
            $UseFullScan = $true
        }

        if ($UseFullScan) {
            $FilesToProcess = Get-HashableFiles -RepoRoot $RepoRoot -ExcludeDirectory $ExcludeDirectory
        }
    }

    if ($FilesToProcess.Count -eq 0) {
        return [PSCustomObject]@{
            FilesProcessed = 0
            HashesComputed = 0
            HashesUpdated  = 0
            HashesNew      = 0
        }
    }

    # Batch-parse all files
    $MarkdownResults = @(Get-Markdown -File @($FilesToProcess))

    $TotalHashes = 0
    $TotalUpdated = 0
    $TotalNew = 0
    $FilesWritten = 0

    foreach ($MdResult in $MarkdownResults) {
        if ($null -eq $MdResult) { continue }

        $RelPath = Get-RelativeHashPath -FilePath $MdResult.FilePath -RepoRoot $RepoRoot
        $JsonPath = [System.IO.Path]::Combine($HashDir, "$RelPath.json")

        # Compute current hashes
        $CurrentHashes = Get-FileHeaderHashes -MarkdownResult $MdResult
        $TotalHashes += $CurrentHashes.Count

        # Load existing hashes to count updates vs new
        $StoredHashes = Read-SessionHashFile -JsonPath $JsonPath
        foreach ($Key in $CurrentHashes.Keys) {
            if ($StoredHashes.ContainsKey($Key)) {
                if (-not [string]::Equals($StoredHashes[$Key], $CurrentHashes[$Key], [System.StringComparison]::OrdinalIgnoreCase)) {
                    $TotalUpdated++
                }
            } else {
                $TotalNew++
            }
        }

        # Write updated hashes
        if ($PSCmdlet.ShouldProcess($RelPath, 'Update session hashes')) {
            Write-SessionHashFile -JsonPath $JsonPath -Hashes $CurrentHashes
            $FilesWritten++
        }
    }

    # Update metadata
    # Use non-ISO format to prevent ConvertFrom-Json from auto-converting to DateTime
    $Now = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    $Meta = Read-SessionHashMeta -MetaPath $MetaPath
    if ($Full) {
        $Meta['LastFullUpdate'] = $Now
    }
    $Meta['LastIncrementalUpdate'] = $Now

    if ($PSCmdlet.ShouldProcess('_meta.json', 'Update hash metadata')) {
        Write-SessionHashMeta -MetaPath $MetaPath -Meta $Meta
    }

    return [PSCustomObject]@{
        FilesProcessed = $FilesWritten
        HashesComputed = $TotalHashes
        HashesUpdated  = $TotalUpdated
        HashesNew      = $TotalNew
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

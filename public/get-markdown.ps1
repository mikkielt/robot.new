<#
    .SYNOPSIS
    Orchestrates Markdown file parsing - delegates per-file work to parse-markdownfile.ps1,
    optionally in parallel via a RunspacePool.

    .DESCRIPTION
    Get-Markdown is the public entry point for Markdown parsing. It accepts file paths or a
    directory, then hands each file to the self-contained parse-markdownfile.ps1 script for
    the actual parsing work.

    Module-level data:
    - $script:CachedParseFileScriptStr: parser script text cached after first read to
      avoid repeated file I/O across calls
    - $script:MarkdownCache: WP-2 memory cache — Dictionary[string, object] keyed by
      file path, storing {ModTime, Result} pairs. Checked first on every call; populated
      after both disk cache hits and full parses

    Two-file architecture:
    - get-markdown.ps1 (this file): orchestration, parallelism, input validation
    - parse-markdownfile.ps1: single-file parsing logic (headers, sections, lists, links)

    The split exists because RunspacePool workers don't share the module scope. The parser
    script is loaded as a string and passed to each worker via AddScript, making it
    fully self-contained. When Robot.MarkdownScanner (lib/MarkdownScanner.cs) is available,
    the parser delegates line scanning to compiled C# for single-pass performance.

    Three-tier caching (WP-2 + WP-8):
    1. Memory cache ($script:MarkdownCache): fastest, per-session lifetime, keyed by
       FilePath -> {ModTime, Result}. Checked first on every call.
    2. Disk cache ({RepoRoot}/.robot.local/.cache/markdown/): persists across sessions. On memory
       miss, check disk index for matching ModTime. Reads deserialize ScanResult from JSON
       and reconstruct PSCustomObject references (same as fresh MarkdownScanner output).
       Requires Robot.ParseCacheHelper and Robot.MarkdownScanner to be available.
    3. Full parse: parse-markdownfile.ps1 via sequential or RunspacePool execution. Results
       written back to both memory and disk caches.

    Parallelism:
    When more than 4 files need parsing, a RunspacePool is created with up to ProcessorCount
    threads. Below that threshold, files are processed sequentially to avoid the ~50ms pool
    setup overhead. This matters for Get-Session which parses dozens of Markdown files in
    a single call.

    Helpers:
    - ConvertFrom-ScanResult: reconstructs PSCustomObject from C# ScanResult + FilePath,
      converting index-based parent references to object references. Same logic as
      parse-markdownfile.ps1's C# path but callable from get-markdown.ps1 for disk
      cache deserialization.

    Return convention:
    - Single file via -File: returns the object directly (not wrapped in array)
    - Multiple files or -Directory: returns a List of objects
#>

# ScanResult → PSCustomObject reconstruction (duplicated in parse-markdownfile.ps1:50-100).
# This copy handles disk cache deserialization. parse-markdownfile.ps1 has a self-contained
# copy for RunspacePool workers. Any changes here MUST be mirrored there.
function ConvertFrom-ScanResult {
    param(
        [object]$CsResult,
        [string]$FilePath
    )

    # Reconstruct header objects with actual ParentHeader references (not indices)
    $HeaderObjs = [System.Collections.Generic.List[object]]::new($CsResult.Headers.Length)
    foreach ($H in $CsResult.Headers) {
        $ParentRef = if ($H.ParentIndex -ge 0) { $HeaderObjs[$H.ParentIndex] } else { $null }
        $HeaderObjs.Add([PSCustomObject]@{
            Level        = $H.Level
            Text         = $H.Text
            ParentHeader = $ParentRef
            LineNumber   = $H.LineNumber
        })
    }

    # Convert ListEntry ParentIndex from global to section-local and set LocalIndex
    $SectionObjs = [System.Collections.Generic.List[object]]::new($CsResult.Sections.Length)
    foreach ($S in $CsResult.Sections) {
        $HeaderRef = if ($S.HeaderIndex -ge 0) { $HeaderObjs[$S.HeaderIndex] } else { $null }
        $Offset = $S.ListStartIndex
        $SectionLists = [System.Collections.Generic.List[object]]::new($S.ListCount)
        for ($J = 0; $J -lt $S.ListCount; $J++) {
            $LI = $CsResult.Lists[$Offset + $J]
            $LI.LocalIndex = $J
            $LI.ParentIndex = if ($LI.ParentIndex -ge 0) { $LI.ParentIndex - $Offset } else { -1 }
            $SectionLists.Add($LI)
        }
        $SectionObjs.Add([PSCustomObject]@{
            Header  = $HeaderRef
            Content = $S.Content
            Lists   = $SectionLists
        })
    }

    return [PSCustomObject]@{
        FilePath = $FilePath
        Headers  = $HeaderObjs
        Sections = $SectionObjs
        Lists    = $CsResult.Lists
        Links    = $CsResult.Links
    }
}

function Get-Markdown {
    <#
        .SYNOPSIS
        Parses Markdown files into structured objects with headers, sections, lists, and links.
    #>

    [CmdletBinding(DefaultParameterSetName = "Directory")] param(
        [Parameter(ParameterSetName = "File", HelpMessage = "Path(s) to Markdown file(s) to parse")] [ValidateScript({
            # Validate each file in the array exists
            $FilePaths = if ($_ -is [array]) { $_ } else { @($_) }
            foreach ($Path in $FilePaths) {
                if (-not [System.IO.File]::Exists($Path)) { throw "File not found: $Path" }
            }
            return $true
        })]
        [string[]]$File,

        [Parameter(ParameterSetName = "Directory", HelpMessage = "Path to directory with Markdown files to parse recursively")] [ValidateScript({
            if (-not [System.IO.Directory]::Exists($_)) { throw "Directory not found: $_" }
            return $true
        })]
        [string]$Directory
    )

    # Default to repo root when called without arguments (e.g. from Get-Session)
    if ($PSCmdlet.ParameterSetName -eq "Directory" -and -not $PSBoundParameters.ContainsKey('Directory')) {
        $Directory = Get-RepoRoot
    }

    # Collect input files from either -File paths or -Directory recursive scan
    $FilesToProcess = [System.Collections.Generic.List[string]]::new()

    if ($PSCmdlet.ParameterSetName -eq "File") {
        foreach ($FilePath in $File) {
            [void]$FilesToProcess.Add($FilePath)
        }
    } else {
        $FilesToProcess.AddRange([System.IO.Directory]::GetFiles($Directory, "*.md", [System.IO.SearchOption]::AllDirectories))
        $FilesToProcess.AddRange([System.IO.Directory]::GetFiles($Directory, "*.markdown", [System.IO.SearchOption]::AllDirectories))
    }

    $AllResults = [System.Collections.Generic.List[object]]::new()

    # ── WP-2: Memory cache — check file mod times before parsing ──────────
    # Cache lookup happens here (parent scope) because RunspacePool workers
    # cannot access $script:MarkdownCache (different runspace).
    if (-not $script:MarkdownCache) {
        $script:MarkdownCache = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }

    $Uncached = [System.Collections.Generic.List[string]]::new()
    foreach ($FP in $FilesToProcess) {
        $FileInfo = [System.IO.FileInfo]::new($FP)
        $ModKey = $FileInfo.LastWriteTimeUtc.Ticks
        if ($script:MarkdownCache.ContainsKey($FP)) {
            $CacheEntry = $script:MarkdownCache[$FP]
            if ($CacheEntry.ModTime -eq $ModKey) {
                [void]$AllResults.Add($CacheEntry.Result)
                continue
            }
        }
        [void]$Uncached.Add($FP)
    }

    # ── WP-8: Disk cache tier — check sidecar before parsing ─────────────
    # Only active when both ParseCacheHelper and MarkdownScanner are compiled.
    # On disk hit: deserialize ScanResult -> reconstruct PSCustomObject -> memory cache.
    # On disk miss: file goes to the parse list for full processing below.
    $HasDiskCache = (([System.Management.Automation.PSTypeName]'Robot.ParseCacheHelper').Type) -and
                    (([System.Management.Automation.PSTypeName]'Robot.MarkdownScanner').Type)
    $DiskCacheDir = $null
    $DiskCacheDataDir = $null
    $DiskCacheIndex = $null
    $DiskCacheIndexDirty = $false
    $StillUncached = [System.Collections.Generic.List[string]]::new()

    if ($HasDiskCache -and $Uncached.Count -gt 0) {
        try {
            $RepoRoot = Get-RepoRoot
            $DiskCacheDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', '.cache', 'markdown')
            $DiskCacheDataDir = [System.IO.Path]::Combine($DiskCacheDir, 'data')

            # Read meta to check version compatibility
            $MetaPath = [System.IO.Path]::Combine($DiskCacheDir, '_meta.json')
            $Meta = [Robot.ParseCacheHelper]::ReadMetaFile($MetaPath)
            $CacheVersionOk = $Meta.ContainsKey('Version') -and
                              ([int]$Meta['Version'] -eq [Robot.ParseCacheHelper]::CacheVersion)

            if ($CacheVersionOk) {
                # Load disk index: maps relative file paths to {ModTime, Key}
                $IndexPath = [System.IO.Path]::Combine($DiskCacheDir, '_index.json')
                $DiskCacheIndex = [Robot.ParseCacheHelper]::ReadMetaFile($IndexPath)

                foreach ($FP in $Uncached) {
                    $FileInfo = [System.IO.FileInfo]::new($FP)
                    $ModKey = $FileInfo.LastWriteTimeUtc.Ticks

                    # Index key: path relative to RepoRoot for portability
                    $RelPath = $FP
                    if ($FP.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $RelPath = $FP.Substring($RepoRoot.Length).TrimStart('\', '/')
                    }

                    $DiskHit = $false
                    if ($DiskCacheIndex.ContainsKey($RelPath)) {
                        $IndexEntry = $DiskCacheIndex[$RelPath]
                        # ModTime stored as string in JSON; compare after conversion
                        $StoredMod = if ($IndexEntry -is [System.Collections.Hashtable] -and
                                         $IndexEntry.ContainsKey('ModTime')) {
                            [long]$IndexEntry['ModTime']
                        } else { 0 }

                        if ($StoredMod -eq $ModKey) {
                            # Disk hit — read ScanResult from data file
                            $DataKey = if ($IndexEntry -is [System.Collections.Hashtable] -and
                                           $IndexEntry.ContainsKey('Key')) {
                                $IndexEntry['Key']
                            } else { $null }

                            if ($DataKey) {
                                $DataPath = [System.IO.Path]::Combine($DiskCacheDataDir, "$DataKey.json")
                                $CsResult = [Robot.ParseCacheHelper]::ReadScanResultFromFile($DataPath)
                                if ($null -ne $CsResult) {
                                    # Reconstruct PSCustomObject from deserialized ScanResult
                                    $Result = ConvertFrom-ScanResult -CsResult $CsResult -FilePath $FP
                                    $script:MarkdownCache[$FP] = @{
                                        ModTime = $ModKey
                                        Result  = $Result
                                    }
                                    [void]$AllResults.Add($Result)
                                    $DiskHit = $true
                                }
                            }
                        }
                    }

                    if (-not $DiskHit) {
                        [void]$StillUncached.Add($FP)
                    }
                }
            } else {
                # Version mismatch — invalidate disk cache, all files need parsing
                $StillUncached.AddRange($Uncached)
                $DiskCacheIndex = @{}
                $DiskCacheIndexDirty = $true
            }
        } catch {
            # Disk cache failure is non-fatal — fall through to full parse
            $StillUncached = $Uncached
            $HasDiskCache = $false
        }
    } else {
        $StillUncached = $Uncached
    }

    # Only parse files that changed, are not in memory cache, and not in disk cache
    if ($StillUncached.Count -gt 0) {
        # Robot.MarkdownScanner compiled centrally in Robot.PowerShell.psm1 — AppDomain-wide,
        # so all RunspacePool workers share the type without per-call compilation.

        # Parser text cached at script scope — used both for [scriptblock]::Create (sequential)
        # and AddScript (parallel workers that lack module scope)
        if (-not $script:CachedParseFileScriptStr) {
            $ParseFileScriptPath = [System.IO.Path]::Combine($script:ModuleRoot, 'private', 'parse-markdownfile.ps1')
            $script:CachedParseFileScriptStr = [System.IO.File]::ReadAllText($ParseFileScriptPath)
        }
        $ParseFileScriptStr = $script:CachedParseFileScriptStr
        $ParseFileScript    = [scriptblock]::Create($ParseFileScriptStr)

        $ParallelThreshold = 4  # RunspacePool setup ~50ms; only amortized above this count

        if ($StillUncached.Count -gt $ParallelThreshold) {
            $MaxThreads = [Math]::Min($StillUncached.Count, [Environment]::ProcessorCount)
            $Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
            $Pool.Open()

            # Each worker receives parser script text + one file path
            $Jobs = [System.Collections.Generic.List[object]]::new($StillUncached.Count)
            foreach ($FP in $StillUncached) {
                $PS = [System.Management.Automation.PowerShell]::Create()
                $PS.RunspacePool = $Pool
                [void]$PS.AddScript($ParseFileScriptStr).AddArgument($FP)
                $Jobs.Add([PSCustomObject]@{ PS = $PS; Handle = $PS.BeginInvoke() })
            }

            # EndInvoke blocks until each worker completes
            foreach ($Job in $Jobs) {
                $JobResults = $Job.PS.EndInvoke($Job.Handle)
                if ($JobResults -and $JobResults.Count -gt 0) {
                    $ParsedResult = $JobResults[0]
                    $ParsedInfo = [System.IO.FileInfo]::new($ParsedResult.FilePath)
                    $script:MarkdownCache[$ParsedResult.FilePath] = @{
                        ModTime = $ParsedInfo.LastWriteTimeUtc.Ticks
                        Result  = $ParsedResult
                    }
                    [void]$AllResults.Add($ParsedResult)
                }
                $Job.PS.Dispose()
            }

            $Pool.Close()
            $Pool.Dispose()
        } else {
            foreach ($FilePath in $StillUncached) {
                $Result = & $ParseFileScript $FilePath
                if ($Result) {
                    $ResultInfo = [System.IO.FileInfo]::new($Result.FilePath)
                    $script:MarkdownCache[$Result.FilePath] = @{
                        ModTime = $ResultInfo.LastWriteTimeUtc.Ticks
                        Result  = $Result
                    }
                    [void]$AllResults.Add($Result)
                }
            }
        }

        # ── WP-8: Disk cache write-back — persist newly parsed files ─────
        # After parsing, write ScanResult to disk for future cold starts.
        # Re-scan via MarkdownScanner to get index-based ScanResult for serialization.
        # Only runs when C# types are available and we have a valid cache directory.
        if ($HasDiskCache -and $DiskCacheDir) {
            try {
                $RepoRoot = Get-RepoRoot
                if (-not $DiskCacheIndex) { $DiskCacheIndex = @{} }

                foreach ($FP in $StillUncached) {
                    # Only write-back files that were successfully parsed and cached in memory
                    if (-not $script:MarkdownCache.ContainsKey($FP)) { continue }

                    try {
                        # Re-scan with MarkdownScanner to get the raw ScanResult with indices
                        $Lines = [System.IO.File]::ReadAllLines($FP)
                        $CsResult = [Robot.MarkdownScanner]::Parse($Lines)

                        # Derive a stable cache key from relative path (filesystem-safe)
                        $RelPath = $FP
                        if ($FP.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $RelPath = $FP.Substring($RepoRoot.Length).TrimStart('\', '/')
                        }
                        $DataKey = $RelPath.Replace('\', '_').Replace('/', '_').Replace('.', '_')

                        # Write ScanResult JSON to data directory
                        $DataPath = [System.IO.Path]::Combine($DiskCacheDataDir, "$DataKey.json")
                        [Robot.ParseCacheHelper]::WriteScanResultToFile($DataPath, $CsResult)

                        # Update index entry with current mod time
                        $FileInfo = [System.IO.FileInfo]::new($FP)
                        $DiskCacheIndex[$RelPath] = @{
                            ModTime = $FileInfo.LastWriteTimeUtc.Ticks
                            Key     = $DataKey
                        }
                        $DiskCacheIndexDirty = $true
                    } catch {
                        # Per-file write failure is non-fatal — skip and continue
                        continue
                    }
                }

                # Flush updated index and meta to disk
                if ($DiskCacheIndexDirty) {
                    $IndexPath = [System.IO.Path]::Combine($DiskCacheDir, '_index.json')
                    [Robot.ParseCacheHelper]::WriteMetaFile($IndexPath, $DiskCacheIndex)

                    $MetaPath = [System.IO.Path]::Combine($DiskCacheDir, '_meta.json')
                    $MetaData = @{
                        Version   = [Robot.ParseCacheHelper]::CacheVersion
                        Timestamp = [System.DateTime]::UtcNow.ToString('o')
                        FileCount = $DiskCacheIndex.Count
                    }
                    [Robot.ParseCacheHelper]::WriteMetaFile($MetaPath, $MetaData)
                }
            } catch {
                # Disk cache write failure is non-fatal — memory cache still valid
            }
        }
    }

    # Single-file callers expect a direct object, not a one-element list
    if ($FilesToProcess.Count -eq 1 -and $PSCmdlet.ParameterSetName -eq "File") {
        return $AllResults[0]
    } else {
        return $AllResults
    }
}

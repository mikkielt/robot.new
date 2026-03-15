<#
    .SYNOPSIS
    Orchestrates Markdown file parsing - delegates per-file work to parse-markdownfile.ps1,
    optionally in parallel via a RunspacePool.

    .DESCRIPTION
    Get-Markdown is the public entry point for Markdown parsing. It accepts file paths or a
    directory, then hands each file to the self-contained parse-markdownfile.ps1 script for
    the actual parsing work.

    Module-level data:
    - $CachedParseFileScriptStr: parser script text cached after first read to avoid
      repeated file I/O across calls

    Two-file architecture:
    - get-markdown.ps1 (this file): orchestration, parallelism, input validation
    - parse-markdownfile.ps1: single-file parsing logic (headers, sections, lists, links)

    The split exists because RunspacePool workers don't share the module scope. The parser
    script is loaded as a string and passed to each worker via AddScript, making it
    fully self-contained. When Robot.MarkdownScanner (lib/MarkdownScanner.cs) is available,
    the parser delegates line scanning to compiled C# for single-pass performance.

    Parallelism:
    When more than 4 files need parsing, a RunspacePool is created with up to ProcessorCount
    threads. Below that threshold, files are processed sequentially to avoid the ~50ms pool
    setup overhead. This matters for Get-Session which parses dozens of Markdown files in
    a single call.

    Return convention:
    - Single file via -File: returns the object directly (not wrapped in array)
    - Multiple files or -Directory: returns a List of objects
#>

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

    # Robot.MarkdownScanner compiled centrally in robot.psm1 — AppDomain-wide,
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

    if ($FilesToProcess.Count -gt $ParallelThreshold) {
        $MaxThreads = [Math]::Min($FilesToProcess.Count, [Environment]::ProcessorCount)
        $Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
        $Pool.Open()

        # Each worker receives parser script text + one file path
        $Jobs = [System.Collections.Generic.List[object]]::new($FilesToProcess.Count)
        foreach ($FP in $FilesToProcess) {
            $PS = [System.Management.Automation.PowerShell]::Create()
            $PS.RunspacePool = $Pool
            [void]$PS.AddScript($ParseFileScriptStr).AddArgument($FP)
            $Jobs.Add([PSCustomObject]@{ PS = $PS; Handle = $PS.BeginInvoke() })
        }

        # EndInvoke blocks until each worker completes
        foreach ($Job in $Jobs) {
            $JobResults = $Job.PS.EndInvoke($Job.Handle)
            if ($JobResults -and $JobResults.Count -gt 0) {
                [void]$AllResults.Add($JobResults[0])
            }
            $Job.PS.Dispose()
        }

        $Pool.Close()
        $Pool.Dispose()
    } else {
        foreach ($FilePath in $FilesToProcess) {
            $Result = & $ParseFileScript $FilePath
            if ($Result) { [void]$AllResults.Add($Result) }
        }
    }

    # Single-file callers expect a direct object, not a one-element list
    if ($FilesToProcess.Count -eq 1 -and $PSCmdlet.ParameterSetName -eq "File") {
        return $AllResults[0]
    } else {
        return $AllResults
    }
}

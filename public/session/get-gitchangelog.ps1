<#
    .SYNOPSIS
    Retrieves git commit history with detailed file change information by
    streaming and parsing git log output.

    .DESCRIPTION
    This file contains Get-GitChangeLog and its helper:

    Helpers:
    - ConvertFrom-CommitLine: parses a COMMIT header line
      (unit-separator-delimited) into a structured PSCustomObject with
      hash, date, author name, and email. Uses DateTimeOffset.Parse for
      ISO 8601 with timezone offset, with DateTime.Parse fallback.

    Get-GitChangeLog executes `git log` via .NET Process and stream-parses
    stdout line by line to build structured commit objects. Two modes:
    - Patch mode (default): full diff output with hunk-level patch content
      per file, supporting optional PatchFilter regex to reduce memory
    - NoPatch mode (-NoPatch): lightweight --name-status output (file paths
      + change types only) for callers that need file lists without diffs

    The streaming parser uses a state machine with three levels:
    commit -> file (diff header) -> patch content (after @@ hunk header).
    Each level is flushed when the next-level marker is encountered.

    Key implementation decisions:
    - ArgumentList (array-based) instead of Arguments (string-based) to
      correctly handle paths with spaces (e.g. "Postaci/Gracze/Zarei Chars.md")
    - Stderr is read asynchronously via Task<string> to prevent pipe buffer
      deadlocks (ScriptBlock event handlers crash with "no Runspace available"
      on thread pool threads)
    - Stdout is parsed as a stream (ReadLine loop) rather than ReadToEnd +
      Split to avoid allocating the entire git output as a single string
    - Only current branch commits are included (no --all flag)
    - ISO 8601 date format avoids locale-dependent parsing failures
    - core.quotepath=false ensures UTF-8 filenames come through unescaped
    - Git executable is resolved via PATH traversal to avoid UseShellExecute
#>

# Parse unit-separator-delimited COMMIT header into structured object.
# DateTimeOffset handles ISO 8601 timezone offsets; falls back to DateTime.Parse.
function ConvertFrom-CommitLine {
    param([System.Text.RegularExpressions.Match]$Match)

    $CommitDate = $null
    $DateString = $Match.Groups[2].Value
    try {
        $CommitDate = [System.DateTimeOffset]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture).DateTime
    } catch {
        try { $CommitDate = [datetime]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $CommitDate = $null }
    }

    return [PSCustomObject]@{
        CommitHash  = $Match.Groups[1].Value
        CommitDate  = $CommitDate
        AuthorName  = $Match.Groups[3].Value
        AuthorEmail = $Match.Groups[4].Value
        Files       = [System.Collections.Generic.List[object]]::new()
    }
}

function Get-GitChangeLog {
    <#
        .SYNOPSIS
        Retrieves git commit history with file-level change details via streaming git log parse.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Include commits after this date")]
        [string]$MinDate,

        [Parameter(HelpMessage = "Include commits before this date")]
        [string]$MaxDate,

        [Parameter(HelpMessage = "Limit to commits affecting this directory")]
        [string]$Directory,

        [Parameter(HelpMessage = "Limit to commits affecting these file path(s)")]
        [string[]]$File,

        [Parameter(HelpMessage = "Skip patch output entirely, use --name-status for speed")]
        [switch]$NoPatch,

        [Parameter(HelpMessage = "Regex filter: only patch lines matching this pattern are stored")]
        [string]$PatchFilter
    )

    $RepoRoot = Get-RepoRoot

    # Array-based arguments avoid quoting issues with paths containing spaces
    $GitArgs = [System.Collections.Generic.List[string]]::new()

    # Disable quotepath for proper UTF-8 filename handling (Polish characters)
    $GitArgs.Add("-c")
    $GitArgs.Add("core.quotepath=false")

    $GitArgs.Add("log")

    # Current branch only — --all would include stale results from unmerged branches
    $GitArgs.Add("--date=iso-strict")
    $GitArgs.Add("--pretty=format:COMMIT%x1F%H%x1F%ad%x1F%an%x1F%ae")
    if ($NoPatch) {
        $GitArgs.Add("--name-status")
    } else {
        $GitArgs.Add("-p")
    }
    $GitArgs.Add("--find-renames")

    $PatchFilterRegex = if ($PatchFilter) {
        [regex]::new($PatchFilter, [System.Text.RegularExpressions.RegexOptions]::Compiled)
    } else { $null }

    if ($MinDate) { $GitArgs.Add("--since=$MinDate") }
    if ($MaxDate) { $GitArgs.Add("--until=$MaxDate") }

    # Convert Directory/File parameters to git pathspecs (relative to repo root)
    $PathSpecs = [System.Collections.Generic.List[string]]::new()

    if ($Directory) {
        $FullDir = [System.IO.Path]::GetFullPath($Directory)

        if (-not $FullDir.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Directory is outside repository."
        }

        if ($FullDir.TrimEnd('/', '\') -ne $RepoRoot.TrimEnd('/', '\')) {
            $RelDir = $FullDir.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $PathSpecs.Add($RelDir + "/")
        }
    }

    if ($File) {
        foreach ($FilePath in $File) {
            $PathSpecs.Add($FilePath.Replace('\', '/'))
        }
    }

    if ($PathSpecs.Count -gt 0) {
        $GitArgs.Add("--")
        foreach ($PathSpec in $PathSpecs) {
            $GitArgs.Add($PathSpec)
        }
    }

    # Manual PATH resolution avoids UseShellExecute (which doesn't support redirection)
    $GitPath = $null
    foreach ($Dir in $env:PATH -split [System.IO.Path]::PathSeparator) {
        if (-not [string]::IsNullOrWhiteSpace($Dir)) {
            $Candidate = [System.IO.Path]::Combine($Dir, "git")
            if ([System.IO.File]::Exists($Candidate)) {
                $GitPath = $Candidate
                break
            }
        }
    }
    if (-not $GitPath) {
        throw "git executable not found in PATH."
    }

    # UTF-8 encoding on both streams; ArgumentList for space-safe argument passing
    $Psi = [System.Diagnostics.ProcessStartInfo]::new()
    $Psi.FileName = $GitPath
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError  = $true
    $Psi.UseShellExecute        = $false
    $Psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $Psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $Psi.WorkingDirectory       = $RepoRoot

    foreach ($Arg in $GitArgs) {
        $Psi.ArgumentList.Add($Arg)
    }

    $Process = [System.Diagnostics.Process]::new()
    $Process.StartInfo = $Psi

    try {
        [void]$Process.Start()

        # Async stderr prevents pipe buffer deadlock; Task<string> avoids
        # "no Runspace available" crash that ScriptBlock event handlers cause
        $StderrTask = $Process.StandardError.ReadToEndAsync()

        # Stream parse avoids materializing entire git output (can be tens of MB)
        $Reader = $Process.StandardOutput
    } catch {
        throw
    }

    try {

    $Results = [System.Collections.Generic.List[object]]::new()

    $CurrentCommit = $null
    $CurrentFile   = $null
    $InPatchContent = $false  # true after first @@ hunk header within a file diff

    # Precompiled patterns for the three-level state machine (commit/file/patch)
    $CommitRegex     = [regex]'^COMMIT\x1F(.+?)\x1F(.+?)\x1F(.+?)\x1F(.+)$'
    $DiffRegex       = [regex]'^diff --git a/(.+) b/(.+)$'
    $NewFileRegex    = [regex]'^new file mode '
    $DeleteRegex     = [regex]'^deleted file mode '
    $RenameFromRegex = [regex]'^rename from (.+)$'
    $RenameToRegex   = [regex]'^rename to (.+)$'
    $SimilarityRegex = [regex]'^similarity index (\d+)%$'
    $HunkRegex       = [regex]'^@@\s'
    $NameStatusRegex = [regex]'^([AMDRC])(\d*)\t(.+)$'

    # State machine: COMMIT lines flush previous commit, diff lines flush previous file
    while ($null -ne ($Line = $Reader.ReadLine())) {
        $TrimLine = $Line.TrimEnd()

        if ($NoPatch -and [string]::IsNullOrEmpty($TrimLine)) { continue }

        # Level 1: COMMIT header — flush previous commit and start new one
        $CommitMatch = $CommitRegex.Match($TrimLine)
        if ($CommitMatch.Success) {
            # Flush any pending file and commit before starting the new one
            if ($CurrentFile -and $CurrentCommit) {
                $CurrentCommit.Files.Add($CurrentFile)
                $CurrentFile = $null
            }
            if ($CurrentCommit) {
                $Results.Add($CurrentCommit)
            }

            $CurrentCommit = ConvertFrom-CommitLine -Match $CommitMatch
            $InPatchContent = $false
            continue
        }

        # NoPatch mode: lightweight --name-status parsing (change type + path)
        if ($NoPatch) {
            if (-not $CurrentCommit) { continue }
            $NsMatch = $NameStatusRegex.Match($TrimLine)
            if ($NsMatch.Success) {
                $ChangeCode = $NsMatch.Groups[1].Value
                $Score = $NsMatch.Groups[2].Value
                $PathPart = $NsMatch.Groups[3].Value

                $FileObj = [PSCustomObject]@{
                    Path        = $null
                    OldPath     = $null
                    ChangeType  = $ChangeCode
                    RenameScore = $null
                    Patch       = [System.Collections.Generic.List[string]]::new()
                }

                if ($ChangeCode -eq 'R' -or $ChangeCode -eq 'C') {
                    # Rename/Copy entries have two tab-separated paths: old -> new
                    $TabIdx = $PathPart.IndexOf("`t")
                    if ($TabIdx -ge 0) {
                        $FileObj.OldPath = $PathPart.Substring(0, $TabIdx)
                        $FileObj.Path = $PathPart.Substring($TabIdx + 1)
                    } else {
                        $FileObj.Path = $PathPart
                    }
                    if ($Score) { $FileObj.RenameScore = [int]$Score }
                } else {
                    $FileObj.Path = $PathPart
                    $FileObj.OldPath = $PathPart
                }

                $CurrentCommit.Files.Add($FileObj)
            }
            continue
        }

        # Level 2: diff header — flush previous file and start new one
        $DiffMatch = $DiffRegex.Match($TrimLine)
        if ($DiffMatch.Success) {
            if ($CurrentFile -and $CurrentCommit) {
                $CurrentCommit.Files.Add($CurrentFile)
            }

            $CurrentFile = [PSCustomObject]@{
                Path        = $DiffMatch.Groups[2].Value
                OldPath     = $DiffMatch.Groups[1].Value
                ChangeType  = "M"
                RenameScore = $null
                Patch       = [System.Collections.Generic.List[string]]::new()
            }

            $InPatchContent = $false
            continue
        }

        if (-not $CurrentFile) { continue }

        # Diff metadata lines update $CurrentFile properties but are not patch content
        if ($NewFileRegex.IsMatch($TrimLine)) {
            $CurrentFile.ChangeType = "A"
            continue
        }

        if ($DeleteRegex.IsMatch($TrimLine)) {
            $CurrentFile.ChangeType = "D"
            continue
        }

        $RenameFromMatch = $RenameFromRegex.Match($TrimLine)
        if ($RenameFromMatch.Success) {
            $CurrentFile.ChangeType = "R"
            $CurrentFile.OldPath = $RenameFromMatch.Groups[1].Value
            continue
        }

        $RenameToMatch = $RenameToRegex.Match($TrimLine)
        if ($RenameToMatch.Success) {
            $CurrentFile.Path = $RenameToMatch.Groups[1].Value
            continue
        }

        $SimilarityMatch = $SimilarityRegex.Match($TrimLine)
        if ($SimilarityMatch.Success) {
            $CurrentFile.RenameScore = [int]$SimilarityMatch.Groups[1].Value
            continue
        }

        # Level 3: patch content begins at first @@ hunk header; skip pre-hunk metadata
        if (-not $InPatchContent) {
            if ($HunkRegex.IsMatch($TrimLine)) {
                $InPatchContent = $true
                $CurrentFile.Patch.Add($Line)
            }
            continue
        }

        # Accumulate patch lines, keeping hunk headers for line number mapping
        if ($PatchFilterRegex) {
            # Hunk headers always kept — they provide line number context for filtered patches
            if ($HunkRegex.IsMatch($TrimLine) -or $PatchFilterRegex.IsMatch($TrimLine)) {
                $CurrentFile.Patch.Add($Line)
            }
        } else {
            $CurrentFile.Patch.Add($Line)
        }
    }

    # Flush final commit and file after stream ends
    if ($CurrentFile -and $CurrentCommit) {
        $CurrentCommit.Files.Add($CurrentFile)
    }

    if ($CurrentCommit) {
        $Results.Add($CurrentCommit)
    }

    $Process.WaitForExit()

    } finally {
    }

    if ($Process.ExitCode -ne 0) {
        $Stderr = $StderrTask.GetAwaiter().GetResult()
        throw "Git command failed (exit code $($Process.ExitCode)): $Stderr"
    }

    return $Results
}

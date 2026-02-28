<#
    .SYNOPSIS
    Retrieves git commit history with detailed file change information by streaming and
    parsing git log output.

    .DESCRIPTION
    This file contains Get-GitChangeLog and its helper:

    Helper:
    - ConvertFrom-CommitLine: parses a COMMIT header line (unit-separator-delimited) into
      a structured PSCustomObject with hash, date, author name, and email

    Get-GitChangeLog executes `git log` and stream-parses stdout line by line to build
    structured commit objects. It supports two modes:
    - Patch mode (default): full diff output with hunk-level patch content per file
    - NoPatch mode (-NoPatch): lightweight --name-status output (file paths + change types only)

    Key implementation decisions:
    - Process execution uses ArgumentList (array-based) instead of Arguments (string-based)
      to correctly handle paths containing spaces (e.g. "Postaci/Gracze/Zarei Chars.md")
    - Stderr is read asynchronously via .NET event handler to prevent pipe buffer deadlocks
    - Stdout is parsed as a stream (ReadLine loop) rather than ReadToEnd + Split to avoid
      allocating the entire git output (potentially tens of MB) as a single string
    - Only commits from the current branch are included (no --all flag)
    - ISO 8601 date format avoids locale-dependent parsing failures
#>

# Helper: parse a COMMIT header line into a structured object
# Input: regex match groups from "COMMIT<US>hash<US>date<US>name<US>email"
# Uses DateTimeOffset.Parse for ISO 8601 with timezone offset.
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
        Retrieves git commit history with detailed file change information.
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

    # Build git arguments as an array - each element is a separate argument,
    # which avoids quoting issues with paths containing spaces
    $GitArgs = [System.Collections.Generic.List[string]]::new()

    # Disable quotepath so UTF-8 filenames come through unescaped
    $GitArgs.Add("-c")
    $GitArgs.Add("core.quotepath=false")

    $GitArgs.Add("log")

    # Current branch only - no --all flag to avoid stale results from unmerged branches
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

    # Pathspec construction from Directory and/or File parameters
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

    # Process setup - UTF-8 encoding, array-based arguments, async stderr
    $Psi = [System.Diagnostics.ProcessStartInfo]::new()
    $Psi.FileName = "git"
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

        # Start async stderr read to prevent pipe buffer deadlock.
        # Uses .NET Task<string> instead of PowerShell ScriptBlock event handler
        # to avoid "no Runspace available" crash on thread pool threads.
        $StderrTask = $Process.StandardError.ReadToEndAsync()

        # Stream-parse stdout line by line to avoid materializing the entire output
        $Reader = $Process.StandardOutput
    } catch {
        throw
    }

    try {

    $Results = [System.Collections.Generic.List[object]]::new()

    $CurrentCommit = $null
    $CurrentFile   = $null
    $InPatchContent = $false  # tracks whether we're past the @@ hunk header

    # Precompiled regex patterns for the streaming parser
    $CommitRegex     = [regex]'^COMMIT\x1F(.+?)\x1F(.+?)\x1F(.+?)\x1F(.+)$'
    $DiffRegex       = [regex]'^diff --git a/(.+) b/(.+)$'
    $NewFileRegex    = [regex]'^new file mode '
    $DeleteRegex     = [regex]'^deleted file mode '
    $RenameFromRegex = [regex]'^rename from (.+)$'
    $RenameToRegex   = [regex]'^rename to (.+)$'
    $SimilarityRegex = [regex]'^similarity index (\d+)%$'
    $HunkRegex       = [regex]'^@@\s'
    $NameStatusRegex = [regex]'^([AMDRC])(\d*)\t(.+)$'

    # Streaming parse loop
    while ($null -ne ($Line = $Reader.ReadLine())) {
        $TrimLine = $Line.TrimEnd()

        if ($NoPatch -and [string]::IsNullOrEmpty($TrimLine)) { continue }

        # Commit header: "COMMIT<US>hash<US>date<US>name<US>email"
        $CommitMatch = $CommitRegex.Match($TrimLine)
        if ($CommitMatch.Success) {
            # Flush previous file and commit
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

        # NoPatch mode: parse --name-status lines (M/A/D/R + tab + path)
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
                    # Rename/Copy: old<TAB>new
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

        # Patch mode: diff header "diff --git a/path b/path"
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

        # Diff metadata lines - set properties on $CurrentFile but are NOT added to Patch
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

        # Pre-hunk metadata (index, ---, +++) is skipped until the first @@ header
        if (-not $InPatchContent) {
            if ($HunkRegex.IsMatch($TrimLine)) {
                $InPatchContent = $true
                $CurrentFile.Patch.Add($Line)
            }
            continue
        }

        # Patch content accumulation - apply filter if specified
        if ($PatchFilterRegex) {
            # Always keep hunk headers (needed for line number mapping)
            if ($HunkRegex.IsMatch($TrimLine) -or $PatchFilterRegex.IsMatch($TrimLine)) {
                $CurrentFile.Patch.Add($Line)
            }
        } else {
            $CurrentFile.Patch.Add($Line)
        }
    }

    # Flush remaining objects
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

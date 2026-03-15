<#
    .SYNOPSIS
    Validates session content integrity by comparing current file state against
    stored SHA256 hashes, detecting content tampering, format anomalies, and
    potential PU manipulation.

    .DESCRIPTION
    This file contains Test-SessionIntegrity which performs 9 validation checks:

    1. ModifiedSessions:     content hash mismatch between stored sidecar
                             and current file (possible edit or tampering)
    2. DeletedSessions:      header in hash store but absent from current
                             file (session removed without hash update)
    3. NewSessions:          header in file but not in hash store (new
                             session added since last hash baseline)
    4. MissingHashFiles:     .md files with no corresponding .json sidecar
                             (never baselined)
    5. MalformedHeaders:     level-3 headers that fail date parsing
    6. PUAffectedSessions:   modified sessions that contain PU data
                             (high severity — potential PU manipulation)
    7. DuplicatePUMarkers:   sessions with 2+ PU section markers within
                             the same section (strong tamper indicator)
    8. FormatAnomalies:      date-like lines without ### header prefix
                             (possible malformed session boundary)
    9. FutureDatedSessions:  session headers with dates after today

    Module-level data:
    - $script:DateLineLikePattern: precompiled regex matching lines starting
      with YYYY-MM-DD for format anomaly detection
    - $script:SessionDatePattern: canonical definition in temporal-helpers.ps1
    - $script:PUSectionPattern: canonical definition in session-parsehelpers.ps1

    Pipeline:
    1. Determine file scope: -File (explicit paths), -Full (all hashable
       files), or incremental (git changelog since last update)
    2. Batch-parse all files via Get-Markdown in a single call
    3. For each file, compare current per-header SHA256 hashes against
       stored .json sidecar (checks 1-3)
    4. Scan sections for malformed dates and format anomalies (checks 5, 8, 9)
    5. For modified sessions, scan content for PU markers (checks 6, 7)

    Incremental mode reads _meta.json for LastIncrementalUpdate timestamp,
    then uses Get-GitChangeLog -NoPatch to identify changed .md files.
    Falls back to full scan if git changelog fails.

    Code block tracking ($InCodeBlock) prevents false-positive format
    anomalies from date strings inside fenced code blocks.
#>

# $script:PUSectionPattern — canonical definition in private/session-parsehelpers.ps1
# (available via module scope; loaded by get-session.ps1 at import time)

# Anchored YYYY-MM-DD pattern for detecting date-like lines that lack ### prefix
$script:DateLineLikePattern = [regex]::new(
    '^\d{4}-\d{2}-\d{2}',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

function Test-SessionIntegrity {
    <#
        .SYNOPSIS
        Validates session content integrity via SHA256 hash comparison and structural checks.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Check all files, not just recently changed ones")]
        [switch]$Full,

        [Parameter(HelpMessage = "Limit validation to specific file path(s)")]
        [string[]]$File,

        [Parameter(HelpMessage = "Check only files changed since this date")]
        [string]$Since,

        [Parameter(HelpMessage = "Directories to exclude from scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Lazy-load helpers to avoid import overhead when called from modules that already loaded them
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

    # Each check category accumulates its own list for structured output
    $ModifiedSessions   = [System.Collections.Generic.List[object]]::new()
    $DeletedSessions    = [System.Collections.Generic.List[object]]::new()
    $NewSessions        = [System.Collections.Generic.List[object]]::new()
    $MissingHashFiles   = [System.Collections.Generic.List[string]]::new()
    $MalformedHeaders   = [System.Collections.Generic.List[object]]::new()
    $PUAffectedSessions = [System.Collections.Generic.List[object]]::new()
    $DuplicatePUMarkers = [System.Collections.Generic.List[object]]::new()
    $FormatAnomalies    = [System.Collections.Generic.List[object]]::new()
    $FutureDatedSessions = [System.Collections.Generic.List[object]]::new()

    # Midnight boundary avoids time-of-day sensitivity in future-date check
    $Today = [datetime]::Today

    # File scope resolution: explicit paths > full scan > incremental (git-based)
    $FilesToCheck = [System.Collections.Generic.List[string]]::new()

    if ($File) {
        foreach ($F in $File) {
            $FullPath = if ([System.IO.Path]::IsPathRooted($F)) { $F } else {
                [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepoRoot, $F))
            }
            if ([System.IO.File]::Exists($FullPath)) {
                [void]$FilesToCheck.Add($FullPath)
            }
        }
    } elseif ($Full) {
        $FilesToCheck = Get-HashableFiles -RepoRoot $RepoRoot -ExcludeDirectory $ExcludeDirectory
    } else {
        # Incremental mode: limit to files changed since last hash update
        $MinDateStr = $Since
        if (-not $MinDateStr) {
            $Meta = Read-SessionHashMeta -MetaPath $MetaPath
            $MinDateStr = $Meta['LastIncrementalUpdate']
        }

        $UseFullScan = $false
        if ($MinDateStr) {
            try {
                $GitLog = Get-GitChangeLog -NoPatch -MinDate $MinDateStr

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

                $AllHashable = [System.Collections.Generic.HashSet[string]]::new(
                    (Get-HashableFiles -RepoRoot $RepoRoot -ExcludeDirectory $ExcludeDirectory),
                    [System.StringComparer]::OrdinalIgnoreCase
                )
                foreach ($CF in $ChangedFiles) {
                    if ($AllHashable.Contains($CF)) {
                        [void]$FilesToCheck.Add($CF)
                    }
                }
            } catch {
                Write-RobotWarning "[WARN Test-SessionIntegrity] Git changelog failed: $_. Falling back to full scan."
                $UseFullScan = $true
            }
        } else {
            $UseFullScan = $true
        }

        if ($UseFullScan) {
            $FilesToCheck = Get-HashableFiles -RepoRoot $RepoRoot -ExcludeDirectory $ExcludeDirectory
        }
    }

    if ($FilesToCheck.Count -eq 0) {
        return [PSCustomObject]@{
            OK                   = $true
            ModifiedSessions     = @()
            DeletedSessions      = @()
            NewSessions          = @()
            MissingHashFiles     = @()
            MalformedHeaders     = @()
            PUAffectedSessions   = @()
            DuplicatePUMarkers   = @()
            FormatAnomalies      = @()
            FutureDatedSessions  = @()
        }
    }

    # Single Get-Markdown call enables RunspacePool parallelism for large file sets
    $MarkdownResults = @(Get-Markdown -File @($FilesToCheck))
    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($MdResult in $MarkdownResults) {
        if ($null -ne $MdResult) {
            $MarkdownByPath[$MdResult.FilePath] = $MdResult
        }
    }

    $script:ProgressFileIdx = 0
    $script:ProgressFileTotal = $FilesToCheck.Count

    foreach ($FilePath in $FilesToCheck) {
        $script:ProgressFileIdx++
        if ($ProgressCallback -and ($script:ProgressFileIdx % 5 -eq 0 -or $script:ProgressFileIdx -eq $script:ProgressFileTotal)) {
            & $ProgressCallback $script:ProgressFileIdx $script:ProgressFileTotal $null
        }

        $RelPath = Get-RelativeHashPath -FilePath $FilePath -RepoRoot $RepoRoot
        $JsonPath = [System.IO.Path]::Combine($HashDir, "$RelPath.json")

        $MdResult = if ($MarkdownByPath.ContainsKey($FilePath)) { $MarkdownByPath[$FilePath] } else { $null }

        # Check 4: Missing hash files
        if (-not [System.IO.File]::Exists($JsonPath)) {
            [void]$MissingHashFiles.Add($RelPath)

            # Even without a hash file, still check for malformed headers and format anomalies
            if ($null -ne $MdResult) {
                # Check 5: Malformed headers (no hash file — scan all)
                foreach ($Section in $MdResult.Sections) {
                    if ($null -eq $Section.Header) { continue }
                    if ($Section.Header.Level -ne 3) { continue }

                    $HeaderText = $Section.Header.Text
                    $DateMatch = $script:SessionDatePattern.Match($HeaderText)
                    if (-not $DateMatch.Success) {
                        $MalformedHeaders.Add([PSCustomObject]@{
                            FilePath     = $FilePath
                            RelativePath = $RelPath
                            Header       = '### ' + $HeaderText
                            Issue        = "Level-3 header does not contain a valid date"
                        })
                        continue
                    }

                    $DateStr = $DateMatch.Groups[1].Value
                    $ParsedDate = ConvertTo-SessionDate -DateString $DateStr
                    if ($null -eq $ParsedDate) {
                        $MalformedHeaders.Add([PSCustomObject]@{
                            FilePath     = $FilePath
                            RelativePath = $RelPath
                            Header       = '### ' + $HeaderText
                            Issue        = "Date '$DateStr' fails strict date validation"
                        })
                    } elseif ($ParsedDate -gt $Today) {
                        # Check 9: Future-dated session
                        $FutureDatedSessions.Add([PSCustomObject]@{
                            FilePath     = $FilePath
                            RelativePath = $RelPath
                            Header       = '### ' + $HeaderText
                            Date         = $DateStr
                            Issue        = "Session date '$DateStr' is in the future"
                        })
                    }
                }
            }

            # Check 8: Format anomalies (from parsed sections — no extra file read)
            if ($null -ne $MdResult) {
                $InCodeBlock = $false
                foreach ($Section in $MdResult.Sections) {
                    $ContentStartLine = if ($null -eq $Section.Header) { 1 } else { $Section.Header.LineNumber + 1 }
                    if ([string]::IsNullOrEmpty($Section.Content)) { continue }
                    $ContentLines = $Section.Content.Split([char]"`n")
                    for ($i = 0; $i -lt $ContentLines.Length; $i++) {
                        $RawLine = $ContentLines[$i]
                        if ($RawLine -match '^```') { $InCodeBlock = -not $InCodeBlock; continue }
                        if ($InCodeBlock) { continue }

                        if ($script:DateLineLikePattern.IsMatch($RawLine) -and -not $RawLine.StartsWith('### ')) {
                            if ($RawLine.Length -gt 0 -and ($RawLine[0] -eq ' ' -or $RawLine[0] -eq "`t" -or $RawLine[0] -eq '-' -or $RawLine[0] -eq '*')) {
                                continue
                            }
                            [void]$FormatAnomalies.Add([PSCustomObject]@{
                                FilePath     = $FilePath
                                RelativePath = $RelPath
                                LineNumber   = $ContentStartLine + $i
                                Line         = $RawLine
                                Issue        = "Date-like line without ### header prefix"
                            })
                        }
                    }
                }
            }

            continue
        }

        # Both markdown parse and hash sidecar available — compare hashes
        if ($null -eq $MdResult) { continue }

        # SHA256 per level-3 header for fine-grained change detection
        $CurrentHashes = Get-FileHeaderHashes -MarkdownResult $MdResult

        # Baseline hashes from the .json sidecar
        $StoredHashes = Read-SessionHashFile -JsonPath $JsonPath

        # Check 1 + 6 + 7: Modified sessions (current headers that exist in store with different hash)
        foreach ($Key in $CurrentHashes.Keys) {
            if ($StoredHashes.ContainsKey($Key)) {
                if (-not [string]::Equals($StoredHashes[$Key], $CurrentHashes[$Key], [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Content changed since baseline — flag for review
                    $IssueEntry = [PSCustomObject]@{
                        FilePath     = $FilePath
                        RelativePath = $RelPath
                        Header       = $Key
                        Issue        = "Content hash mismatch"
                        StoredHash   = $StoredHashes[$Key]
                        CurrentHash  = $CurrentHashes[$Key]
                        HasPU        = $false
                    }
                    [void]$ModifiedSessions.Add($IssueEntry)

                    # Locate section content to check for PU data in modified sessions
                    $SectionContent = $null
                    foreach ($Section in $MdResult.Sections) {
                        if ($null -eq $Section.Header) { continue }
                        $SectionHeaderLine = ('#' * $Section.Header.Level) + ' ' + $Section.Header.Text
                        if ([string]::Equals($SectionHeaderLine, $Key, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $SectionContent = $Section.Content
                            break
                        }
                    }

                    if ($null -ne $SectionContent) {
                        $ContentLines = $SectionContent.Split([char]"`n")
                        $PUMarkerCount = 0

                        foreach ($Line in $ContentLines) {
                            if ($script:PUSectionPattern.IsMatch($Line)) {
                                $PUMarkerCount++
                            }
                        }

                        # Check 6: PU-affected sessions
                        if ($PUMarkerCount -gt 0) {
                            $IssueEntry.HasPU = $true
                            $PUAffectedSessions.Add([PSCustomObject]@{
                                FilePath     = $FilePath
                                RelativePath = $RelPath
                                Header       = $Key
                                Issue        = "Modified session contains PU data"
                                StoredHash   = $StoredHashes[$Key]
                                CurrentHash  = $CurrentHashes[$Key]
                                HasPU        = $true
                            })
                        }

                        # Check 7: Duplicate PU markers (tamper indicator)
                        if ($PUMarkerCount -ge 2) {
                            $DuplicatePUMarkers.Add([PSCustomObject]@{
                                FilePath      = $FilePath
                                RelativePath  = $RelPath
                                Header        = $Key
                                Issue         = "Duplicate PU markers detected (count: $PUMarkerCount)"
                                PUMarkerCount = $PUMarkerCount
                                StoredHash    = $StoredHashes[$Key]
                                CurrentHash   = $CurrentHashes[$Key]
                            })
                        }
                    }
                }
            } else {
                # Check 3: New session (in file but not in hash store)
                $NewSessions.Add([PSCustomObject]@{
                    FilePath     = $FilePath
                    RelativePath = $RelPath
                    Header       = $Key
                    Issue        = "Header not found in hash store"
                    StoredHash   = $null
                    CurrentHash  = $CurrentHashes[$Key]
                    HasPU        = $false
                })
            }
        }

        # Check 2: Deleted sessions (in hash store but not in current file)
        foreach ($Key in $StoredHashes.Keys) {
            if (-not $CurrentHashes.ContainsKey($Key)) {
                $DeletedSessions.Add([PSCustomObject]@{
                    FilePath     = $FilePath
                    RelativePath = $RelPath
                    Header       = $Key
                    Issue        = "Header present in hash store but missing from file"
                    StoredHash   = $StoredHashes[$Key]
                    CurrentHash  = $null
                    HasPU        = $false
                })
            }
        }

        # Check 5: Malformed headers
        foreach ($Section in $MdResult.Sections) {
            if ($null -eq $Section.Header) { continue }
            if ($Section.Header.Level -ne 3) { continue }

            $HeaderText = $Section.Header.Text
            $DateMatch = $script:SessionDatePattern.Match($HeaderText)
            if (-not $DateMatch.Success) {
                $MalformedHeaders.Add([PSCustomObject]@{
                    FilePath     = $FilePath
                    RelativePath = $RelPath
                    Header       = '### ' + $HeaderText
                    Issue        = "Level-3 header does not contain a valid date"
                })
                continue
            }

            $DateStr = $DateMatch.Groups[1].Value
            $ParsedDate = ConvertTo-SessionDate -DateString $DateStr
            if ($null -eq $ParsedDate) {
                $MalformedHeaders.Add([PSCustomObject]@{
                    FilePath     = $FilePath
                    RelativePath = $RelPath
                    Header       = '### ' + $HeaderText
                    Issue        = "Date '$DateStr' fails strict date validation"
                })
            } elseif ($ParsedDate -gt $Today) {
                # Check 9: Future-dated session
                $FutureDatedSessions.Add([PSCustomObject]@{
                    FilePath     = $FilePath
                    RelativePath = $RelPath
                    Header       = '### ' + $HeaderText
                    Date         = $DateStr
                    Issue        = "Session date '$DateStr' is in the future"
                })
            }
        }

        # Check 8: Format anomalies — detect date-like lines outside code blocks
        # that lack proper ### prefix (possible broken session boundary)
        $InCodeBlock = $false
        foreach ($Section in $MdResult.Sections) {
            $ContentStartLine = if ($null -eq $Section.Header) { 1 } else { $Section.Header.LineNumber + 1 }
            if ([string]::IsNullOrEmpty($Section.Content)) { continue }
            $ContentLines = $Section.Content.Split([char]"`n")
            for ($i = 0; $i -lt $ContentLines.Length; $i++) {
                $RawLine = $ContentLines[$i]
                if ($RawLine -match '^```') { $InCodeBlock = -not $InCodeBlock; continue }
                if ($InCodeBlock) { continue }

                if ($script:DateLineLikePattern.IsMatch($RawLine) -and -not $RawLine.StartsWith('### ')) {
                    if ($RawLine.Length -gt 0 -and ($RawLine[0] -eq ' ' -or $RawLine[0] -eq "`t" -or $RawLine[0] -eq '-' -or $RawLine[0] -eq '*')) {
                        continue
                    }
                    [void]$FormatAnomalies.Add([PSCustomObject]@{
                        FilePath     = $FilePath
                        RelativePath = $RelPath
                        LineNumber   = $ContentStartLine + $i
                        Line         = $RawLine
                        Issue        = "Date-like line without ### header prefix"
                    })
                }
            }
        }
    }

    $AllOK = $ModifiedSessions.Count -eq 0 -and
             $DeletedSessions.Count -eq 0 -and
             $NewSessions.Count -eq 0 -and
             $MissingHashFiles.Count -eq 0 -and
             $MalformedHeaders.Count -eq 0 -and
             $PUAffectedSessions.Count -eq 0 -and
             $DuplicatePUMarkers.Count -eq 0 -and
             $FormatAnomalies.Count -eq 0 -and
             $FutureDatedSessions.Count -eq 0

    return [PSCustomObject]@{
        OK                   = $AllOK
        ModifiedSessions     = $ModifiedSessions.ToArray()
        DeletedSessions      = $DeletedSessions.ToArray()
        NewSessions          = $NewSessions.ToArray()
        MissingHashFiles     = $MissingHashFiles.ToArray()
        MalformedHeaders     = $MalformedHeaders.ToArray()
        PUAffectedSessions   = $PUAffectedSessions.ToArray()
        DuplicatePUMarkers   = $DuplicatePUMarkers.ToArray()
        FormatAnomalies      = $FormatAnomalies.ToArray()
        FutureDatedSessions  = $FutureDatedSessions.ToArray()
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

<#
    .SYNOPSIS
    Validates session content integrity by comparing current file state against
    stored SHA256 hashes, detecting content tampering, format anomalies, and
    potential PU manipulation.

    .DESCRIPTION
    This file contains Test-SessionIntegrity which performs 8 validation checks:

    1. Modified Sessions:      content changed since last hash (hash mismatch)
    2. Deleted Sessions:       header in hash store but not in current file
    3. New Sessions:           header in file but not in hash store
    4. Missing Hash Files:     .md files with no corresponding .json sidecar
    5. Malformed Headers:      ### headers that fail date parsing
    6. PU-Affected Sessions:   modified sessions containing PU data (high severity)
    7. Duplicate PU Markers:   sessions with 2+ PU section markers (tamper indicator)
    8. Format Anomalies:       date-like lines without proper ### header prefix
    9. Future-Dated Sessions:  ### session headers with dates after today

    Returns a structured diagnostic object following the same pattern as
    Test-PlayerCharacterPUAssignment: an OK boolean and categorized arrays.

    Supports full and incremental modes. Incremental mode uses Get-GitChangeLog
    to limit checks to recently changed files.

    Dot-sources:
    - private/session-hashhelpers.ps1 (hashing primitives)
    - private/admin-config.ps1 (ResDir resolution)
#>

# Precompiled PU section pattern (same as Test-PlayerCharacterPUAssignment)
$script:IntegrityPUSectionPattern = [regex]::new(
    '^\s*[-\*]\s+@?[Pp][Uu]\s*:',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Precompiled date-like line pattern for format anomaly detection
# Matches lines starting with YYYY-MM-DD but NOT preceded by ### prefix
$script:DateLineLikePattern = [regex]::new(
    '^\d{4}-\d{2}-\d{2}',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Date regex for header validation (same as Get-Session)
$script:IntegrityDateRegex = [regex]::new(
    '\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

function Test-SessionIntegrity {
    <#
        .SYNOPSIS
        Validates session content integrity by comparing current file state against stored hashes.
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

    # Result collections
    $ModifiedSessions   = [System.Collections.Generic.List[object]]::new()
    $DeletedSessions    = [System.Collections.Generic.List[object]]::new()
    $NewSessions        = [System.Collections.Generic.List[object]]::new()
    $MissingHashFiles   = [System.Collections.Generic.List[string]]::new()
    $MalformedHeaders   = [System.Collections.Generic.List[object]]::new()
    $PUAffectedSessions = [System.Collections.Generic.List[object]]::new()
    $DuplicatePUMarkers = [System.Collections.Generic.List[object]]::new()
    $FormatAnomalies    = [System.Collections.Generic.List[object]]::new()
    $FutureDatedSessions = [System.Collections.Generic.List[object]]::new()

    # Today's date at midnight for future-date comparison
    $Today = [datetime]::Today

    # Determine which files to check
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
        # Incremental: use git changelog
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

    # Batch-parse all files
    $MarkdownResults = @(Get-Markdown -File @($FilesToCheck))
    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($MdResult in $MarkdownResults) {
        if ($null -ne $MdResult) {
            $MarkdownByPath[$MdResult.FilePath] = $MdResult
        }
    }

    foreach ($FilePath in $FilesToCheck) {
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
                    $DateMatch = $script:IntegrityDateRegex.Match($HeaderText)
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
                    [datetime]$ParsedDate = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($DateStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$ParsedDate)) {
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

            # Check 8: Format anomalies
            if ([System.IO.File]::Exists($FilePath)) {
                $RawLines = [System.IO.File]::ReadAllLines($FilePath)
                $InCodeBlock = $false
                for ($i = 0; $i -lt $RawLines.Length; $i++) {
                    $RawLine = $RawLines[$i]
                    if ($RawLine -match '^```') { $InCodeBlock = -not $InCodeBlock; continue }
                    if ($InCodeBlock) { continue }

                    if ($script:DateLineLikePattern.IsMatch($RawLine) -and -not $RawLine.StartsWith('### ')) {
                        # Exclude lines inside list items (indented) — those are likely @Data or other tags
                        if ($RawLine.Length -gt 0 -and ($RawLine[0] -eq ' ' -or $RawLine[0] -eq "`t" -or $RawLine[0] -eq '-' -or $RawLine[0] -eq '*')) {
                            continue
                        }
                        $FormatAnomalies.Add([PSCustomObject]@{
                            FilePath     = $FilePath
                            RelativePath = $RelPath
                            LineNumber   = $i + 1
                            Line         = $RawLine
                            Issue        = "Date-like line without ### header prefix"
                        })
                    }
                }
            }

            continue
        }

        # We have both a markdown result and a hash file
        if ($null -eq $MdResult) { continue }

        # Compute current hashes
        $CurrentHashes = Get-FileHeaderHashes -MarkdownResult $MdResult

        # Load stored hashes
        $StoredHashes = Read-SessionHashFile -JsonPath $JsonPath

        # Check 1, 2, 3: Compare stored vs current

        # Check 1 + 6 + 7: Modified sessions
        foreach ($Key in $CurrentHashes.Keys) {
            if ($StoredHashes.ContainsKey($Key)) {
                if (-not [string]::Equals($StoredHashes[$Key], $CurrentHashes[$Key], [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Hash mismatch — modified session
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

                    # Find the corresponding section content for PU checks
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
                            if ($script:IntegrityPUSectionPattern.IsMatch($Line)) {
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
            $DateMatch = $script:IntegrityDateRegex.Match($HeaderText)
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
            [datetime]$ParsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($DateStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$ParsedDate)) {
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

        # Check 8: Format anomalies (raw line scan)
        $RawLines = [System.IO.File]::ReadAllLines($FilePath)
        $InCodeBlock = $false
        for ($i = 0; $i -lt $RawLines.Length; $i++) {
            $RawLine = $RawLines[$i]
            if ($RawLine -match '^```') { $InCodeBlock = -not $InCodeBlock; continue }
            if ($InCodeBlock) { continue }

            if ($script:DateLineLikePattern.IsMatch($RawLine) -and -not $RawLine.StartsWith('### ')) {
                # Exclude lines inside list items (indented) — those are likely @Data or other tags
                if ($RawLine.Length -gt 0 -and ($RawLine[0] -eq ' ' -or $RawLine[0] -eq "`t" -or $RawLine[0] -eq '-' -or $RawLine[0] -eq '*')) {
                    continue
                }
                $FormatAnomalies.Add([PSCustomObject]@{
                    FilePath     = $FilePath
                    RelativePath = $RelPath
                    LineNumber   = $i + 1
                    Line         = $RawLine
                    Issue        = "Date-like line without ### header prefix"
                })
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

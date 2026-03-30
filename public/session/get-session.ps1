<#
    .SYNOPSIS
    Parses session metadata from Markdown files into structured objects with
    format detection, narrator resolution, and cross-file deduplication.

    .DESCRIPTION
    This file contains Get-Session and its core helpers. It dot-sources
    session-parsehelpers.ps1 for format-specific content parsing,
    session-intelhelpers.ps1 for notification routing and mention extraction,
    and repo-filehelpers.ps1 for shared file enumeration with exclusion filtering.

    Helpers:
    - ConvertFrom-SessionHeader: parses a yyyy-MM-dd date (with optional
      /DD range suffix) from a session header string. Returns a hashtable
      with Date, DateEnd, DateStr, EndDayStr or $null.
    - Get-SessionFormat: classifies a section as Gen1/Gen2/Gen3/Gen4
      based on content heuristics (italic location prefix, @-prefixed
      list items, PU-like list items). Detection order: Gen2 > Gen4 >
      Gen3 > Gen1 (fallback).
    - Merge-SessionGroup: deduplicates sessions sharing the same header
      across files, selecting the metadata-richest primary via scoring
      and merging array fields (locations, logs, PU, changes, transfers,
      mentions, Intel, DeclaredFiles) via HashSet/Dictionary union.
      Reports scalar field conflicts (Title, Format) as warnings.

    Module-level data:
    - $script:SessionFileCache: per-file session cache (WP-4) storing
      structural extraction results keyed by FilePath -> {ModTime, Sessions, Failed}.
      Cache stores pre-narrator/pre-Intel data; entity-dependent
      post-processing runs on every call including cache hits.

    Get-Session scans Markdown files for level-3 headers containing a
    yyyy-MM-dd date and extracts structured session objects. It supports
    four format generations:
    - Gen1 (START-2022): plain text, no structured metadata
    - Gen2 (2022-2023): italic location lines (*Lokalizacja: ...*)
    - Gen3 (2024-2026): list-based metadata (- Lokalizacje:, - Logi:,
      - PU:, - Zmiany:). Efekty/Objaśnienia present in source but not
      extracted to session fields.
    - Gen4 (2026+): @-prefixed tags (- @Lokacje:, - @PU:, - @Logi:,
      - @Zmiany:). Backwards compatible with Gen3.

    Pipeline (WP-4 + WP-6 architecture):
    1. Collect input files (explicit file, directory scan, or repo root)
    2. Pre-fetch shared dependencies: entities, players, name index
    3. Pre-build entity indices for O(1) Intel resolution (EntityByGroup,
       EntityByLocation) to avoid O(E) scans per Intel directive
    4. Batch-parse all files via Get-Markdown (WP-2 cache handles this)
    5. Per file: check $script:SessionFileCache
       a. Cache HIT: use cached structural sessions
       b. Cache MISS: C# extraction (Robot.SessionExtractor, WP-6) or
          PowerShell fallback -> store in cache
    6. Post-processing (runs on both cache hits and misses):
       a. Batch Resolve-Narrator for header-based narrator resolution
       b. @Narrator override resolution (name index dependent)
       c. Location Strategy 1 (entity resolution for Gen3/Gen4)
       d. Entity mention extraction (opt-in via -IncludeMentions)
       e. Intel target resolution (Resolve-IntelTargets)
    7. Date filtering (AFTER cache lookup to support wider ranges)
    8. Cross-file deduplication groups by exact header text (Ordinal)

    The C# extractor (Robot.SessionExtractor) handles structural extraction
    only: header parsing, format detection, tag dispatch, and tag-based
    location extraction (Strategy 2). Entity-dependent operations stay in
    PowerShell. When the C# type is unavailable, the full PS extraction
    loop runs as fallback.
#>

. "$script:ModuleRoot/private/temporal-helpers.ps1"
. "$script:ModuleRoot/private/session-parsehelpers.ps1"
. "$script:ModuleRoot/private/session-intelhelpers.ps1"
. "$script:ModuleRoot/private/repo-filehelpers.ps1"

# C# types: Robot.NarratorResult, Robot.Narrator (lib/NarratorResult.cs),
# Robot.SessionExtractor (lib/SessionExtractor.cs)
# Compiled centrally in Robot.PowerShell.psm1 at module import time.

# Extracts yyyy-MM-dd date (with optional /DD range suffix) from a session
# header. Accepts pre-matched regex and pre-parsed date to avoid redundant work
# when the caller has already performed these steps during pre-filtering.
function ConvertFrom-SessionHeader {
    param(
        [string]$Header,
        [regex]$DateRegex,
        [object]$Match,        # optional pre-matched regex result to avoid redundant matching
        [datetime]$ParsedDate  # optional pre-parsed date to avoid redundant TryParseExact
    )

    if (-not $Match) { $Match = $DateRegex.Match($Header) }
    if (-not $Match.Success) { return $null }

    $DateStr    = $Match.Groups[1].Value
    $EndDayStr  = $Match.Groups[2].Value

    if ($PSBoundParameters.ContainsKey('ParsedDate')) {
        $Parsed = $ParsedDate
    } else {
        $Parsed = ConvertTo-SessionDate -DateString $DateStr
        if ($null -eq $Parsed) {
            return $null
        }
    }

    $DateEnd = $null
    if ($EndDayStr) {
        $EndStr = $DateStr.Substring(0, 8) + $EndDayStr
        $EndParsed = ConvertTo-SessionDate -DateString $EndStr
        if ($EndParsed) {
            $DateEnd = $EndParsed
        }
    }

    return @{
        Date      = $Parsed
        DateEnd   = $DateEnd
        DateStr   = $DateStr
        EndDayStr = $EndDayStr
    }
}

# Format detection: Gen2 (italic location prefix) > Gen4 (@ prefix on
# top-level list items) > Gen3 (PU-like top-level items) > Gen1 (fallback).
function Get-SessionFormat {
    param(
        [string]$FirstNonEmptyLine,
        [object]$SectionLists
    )

    if ($FirstNonEmptyLine -and $FirstNonEmptyLine.StartsWith('*Lokalizacj')) {
        return "Gen2"
    }
    foreach ($LI in $SectionLists) {
        if ($LI.Indent -ne 0) { continue }
        $LowerText = $LI.Text.ToLowerInvariant()
        if ($LowerText.Length -gt 1 -and $LowerText[0] -eq '@' -and [char]::IsLetter($LowerText[1])) {
            return "Gen4"
        }
        if ($LowerText.Length -gt 2 -and $LowerText.StartsWith('pu') -and ($LowerText[2] -eq ':' -or $LowerText[2] -eq ' ')) {
            return "Gen3"
        }
    }
    return "Gen1"
}

# Deduplicates sessions sharing the same header across files. Selects the
# metadata-richest primary via scoring and merges array fields via HashSet union.
function Merge-SessionGroup {
    param(
        [System.Collections.Generic.List[object]]$Group,
        [bool]$IncludeContent
    )

    $Count = $Group.Count

    if ($Count -eq 1) {
        $S = $Group[0]
        $S.FilePaths      = @($S.FilePath)
        $S.IsMerged       = $false
        $S.DuplicateCount = 1
        $S | Add-Member -NotePropertyName 'CopyFormats' -NotePropertyValue $null -Force
        return $S
    }

    # Score: each non-null metadata field adds 1; Content adds 2 (it implies richer source)
    $Primary      = $Group[0]
    $PrimaryScore = 0
    foreach ($S in $Group) {
        $Score = 0
        if ($S.Date)       { $Score++ }
        if ($S.Title)      { $Score++ }
        if ($S.Narrator -and $S.Narrator.Narrators.Count -gt 0) { $Score++ }
        if ($S.Locations -and $S.Locations.Count -gt 0) { $Score++ }
        if ($S.Logs -and $S.Logs.Count -gt 0)           { $Score++ }
        if ($S.PU -and $S.PU.Count -gt 0)                { $Score++ }
        if ($S.Content) { $Score += 2 }
        if ($Score -gt $PrimaryScore) {
            $Primary      = $S
            $PrimaryScore = $Score
        }
    }

    # Collect provenance metadata for dedup conflict analysis
    $AllFilePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $CopyFormatsList = [System.Collections.Generic.List[PSCustomObject]]::new($Count)
    foreach ($S in $Group) {
        [void]$AllFilePaths.Add($S.FilePath)
        [void]$CopyFormatsList.Add([PSCustomObject]@{ FilePath = $S.FilePath; Format = $S.Format })
    }

    # Warn when copies disagree on scalar fields (Title, Format)
    if ($null -ne $Primary.Date) {
        $ScalarFields = @('Title', 'Format')
        foreach ($FieldName in $ScalarFields) {
            $DistinctValues = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($S in $Group) {
                $Val = $S.$FieldName
                if ($null -ne $Val) { [void]$DistinctValues.Add($Val.ToString()) }
            }
            if ($DistinctValues.Count -gt 1) {
                $ValList = $DistinctValues -join ' vs '
                Write-RobotWarning "[WARN Get-Session] Dedup conflict on '$FieldName' for header '$($Primary.Header)': $ValList"
            }
        }
    }

    # Union array fields across all copies via HashSet/Dictionary dedup
    $MergedLocations    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedLogs         = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedPU           = [System.Collections.Generic.List[object]]::new()
    $PUSet              = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedChanges      = [System.Collections.Generic.List[object]]::new()
    $MergedTransfers    = [System.Collections.Generic.List[object]]::new()
    $MergedMentions     = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedIntel        = [System.Collections.Generic.List[object]]::new()
    $IntelSet           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $MergedDeclaredFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($S in $Group) {
        if ($S.Locations) {
            foreach ($L in $S.Locations) { [void]$MergedLocations.Add($L) }
        }
        if ($S.Logs) {
            foreach ($L in $S.Logs) { [void]$MergedLogs.Add($L) }
        }
        if ($S.PU) {
            foreach ($P in $S.PU) {
                $PUKey = "$($P.Character)|$($P.Value)"
                if ($PUSet.Add($PUKey)) { $MergedPU.Add($P) }
            }
        }
        if ($S.Changes) {
            foreach ($C in $S.Changes) { $MergedChanges.Add($C) }
        }
        if ($S.Transfers) {
            foreach ($T in $S.Transfers) { $MergedTransfers.Add($T) }
        }
        if ($S.Mentions) {
            foreach ($M in $S.Mentions) {
                if (-not $MergedMentions.ContainsKey($M.Name)) {
                    $MergedMentions[$M.Name] = $M
                }
            }
        }
        if ($S.Intel) {
            foreach ($I in $S.Intel) {
                $IntelKey = "$($I.RawTarget)|$($I.Message)"
                if ($IntelSet.Add($IntelKey)) {
                    $MergedIntel.Add($I)
                }
            }
        }
        if ($S.DeclaredFiles) {
            foreach ($DF in $S.DeclaredFiles) { [void]$MergedDeclaredFiles.Add($DF) }
        }
    }

    $MergedContent = $null
    if ($IncludeContent) {
        $LongestLen = -1
        foreach ($S in $Group) {
            if ($S.Content -and $S.Content.Length -gt $LongestLen) {
                $LongestLen    = $S.Content.Length
                $MergedContent = $S.Content
            }
        }
    }

    $Merged = [PSCustomObject]@{
        FilePath       = $Primary.FilePath
        FilePaths      = [string[]]$AllFilePaths
        Header         = $Primary.Header
        Date           = $Primary.Date
        DateEnd        = $Primary.DateEnd
        Title          = $Primary.Title
        Narrator       = $Primary.Narrator
        Locations      = [string[]]$MergedLocations
        Logs           = [string[]]$MergedLogs
        PU             = $MergedPU.ToArray()
        Format         = $Primary.Format
        IsMerged       = $true
        DuplicateCount = $Count
        Content        = $MergedContent
        Changes        = $MergedChanges.ToArray()
        Transfers      = $MergedTransfers.ToArray()
        Mentions       = [object[]]$MergedMentions.Values
        Intel          = $MergedIntel.ToArray()
        DeclaredFiles  = [string[]]$MergedDeclaredFiles
        CopyFormats    = $CopyFormatsList.ToArray()
    }

    return $Merged
}

function Get-Session {
    <#
        .SYNOPSIS
        Parses session metadata from Markdown files with format detection, narrator resolution, and deduplication.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate = [datetime]::Parse("2000-01-01"),

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate = [datetime]::Now,

        [Parameter(HelpMessage = "Path to a specific Markdown file to parse")]
        [string]$File,

        [Parameter(HelpMessage = "Path to a directory to scan for Markdown files")]
        [string]$Directory,

        [Parameter(HelpMessage = "Include full session content text in output")]
        [switch]$IncludeContent,

        [Parameter(HelpMessage = "Include entity mentions extracted from session body text")]
        [switch]$IncludeMentions,

        [Parameter(HelpMessage = "Include sessions that failed header parsing (no valid date)")]
        [switch]$IncludeFailed,

        [Parameter(HelpMessage = "Directories to exclude from recursive file scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched player list from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Fetch and parse log content, attaching LogData to each session")]
        [switch]$IncludeLogs,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Pre-built name index from Get-NameIndex (avoids redundant BK-tree rebuild)")]
        [hashtable]$NameIndex,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $RepoRoot = Get-RepoRoot

    # Resolve file scope: explicit -File, explicit -Directory, or full repo

    if (-not $File -and -not $Directory) {
        $Directory = $RepoRoot
    }

    $FilesToProcess = [System.Collections.Generic.List[string]]::new()

    if ($File) {
        if ([System.IO.File]::Exists($File)) {
            $FilesToProcess.Add($File)
        }
    } else {
        $SearchDir = if ($Directory) { $Directory } else { $RepoRoot }
        $RepoFiles = [string[]]@(Get-RepoFiles -RepoRoot $SearchDir -Pattern '*.md' -ExcludeDirectory $ExcludeDirectory)
        if ($RepoFiles.Count -gt 0) {
            $FilesToProcess.AddRange($RepoFiles)
        }
    }

    # Shared dependencies: entities, players, name index (built once, reused across all files)

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-Entity
    }
    if (-not $PSBoundParameters.ContainsKey('Players')) {
        $Players  = Get-Player -Entities $Entities
    }
    $NameIndexResult = if ($PSBoundParameters.ContainsKey('NameIndex') -and $NameIndex) {
        $NameIndex
    } else {
        Get-NameIndex -Players $Players -Entities $Entities
    }
    $Index     = $NameIndexResult.Index
    $StemIndex = $NameIndexResult.StemIndex
    $BKTree    = $NameIndexResult.BKTree

    $MentionCache  = @{}
    $IntelCache    = @{}
    $NarratorCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # O(1) entity indices for Intel resolution — avoids O(E) linear scans per directive
    $EntityByGroup = @{}
    $EntityByLocation = @{}
    foreach ($Entity in $Entities) {
        if ($Entity.GroupHistory -and $Entity.GroupHistory.Count -gt 0) {
            foreach ($GH in $Entity.GroupHistory) {
                if (-not $EntityByGroup.ContainsKey($GH.Value)) {
                    $EntityByGroup[$GH.Value] = [System.Collections.Generic.List[object]]::new()
                }
                $EntityByGroup[$GH.Value].Add(@{ Entity = $Entity; History = $GH })
            }
        }
        if ($Entity.LocationHistory -and $Entity.LocationHistory.Count -gt 0) {
            foreach ($LH in $Entity.LocationHistory) {
                if (-not $EntityByLocation.ContainsKey($LH.Value)) {
                    $EntityByLocation[$LH.Value] = [System.Collections.Generic.List[object]]::new()
                }
                $EntityByLocation[$LH.Value].Add(@{ Entity = $Entity; History = $LH })
            }
        }
    }

    # Local regex patterns shared across all sections in the processing loop

    $DateRegex      = $script:SessionDatePattern
    $LocItalicRegex = [regex]::new('\*Lokalizacj[ae]?:\s*(.+?)\*')
    $PURegex        = [regex]::new('^(.+?):\s*([\d,\.]+)')
    $UrlRegex       = [regex]::new('(https?://\S+)')
    $LogiLineRegex  = [regex]::new('^Logi:\s*(https?://\S+)')

    # Separate lists for valid and failed sessions (failed only populated when -IncludeFailed)

    $AllSessions    = [System.Collections.Generic.List[object]]::new()
    $FailedSessions = [System.Collections.Generic.List[object]]::new()

    # Single Get-Markdown call enables RunspacePool parallelism for large directory scans

    $AllMarkdownResults = @(Get-Markdown -File ($FilesToProcess.ToArray()))
    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($MarkdownResult in $AllMarkdownResults) { $MarkdownByPath[$MarkdownResult.FilePath] = $MarkdownResult }

    # WP-4: Lazy-initialize per-file session cache. Caching structural data
    # (header, date, format, tag-extracted metadata) avoids re-parsing unchanged
    # files on repeated Get-Session calls within the same module session.
    if (-not $script:SessionFileCache) {
        $script:SessionFileCache = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }

    # WP-6: Prefer C# SessionExtractor when available — compiled extraction is
    # ~3x faster than the PowerShell per-section loop for large session files
    $UseCsExtractor = ([System.Management.Automation.PSTypeName]'Robot.SessionExtractor').Type -ne $null

    # Cache key includes content/failed flags because sessions cached without
    # content must be re-extracted when -IncludeContent is requested, and vice versa
    $CacheFlags = "c$([int]$IncludeContent.IsPresent)f$([int]$IncludeFailed.IsPresent)"

    # Per-file processing: pre-filter sections, resolve narrators, extract metadata

    $script:ProgressFileIdx = 0
    $script:ProgressFileTotal = $FilesToProcess.Count

    foreach ($FilePath in $FilesToProcess) {
        $script:ProgressFileIdx++
        if ($ProgressCallback -and ($script:ProgressFileIdx % 5 -eq 0 -or $script:ProgressFileIdx -eq $script:ProgressFileTotal)) {
            & $ProgressCallback $script:ProgressFileIdx $script:ProgressFileTotal $null
        }

        $Markdown = if ($MarkdownByPath.ContainsKey($FilePath)) { $MarkdownByPath[$FilePath] } else { $null }
        if ($null -eq $Markdown) { continue }

        $SessionSections = $Markdown.Sections.Where({ $_.Header -and $_.Header.Level -eq 3 })
        if ($SessionSections.Count -eq 0) { continue }

        # WP-4: Check per-file cache before extraction. Date filtering runs AFTER
        # cache lookup so a cached file can serve both narrow and wide date ranges
        # without re-extraction. Cache key uses file mod-time + flag suffix.
        $FileInfo = [System.IO.FileInfo]::new($FilePath)
        $FileModKey = "$($FileInfo.LastWriteTimeUtc.Ticks):$CacheFlags"
        $CachedFileData = $null
        $CacheHit = $false

        if ($script:SessionFileCache.ContainsKey($FilePath)) {
            $CachedEntry = $script:SessionFileCache[$FilePath]
            if ($CachedEntry.ModTime -eq $FileModKey) {
                $CachedFileData = $CachedEntry
                $CacheHit = $true
            }
        }

        if ($CacheHit) {
            # Cache hit: reuse structural sessions. Entity-dependent post-processing
            # (narrator, Intel targets, Location Strategy 1, mentions) still re-runs
            # because the entity index may have changed since the cache was populated.
            $FileStructuralSessions = $CachedFileData.Sessions
            $FileFailedSessions     = $CachedFileData.Failed
        } else {
            # Cache miss: run structural extraction (C# fast path or PS fallback)
            $FileStructuralSessions = [System.Collections.Generic.List[object]]::new()
            $FileFailedSessions     = [System.Collections.Generic.List[object]]::new()

            # WP-6: C# fast path — Robot.SessionExtractor handles header parsing,
            # format detection, and tag dispatch in compiled code
            if ($UseCsExtractor) {
                for ($SectI = 0; $SectI -lt $SessionSections.Count; $SectI++) {
                    $Section = $SessionSections[$SectI]
                    $Header  = $Section.Header.Text

                    # Flatten list items into parallel arrays for C# interop (avoids marshalling PSCustomObjects)
                    $ItemCount = @($Section.Lists).Count
                    $Texts = [string[]]::new($ItemCount)
                    $ParentIndices = [int[]]::new($ItemCount)
                    for ($Idx = 0; $Idx -lt $ItemCount; $Idx++) {
                        $LI = @($Section.Lists)[$Idx]
                        $Texts[$Idx] = $LI.Text
                        $ParentIndices[$Idx] = $LI.ParentIndex
                    }

                    $CsSess = [Robot.SessionExtractor]::ExtractSection(
                        $Header,
                        $Section.Content,
                        $Texts,
                        $ParentIndices,
                        $DateRegex,
                        $PURegex,
                        $UrlRegex,
                        $IncludeContent.IsPresent
                    )

                    if ($null -eq $CsSess) {
                        # No valid date — record as failed
                        if ($IncludeFailed) {
                            $FileFailedSessions.Add(@{
                                Header       = $Header
                                Content      = if ($IncludeContent) { $Section.Content } else { $null }
                                SectionIndex = $SectI
                            })
                        }
                        continue
                    }

                    $FileStructuralSessions.Add(@{
                        Header           = $CsSess.Header
                        Date             = $CsSess.Date
                        DateEnd          = $CsSess.DateEnd
                        DateStr          = $CsSess.DateStr
                        EndDayStr        = $CsSess.EndDayStr
                        Title            = $CsSess.Title
                        Format           = $CsSess.Format
                        Locations        = $CsSess.Locations
                        Logs             = if ($CsSess.Logs) { @($CsSess.Logs) } else { @() }
                        PU               = if ($CsSess.PU) { @($CsSess.PU) } else { @() }
                        Changes          = if ($CsSess.Changes) { @($CsSess.Changes) } else { @() }
                        Transfers        = if ($CsSess.Transfers) { @($CsSess.Transfers) } else { @() }
                        RawIntel         = if ($CsSess.RawIntel) { $CsSess.RawIntel } else { [System.Collections.Generic.List[object]]::new() }
                        NarratorRawText  = $CsSess.NarratorRawText
                        MetaNarrators    = if ($CsSess.MetaNarrators) { @($CsSess.MetaNarrators) } else { @() }
                        Files            = if ($CsSess.Files) { @($CsSess.Files) } else { @() }
                        Content          = $CsSess.Content
                        FirstNonEmptyLine = $CsSess.FirstNonEmptyLine
                        SectionIndex     = $SectI
                    })
                }
            } else {
                # PowerShell fallback: full per-section extraction loop
                for ($SectI = 0; $SectI -lt $SessionSections.Count; $SectI++) {
                    $Section = $SessionSections[$SectI]
                    $Header  = $Section.Header.Text

                    $DMatch = $DateRegex.Match($Header)
                    $DateInfo = $null
                    if ($DMatch.Success) {
                        $DStr = $DMatch.Groups[1].Value
                        $DParsed = ConvertTo-SessionDate -DateString $DStr
                        if ($DParsed) {
                            $DateInfo = @{
                                Date      = $DParsed
                                DateEnd   = $null
                                DateStr   = $DStr
                                EndDayStr = $DMatch.Groups[2].Value
                            }
                            if ($DateInfo.EndDayStr) {
                                $EndStr = $DStr.Substring(0, 8) + $DateInfo.EndDayStr
                                $EndParsed = ConvertTo-SessionDate -DateString $EndStr
                                if ($EndParsed) { $DateInfo.DateEnd = $EndParsed }
                            }
                        }
                    }

                    # @Data override rescues sessions with malformed header dates
                    $DateOverrideStr = $null
                    if ($Section.Lists) {
                        foreach ($LI in $Section.Lists) {
                            if ($LI.Indent -ne 0) { continue }
                            $DOTestText = if ($LI.Text.StartsWith('@')) { $LI.Text.Substring(1) } else { $LI.Text }
                            $DOLower = $DOTestText.ToLowerInvariant()
                            if ($DOLower.StartsWith('data') -and $DOLower.Length -gt 4 -and ($DOLower[4] -eq ':' -or $DOLower[4] -eq ' ')) {
                                $DOColonIdx = $DOTestText.IndexOf(':')
                                if ($DOColonIdx -ge 0) {
                                    $DOInline = $DOTestText.Substring($DOColonIdx + 1).Trim()
                                    if ($DOInline.Length -gt 0) {
                                        $DateOverrideStr = $DOInline
                                    } else {
                                        foreach ($DOChild in $Section.Lists) {
                                            if ($DOChild.ParentIndex -eq $LI.LocalIndex) {
                                                $DateOverrideStr = $DOChild.Text.Trim()
                                                break
                                            }
                                        }
                                    }
                                }
                                break
                            }
                        }
                    }
                    if ($DateOverrideStr) {
                        $DOParsed = ConvertTo-SessionDate -DateString $DateOverrideStr
                        if ($DOParsed) {
                            if ($null -eq $DateInfo) {
                                $DateInfo = @{
                                    Date      = $DOParsed
                                    DateEnd   = $null
                                    DateStr   = $DateOverrideStr
                                    EndDayStr = $null
                                }
                            } else {
                                $DateInfo.Date = $DOParsed
                                $DateInfo.DateStr = $DateOverrideStr
                            }
                        }
                    }

                    if ($null -eq $DateInfo) {
                        if ($IncludeFailed) {
                            $FileFailedSessions.Add(@{
                                Header       = $Header
                                Content      = if ($IncludeContent) { $Section.Content } else { $null }
                                SectionIndex = $SectI
                            })
                        }
                        continue
                    }

                    # Extract title from header
                    $Title = Get-SessionTitle -Header $Header -DateInfo $DateInfo

                    # Classify session format
                    $ContentLines = $Section.Content.Split([char]"`n")
                    $FirstNonEmptyLine = $null
                    foreach ($CLine in $ContentLines) {
                        if (-not [string]::IsNullOrWhiteSpace($CLine)) {
                            $FirstNonEmptyLine = $CLine
                            break
                        }
                    }
                    $Format = Get-SessionFormat -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists

                    # Build section children-of index
                    $SectionChildrenOf = @{}
                    foreach ($LI in $Section.Lists) {
                        if ($LI.ParentIndex -ge 0) {
                            if (-not $SectionChildrenOf.ContainsKey($LI.ParentIndex)) {
                                $SectionChildrenOf[$LI.ParentIndex] = [System.Collections.Generic.List[object]]::new()
                            }
                            $SectionChildrenOf[$LI.ParentIndex].Add($LI)
                        }
                    }

                    # Tag-based location extraction (Strategy 2 only — Strategy 1 runs in post-processing)
                    $Locations = Get-SessionLocations -Format $Format -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists -LocItalicRegex $LocItalicRegex -Index $null -ChildrenOf $SectionChildrenOf

                    # List-based metadata extraction
                    $ListMeta = Get-SessionListMetadata -SectionLists $Section.Lists -PURegex $PURegex -UrlRegex $UrlRegex -ChildrenOf $SectionChildrenOf

                    $Logs = $ListMeta.Logs
                    if ($Logs.Count -eq 0) {
                        $Logs = Get-SessionPlainTextLogs -ContentLines $ContentLines -LogiLineRegex $LogiLineRegex
                    }

                    # Extract narrator raw text from header
                    $NarratorRaw = $null
                    $LastComma = $Header.LastIndexOf(',')
                    if ($LastComma -ge 0 -and ($Header.Split(',').Length - 1) -ge 2) {
                        $NarratorRaw = $Header.Substring($LastComma + 1).Trim()
                    }

                    $FileStructuralSessions.Add(@{
                        Header           = $Header
                        Date             = $DateInfo.Date
                        DateEnd          = $DateInfo.DateEnd
                        DateStr          = $DateInfo.DateStr
                        EndDayStr        = $DateInfo.EndDayStr
                        Title            = $Title
                        Format           = $Format
                        Locations        = if ($Locations) { @($Locations) } else { @() }
                        Logs             = if ($Logs) { @($Logs) } else { @() }
                        PU               = if ($ListMeta.PU) { @($ListMeta.PU) } else { @() }
                        Changes          = if ($ListMeta.Changes -and $ListMeta.Changes.Count -gt 0) { @($ListMeta.Changes) } else { @() }
                        Transfers        = if ($ListMeta.Transfers -and $ListMeta.Transfers.Count -gt 0) { @($ListMeta.Transfers) } else { @() }
                        RawIntel         = if ($ListMeta.Intel -and $ListMeta.Intel.Count -gt 0) { $ListMeta.Intel } else { [System.Collections.Generic.List[object]]::new() }
                        NarratorRawText  = $NarratorRaw
                        MetaNarrators    = if ($ListMeta.Narrators -and $ListMeta.Narrators.Count -gt 0) { @($ListMeta.Narrators) } else { @() }
                        Files            = if ($ListMeta.Files) { @($ListMeta.Files) } else { @() }
                        Content          = if ($IncludeContent) { $Section.Content } else { $null }
                        FirstNonEmptyLine = $FirstNonEmptyLine
                        SectionIndex     = $SectI
                    })
                }
            }

            # Persist structural results so subsequent calls with different date ranges skip extraction
            $script:SessionFileCache[$FilePath] = @{
                ModTime  = $FileModKey
                Sessions = $FileStructuralSessions
                Failed   = $FileFailedSessions
            }
        }

        # ── Post-processing: entity-dependent operations ──────────────────────
        # These steps run on EVERY call (including cache hits) because they
        # depend on the current entity index, which may have changed since
        # the structural cache was populated.

        # Build parseable sections list for batch narrator resolution
        $ParseableSections = [System.Collections.Generic.List[object]]::new()
        foreach ($StructSess in $FileStructuralSessions) {
            if ($null -ne $StructSess.NarratorRawText -or $StructSess.MetaNarrators.Count -gt 0) {
                $ParseableSections.Add([PSCustomObject]@{ Header = $StructSess.Header })
            }
        }

        $NarratorResults = $null
        if ($ParseableSections.Count -gt 0) {
            $NarratorResults = Resolve-Narrator -Sessions $ParseableSections.ToArray() -Index $Index -StemIndex $StemIndex -BKTree $BKTree -NarratorCache $NarratorCache
        }

        $NarratorIdx = 0
        foreach ($StructSess in $FileStructuralSessions) {
            # Date filtering (cache stores ALL sessions; filter here)
            if ($StructSess.Date -lt $MinDate -or $StructSess.Date -gt $MaxDate) {
                # Still advance narrator index to keep in sync
                if ($null -ne $StructSess.NarratorRawText -or $StructSess.MetaNarrators.Count -gt 0) {
                    $NarratorIdx++
                }
                continue
            }

            # Narrator resolution from header
            $NarratorResult = $null
            if ($null -ne $StructSess.NarratorRawText -or $StructSess.MetaNarrators.Count -gt 0) {
                if ($NarratorResults) {
                    $NarratorResult = if ($NarratorResults -is [array]) { $NarratorResults[$NarratorIdx] } else { $NarratorResults }
                }
                $NarratorIdx++
            }

            # @Narrator override replaces header-based resolution with explicit canonical names
            $MetaNarrators = $StructSess.MetaNarrators
            if ($MetaNarrators -and $MetaNarrators.Count -gt 0) {
                $OverrideNarrators = [System.Collections.Generic.List[object]]::new()
                foreach ($CanonName in $MetaNarrators) {
                    if ($Index.ContainsKey($CanonName)) {
                        $IdxEntry = $Index[$CanonName]
                        if (-not $IdxEntry.Ambiguous -and $IdxEntry.OwnerType -eq 'Player') {
                            $OverrideNarrators.Add([Robot.Narrator]::new($IdxEntry.Owner.Name, $IdxEntry.Owner, 'High'))
                            continue
                        }
                    }
                    $Resolved = Resolve-Name -Query $CanonName -Index $Index -StemIndex $StemIndex -BKTree $BKTree -OwnerType 'Player'
                    if ($Resolved) {
                        $OverrideNarrators.Add([Robot.Narrator]::new($Resolved.Name, $Resolved, 'Medium'))
                    }
                }

                if ($OverrideNarrators.Count -gt 0) {
                    $OverallConf = 'High'
                    foreach ($N in $OverrideNarrators) {
                        if ($N.Confidence -ne 'High') { $OverallConf = $N.Confidence }
                    }
                    $NarratorResult = [Robot.NarratorResult]::new(
                        @($OverrideNarrators),
                        $false,
                        $OverallConf,
                        $(if ($NarratorResult) { $NarratorResult.RawText } else { $null })
                    )
                }
            }

            # Location Strategy 1: entity-based resolution for Gen3/Gen4 sessions
            # where Strategy 2 (tag extraction) yielded no locations. Requires the
            # entity index, so it runs in post-processing rather than structural extraction.
            $LocationsV = $StructSess.Locations
            if (($LocationsV.Count -eq 0) -and ($StructSess.Format -eq 'Gen3' -or $StructSess.Format -eq 'Gen4') -and $Index) {
                $Section = $null
                # Find matching section from Markdown parse for list item access
                $SectIdx = $StructSess.SectionIndex
                if ($SectIdx -ge 0 -and $SectIdx -lt $SessionSections.Count) {
                    $Section = $SessionSections[$SectIdx]
                }
                if ($Section -and $Section.Lists) {
                    $SectionChildrenOf = @{}
                    foreach ($LI in $Section.Lists) {
                        if ($LI.ParentIndex -ge 0) {
                            if (-not $SectionChildrenOf.ContainsKey($LI.ParentIndex)) {
                                $SectionChildrenOf[$LI.ParentIndex] = [System.Collections.Generic.List[object]]::new()
                            }
                            $SectionChildrenOf[$LI.ParentIndex].Add($LI)
                        }
                    }
                    $LocResult = Get-SessionLocations -Format $StructSess.Format -FirstNonEmptyLine $StructSess.FirstNonEmptyLine -SectionLists $Section.Lists -LocItalicRegex $LocItalicRegex -Index $Index -ChildrenOf $SectionChildrenOf
                    if ($LocResult -and $LocResult.Count -gt 0) {
                        $LocationsV = @($LocResult)
                    }
                }
            }

            # Entity mention extraction (opt-in via -IncludeMentions for performance)
            $MentionsV = @()
            if ($IncludeMentions) {
                $Section = $null
                $SectIdx = $StructSess.SectionIndex
                if ($SectIdx -ge 0 -and $SectIdx -lt $SessionSections.Count) {
                    $Section = $SessionSections[$SectIdx]
                }
                if ($Section) {
                    $SectionChildrenOf = @{}
                    foreach ($LI in $Section.Lists) {
                        if ($LI.ParentIndex -ge 0) {
                            if (-not $SectionChildrenOf.ContainsKey($LI.ParentIndex)) {
                                $SectionChildrenOf[$LI.ParentIndex] = [System.Collections.Generic.List[object]]::new()
                            }
                            $SectionChildrenOf[$LI.ParentIndex].Add($LI)
                        }
                    }
                    $RawMentions = Get-SessionMentions `
                        -Content $Section.Content `
                        -SectionLists $Section.Lists `
                        -Format $StructSess.Format `
                        -FirstNonEmptyLine $StructSess.FirstNonEmptyLine `
                        -Index $Index `
                        -StemIndex $StemIndex `
                        -ResolveCache $MentionCache `
                        -ChildrenOf $SectionChildrenOf
                    $MentionsV = if ($RawMentions -and $RawMentions.Count -gt 0) { @($RawMentions) } else { @() }
                }
            }

            # Intel resolution: map @Intel directives to recipient entities
            $IntelV = @()
            $RawIntel = $StructSess.RawIntel
            if ($RawIntel -and $RawIntel.Count -gt 0 -and $null -ne $StructSess.Date) {
                # Normalize raw Intel to SessionIntel C# objects — PS fallback
                # produces hashtables while C# extractor produces typed objects
                $IntelList = [System.Collections.Generic.List[object]]::new()
                foreach ($RI in $RawIntel) {
                    if ($RI -is [Robot.SessionIntel]) {
                        $IntelList.Add($RI)
                    } else {
                        $IntelList.Add([Robot.SessionIntel]::new($RI.RawTarget, $RI.Message))
                    }
                }
                $ResolvedIntel = Resolve-IntelTargets `
                    -RawIntel $IntelList `
                    -SessionDate $StructSess.Date `
                    -Entities $Entities `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -Players $Players `
                    -ResolveCache $IntelCache `
                    -EntityByGroup $EntityByGroup `
                    -EntityByLocation $EntityByLocation
                $IntelV = if ($ResolvedIntel -and $ResolvedIntel.Count -gt 0) { @($ResolvedIntel) } else { @() }
            }

            # Assemble final session object with all extracted + post-processed metadata
            $LocationsArr = if ($LocationsV) { @($LocationsV) } else { @() }
            $LogsArr = if ($StructSess.Logs) { @($StructSess.Logs) } else { @() }
            $PUArr = if ($StructSess.PU) { @($StructSess.PU) } else { @() }
            $ChangesArr = if ($StructSess.Changes) { @($StructSess.Changes) } else { @() }
            $TransfersArr = if ($StructSess.Transfers) { @($StructSess.Transfers) } else { @() }
            $DeclaredFilesArr = if ($StructSess.Files) { @($StructSess.Files) } else { @() }

            $SessionProps = [ordered]@{
                FilePath       = $FilePath
                FilePaths      = $null
                Header         = $StructSess.Header
                Date           = $StructSess.Date
                DateEnd        = $StructSess.DateEnd
                Title          = $StructSess.Title
                Narrator       = $NarratorResult
                Locations      = $LocationsArr
                Logs           = $LogsArr
                PU             = $PUArr
                Format         = $StructSess.Format
                IsMerged       = $false
                DuplicateCount = 1
                Content        = $StructSess.Content
                Changes        = $ChangesArr
                Transfers      = $TransfersArr
                Mentions       = $MentionsV
                Intel          = $IntelV
                DeclaredFiles  = $DeclaredFilesArr
            }
            $AllSessions.Add([PSCustomObject]$SessionProps)
        }

        # Append failed sessions for this file
        if ($IncludeFailed -and $FileFailedSessions.Count -gt 0) {
            foreach ($FailedData in $FileFailedSessions) {
                $FailedSession = [PSCustomObject]@{
                    FilePath       = $FilePath
                    FilePaths      = @($FilePath)
                    Header         = $FailedData.Header
                    Date           = $null
                    DateEnd        = $null
                    Title          = $FailedData.Header
                    Narrator       = $null
                    Locations      = @()
                    Logs           = @()
                    PU             = @()
                    Format         = "Unknown"
                    IsMerged       = $false
                    DuplicateCount = 0
                    Content        = $FailedData.Content
                    Changes        = @()
                    Mentions       = @()
                    Intel          = @()
                    DeclaredFiles  = @()
                    ParseError     = "Header does not contain a valid yyyy-MM-dd date"
                }
                $FailedSessions.Add($FailedSession)
            }
        }
    }

    # Cross-file deduplication: group by exact header text, merge array fields

    $SessionsByHeader = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($Sess in $AllSessions) {
        if (-not $SessionsByHeader.ContainsKey($Sess.Header)) {
            $SessionsByHeader[$Sess.Header] = [System.Collections.Generic.List[object]]::new()
        }
        $SessionsByHeader[$Sess.Header].Add($Sess)
    }

    $DedupSessions = [System.Collections.Generic.List[object]]::new($SessionsByHeader.Count)

    foreach ($Entry in $SessionsByHeader.GetEnumerator()) {
        $Merged = Merge-SessionGroup -Group $Entry.Value -IncludeContent $IncludeContent.IsPresent
        $DedupSessions.Add($Merged)
    }

    # Remove null-date entries (non-session level-3 headers that matched no date)
    $Filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($S in $DedupSessions) {
        if ($null -ne $S.Date) { $Filtered.Add($S) }
    }

    # Failed sessions (no valid date) appended for diagnostic consumers

    if ($IncludeFailed -and $FailedSessions.Count -gt 0) {
        foreach ($F in $FailedSessions) {
            $Filtered.Add($F)
        }
    }

    # Optional log attachment: fetch and parse log content for sessions with URLs
    if ($IncludeLogs) {
        $LogIndex = if ($NameIndex) { $NameIndex } else { $null }
        $LogResults = $Filtered | Get-SessionLog -Index $LogIndex -SkipFetch:$false
        # Positional matching: Get-SessionLog emits in same order as input sessions
        $SessionsWithLogs = [System.Collections.Generic.List[object]]::new()
        foreach ($S in $Filtered) {
            if ($null -ne $S.Logs -and $S.Logs.Count -gt 0) {
                $SessionsWithLogs.Add($S)
            }
        }
        $LogResultArray = @($LogResults)
        for ($i = 0; $i -lt $SessionsWithLogs.Count -and $i -lt $LogResultArray.Count; $i++) {
            $SessionsWithLogs[$i] | Add-Member -NotePropertyName 'LogData' -NotePropertyValue $LogResultArray[$i].Logs -Force
        }
    }

    return $Filtered

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

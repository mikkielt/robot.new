<#
    .SYNOPSIS
    Parses session metadata from Markdown files into structured objects with
    format detection, narrator resolution, and cross-file deduplication.

    .DESCRIPTION
    This file contains Get-Session and its core helpers. It dot-sources
    session-parsehelpers.ps1 for format-specific content parsing and
    session-intelhelpers.ps1 for notification routing and mention extraction.

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
      mentions, Intel) via HashSet/Dictionary union. Reports scalar
      field conflicts (Title, Format) as warnings.

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

    Pipeline:
    1. Collect input files (explicit file, directory scan, or repo root)
    2. Pre-fetch shared dependencies: entities, players, name index
    3. Pre-build entity indices for O(1) Intel resolution (EntityByGroup,
       EntityByLocation) to avoid O(E) scans per Intel directive
    4. Batch-parse all files via Get-Markdown (RunspacePool parallelism)
    5. Per file: pre-filter sections by date regex, batch Resolve-Narrator
    6. Per section: parse date, detect format, build ChildrenOf hashtable
       keyed by ParentIndex/LocalIndex for O(1) parent-child lookups,
       extract locations/PU/logs/changes/transfers/mentions/Intel
    7. @Data override rescues sessions with malformed header dates
    8. @Narrator override replaces header-based narrator resolution
    9. Cross-file deduplication groups by exact header text (Ordinal)

    Critical invariant: NarratorIdx must stay in sync with ParseableIndices
    even when sessions are date-filtered out, because Resolve-Narrator
    returns results for all parseable sections in a file.
#>

. "$script:ModuleRoot/private/temporal-helpers.ps1"
. "$script:ModuleRoot/private/session-parsehelpers.ps1"
. "$script:ModuleRoot/private/session-intelhelpers.ps1"

# C# types: Robot.NarratorResult, Robot.Narrator (lib/NarratorResult.cs)
# Compiled centrally in robot.psm1 at module import time.

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
        $AllFiles = [System.IO.Directory]::GetFiles($SearchDir, "*.md", [System.IO.SearchOption]::AllDirectories)

        # Exclusion prefixes prevent scanning the module's own files and user-specified directories
        $Sep = [System.IO.Path]::DirectorySeparatorChar
        $ExcludePrefixes = [System.Collections.Generic.List[string]]::new()

        # Auto-exclude module directory to avoid parsing devdocs/tests as session files
        $SearchDirNorm  = $SearchDir.TrimEnd($Sep) + $Sep
        $ModuleRootNorm = $script:ModuleRoot.TrimEnd($Sep) + $Sep
        if ($ModuleRootNorm.StartsWith($SearchDirNorm, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $SearchDirNorm.StartsWith($ModuleRootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ExcludePrefixes.Add($ModuleRootNorm)
        }

        # Also exclude the module's submodule copy when Set-DataDirectory points elsewhere
        $ModuleLeafName = [System.IO.Path]::GetFileName($script:ModuleRoot.TrimEnd($Sep))
        $ModuleInSearchDir = [System.IO.Path]::Combine($SearchDir, $ModuleLeafName) + $Sep
        if (-not $ModuleInSearchDir.Equals($ModuleRootNorm, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Directory]::Exists($ModuleInSearchDir.TrimEnd($Sep))) {
            $ExcludePrefixes.Add($ModuleInSearchDir)
        }

        # Append user-specified directory exclusions
        foreach ($Dir in $ExcludeDirectory) {
            if ([System.IO.Directory]::Exists($Dir)) {
                $ExcludePrefixes.Add($Dir.TrimEnd($Sep) + $Sep)
            }
        }

        if ($ExcludePrefixes.Count -eq 0) {
            $FilesToProcess.AddRange($AllFiles)
        } else {
            foreach ($f in $AllFiles) {
                $Skip = $false
                foreach ($Prefix in $ExcludePrefixes) {
                    if ($f.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $Skip = $true
                        break
                    }
                }
                if (-not $Skip) { $FilesToProcess.Add($f) }
            }
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

        # Single-pass pre-filter: cache date regex matches and build parseable sections list
        $HasCandidateSession = $false
        $ParseableSections   = [System.Collections.Generic.List[object]]::new()
        $ParseableIndices    = [System.Collections.Generic.HashSet[int]]::new()
        $CachedDateMatches   = [System.Collections.Generic.Dictionary[int, object]]::new()
        $CachedDateParsed    = [System.Collections.Generic.Dictionary[int, object]]::new()

        for ($i = 0; $i -lt $SessionSections.Count; $i++) {
            $Sect = $SessionSections[$i]
            $DMatch = $DateRegex.Match($Sect.Header.Text)
            $CachedDateMatches[$i] = $DMatch

            if ($DMatch.Success) {
                $ParseableSections.Add($Sect)
                [void]$ParseableIndices.Add($i)

                # Cache parsed date to avoid redundant TryParseExact in ConvertFrom-SessionHeader
                $DStr = $DMatch.Groups[1].Value
                $DParsed = ConvertTo-SessionDate -DateString $DStr
                if ($DParsed) {
                    $CachedDateParsed[$i] = $DParsed
                    if (-not $HasCandidateSession -and $DParsed -ge $MinDate -and $DParsed -le $MaxDate) {
                        $HasCandidateSession = $true
                    }
                }
            } else {
                # No date match — must process (may become a failed session entry)
                $HasCandidateSession = $true
            }
        }
        if (-not $HasCandidateSession) { continue }

        $NarratorResults = $null
        if ($ParseableSections.Count -gt 0) {
            $NarratorResults = Resolve-Narrator -Sessions $ParseableSections.ToArray() -Index $Index -StemIndex $StemIndex -BKTree $BKTree -NarratorCache $NarratorCache
        }

        # Per-section processing: date parsing, format detection, metadata extraction

        $NarratorIdx = 0
        for ($i = 0; $i -lt $SessionSections.Count; $i++) {
            $Section = $SessionSections[$i]
            $Header  = $Section.Header.Text

            # Reuse cached regex match and pre-parsed date from the pre-filter pass
            $CachedMatch = if ($CachedDateMatches.ContainsKey($i)) { $CachedDateMatches[$i] } else { $null }
            $HeaderArgs = @{ Header = $Header; DateRegex = $DateRegex; Match = $CachedMatch }
            if ($CachedDateParsed.ContainsKey($i)) { $HeaderArgs['ParsedDate'] = $CachedDateParsed[$i] }
            $DateInfo = ConvertFrom-SessionHeader @HeaderArgs

            # @Data override rescues sessions with malformed header dates (e.g. "2024-07-014")
            # by providing a correct date via a structured tag in the session body
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
                # Header does not match session pattern - record as failed
                if ($IncludeFailed) {
                    $FailedSession = [PSCustomObject]@{
                        FilePath       = $FilePath
                        FilePaths      = @($FilePath)
                        Header         = $Header
                        Date           = $null
                        DateEnd        = $null
                        Title          = $Header
                        Narrator       = $null
                        Locations      = @()
                        Logs           = @()
                        PU             = @()
                        Format         = "Unknown"
                        IsMerged       = $false
                        DuplicateCount = 0
                        Content        = if ($IncludeContent) { $Section.Content } else { $null }
                        Changes        = @()
                        Mentions       = @()
                        Intel          = @()
                        ParseError     = "Header does not contain a valid yyyy-MM-dd date"
                    }
                    $FailedSessions.Add($FailedSession)
                }
                continue
            }

            # Extract narrator BEFORE date filtering — $NarratorIdx must stay in sync
            # with $ParseableIndices even when sessions are filtered out
            $NarratorResult = $null
            if ($NarratorResults -and $ParseableIndices.Contains($i)) {
                $NarratorResult = if ($NarratorResults -is [array]) { $NarratorResults[$NarratorIdx] } else { $NarratorResults }
                $NarratorIdx++
            }

            # Date filtering
            if ($DateInfo.Date -lt $MinDate -or $DateInfo.Date -gt $MaxDate) { continue }

            # Extract title from header (middle comma-separated segment)
            $Title = Get-SessionTitle -Header $Header -DateInfo $DateInfo

            # Classify session format generation from content heuristics
            $ContentLines = $Section.Content.Split([char]"`n")

            $FirstNonEmptyLine = $null
            foreach ($CLine in $ContentLines) {
                if (-not [string]::IsNullOrWhiteSpace($CLine)) {
                    $FirstNonEmptyLine = $CLine
                    break
                }
            }

            $Format = Get-SessionFormat -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists

            # Parent-to-children list index built once per section and shared by
            # Get-SessionLocations, Get-SessionListMetadata, and Get-SessionMentions.
            # Keyed by section-local ParentIndex; lookup via item's LocalIndex.
            $SectionChildrenOf = @{}
            foreach ($LI in $Section.Lists) {
                if ($LI.ParentIndex -ge 0) {
                    if (-not $SectionChildrenOf.ContainsKey($LI.ParentIndex)) {
                        $SectionChildrenOf[$LI.ParentIndex] = [System.Collections.Generic.List[object]]::new()
                    }
                    $SectionChildrenOf[$LI.ParentIndex].Add($LI)
                }
            }

            # Extract session metadata: locations, PU, logs, changes, transfers
            $Locations = Get-SessionLocations -Format $Format -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists -LocItalicRegex $LocItalicRegex -Index $Index -ChildrenOf $SectionChildrenOf

            # List-based metadata extraction (PU, logs, changes, transfers, narrators)
            $ListMeta = Get-SessionListMetadata -SectionLists $Section.Lists -PURegex $PURegex -UrlRegex $UrlRegex -ChildrenOf $SectionChildrenOf

            $Logs    = $ListMeta.Logs
            $PU      = $ListMeta.PU
            $Changes = $ListMeta.Changes
            $Transfers = $ListMeta.Transfers

            # @Narrator override replaces header-based resolution with explicit canonical names
            $MetaNarrators = $ListMeta.Narrators
            if ($MetaNarrators -and $MetaNarrators.Count -gt 0) {
                $OverrideNarrators = [System.Collections.Generic.List[object]]::new()
                foreach ($CanonName in $MetaNarrators) {
                    # Exact name index match yields High confidence
                    if ($Index.ContainsKey($CanonName)) {
                        $IdxEntry = $Index[$CanonName]
                        if (-not $IdxEntry.Ambiguous -and $IdxEntry.OwnerType -eq 'Player') {
                            $OverrideNarrators.Add([Robot.Narrator]::new($IdxEntry.Owner.Name, $IdxEntry.Owner, 'High'))
                            continue
                        }
                    }
                    # Fuzzy resolution fallback yields Medium confidence
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

            # Gen1/Gen2 fallback: extract log URLs from plain text "Logi:" lines
            if ($Logs.Count -eq 0) {
                $Logs = Get-SessionPlainTextLogs -ContentLines $ContentLines -LogiLineRegex $LogiLineRegex
            }

            # Entity mention extraction (opt-in via -IncludeMentions for performance)
            $MentionsV = @()
            if ($IncludeMentions) {
                $RawMentions = Get-SessionMentions `
                    -Content $Section.Content `
                    -SectionLists $Section.Lists `
                    -Format $Format `
                    -FirstNonEmptyLine $FirstNonEmptyLine `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -ResolveCache $MentionCache `
                    -ChildrenOf $SectionChildrenOf `
                    -ContentLines $ContentLines
                $MentionsV = if ($RawMentions -and $RawMentions.Count -gt 0) { @($RawMentions) } else { @() }
            }

            # Intel resolution: map @Intel directives to recipient entities
            $IntelV = @()
            if ($ListMeta.Intel -and $ListMeta.Intel.Count -gt 0 -and $null -ne $DateInfo.Date) {
                $ResolvedIntel = Resolve-IntelTargets `
                    -RawIntel $ListMeta.Intel `
                    -SessionDate $DateInfo.Date `
                    -Entities $Entities `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -Players $Players `
                    -ResolveCache $IntelCache `
                    -EntityByGroup $EntityByGroup `
                    -EntityByLocation $EntityByLocation
                $IntelV = if ($ResolvedIntel -and $ResolvedIntel.Count -gt 0) { @($ResolvedIntel) } else { @() }
            }

            # Assemble final session object with all extracted metadata
            $LocationsV = if ($Locations) { @($Locations) } else { @() }
            $LogsV = if ($Logs) { @($Logs) } else { @() }
            $PUV = if ($PU) { @($PU) } else { @() }
            $ChangesV = if ($Changes -and $Changes.Count -gt 0) { @($Changes) } else { @() }
            $TransfersV = if ($Transfers -and $Transfers.Count -gt 0) { @($Transfers) } else { @() }

            $SessionProps = [ordered]@{
                FilePath       = $FilePath
                FilePaths      = $null
                Header         = $Header
                Date           = $DateInfo.Date
                DateEnd        = $DateInfo.DateEnd
                Title          = $Title
                Narrator       = $NarratorResult
                Locations      = $LocationsV
                Logs           = $LogsV
                PU             = $PUV
                Format         = $Format
                IsMerged       = $false
                DuplicateCount = 1
                Content        = if ($IncludeContent) { $Section.Content } else { $null }
                Changes        = $ChangesV
                Transfers      = $TransfersV
                Mentions       = $MentionsV
                Intel          = $IntelV
            }
            $AllSessions.Add([PSCustomObject]$SessionProps)
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

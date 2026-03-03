<#
    .SYNOPSIS
    Parses session metadata from Markdown files into structured objects with format
    detection, narrator resolution, and cross-file deduplication.

    .DESCRIPTION
    This file contains Get-Session and its core helpers. It dot-sources
    session-parsehelpers.ps1 for format-specific content parsing and
    session-intelhelpers.ps1 for notification routing and mention extraction.

    Helpers:
    - ConvertFrom-SessionHeader: parses a yyyy-MM-dd date (with optional /DD range)
      from a session header string
    - Get-SessionFormat: classifies a section as Gen1/Gen2/Gen3/Gen4 based on content
      heuristics (italic location lines, structured list items, @-prefixed tags, etc.)
    - Merge-SessionGroup: deduplicates sessions sharing the same header across files,
      selecting the metadata-richest primary and merging array fields

    Get-Session scans Markdown files for level-3 headers containing a yyyy-MM-dd date
    and extracts structured session objects. It supports four format generations that
    evolved over time:
    - Gen1 (START-2022): plain text with no structured metadata
    - Gen2 (2022-2023): italic location lines (*Lokalizacja: ...*)
    - Gen3 (2024-2026): fully structured list-based metadata (- Lokalizacje:, - Logi:, - PU:).
      - Zmiany: blocks contain entity state overrides and are extracted to session objects.
      - Efekty: and Objaśnienia: are present in source but not extracted to session object fields.
    - Gen4 (2026+): @-prefixed list-based metadata (- @Lokacje:, - @PU:, - @Logi:, - @Zmiany:).
      Backwards compatible - Gen3 sessions parse identically to before.

    Key implementation decisions:
    - All Markdown files are batch-parsed in a single Get-Markdown call to enable
      RunspacePool parallelism for large directory scans
    - Narrator resolution is batched per file (Resolve-Narrator takes all parseable
      sections at once) so the shared name index is built only once
    - NarratorIdx tracking must stay in sync with ParseableIndices even when sessions
      are date-filtered out, because Resolve-Narrator returns results for all sections
    - Cross-file deduplication groups by exact header text (Ordinal comparison) and
      merges array fields (locations, logs, PU) via HashSet union
#>

# Dot-source helpers
. "$script:ModuleRoot/private/session-parsehelpers.ps1"
. "$script:ModuleRoot/private/session-intelhelpers.ps1"

# Helper: parse session date from header
# Extracts a yyyy-MM-dd date (and optional /DD range suffix) from a session
# header string. Returns hashtable: @{ Date; DateEnd; Match } or $null when
# no valid date is found in the header.
function ConvertFrom-SessionHeader {
    param(
        [string]$Header,
        [regex]$DateRegex,
        [object]$Match  # optional pre-matched regex result to avoid redundant matching
    )

    if (-not $Match) { $Match = $DateRegex.Match($Header) }
    if (-not $Match.Success) { return $null }

    $DateStr    = $Match.Groups[1].Value
    $EndDayStr  = $Match.Groups[2].Value

    [datetime]$Parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($DateStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
        return $null
    }

    $DateEnd = $null
    if ($EndDayStr) {
        [datetime]$EndParsed = [datetime]::MinValue
        $EndStr = $DateStr.Substring(0, 8) + $EndDayStr
        if ([datetime]::TryParseExact($EndStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$EndParsed)) {
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

# Helper: detect session format generation
# Determines the format generation based on content heuristics:
#   Gen1 (START-2022): No structured metadata, plain text Logi/Rezultat lines
#   Gen2 (2022-2023): Italic location line (*Lokalizacja: ...*), plain text Logi
#   Gen3 (2024-2026): List-based metadata (- Lokalizacje:, - Logi:, - PU:, etc.)
#   Gen4 (2026+):     @-prefixed list-based metadata (- @Lokacje:, - @PU:, etc.)
# Returns: "Gen1", "Gen2", "Gen3", or "Gen4"
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

# Helper: merge duplicate sessions
# Given a group of sessions sharing the same header, selects the primary (most
# metadata-rich) and merges array fields from all duplicates. Returns a single
# merged session object.
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
        return $S
    }

    # Pick primary: highest metadata score
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

    # Collect all file paths (HashSet for O(1) dedup)
    $AllFilePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($S in $Group) {
        [void]$AllFilePaths.Add($S.FilePath)
    }

    # Conflict detection for scalar fields
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
                [System.Console]::Error.WriteLine("[WARN Get-Session] Dedup conflict on '$FieldName' for header '$($Primary.Header)': $ValList")
            }
        }
    }

    # Merge array fields: union unique values
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
    }

    return $Merged
}

function Get-Session {
    <#
        .SYNOPSIS
        Parses session metadata from Markdown files into structured objects with
        format detection, narrator resolution, and cross-file deduplication.
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
        [switch]$IncludeLogs
    )

    $RepoRoot = Get-RepoRoot

    # Collect input files

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

        # Build exclusion prefixes
        $Sep = [System.IO.Path]::DirectorySeparatorChar
        $ExcludePrefixes = [System.Collections.Generic.List[string]]::new()

        # Auto-exclude the module's own directory when it is a proper subdirectory of the search path
        $SearchDirNorm  = $SearchDir.TrimEnd($Sep) + $Sep
        $ModuleRootNorm = $script:ModuleRoot.TrimEnd($Sep) + $Sep
        if ($ModuleRootNorm.StartsWith($SearchDirNorm, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $SearchDirNorm.StartsWith($ModuleRootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ExcludePrefixes.Add($ModuleRootNorm)
        }

        # When Set-DataDirectory points to a different repo, the module may also
        # exist as a submodule inside SearchDir under the same leaf name.
        $ModuleLeafName = [System.IO.Path]::GetFileName($script:ModuleRoot.TrimEnd($Sep))
        $ModuleInSearchDir = [System.IO.Path]::Combine($SearchDir, $ModuleLeafName) + $Sep
        if (-not $ModuleInSearchDir.Equals($ModuleRootNorm, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Directory]::Exists($ModuleInSearchDir.TrimEnd($Sep))) {
            $ExcludePrefixes.Add($ModuleInSearchDir)
        }

        # Add user-specified exclusions
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

    # Pre-fetch shared dependencies

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-Entity
    }
    if (-not $PSBoundParameters.ContainsKey('Players')) {
        $Players  = Get-Player -Entities $Entities
    }
    $NameIndexResult = Get-NameIndex -Players $Players -Entities $Entities
    $Index     = $NameIndexResult.Index
    $StemIndex = $NameIndexResult.StemIndex
    $BKTree    = $NameIndexResult.BKTree

    $MentionCache = @{}
    $IntelCache   = @{}

    # Precompile regex patterns

    $DateRegex      = [regex]::new('\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b')
    $LocItalicRegex = [regex]::new('\*Lokalizacj[ae]?:\s*(.+?)\*')
    $PURegex        = [regex]::new('^(.+?):\s*([\d,\.]+)')
    $UrlRegex       = [regex]::new('(https?://\S+)')
    $LogiLineRegex  = [regex]::new('^Logi:\s*(https?://\S+)')

    # Results collection

    $AllSessions    = [System.Collections.Generic.List[object]]::new()
    $FailedSessions = [System.Collections.Generic.List[object]]::new()

    # Batch-parse all Markdown files in a single call

    $AllMarkdownResults = @(Get-Markdown -File ($FilesToProcess.ToArray()))
    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($MarkdownResult in $AllMarkdownResults) { $MarkdownByPath[$MarkdownResult.FilePath] = $MarkdownResult }

    # Main file processing loop

    foreach ($FilePath in $FilesToProcess) {

        $Markdown = if ($MarkdownByPath.ContainsKey($FilePath)) { $MarkdownByPath[$FilePath] } else { $null }
        if ($null -eq $Markdown) { continue }

        $SessionSections = $Markdown.Sections.Where({ $_.Header -and $_.Header.Level -eq 3 })
        if ($SessionSections.Count -eq 0) { continue }

        # Single pass: pre-filter + cache date regex matches + build parseable sections list.
        # Merges what was previously two separate passes over $SessionSections.
        $HasCandidateSession = $false
        $ParseableSections   = [System.Collections.Generic.List[object]]::new()
        $ParseableIndices    = [System.Collections.Generic.HashSet[int]]::new()
        $CachedDateMatches   = [System.Collections.Generic.Dictionary[int, object]]::new()

        for ($i = 0; $i -lt $SessionSections.Count; $i++) {
            $Sect = $SessionSections[$i]
            $DMatch = $DateRegex.Match($Sect.Header.Text)
            $CachedDateMatches[$i] = $DMatch

            if ($DMatch.Success) {
                $ParseableSections.Add($Sect)
                [void]$ParseableIndices.Add($i)

                if (-not $HasCandidateSession) {
                    $DStr = $DMatch.Groups[1].Value
                    [datetime]$DParsed = [datetime]::MinValue
                    if ([datetime]::TryParseExact($DStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$DParsed)) {
                        if ($DParsed -ge $MinDate -and $DParsed -le $MaxDate) {
                            $HasCandidateSession = $true
                        }
                    }
                }
            } else {
                # No date - can't filter out, must process (or skip as failed)
                $HasCandidateSession = $true
            }
        }
        if (-not $HasCandidateSession) { continue }

        $NarratorResults = $null
        if ($ParseableSections.Count -gt 0) {
            $NarratorResults = Resolve-Narrator -Sessions $ParseableSections.ToArray() -Index $Index -StemIndex $StemIndex -BKTree $BKTree
        }

        # Process each section

        $NarratorIdx = 0
        for ($i = 0; $i -lt $SessionSections.Count; $i++) {
            $Section = $SessionSections[$i]
            $Header  = $Section.Header.Text

            # Parse date from header (using cached regex match)
            $CachedMatch = if ($CachedDateMatches.ContainsKey($i)) { $CachedDateMatches[$i] } else { $null }
            $DateInfo = ConvertFrom-SessionHeader -Header $Header -DateRegex $DateRegex -Match $CachedMatch

            # @Data override: scan for date override tag before failed-session check.
            # This rescues sessions with malformed header dates (e.g. "2024-07-014").
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
                                    if ($DOChild.ParentListItem -eq $LI) {
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
                [datetime]$DOParsed = [datetime]::MinValue
                if ([datetime]::TryParseExact($DateOverrideStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$DOParsed)) {
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

            # Narrator result (aligned with parseable sections index)
            # Must be extracted BEFORE date filtering to keep $NarratorIdx in sync
            # with $ParseableIndices - skipped sessions must still consume their slot.
            $NarratorResult = $null
            if ($NarratorResults -and $ParseableIndices.Contains($i)) {
                $NarratorResult = if ($NarratorResults -is [array]) { $NarratorResults[$NarratorIdx] } else { $NarratorResults }
                $NarratorIdx++
            }

            # Date filtering
            if ($DateInfo.Date -lt $MinDate -or $DateInfo.Date -gt $MaxDate) { continue }

            # Title extraction
            $Title = Get-SessionTitle -Header $Header -DateInfo $DateInfo

            # Format detection
            $ContentLines = $Section.Content.Split([char]"`n")

            $FirstNonEmptyLine = $null
            foreach ($CLine in $ContentLines) {
                if (-not [string]::IsNullOrWhiteSpace($CLine)) {
                    $FirstNonEmptyLine = $CLine
                    break
                }
            }

            $Format = Get-SessionFormat -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists

            # Location extraction
            $Locations = Get-SessionLocations -Format $Format -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists -LocItalicRegex $LocItalicRegex -Index $Index

            # List-based metadata (PU, Logs)
            $ListMeta = Get-SessionListMetadata -SectionLists $Section.Lists -PURegex $PURegex -UrlRegex $UrlRegex

            $Logs    = $ListMeta.Logs
            $PU      = $ListMeta.PU
            $Changes = $ListMeta.Changes
            $Transfers = $ListMeta.Transfers

            # @Narrator override: when present, completely replaces header-based narrator resolution
            $MetaNarrators = $ListMeta.Narrators
            if ($MetaNarrators -and $MetaNarrators.Count -gt 0) {
                $OverrideNarrators = [System.Collections.Generic.List[object]]::new()
                foreach ($CanonName in $MetaNarrators) {
                    # Exact index lookup -> High confidence
                    if ($Index.ContainsKey($CanonName)) {
                        $IdxEntry = $Index[$CanonName]
                        if (-not $IdxEntry.Ambiguous -and $IdxEntry.OwnerType -eq 'Player') {
                            $OverrideNarrators.Add([PSCustomObject]@{
                                Name       = $IdxEntry.Owner.Name
                                Player     = $IdxEntry.Owner
                                Confidence = 'High'
                            })
                            continue
                        }
                    }
                    # Fallback: full Resolve-Name with Player type filter -> Medium confidence
                    $Resolved = Resolve-Name -Query $CanonName -Index $Index -StemIndex $StemIndex -BKTree $BKTree -OwnerType 'Player'
                    if ($Resolved) {
                        $OverrideNarrators.Add([PSCustomObject]@{
                            Name       = $Resolved.Name
                            Player     = $Resolved
                            Confidence = 'Medium'
                        })
                    }
                }

                if ($OverrideNarrators.Count -gt 0) {
                    $OverallConf = 'High'
                    foreach ($N in $OverrideNarrators) {
                        if ($N.Confidence -ne 'High') { $OverallConf = $N.Confidence }
                    }
                    $NarratorResult = [PSCustomObject]@{
                        Narrators  = @($OverrideNarrators)
                        IsCouncil  = $false
                        Confidence = $OverallConf
                        RawText    = if ($NarratorResult) { $NarratorResult.RawText } else { $null }
                    }
                }
            }

            # Plain text log fallback (Gen 1/2)
            if ($Logs.Count -eq 0) {
                $Logs = Get-SessionPlainTextLogs -ContentLines $ContentLines -LogiLineRegex $LogiLineRegex
            }

            # Mention extraction
            $MentionsV = @()
            if ($IncludeMentions) {
                $RawMentions = Get-SessionMentions `
                    -Content $Section.Content `
                    -SectionLists $Section.Lists `
                    -Format $Format `
                    -FirstNonEmptyLine $FirstNonEmptyLine `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -ResolveCache $MentionCache
                $MentionsV = if ($RawMentions -and $RawMentions.Count -gt 0) { @($RawMentions) } else { @() }
            }

            # Intel resolution - always runs when @Intel entries exist
            $IntelV = @()
            if ($ListMeta.Intel -and $ListMeta.Intel.Count -gt 0 -and $null -ne $DateInfo.Date) {
                $ResolvedIntel = Resolve-IntelTargets `
                    -RawIntel $ListMeta.Intel `
                    -SessionDate $DateInfo.Date `
                    -Entities $Entities `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -Players $Players `
                    -ResolveCache $IntelCache
                $IntelV = if ($ResolvedIntel -and $ResolvedIntel.Count -gt 0) { @($ResolvedIntel) } else { @() }
            }

            # Build session object
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

    # Deduplication pass

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

    # Filter out entries with no parsed date - these are non-session headers
    $Filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($S in $DedupSessions) {
        if ($null -ne $S.Date) { $Filtered.Add($S) }
    }

    # Append failed sessions if requested

    if ($IncludeFailed -and $FailedSessions.Count -gt 0) {
        foreach ($F in $FailedSessions) {
            $Filtered.Add($F)
        }
    }

    # Attach parsed log data if requested
    if ($IncludeLogs) {
        $LogIndex = if ($NameIndex) { $NameIndex } else { $null }
        $LogResults = $Filtered | Get-SessionLog -Index $LogIndex -SkipFetch:$false
        # Match results to sessions by positional index (same order as collect-then-emit)
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
}

<#
    .SYNOPSIS
    Queries the persistent session participation graph index.

    .DESCRIPTION
    Read-only query API over the index built by Set-SessionGraph. Loads
    _index.json and applies filters (entity name, type, date range, tier)
    to produce four output modes:

    - Sessions:       for an entity, all sessions with participation details
    - CoParticipants: for an entity, all co-participating entities ranked
                      by shared session count
    - EntityTimeline: for a session header, all participants with
                      tier/source metadata
    - Summary:        global stats with tier coverage breakdown by format
                      generation

    Pipeline:
    1. Load _index.json via Read-SessionGraphIndex
    2. Apply date range filter across all index entries using
       Test-GraphEntryDateInRange (shared helper from session-graphhelpers)
    3. Dispatch to mode-specific logic:
       - Summary: aggregate FormatBreakdown and TierCounts across all entries
       - EntityTimeline: exact header match, list participants within tier
       - Sessions: scan all entries for EntityName match, collect full entries
       - CoParticipants: from Sessions results, build co-occurrence counts
         via Dictionary and sort descending by SharedSessions

    Sessions and CoParticipants modes require -EntityName. EntityTimeline
    requires -SessionHeader. Summary operates on the full filtered set.

    Returns empty array @() with a warning when the index does not exist
    or is empty, rather than throwing, so callers can handle gracefully.

    MinTier acts as an upper bound on participant tier: only participants
    with Tier <= MinTier are included. Tier 0 = filesystem evidence,
    Tier 1 = metadata, Tier 2 = body text mention.
#>

function Get-SessionGraph {
    <#
        .SYNOPSIS
        Queries the session participation graph for entity involvement and co-participation.
    #>

    [CmdletBinding()] param(
        [Parameter(Position = 0, HelpMessage = "Entity name to look up")]
        [string]$EntityName,

        [Parameter(HelpMessage = "Filter by entity type(s)")]
        [string[]]$EntityType,

        [Parameter(HelpMessage = "Look up a specific session by header")]
        [string]$SessionHeader,

        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Maximum tier to include (0=filesystem only, 1=+metadata, 2=+bodytext)")]
        [ValidateRange(0, 2)]
        [int]$MinTier = 2,

        [Parameter(HelpMessage = "Output mode")]
        [ValidateSet('Sessions', 'CoParticipants', 'EntityTimeline', 'Summary')]
        [string]$Mode = 'Sessions',

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Lazy-load helpers to avoid import overhead when called from modules that already loaded them
    if (-not (Get-Command 'Read-SessionGraphIndex' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/session-graphhelpers.ps1"
    }
    if (-not (Get-Command 'Get-AdminConfig' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/admin-config.ps1"
    }

    $Config = Get-AdminConfig
    $GraphDir = [System.IO.Path]::Combine($Config.ResDir, 'session-graph')
    $IndexPath = [System.IO.Path]::Combine($GraphDir, '_index.json')

    if (-not [System.IO.File]::Exists($IndexPath)) {
        Write-RobotWarning "[WARN Get-SessionGraph] Index not found at '$IndexPath'. Run Set-SessionGraph -Full first."
        return @()
    }

    $Index = Read-SessionGraphIndex -IndexPath $IndexPath
    if ($Index.Count -eq 0) {
        Write-RobotWarning "[WARN Get-SessionGraph] Index is empty."
        return @()
    }

    # Pre-filter all index entries by date range before mode dispatch
    $FilteredHeaders = [System.Collections.Generic.List[string]]::new()
    foreach ($Header in $Index.Keys) {
        $Entry = $Index[$Header]
        if (($MinDate -or $MaxDate) -and
            -not (Test-GraphEntryDateInRange -Entry $Entry -MinDate $MinDate -MaxDate $MaxDate)) { continue }
        [void]$FilteredHeaders.Add($Header)
    }

    # --- Summary mode ---
    if ($Mode -eq 'Summary') {
        $TotalSessions = $FilteredHeaders.Count
        $FormatCounts = @{}
        $TierCounts = @{ 0 = 0; 1 = 0; 2 = 0 }
        $TotalParticipants = 0

        foreach ($Header in $FilteredHeaders) {
            $Entry = $Index[$Header]
            $Format = if ($Entry.ContainsKey('Format') -and $Entry['Format']) { $Entry['Format'] } else { 'Unknown' }
            if (-not $FormatCounts.ContainsKey($Format)) { $FormatCounts[$Format] = 0 }
            $FormatCounts[$Format]++

            if ($Entry.ContainsKey('Participants') -and $Entry['Participants']) {
                foreach ($P in $Entry['Participants']) {
                    $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
                    if ($PTier -le $MinTier) {
                        $TotalParticipants++
                        if ($TierCounts.ContainsKey($PTier)) { $TierCounts[$PTier]++ }
                    }
                }
            }
        }

        return [PSCustomObject]@{
            TotalSessions     = $TotalSessions
            TotalParticipants = $TotalParticipants
            FormatBreakdown   = [PSCustomObject]$FormatCounts
            Tier0Count        = $TierCounts[0]
            Tier1Count        = $TierCounts[1]
            Tier2Count        = $TierCounts[2]
        }
    }

    # --- EntityTimeline mode ---
    if ($Mode -eq 'EntityTimeline') {
        if (-not $SessionHeader) {
            Write-RobotWarning "[WARN Get-SessionGraph] EntityTimeline mode requires -SessionHeader."
            return @()
        }

        $MatchedEntry = $null
        $MatchedHeader = $null
        foreach ($Header in $FilteredHeaders) {
            if ([string]::Equals($Header, $SessionHeader, [System.StringComparison]::OrdinalIgnoreCase)) {
                $MatchedEntry = $Index[$Header]
                $MatchedHeader = $Header
                break
            }
        }

        if (-not $MatchedEntry) {
            Write-RobotWarning "[WARN Get-SessionGraph] Session '$SessionHeader' not found in index."
            return @()
        }

        $Result = [System.Collections.Generic.List[object]]::new()
        if ($MatchedEntry.ContainsKey('Participants') -and $MatchedEntry['Participants']) {
            foreach ($P in $MatchedEntry['Participants']) {
                $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
                if ($PTier -gt $MinTier) { continue }
                $PType = if ($P.ContainsKey('Type')) { $P['Type'] } else { $null }
                if ($EntityType -and $PType -and $PType -notin $EntityType) { continue }

                $Result.Add([PSCustomObject]@{
                    Session = $MatchedHeader
                    Name    = $P['Name']
                    Type    = $PType
                    Tier    = $PTier
                    Source  = if ($P.ContainsKey('Source')) { $P['Source'] } else { $null }
                    Weight  = if ($P.ContainsKey('Weight')) { $P['Weight'] } else { $null }
                })
            }
        }

        return @($Result)
    }

    # --- Sessions and CoParticipants modes: both scan for EntityName matches ---
    if (-not $EntityName) {
        Write-RobotWarning "[WARN Get-SessionGraph] Sessions and CoParticipants modes require -EntityName."
        return @()
    }

    # Linear scan for EntityName across all filtered sessions (index is not keyed by participant)
    $MatchingSessions = [System.Collections.Generic.List[object]]::new()

    foreach ($Header in $FilteredHeaders) {
        $Entry = $Index[$Header]
        if (-not $Entry.ContainsKey('Participants') -or -not $Entry['Participants']) { continue }

        $EntityMatch = $null
        foreach ($P in $Entry['Participants']) {
            $PName = if ($P.ContainsKey('Name')) { $P['Name'] } else { $null }
            if (-not $PName) { continue }
            if (-not [string]::Equals($PName, $EntityName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
            if ($PTier -gt $MinTier) { continue }
            $EntityMatch = $P
            break
        }

        if (-not $EntityMatch) { continue }

        [void]$MatchingSessions.Add([PSCustomObject]@{
            Header       = $Header
            Date         = if ($Entry.ContainsKey('Date')) { $Entry['Date'] } else { $null }
            Format       = if ($Entry.ContainsKey('Format')) { $Entry['Format'] } else { $null }
            EntityTier   = if ($EntityMatch.ContainsKey('Tier')) { $EntityMatch['Tier'] } else { 2 }
            EntitySource = if ($EntityMatch.ContainsKey('Source')) { $EntityMatch['Source'] } else { $null }
            EntityWeight = if ($EntityMatch.ContainsKey('Weight')) { $EntityMatch['Weight'] } else { $null }
            Participants = $Entry['Participants']
            FilePaths    = if ($Entry.ContainsKey('FilePaths')) { $Entry['FilePaths'] } else { @() }
        })
    }

    if ($Mode -eq 'Sessions') {
        return @($MatchingSessions)
    }

    # --- CoParticipants mode ---
    # Accumulate co-occurrence counts from the matched sessions' participant lists
    $CoPartCounts = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($MS in $MatchingSessions) {
        if (-not $MS.Participants) { continue }
        foreach ($P in $MS.Participants) {
            $PName = if ($P.ContainsKey('Name')) { $P['Name'] } else { $null }
            if (-not $PName) { continue }
            if ([string]::Equals($PName, $EntityName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
            if ($PTier -gt $MinTier) { continue }
            $PType = if ($P.ContainsKey('Type')) { $P['Type'] } else { $null }
            if ($EntityType -and $PType -and $PType -notin $EntityType) { continue }

            if ($CoPartCounts.ContainsKey($PName)) {
                $CoPartCounts[$PName].SharedSessions++
            } else {
                $CoPartCounts[$PName] = [PSCustomObject]@{
                    Name           = $PName
                    Type           = $PType
                    SharedSessions = 1
                }
            }
        }
    }

    # Most frequently co-occurring entities first
    $CoPartList = [System.Collections.Generic.List[object]]::new($CoPartCounts.Values)
    $CoPartList.Sort([System.Comparison[object]]{
        param($A, $B)
        return $B.SharedSessions.CompareTo($A.SharedSessions)
    })

    return @($CoPartList)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

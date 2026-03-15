<#
    .SYNOPSIS
    Returns a session participation profile for a narrator.

    .DESCRIPTION
    Loads the session graph index built by Set-SessionGraph and filters
    sessions where the narrator matches the given name. Aggregates
    participant counts, entity type distribution, date range, and average
    party size into a single profile object.

    Pipeline:
    1. Load _index.json via Read-SessionGraphIndex
    2. Extract narrator from each session header's third comma-separated
       segment (### Date, Title, Narrator) using LastIndexOf for robustness
       when titles contain commas
    3. Apply date range and tier threshold filters
    4. Accumulate per-type participant counts via HashSet for unique names
       and Dictionary for type breakdown
    5. Compute average party size across matching sessions

    The function returns an empty profile (SessionCount=0) with a warning
    when the index file does not exist, rather than throwing, so callers
    can distinguish "no data" from "narrator not found" (SessionCount=0
    but no warning).

    Tier filtering uses MinTier as an upper bound: participants with
    Tier > MinTier are excluded. Default 2 includes all tiers.
#>

function Get-NarratorSessionProfile {
    <#
        .SYNOPSIS
        Returns a session participation profile for a specific narrator.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "Narrator name")]
        [string]$NarratorName,

        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Maximum tier to include (0-2)")]
        [ValidateRange(0, 2)]
        [int]$MinTier = 2,

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
        Write-RobotWarning "[WARN Get-NarratorSessionProfile] Index not found. Run Set-SessionGraph -Full first."
        return [PSCustomObject]@{
            NarratorName        = $NarratorName
            SessionCount        = 0
            DateFirst           = $null
            DateLast            = $null
            UniqueParticipants  = 0
            ParticipantsByType  = @{}
            AveragePartySize    = 0
            Sessions            = @()
        }
    }

    $Index = Read-SessionGraphIndex -IndexPath $IndexPath

    # Scan all index entries to find sessions narrated by $NarratorName
    $MatchingSessions = [System.Collections.Generic.List[object]]::new()
    $AllParticipantNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $TypeCounts = @{}
    $TotalParticipants = 0
    $Dates = [System.Collections.Generic.List[datetime]]::new()

    foreach ($Header in $Index.Keys) {
        $Entry = $Index[$Header]

        # Extract narrator from the last comma-separated segment of the header
        $HeaderNarrator = $null
        $CommaIdx = $Header.LastIndexOf(',')
        if ($CommaIdx -ge 0) {
            $HeaderNarrator = $Header.Substring($CommaIdx + 1).Trim()
        }

        if (-not $HeaderNarrator) { continue }
        if (-not [string]::Equals($HeaderNarrator, $NarratorName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        # Date filter applied before accumulation to avoid counting out-of-range sessions
        $SessionDate = ConvertFrom-GraphEntryDate -Entry $Entry
        if ($MinDate -and ($null -eq $SessionDate -or $SessionDate -lt $MinDate)) { continue }
        if ($MaxDate -and ($null -eq $SessionDate -or $SessionDate -gt $MaxDate)) { continue }

        if ($SessionDate) { [void]$Dates.Add($SessionDate) }

        # Accumulate participant stats, filtering by tier threshold
        $SessionParticipantCount = 0
        if ($Entry.ContainsKey('Participants') -and $Entry['Participants']) {
            foreach ($P in $Entry['Participants']) {
                $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
                if ($PTier -gt $MinTier) { continue }
                $PName = if ($P.ContainsKey('Name')) { $P['Name'] } else { $null }
                $PType = if ($P.ContainsKey('Type')) { $P['Type'] } else { 'Nieznany' }

                if ($PName) {
                    [void]$AllParticipantNames.Add($PName)
                    $SessionParticipantCount++
                    $TotalParticipants++

                    if (-not $TypeCounts.ContainsKey($PType)) { $TypeCounts[$PType] = 0 }
                    $TypeCounts[$PType]++
                }
            }
        }

        $MatchingSessions.Add([PSCustomObject]@{
            Header           = $Header
            Date             = if ($SessionDate) { $SessionDate.ToString('yyyy-MM-dd') } else { $null }
            ParticipantCount = $SessionParticipantCount
        })
    }

    $Dates.Sort()
    $DateFirst = if ($Dates.Count -gt 0) { $Dates[0].ToString('yyyy-MM-dd') } else { $null }
    $DateLast  = if ($Dates.Count -gt 0) { $Dates[$Dates.Count - 1].ToString('yyyy-MM-dd') } else { $null }

    $AvgPartySize = if ($MatchingSessions.Count -gt 0) {
        [math]::Round($TotalParticipants / $MatchingSessions.Count, 1)
    } else { 0 }

    # Chronological ordering for presentation
    $SortedSessions = @($MatchingSessions | Sort-Object { $_.Date })

    return [PSCustomObject]@{
        NarratorName        = $NarratorName
        SessionCount        = $MatchingSessions.Count
        DateFirst           = $DateFirst
        DateLast            = $DateLast
        UniqueParticipants  = $AllParticipantNames.Count
        ParticipantsByType  = $TypeCounts
        AveragePartySize    = $AvgPartySize
        Sessions            = $SortedSessions
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

<#
    .SYNOPSIS
    Returns a session participation profile for a narrator.

    .DESCRIPTION
    Loads the session graph index and filters sessions where the narrator
    matches the given name (parsed from the session header). Aggregates
    participant counts, entity type distribution, date range, and average
    party size.

    Narrator matching uses OrdinalIgnoreCase comparison against the third
    comma-separated segment of the session header (### Date, Title, Narrator).
#>

function Get-NarratorSessionProfile {
    <#
        .SYNOPSIS
        Returns session statistics for a narrator.
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

    # Load helpers
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

    # Parse narrator from session header (### YYYY-MM-DD, Title, Narrator)
    $MatchingSessions = [System.Collections.Generic.List[object]]::new()
    $AllParticipantNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $TypeCounts = @{}
    $TotalParticipants = 0
    $Dates = [System.Collections.Generic.List[datetime]]::new()

    foreach ($Header in $Index.Keys) {
        $Entry = $Index[$Header]

        # Parse narrator from header
        $HeaderNarrator = $null
        $CommaIdx = $Header.LastIndexOf(',')
        if ($CommaIdx -ge 0) {
            $HeaderNarrator = $Header.Substring($CommaIdx + 1).Trim()
        }

        if (-not $HeaderNarrator) { continue }
        if (-not [string]::Equals($HeaderNarrator, $NarratorName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        # Date filter
        $SessionDate = $null
        if ($Entry.ContainsKey('Date') -and $Entry['Date']) {
            [datetime]$Parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($Entry['Date'], 'yyyy-MM-dd',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$Parsed)) {
                $SessionDate = $Parsed
            }
        }

        if ($MinDate -and ($null -eq $SessionDate -or $SessionDate -lt $MinDate)) { continue }
        if ($MaxDate -and ($null -eq $SessionDate -or $SessionDate -gt $MaxDate)) { continue }

        if ($SessionDate) { [void]$Dates.Add($SessionDate) }

        # Count participants (within tier threshold)
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

    # Sort sessions by date
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

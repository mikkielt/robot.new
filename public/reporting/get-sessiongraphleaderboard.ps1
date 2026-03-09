<#
    .SYNOPSIS
    Returns entities ranked by session participation count.

    .DESCRIPTION
    Loads the session graph index and counts sessions per participant entity,
    returning a ranked leaderboard. Supports filtering by entity type and
    tier threshold.
#>

function Get-SessionGraphLeaderboard {
    <#
        .SYNOPSIS
        Returns entities ranked by session participation count.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by entity type (e.g. Postać, NPC, Lokacja, Grupa)")]
        [string]$EntityType,

        [Parameter(HelpMessage = "Number of top entries to return")]
        [int]$Top = 20,

        [Parameter(HelpMessage = "Maximum tier to include (0-2)")]
        [ValidateRange(0, 2)]
        [int]$MinTier = 2,

        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate,

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
        Write-RobotWarning "[WARN Get-SessionGraphLeaderboard] Index not found. Run Set-SessionGraph -Full first."
        return @()
    }

    $Index = Read-SessionGraphIndex -IndexPath $IndexPath

    # Accumulate per-entity session counts and tier breakdown
    $EntityStats = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Header in $Index.Keys) {
        $Entry = $Index[$Header]

        # Date filter
        if ($MinDate -or $MaxDate) {
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
        }

        if (-not $Entry.ContainsKey('Participants') -or -not $Entry['Participants']) { continue }

        foreach ($P in $Entry['Participants']) {
            $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
            if ($PTier -gt $MinTier) { continue }

            $PName = if ($P.ContainsKey('Name')) { $P['Name'] } else { $null }
            $PType = if ($P.ContainsKey('Type')) { $P['Type'] } else { $null }
            if (-not $PName) { continue }
            if ($EntityType -and $PType -and -not [string]::Equals($PType, $EntityType, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            if ($EntityStats.ContainsKey($PName)) {
                $Stats = $EntityStats[$PName]
                $Stats.SessionCount++
                $TierKey = "Tier$PTier"
                if ($Stats.TierBreakdown.ContainsKey($TierKey)) { $Stats.TierBreakdown[$TierKey]++ }
            } else {
                $EntityStats[$PName] = [PSCustomObject]@{
                    Name          = $PName
                    Type          = $PType
                    SessionCount  = 1
                    TierBreakdown = @{ Tier0 = 0; Tier1 = 0; Tier2 = 0 }
                }
                $TierKey = "Tier$PTier"
                $EntityStats[$PName].TierBreakdown[$TierKey] = 1
            }
        }
    }

    # Sort by session count descending, take top N
    $Sorted = [System.Collections.Generic.List[object]]::new($EntityStats.Values)
    $Sorted.Sort([System.Comparison[object]]{
        param($A, $B)
        return $B.SessionCount.CompareTo($A.SessionCount)
    })

    $ResultCount = [Math]::Min($Top, $Sorted.Count)
    $Result = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $ResultCount; $i++) {
        $Entry = $Sorted[$i]
        $Result.Add([PSCustomObject]@{
            Rank          = $i + 1
            Name          = $Entry.Name
            Type          = $Entry.Type
            SessionCount  = $Entry.SessionCount
            Tier0         = $Entry.TierBreakdown['Tier0']
            Tier1         = $Entry.TierBreakdown['Tier1']
            Tier2         = $Entry.TierBreakdown['Tier2']
        })
    }

    return @($Result)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

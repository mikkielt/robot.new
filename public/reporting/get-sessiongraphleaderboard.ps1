<#
    .SYNOPSIS
    Returns entities ranked by session participation count.

    .DESCRIPTION
    Loads the session graph index built by Set-SessionGraph and counts
    sessions per participant entity, returning a ranked leaderboard with
    tier breakdown. Supports filtering by entity type, tier threshold,
    and date range.

    Pipeline:
    1. Load _index.json via Read-SessionGraphIndex
    2. Iterate all index entries, applying date range filter via
       Test-GraphEntryDateInRange
    3. For each participant within the tier threshold, accumulate session
       count and per-tier breakdown in a Dictionary keyed by entity name
       (OrdinalIgnoreCase)
    4. Sort by SessionCount descending and take top N entries
    5. Assign sequential Rank (1-based) to each result

    The tier breakdown (Tier0/Tier1/Tier2) shows the evidence quality
    distribution: Tier 0 = filesystem (file path contains entity name),
    Tier 1 = metadata (@Lokacje, @PU), Tier 2 = body text mention.
    This helps distinguish entities with strong structural evidence from
    those that only appear in narrative text.
#>

function Get-SessionGraphLeaderboard {
    <#
        .SYNOPSIS
        Returns a ranked leaderboard of entities by session participation count.
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
        Write-RobotWarning "[WARN Get-SessionGraphLeaderboard] Index not found. Run Set-SessionGraph -Full first."
        return @()
    }

    $Index = Read-SessionGraphIndex -IndexPath $IndexPath

    # Single-pass accumulation: one dictionary entry per unique entity name
    $EntityStats = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Header in $Index.Keys) {
        $Entry = $Index[$Header]

        # Skip sessions outside the requested date range
        if (($MinDate -or $MaxDate) -and
            -not (Test-GraphEntryDateInRange -Entry $Entry -MinDate $MinDate -MaxDate $MaxDate)) { continue }

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

    # Rank by participation frequency, truncate to requested leaderboard size
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

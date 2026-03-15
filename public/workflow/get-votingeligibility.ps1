<#
    .SYNOPSIS
    Voting eligibility assessment based on historical PU assignment runs.

    .DESCRIPTION
    This file contains Get-VotingEligibility — a read-only function that
    determines player voting eligibility by replaying PU computation over
    actual PU assignment runs recorded in pu-sessions.md.

    Unlike the legacy Get-ElectionPlayerList which used raw session dates
    for its 6-month window, this function scopes activity to the actual
    PU assignment process by:
    1. Parsing pu-sessions.md processing timestamps to identify runs.
    2. Filtering to runs whose processing date falls within the lookback.
    3. Grouping runs by calendar month and merging into monthly batches.
    4. Deriving the narrowest date range from session headers to minimize
       Get-Session file scanning scope (avoid full-repo scan).
    5. Fetching session objects matching the recorded headers.
    6. Building a character lookup (including aliases) for PU-to-player mapping.
    7. Replaying the PU computation algorithm month-by-month with overflow
       pool tracking across months (same cap/overflow logic as
       Invoke-PlayerCharacterPUAssignment).
    8. Aggregating GrantedPU per player across all characters and months.

    This ensures the eligibility window matches what was actually processed
    by the PU assignment workflow, not an approximation based on session dates.

    Output is sorted with eligible players first (for quick visual scan in
    CLI and reports), then alphabetically within each group.

    Module-level data:
    - $script:HistorySessionPattern: precompiled regex for "    - ### header" lines
    - $script:SessionHeaderDatePattern: precompiled regex for YYYY-MM-DD prefix extraction
    - $script:AdminHistoryTimestampPattern: canonical definition in admin-state.ps1
#>

. "$script:ModuleRoot/private/admin-state.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

# $script:AdminHistoryTimestampPattern — canonical definition in private/admin-state.ps1
# (loaded via the dot-source above)

# Precompiled pattern for session header lines: "    - ### header"
$script:HistorySessionPattern = [regex]::new(
    '^\s+-\s+###\s+(.+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Precompiled pattern for extracting date from session header: "YYYY-MM-DD, ..."
$script:SessionHeaderDatePattern = [regex]::new(
    '^(\d{4}-\d{2}-\d{2})',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

function Get-VotingEligibility {
    <#
        .SYNOPSIS
        Determines player voting eligibility based on PU earned in recent
        assignment runs.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Number of months to look back for PU assignment runs (default: 6)")]
        [int]$Months = 6,

        [Parameter(HelpMessage = "Minimum PU required for voting eligibility (default: 3.0)")]
        [decimal]$MinimumPU = [decimal]3.0,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-AdminConfig

    # --- 1. Parse pu-sessions.md into timestamped run blocks ---
    # Each block starts with a timestamp line and contains indented session headers.

    $PUSessionsPath = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.md')

    if (-not [System.IO.File]::Exists($PUSessionsPath)) {
        Write-RobotInfo "[INFO Get-VotingEligibility] No pu-sessions.md found at '$PUSessionsPath'"
        return @()
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($PUSessionsPath, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $Runs = [System.Collections.Generic.List[object]]::new()
    $CurrentTimestamp = $null
    $CurrentHeaders = $null

    foreach ($Line in $Lines) {
        $TsMatch = $script:AdminHistoryTimestampPattern.Match($Line)
        if ($TsMatch.Success) {
            if ($null -ne $CurrentTimestamp -and $CurrentHeaders.Count -gt 0) {
                [void]$Runs.Add([PSCustomObject]@{
                    Timestamp = $CurrentTimestamp
                    Headers   = $CurrentHeaders
                })
            }

            $DateStr = $TsMatch.Groups[1].Value
            $CurrentTimestamp = [datetime]::ParseExact(
                $DateStr, 'yyyy-MM-dd HH:mm',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $CurrentHeaders = [System.Collections.Generic.List[string]]::new()
            continue
        }

        $HeaderMatch = $script:HistorySessionPattern.Match($Line)
        if ($HeaderMatch.Success -and $null -ne $CurrentHeaders) {
            $Header = $HeaderMatch.Groups[1].Value.Trim()
            if ($Header.Length -gt 0) {
                [void]$CurrentHeaders.Add($Header)
            }
        }
    }

    # Flush last block
    if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders -and $CurrentHeaders.Count -gt 0) {
        [void]$Runs.Add([PSCustomObject]@{
            Timestamp = $CurrentTimestamp
            Headers   = $CurrentHeaders
        })
    }

    if ($Runs.Count -eq 0) {
        Write-RobotInfo "[INFO Get-VotingEligibility] No PU assignment runs found in pu-sessions.md"
        return @()
    }

    # 2. Scope to lookback window by processing timestamp (not session date)
    #    so eligibility reflects when PU was actually awarded, not when the session happened

    $Now = [datetime]::Now
    $CutoffDate = [datetime]::new($Now.AddMonths(-$Months).Year, $Now.AddMonths(-$Months).Month, 1)

    $FilteredRuns = [System.Collections.Generic.List[object]]::new()
    foreach ($Run in $Runs) {
        if ($Run.Timestamp -ge $CutoffDate) {
            [void]$FilteredRuns.Add($Run)
        }
    }

    if ($FilteredRuns.Count -eq 0) {
        Write-RobotInfo "[INFO Get-VotingEligibility] No PU assignment runs found in the last $Months months"
        return @()
    }

    # 3. Group by calendar month — the 5 PU/month cap must apply per-month
    #    to match the production Invoke-PlayerCharacterPUAssignment behavior

    $MonthBatches = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($Run in $FilteredRuns) {
        $MonthKey = $Run.Timestamp.ToString('yyyy-MM')
        if (-not $MonthBatches.ContainsKey($MonthKey)) {
            $MonthBatches[$MonthKey] = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        }
        foreach ($Header in $Run.Headers) {
            [void]$MonthBatches[$MonthKey].Add($Header)
        }
    }

    # Overflow pool carries forward across months, so chronological order is required
    $SortedMonths = [System.Collections.Generic.List[string]]::new($MonthBatches.Keys)
    $SortedMonths.Sort([System.StringComparer]::Ordinal)

    # 4. Derive the narrowest date range covering all referenced sessions
    #    to constrain Get-Session's file scanning (avoid full-repo scan)

    $AllHeaders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $MinSessionDate = [datetime]::MaxValue
    $MaxSessionDate = [datetime]::MinValue

    foreach ($MonthKey in $SortedMonths) {
        foreach ($Header in $MonthBatches[$MonthKey]) {
            [void]$AllHeaders.Add($Header)
            $DateMatch = $script:SessionHeaderDatePattern.Match($Header)
            if ($DateMatch.Success) {
                $SessionDate = [datetime]::ParseExact(
                    $DateMatch.Groups[1].Value, 'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
                if ($SessionDate -lt $MinSessionDate) { $MinSessionDate = $SessionDate }
                if ($SessionDate -gt $MaxSessionDate) { $MaxSessionDate = $SessionDate }
            }
        }
    }

    if ($MinSessionDate -eq [datetime]::MaxValue) {
        Write-RobotInfo "[INFO Get-VotingEligibility] Could not determine session date range from headers"
        return @()
    }

    # 5. Fetch session objects for the derived date range

    $Sessions = Get-Session -MinDate $MinSessionDate -MaxDate $MaxSessionDate -Unique

    # Index by header (stripped of "### " prefix) for O(1) lookup per PU run
    $SessionLookup = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($Session in $Sessions) {
        if ($Session.PU -and $Session.PU.Count -gt 0) {
            $NormalizedHeader = $Session.Header.Trim()
            if ($NormalizedHeader.StartsWith('### ')) {
                $NormalizedHeader = $NormalizedHeader.Substring(4)
            }
            if (-not $SessionLookup.ContainsKey($NormalizedHeader)) {
                $SessionLookup[$NormalizedHeader] = $Session
            }
        }
    }

    # 6. Build character lookup (including aliases) for PU entry -> player mapping
    #    Aliases are needed because PU entries may use any known name variant

    $AllCharacters = Get-PlayerCharacter
    $CharacterLookup = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($Char in $AllCharacters) {
        if (-not $CharacterLookup.ContainsKey($Char.Name)) {
            $CharacterLookup[$Char.Name] = $Char
        }
        if ($Char.Aliases) {
            foreach ($Alias in $Char.Aliases) {
                if (-not [string]::IsNullOrWhiteSpace($Alias) -and -not $CharacterLookup.ContainsKey($Alias)) {
                    $CharacterLookup[$Alias] = $Char
                }
            }
        }
    }

    # 7. Replay PU computation month-by-month, mirroring
    #    Invoke-PlayerCharacterPUAssignment's algorithm for accuracy

    # Overflow pool per character: excess PU above the 5/month cap carries forward
    $OverflowPool = [System.Collections.Generic.Dictionary[string, decimal]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Accumulates GrantedPU per player across all characters and months
    $PlayerPU = [System.Collections.Generic.Dictionary[string, decimal]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Keep one character ref per player to extract MargonemID for the output
    $PlayerCharacterMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($MonthKey in $SortedMonths) {
        $MonthHeaders = $MonthBatches[$MonthKey]

        # Aggregate PU entries per character for this month's sessions
        $PUByCharacter = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[decimal]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($Header in $MonthHeaders) {
            $Session = $null
            if (-not $SessionLookup.TryGetValue($Header, [ref]$Session)) { continue }

            foreach ($PUEntry in $Session.PU) {
                if ($null -eq $PUEntry.Value) { continue }

                $CharName = $PUEntry.Character
                # Resolve alias to canonical name for consistent aggregation
                $Character = $null
                if ($CharacterLookup.TryGetValue($CharName, [ref]$Character)) {
                    $CanonicalName = $Character.Name
                } else {
                    # Unresolved character — skip silently (historical data may reference deleted characters)
                    continue
                }

                if (-not $PUByCharacter.ContainsKey($CanonicalName)) {
                    $PUByCharacter[$CanonicalName] = [System.Collections.Generic.List[decimal]]::new()
                }
                [void]$PUByCharacter[$CanonicalName].Add([decimal]$PUEntry.Value)

                # Track player -> character mapping for MargonemID output
                if (-not $PlayerCharacterMap.ContainsKey($Character.PlayerName)) {
                    $PlayerCharacterMap[$Character.PlayerName] = $Character
                }
            }
        }

        # Apply PU algorithm per character: BasePU = 1 + sum, capped at 5, with overflow pool
        foreach ($Entry in $PUByCharacter.GetEnumerator()) {
            $CanonicalName = $Entry.Key
            $PUValues = $Entry.Value
            $Character = $CharacterLookup[$CanonicalName]

            $SessionPUSum = [decimal]0
            foreach ($Val in $PUValues) {
                $SessionPUSum += $Val
            }

            $BasePU = [decimal]1 + $SessionPUSum  # base participation bonus of 1

            $OriginalPUExceeded = [decimal]0
            if ($OverflowPool.ContainsKey($CanonicalName)) {
                $OriginalPUExceeded = $OverflowPool[$CanonicalName]
            }

            $UsedExceeded = [decimal]0
            $OverflowPU = [decimal]0

            if ($BasePU -le 5 -and $OriginalPUExceeded -gt 0) {
                $UsedExceeded = [math]::Min(5 - $BasePU, $OriginalPUExceeded)
            }

            if ($BasePU -gt 5) {
                $OverflowPU = $BasePU - 5
            }

            $GrantedPU = [math]::Min($BasePU + $UsedExceeded, [decimal]5)  # 5 PU/month cap
            $RemainingPUExceeded = ($OriginalPUExceeded - $UsedExceeded) + $OverflowPU
            $OverflowPool[$CanonicalName] = [math]::Max([decimal]0, $RemainingPUExceeded)

            # Accumulate across characters — one player may have multiple characters
            $PlayerName = $Character.PlayerName
            if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
                if (-not $PlayerPU.ContainsKey($PlayerName)) {
                    $PlayerPU[$PlayerName] = [decimal]0
                }
                $PlayerPU[$PlayerName] += $GrantedPU
            }
        }
    }

    # 8. Build output — eligible players first for quick visual scan

    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in $PlayerPU.GetEnumerator()) {
        $PlayerName = $Entry.Key
        $TotalPU = [math]::Round($Entry.Value, 2)

        $MargonemID = $null
        if ($PlayerCharacterMap.ContainsKey($PlayerName)) {
            $MargonemID = $PlayerCharacterMap[$PlayerName].Player.MargonemID
        }

        [void]$Results.Add([PSCustomObject]@{
            PlayerName     = $PlayerName
            PU             = $TotalPU
            VotingEligible = $TotalPU -ge $MinimumPU
            MargonemID     = $MargonemID
        })
    }

    # Partition and sort: eligible first, then ineligible, alphabetical within each
    $Sorted = [System.Collections.Generic.List[object]]::new()
    $Eligible = [System.Collections.Generic.List[object]]::new()
    $Ineligible = [System.Collections.Generic.List[object]]::new()

    foreach ($Item in $Results) {
        if ($Item.VotingEligible) { [void]$Eligible.Add($Item) }
        else { [void]$Ineligible.Add($Item) }
    }

    $EligibleSorted = $Eligible | Sort-Object -Property PlayerName
    $IneligibleSorted = $Ineligible | Sort-Object -Property PlayerName

    foreach ($Item in $EligibleSorted) { [void]$Sorted.Add($Item) }
    foreach ($Item in $IneligibleSorted) { [void]$Sorted.Add($Item) }

    return $Sorted

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

<#
    .SYNOPSIS
    Voting eligibility assessment based on historical PU assignment runs.

    .DESCRIPTION
    This file contains Get-VotingEligibility - a read-only function that
    determines player voting eligibility by replaying PU computation over
    actual PU assignment runs recorded in pu-sessions.md.

    Unlike the legacy Get-ElectionPlayerList which used raw session dates
    for its 6-month window, this function scopes activity to the actual
    PU assignment process by:
    1. Parsing pu-sessions.md processing timestamps to identify runs.
    2. Filtering to runs whose processing date falls within the lookback.
    3. Grouping runs by calendar month and merging into monthly batches.
    4. Fetching session objects matching the recorded headers.
    5. Replaying the PU computation algorithm month-by-month with overflow
       pool tracking across months.
    6. Aggregating GrantedPU per player across all characters and months.

    This ensures the eligibility window matches what was actually processed
    by the PU assignment workflow, not an approximation based on session
    dates.

    Dot-sources admin-state.ps1 and admin-config.ps1 for state file
    handling and config resolution.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/admin-state.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

# Precompiled pattern for pu-sessions.md timestamp lines: "- YYYY-MM-dd HH:mm (timezone):"
$script:HistoryTimestampPattern = [regex]::new(
    '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+\(([^)]+)\)\s*:\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

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
        [decimal]$MinimumPU = [decimal]3.0
    )

    $Config = Get-AdminConfig

    # --- 1. Parse pu-sessions.md into timestamped run blocks ---

    $PUSessionsPath = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.md')

    if (-not [System.IO.File]::Exists($PUSessionsPath)) {
        [System.Console]::Error.WriteLine("[INFO Get-VotingEligibility] No pu-sessions.md found at '$PUSessionsPath'")
        return @()
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($PUSessionsPath, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    # Each run block: timestamp + list of session headers
    $Runs = [System.Collections.Generic.List[object]]::new()
    $CurrentTimestamp = $null
    $CurrentHeaders = $null

    foreach ($Line in $Lines) {
        $TsMatch = $script:HistoryTimestampPattern.Match($Line)
        if ($TsMatch.Success) {
            # Save previous block if any
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
        [System.Console]::Error.WriteLine("[INFO Get-VotingEligibility] No PU assignment runs found in pu-sessions.md")
        return @()
    }

    # 2. Filter runs to last N months by processing timestamp

    $Now = [datetime]::Now
    $CutoffDate = [datetime]::new($Now.AddMonths(-$Months).Year, $Now.AddMonths(-$Months).Month, 1)

    $FilteredRuns = [System.Collections.Generic.List[object]]::new()
    foreach ($Run in $Runs) {
        if ($Run.Timestamp -ge $CutoffDate) {
            [void]$FilteredRuns.Add($Run)
        }
    }

    if ($FilteredRuns.Count -eq 0) {
        [System.Console]::Error.WriteLine("[INFO Get-VotingEligibility] No PU assignment runs found in the last $Months months")
        return @()
    }

    # 3. Group runs by calendar month and merge headers

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

    # Sort months chronologically for sequential overflow tracking
    $SortedMonths = [System.Collections.Generic.List[string]]::new($MonthBatches.Keys)
    $SortedMonths.Sort([System.StringComparer]::Ordinal)

    # 4. Collect all unique headers and determine session date range

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
        [System.Console]::Error.WriteLine("[INFO Get-VotingEligibility] Could not determine session date range from headers")
        return @()
    }

    # 5. Fetch session objects via Get-Session and filter to matching headers

    $Sessions = Get-Session -MinDate $MinSessionDate -MaxDate $MaxSessionDate -Unique

    # Build header → session lookup
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

    # 6. Resolve characters

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

    # 7. Replay PU computation month-by-month with overflow tracking

    # Overflow pool per character (by canonical name), starts at 0
    $OverflowPool = [System.Collections.Generic.Dictionary[string, decimal]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Accumulate GrantedPU per player across all months
    $PlayerPU = [System.Collections.Generic.Dictionary[string, decimal]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Track which players have been seen (for MargonemID lookup later)
    $PlayerCharacterMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($MonthKey in $SortedMonths) {
        $MonthHeaders = $MonthBatches[$MonthKey]

        # Collect PU entries for this month's sessions
        $PUByCharacter = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[decimal]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($Header in $MonthHeaders) {
            $Session = $null
            if (-not $SessionLookup.TryGetValue($Header, [ref]$Session)) { continue }

            foreach ($PUEntry in $Session.PU) {
                if ($null -eq $PUEntry.Value) { continue }

                $CharName = $PUEntry.Character
                # Resolve to canonical name
                $Character = $null
                if ($CharacterLookup.TryGetValue($CharName, [ref]$Character)) {
                    $CanonicalName = $Character.Name
                } else {
                    # Unresolved character - skip silently for election purposes
                    continue
                }

                if (-not $PUByCharacter.ContainsKey($CanonicalName)) {
                    $PUByCharacter[$CanonicalName] = [System.Collections.Generic.List[decimal]]::new()
                }
                [void]$PUByCharacter[$CanonicalName].Add([decimal]$PUEntry.Value)

                # Track player for later
                if (-not $PlayerCharacterMap.ContainsKey($Character.PlayerName)) {
                    $PlayerCharacterMap[$Character.PlayerName] = $Character
                }
            }
        }

        # Compute PU for each character this month
        foreach ($Entry in $PUByCharacter.GetEnumerator()) {
            $CanonicalName = $Entry.Key
            $PUValues = $Entry.Value
            $Character = $CharacterLookup[$CanonicalName]

            # Sum session PU values
            $SessionPUSum = [decimal]0
            foreach ($Val in $PUValues) {
                $SessionPUSum += $Val
            }

            # PU calculation (same algorithm as Invoke-PlayerCharacterPUAssignment)
            $BasePU = [decimal]1 + $SessionPUSum

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

            $GrantedPU = [math]::Min($BasePU + $UsedExceeded, [decimal]5)
            $RemainingPUExceeded = ($OriginalPUExceeded - $UsedExceeded) + $OverflowPU

            # Update overflow pool for next month
            $OverflowPool[$CanonicalName] = [math]::Max([decimal]0, $RemainingPUExceeded)

            # Accumulate GrantedPU for the player
            $PlayerName = $Character.PlayerName
            if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
                if (-not $PlayerPU.ContainsKey($PlayerName)) {
                    $PlayerPU[$PlayerName] = [decimal]0
                }
                $PlayerPU[$PlayerName] += $GrantedPU
            }
        }
    }

    # 8. Build output

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

    # Sort: eligible first, then by player name
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
}

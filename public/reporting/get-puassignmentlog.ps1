<#
    .SYNOPSIS
    Parses the PU assignment state file into structured processing history.

    .DESCRIPTION
    Reads the append-only pu-sessions.md state file and returns structured
    objects showing when PU was processed and which sessions were included
    in each run.

    Module-level data:
    - $script:AdminHistoryTimestampPattern: precompiled regex from admin-state.ps1
      that matches timestamp header lines in the state file
    - $script:HistoryEntryPattern: precompiled regex from admin-state.ps1 that
      matches session header entries under each timestamp
    - $script:MultiSpacePattern: precompiled regex from admin-state.ps1 for
      normalizing multiple consecutive spaces in header text

    Pipeline:
    1. Read pu-sessions.md as raw text (UTF-8 no BOM) and split into lines
    2. Stream-parse lines: timestamp headers start new entries, indented
       lines with list markers are session headers belonging to the current entry
    3. Parse each session header into structured Date/Title/Narrator fields
       by splitting on comma separators
    4. Apply ProcessedAt date range filters (MinDate/MaxDate)
    5. Sort descending by ProcessedAt (most recent first) for display

    The state file is append-only: each PU assignment run appends a timestamp
    header followed by the session headers that were processed. This function
    reconstructs the full history by scanning all entries.
#>

. "$script:ModuleRoot/private/admin-state.ps1"

# $script:AdminHistoryTimestampPattern — canonical definition in private/admin-state.ps1
# (loaded via the dot-source above)

function Get-PUAssignmentLog {
    <#
        .SYNOPSIS
        Returns structured PU assignment processing history from the state file.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Path to the PU sessions state file")]
        [string]$Path,

        [Parameter(HelpMessage = "Include only runs on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only runs on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $Path) {
        $Config = Get-AdminConfig
        $Path = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.md')
    }

    if (-not [System.IO.File]::Exists($Path)) {
        Write-RobotWarning "[WARN Get-PUAssignmentLog] State file not found: '$Path'"
        return @()
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($Path, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $Entries = [System.Collections.Generic.List[object]]::new()
    $CurrentTimestamp = $null
    $CurrentTimezone = $null
    $CurrentHeaders = $null

    foreach ($Line in $Lines) {
        # Timestamp lines delimit PU processing runs in the state file
        $TsMatch = $script:AdminHistoryTimestampPattern.Match($Line)
        if ($TsMatch.Success) {
            # Emit completed entry before starting a new one
            if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders) {
                $Entries.Add([PSCustomObject]@{
                    ProcessedAt  = $CurrentTimestamp
                    Timezone     = $CurrentTimezone
                    SessionCount = $CurrentHeaders.Count
                    Sessions     = @($CurrentHeaders)
                })
            }

            # Start a new processing run entry
            $TsStr = $TsMatch.Groups[1].Value
            $CurrentTimezone = $TsMatch.Groups[2].Value
            $CurrentTimestamp = [datetime]::ParseExact($TsStr, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $CurrentHeaders = [System.Collections.Generic.List[object]]::new()
            continue
        }

        # Session header lines are indented list items under the current timestamp
        $HdrMatch = $script:HistoryEntryPattern.Match($Line)
        if ($HdrMatch.Success -and $null -ne $CurrentHeaders) {
            $Header = $HdrMatch.Groups[1].Value.Trim()
            $Header = $script:MultiSpacePattern.Replace($Header, ' ')

            if ($Header.Length -eq 0) { continue }

            # Decompose header into Date/Title/Narrator components
            $Parts = $Header.Split(',')
            $SessionDate = $null
            $SessionTitle = $null
            $SessionNarrator = $null

            if ($Parts.Count -ge 1) {
                $DateStr = $Parts[0].Trim()
                try { $SessionDate = [datetime]::ParseExact($DateStr, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
            }
            if ($Parts.Count -ge 2) {
                $SessionTitle = $Parts[1].Trim()
            }
            if ($Parts.Count -ge 3) {
                $SessionNarrator = $Parts[2].Trim()
            }

            $CurrentHeaders.Add([PSCustomObject]@{
                Header   = $Header
                Date     = $SessionDate
                Title    = $SessionTitle
                Narrator = $SessionNarrator
            })
        }
    }

    # Flush last entry
    if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders) {
        $Entries.Add([PSCustomObject]@{
            ProcessedAt  = $CurrentTimestamp
            Timezone     = $CurrentTimezone
            SessionCount = $CurrentHeaders.Count
            Sessions     = @($CurrentHeaders)
        })
    }

    # Post-parse filtering on the processing timestamp (not session dates)
    if ($MinDate -or $MaxDate) {
        $Filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($Entry in $Entries) {
            if ($MinDate -and $Entry.ProcessedAt -lt $MinDate) { continue }
            if ($MaxDate -and $Entry.ProcessedAt -gt $MaxDate) { continue }
            $Filtered.Add($Entry)
        }
        $Entries = $Filtered
    }

    # Most recent runs first for typical "what happened last?" queries
    $Entries.Sort([System.Comparison[object]]{
        param($a, $b)
        return $b.ProcessedAt.CompareTo($a.ProcessedAt)
    })

    return @($Entries)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

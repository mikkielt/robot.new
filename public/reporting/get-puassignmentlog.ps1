<#
    .SYNOPSIS
    Parses the PU assignment state file into structured processing history.

    .DESCRIPTION
    Reads the append-only pu-sessions.md state file and returns structured objects
    showing when PU was processed and which sessions were included in each run.
    Each entry contains the processing timestamp and the list of session headers.

    Dot-sources admin-state.ps1 for precompiled regex patterns.
#>

. "$script:ModuleRoot/private/admin-state.ps1"

# Precompiled pattern for timestamp lines: "- 2025-06-15 14:30 (UTC+01:00):"
$script:TimestampLinePattern = [regex]::new(
    '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+\(([^)]+)\):\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

function Get-PUAssignmentLog {
    <#
        .SYNOPSIS
        View structured PU processing history from the state file.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Path to the PU sessions state file")]
        [string]$Path,

        [Parameter(HelpMessage = "Include only runs on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only runs on or before this date")]
        [datetime]$MaxDate
    )

    if (-not $Path) {
        $Path = Join-Path (Get-Location) '.robot/res/pu-sessions.md'
    }

    if (-not [System.IO.File]::Exists($Path)) {
        [System.Console]::Error.WriteLine("[WARN Get-PUAssignmentLog] State file not found: '$Path'")
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
        # Check for timestamp line
        $TsMatch = $script:TimestampLinePattern.Match($Line)
        if ($TsMatch.Success) {
            # Flush previous entry
            if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders) {
                $Entries.Add([PSCustomObject]@{
                    ProcessedAt  = $CurrentTimestamp
                    Timezone     = $CurrentTimezone
                    SessionCount = $CurrentHeaders.Count
                    Sessions     = @($CurrentHeaders)
                })
            }

            # Parse timestamp
            $TsStr = $TsMatch.Groups[1].Value
            $CurrentTimezone = $TsMatch.Groups[2].Value
            $CurrentTimestamp = [datetime]::ParseExact($TsStr, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $CurrentHeaders = [System.Collections.Generic.List[object]]::new()
            continue
        }

        # Check for session header line (uses admin-state.ps1 pattern)
        $HdrMatch = $script:HistoryEntryPattern.Match($Line)
        if ($HdrMatch.Success -and $null -ne $CurrentHeaders) {
            $Header = $HdrMatch.Groups[1].Value.Trim()
            $Header = $script:MultiSpacePattern.Replace($Header, ' ')

            if ($Header.Length -eq 0) { continue }

            # Parse header: "2025-06-15, Ucieczka z Erathii, Catherine"
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

    # Date range filtering on ProcessedAt
    if ($MinDate -or $MaxDate) {
        $Filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($Entry in $Entries) {
            if ($MinDate -and $Entry.ProcessedAt -lt $MinDate) { continue }
            if ($MaxDate -and $Entry.ProcessedAt -gt $MaxDate) { continue }
            $Filtered.Add($Entry)
        }
        $Entries = $Filtered
    }

    # Sort by ProcessedAt descending (most recent first)
    $Entries.Sort([System.Comparison[object]]{
        param($a, $b)
        return $b.ProcessedAt.CompareTo($a.ProcessedAt)
    })

    return @($Entries)
}

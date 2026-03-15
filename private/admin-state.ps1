<#
    .SYNOPSIS
    Append-only state file helpers for admin workflow history tracking.

    .DESCRIPTION
    Non-exported helper functions consumed by Invoke-PlayerCharacterPUAssignment
    and other admin commands via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Get-AdminHistoryEntries: reads processed session headers from a state file
    - Add-AdminHistoryEntry:  appends new entries with timestamp to a state file

    Module-level data:
    - $script:HistoryEntryPattern:           precompiled regex for indented history entry lines "    - ### ..."
    - $script:MultiSpacePattern:             precompiled regex for collapsing multiple whitespace runs
    - $script:AdminHistoryTimestampPattern:  precompiled regex for timestamp lines "- YYYY-MM-dd HH:mm (timezone):"

    State files (`.robot/res/*.md`) use an append-only Markdown format:

        - YYYY-MM-dd HH:mm (timezone):
            - ### session header 1
            - ### session header 2

    Get-AdminHistoryEntries scans lines with HistoryEntryPattern to extract
    "### header" entries, normalizes each (trim + collapse whitespace), and
    returns a HashSet[string] (OrdinalIgnoreCase) for O(1) membership checks.
    This lets PU assignment detect already-processed sessions without scanning
    the full history on each comparison.

    Add-AdminHistoryEntry appends new entries at the end of the file with a
    UTC-offset timestamp line. If the file does not exist, it creates it from
    the pu-sessions-header.md.template via Get-AdminTemplate. Headers are
    sorted alphabetically (chronological since they start with YYYY-MM-DD)
    and normalized with a "### " prefix if absent.

    AdminHistoryTimestampPattern is additionally consumed by Get-PUAssignmentLog
    and Get-VotingEligibility to parse historical assignment timestamps.
#>

$script:HistoryEntryPattern = [regex]::new('^\s+-\s+###\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:MultiSpacePattern = [regex]::new('\s{2,}', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:AdminHistoryTimestampPattern = [regex]::new(
    '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+\(([^)]+)\)\s*:\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

function Get-AdminHistoryEntries {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to the state file")]
        [string]$Path
    )

    $Result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not [System.IO.File]::Exists($Path)) {
        return , $Result
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($Path, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    foreach ($Line in $Lines) {
        $Match = $script:HistoryEntryPattern.Match($Line)
        if (-not $Match.Success) { continue }

        $Header = $Match.Groups[1].Value.Trim()
        $Header = $script:MultiSpacePattern.Replace($Header, ' ')

        if ($Header.Length -gt 0) {
            [void]$Result.Add($Header)
        }
    }

    return , $Result
}

function Add-AdminHistoryEntry {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to the state file")]
        [string]$Path,

        [Parameter(Mandatory, HelpMessage = "Session header strings to append")]
        [AllowEmptyCollection()]
        [string[]]$Headers
    )

    if ($Headers.Count -eq 0) { return }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

    # Create file with template preamble on first use
    if (-not [System.IO.File]::Exists($Path)) {
        $Dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [System.IO.Directory]::Exists($Dir)) {
            [void][System.IO.Directory]::CreateDirectory($Dir)
        }

        if (-not (Get-Command 'Get-AdminTemplate' -ErrorAction SilentlyContinue)) {
            . ([System.IO.Path]::Combine($PSScriptRoot, 'admin-config.ps1'))
        }

        $Preamble = Get-AdminTemplate -Name 'pu-sessions-header.md.template'
        [System.IO.File]::WriteAllText($Path, $Preamble, $UTF8NoBOM)
    }

    $SB = [System.Text.StringBuilder]::new(512)
    $Now = [datetime]::Now
    $TimezoneOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $Sign = if ($TimezoneOffset -ge [System.TimeSpan]::Zero) { '+' } else { '-' }
    $TzStr = "UTC$Sign$($TimezoneOffset.ToString('hh\:mm'))"
    $Timestamp = $Now.ToString('yyyy-MM-dd HH:mm')

    [void]$SB.Append("- $Timestamp ($TzStr):")
    [void]$SB.Append("`n")

    # Headers start with YYYY-MM-DD, so ordinal sort yields chronological order
    $SortedHeaders = [System.Collections.Generic.List[string]]::new($Headers)
    $SortedHeaders.Sort([System.StringComparer]::Ordinal)

    foreach ($Header in $SortedHeaders) {
        $Normalized = $Header.Trim()
        if (-not $Normalized.StartsWith('### ')) {
            $Normalized = "### $Normalized"
        }
        [void]$SB.Append("    - $Normalized")
        [void]$SB.Append("`n")
    }

    [System.IO.File]::AppendAllText($Path, $SB.ToString(), $UTF8NoBOM)
}

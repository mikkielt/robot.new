<#
    .SYNOPSIS
    Append-only state file helpers for admin workflow history tracking.

    .DESCRIPTION
    Non-exported helper functions consumed by Invoke-PlayerCharacterPUAssignment
    and other admin commands via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Get-AdminHistoryEntries: reads processed session headers from a state file
    - Add-AdminHistoryEntry:  appends new entries with timestamp to a state file

    State files (`.robot/res/*.md`) use an append-only format:

        - YYYY-MM-dd HH:mm (timezone):
            - ### session header 1
            - ### session header 2

    Header normalization: trim whitespace, collapse multiple spaces, strip
    leading `### ` prefix before comparison. Returns a HashSet for O(1)
    lookups when checking whether a session has already been processed.
#>

# Precompiled pattern matching indented history entry lines: "    - ### ..."
$script:HistoryEntryPattern = [regex]::new('^\s+-\s+###\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Precompiled pattern for collapsing multiple whitespace
$script:MultiSpacePattern = [regex]::new('\s{2,}', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Reads all processed session headers from a state file.
# Returns a HashSet[string] (OrdinalIgnoreCase) of normalized header strings.
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
        # Normalize: collapse multiple spaces
        $Header = $script:MultiSpacePattern.Replace($Header, ' ')

        if ($Header.Length -gt 0) {
            [void]$Result.Add($Header)
        }
    }

    return , $Result
}

# Appends new processed session headers to a state file with a timestamp line.
# Creates the file with a standard preamble if it does not exist.
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

    # Ensure file exists with preamble
    if (-not [System.IO.File]::Exists($Path)) {
        $Dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [System.IO.Directory]::Exists($Dir)) {
            [void][System.IO.Directory]::CreateDirectory($Dir)
        }

        $FileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $Preamble = "W tym pliku znajduje się lista sesji przetworzonych przez system.`n`n## Historia`n`n"
        [System.IO.File]::WriteAllText($Path, $Preamble, $UTF8NoBOM)
    }

    # Build entry block
    $SB = [System.Text.StringBuilder]::new(512)

    # Timestamp line matching legacy format: "- YYYY-MM-dd HH:mm (timezone):"
    $Now = [datetime]::Now
    $TimezoneOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $Sign = if ($TimezoneOffset -ge [System.TimeSpan]::Zero) { '+' } else { '-' }
    $TzStr = "UTC$Sign$($TimezoneOffset.ToString('hh\:mm'))"
    $Timestamp = $Now.ToString('yyyy-MM-dd HH:mm')

    [void]$SB.Append("- $Timestamp ($TzStr):")
    [void]$SB.Append("`n")

    # Sort headers chronologically (they contain dates as first element)
    $SortedHeaders = [System.Collections.Generic.List[string]]::new($Headers)
    $SortedHeaders.Sort([System.StringComparer]::Ordinal)

    foreach ($Header in $SortedHeaders) {
        $Normalized = $Header.Trim()
        # Ensure header has ### prefix for the state file format
        if (-not $Normalized.StartsWith('### ')) {
            $Normalized = "### $Normalized"
        }
        [void]$SB.Append("    - $Normalized")
        [void]$SB.Append("`n")
    }

    [System.IO.File]::AppendAllText($Path, $SB.ToString(), $UTF8NoBOM)
}

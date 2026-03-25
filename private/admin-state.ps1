<#
    .SYNOPSIS
    JSON state file helpers for admin workflow history tracking.

    .DESCRIPTION
    Non-exported helper functions consumed by Invoke-PlayerCharacterPUAssignment
    and other admin commands via dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Save-JsonStateFile:        atomic JSON write with temp-file swap and .bak backup
    - Read-JsonStateFile:        reads JSON state file with backup recovery on corruption
    - Get-AdminHistoryEntries:   reads processed session headers from JSON state file
    - Add-AdminHistoryEntry:     appends new run with timestamp to JSON state file
    - Convert-PUHistoryToJson:   (moved to migration/phase0-helpers.ps1)

    Module-level data:
    - $script:HistoryEntryPattern:           precompiled regex for legacy Markdown parsing (migration only)
    - $script:MultiSpacePattern:             precompiled regex for collapsing multiple whitespace runs
    - $script:AdminHistoryTimestampPattern:  precompiled regex for legacy timestamp lines (migration only)

    State file (`.robot.local/res/pu-sessions.json`) uses a structured JSON format:

        {
          "version": 2,
          "runs": [
            {
              "processedAt": "2025-01-15T14:30:00",
              "timezone": "UTC+01:00",
              "sessions": ["2024-06-15, Title, Narrator"]
            }
          ]
        }

    Save-JsonStateFile implements crash-safe writes via a three-step
    temp-file swap: write to .tmp, rotate current to .bak, move .tmp
    into place. This guarantees the file is never in a half-written state
    even if the process is killed mid-write.

    Read-JsonStateFile reads and deserializes a JSON state file. On parse
    failure (truncation, corruption), it falls back to the .bak copy left
    by the last successful write, restoring the backup as the primary file
    if recovery succeeds.

    Get-AdminHistoryEntries reads all session strings from all runs,
    normalizes each (trim + collapse whitespace), and returns a
    HashSet[string] (OrdinalIgnoreCase) for O(1) membership checks.

    Add-AdminHistoryEntry reads the JSON file, appends a new run with
    timestamp and sorted session headers, and writes back atomically via
    Save-JsonStateFile. ConvertFrom-Json returns PSCustomObjects, so the
    runs list is rebuilt as a mutable List[object] before appending.

#>

$script:MultiSpacePattern = [regex]::new('\s{2,}', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# ── Shared JSON State Utilities ──────────────────────────────────────────────

function Save-JsonStateFile {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Data,
        [int]$Depth = 10
    )

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Json = $Data | ConvertTo-Json -Depth $Depth
    $TempPath = "$Path.tmp"
    $BackupPath = "$Path.bak"

    [System.IO.File]::WriteAllText($TempPath, $Json, $UTF8NoBOM)

    if ([System.IO.File]::Exists($Path)) {
        if ([System.IO.File]::Exists($BackupPath)) {
            [System.IO.File]::Delete($BackupPath)
        }
        [System.IO.File]::Move($Path, $BackupPath)
    }

    [System.IO.File]::Move($TempPath, $Path)
}

function Read-JsonStateFile {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }

    try {
        $RawJson = [System.IO.File]::ReadAllText($Path, $UTF8NoBOM)
        $Parsed = $RawJson | ConvertFrom-Json
        return $Parsed
    }
    catch {
        # Try backup on corruption
        $BackupPath = "$Path.bak"
        Write-RobotWarning "[WARN Read-JsonStateFile] Failed to read '$Path': $($_.Exception.Message). Trying backup..."
        if ([System.IO.File]::Exists($BackupPath)) {
            try {
                $RawJson = [System.IO.File]::ReadAllText($BackupPath, $UTF8NoBOM)
                $Parsed = $RawJson | ConvertFrom-Json
                [System.IO.File]::Copy($BackupPath, $Path, $true)
                Write-RobotWarning "[WARN Read-JsonStateFile] Recovered from backup: '$BackupPath'"
                return $Parsed
            }
            catch {
                Write-RobotWarning "[WARN Read-JsonStateFile] Backup recovery also failed: $($_.Exception.Message)"
            }
        }
        return $null
    }
}

# ── PU History Read/Write ────────────────────────────────────────────────────

function Get-AdminHistoryEntries {
    <#
        .SYNOPSIS
        Returns a HashSet of all session headers previously processed by PU assignment.
    #>

    param(
        [Parameter(Mandatory, HelpMessage = "Path to the state file")]
        [string]$Path
    )

    $Result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $State = Read-JsonStateFile -Path $Path
    if ($null -eq $State) {
        return , $Result
    }

    $Runs = if ($State.runs) { @($State.runs) } else { @() }
    foreach ($Run in $Runs) {
        $Sessions = if ($Run.sessions) { @($Run.sessions) } else { @() }
        foreach ($Header in $Sessions) {
            $Normalized = $Header.Trim()
            $Normalized = $script:MultiSpacePattern.Replace($Normalized, ' ')
            if ($Normalized.Length -gt 0) {
                [void]$Result.Add($Normalized)
            }
        }
    }

    return , $Result
}

function ConvertTo-MutableStateObject {
    param(
        [string]$Path,
        [int]$DefaultVersion,
        [string]$CollectionKey
    )

    $Parsed = Read-JsonStateFile -Path $Path
    if ($null -eq $Parsed) {
        return [ordered]@{
            version       = $DefaultVersion
            $CollectionKey = [System.Collections.Generic.List[object]]::new()
        }
    }

    $List = [System.Collections.Generic.List[object]]::new()
    $Raw = $Parsed.$CollectionKey
    if ($Raw) {
        foreach ($Item in @($Raw)) { [void]$List.Add($Item) }
    }

    return [ordered]@{
        version       = if ($Parsed.version) { $Parsed.version } else { $DefaultVersion }
        $CollectionKey = $List
    }
}

function Get-TimezoneOffsetString {
    param([datetime]$ReferenceTime = [datetime]::Now)
    $Offset = [System.TimeZoneInfo]::Local.GetUtcOffset($ReferenceTime)
    $Sign = if ($Offset -ge [System.TimeSpan]::Zero) { '+' } else { '-' }
    return "UTC$Sign$($Offset.ToString('hh\:mm'))"
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

    $State = ConvertTo-MutableStateObject -Path $Path -DefaultVersion 2 -CollectionKey 'runs'

    $Now = [datetime]::Now
    $TzStr = Get-TimezoneOffsetString -ReferenceTime $Now
    $Timestamp = $Now.ToString('yyyy-MM-ddTHH:mm:ss')

    # Strip "### " prefixes and sort — ordinal sort yields chronological order since headers start with YYYY-MM-DD
    $SortedHeaders = [System.Collections.Generic.List[string]]::new()
    foreach ($Header in $Headers) {
        $Normalized = $Header.Trim()
        if ($Normalized.StartsWith('### ')) {
            $Normalized = $Normalized.Substring(4)
        }
        [void]$SortedHeaders.Add($Normalized)
    }
    $SortedHeaders.Sort([System.StringComparer]::Ordinal)

    $NewRun = [ordered]@{
        processedAt = $Timestamp
        timezone    = $TzStr
        sessions    = @($SortedHeaders)
    }

    if ($State.runs -is [System.Collections.IList]) {
        [void]$State.runs.Add($NewRun)
    } else {
        $State.runs = @($State.runs) + @($NewRun)
    }

    Save-JsonStateFile -Path $Path -Data $State
}


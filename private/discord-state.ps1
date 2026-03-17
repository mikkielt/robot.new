<#
    .SYNOPSIS
    Append-only state file helpers for Discord delivery tracking.

    .DESCRIPTION
    Non-exported helper functions consumed by Invoke-PlayerCharacterPUAssignment,
    Invoke-DiscordAnnouncementWorkflow, and Get-DiscordDeliveryLog via dot-sourcing.
    Not auto-loaded by robot.psm1 (non-Verb-Noun filename).

    Helpers:
    - Add-DiscordDeliveryEntry:   appends timestamped delivery record to state file
    - Get-DiscordDeliveryEntries: parses state file into structured objects

    Module-level data:
    - $script:DiscordDeliveryPattern:        precompiled regex for delivery entry lines
    - $script:DiscordDeliveryContextPattern:  precompiled regex for context sub-lines
    - $script:DiscordDeliveryErrorPattern:    precompiled regex for error sub-lines

    State file (`.robot/res/discord-delivery.md`) uses an append-only Markdown format:

        - YYYY-MM-dd HH:mm:ss (timezone) [OK|FAIL] Operation -> Recipient (HTTP NNN)
            - Context line
            - ERROR: error message

    Get-DiscordDeliveryEntries parses each entry into a PSCustomObject with
    Timestamp, Timezone, Status, Operation, Recipient, StatusCode, Context,
    and ErrorMessage fields.

    Add-DiscordDeliveryEntry appends a new entry at the end of the file with a
    UTC-offset timestamp. Creates the file with a header preamble on first use.

    Follows the same append-only pattern as admin-state.ps1.
#>

$script:DiscordDeliveryPattern = [regex]::new(
    '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+\(([^)]+)\)\s+\[(OK|FAIL)\]\s+(\w+(?:-\w+)*)\s+->\s+(.+?)(?:\s+\(HTTP\s+(\d+)\))?\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)
$script:DiscordDeliveryContextPattern = [regex]::new(
    '^\s+-\s+(?!ERROR:\s)(.+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)
$script:DiscordDeliveryErrorPattern = [regex]::new(
    '^\s+-\s+ERROR:\s+(.+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

function Add-DiscordDeliveryEntry {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [ValidateSet('PU', 'PU-Resend', 'Intel', 'Announcement', 'Custom')]
        [string]$Operation,
        [Parameter(Mandatory)] [string]$Recipient,
        [Parameter(Mandatory)] [bool]$Success,
        [int]$StatusCode,
        [string]$ErrorMessage,
        [string]$Context
    )

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

    if (-not [System.IO.File]::Exists($Path)) {
        $Dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [System.IO.Directory]::Exists($Dir)) {
            [void][System.IO.Directory]::CreateDirectory($Dir)
        }
        [System.IO.File]::WriteAllText($Path, "# Discord Delivery Log`n`n", $UTF8NoBOM)
    }

    $SB = [System.Text.StringBuilder]::new(256)
    $Now = [datetime]::Now
    $TimezoneOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $Sign = if ($TimezoneOffset -ge [System.TimeSpan]::Zero) { '+' } else { '-' }
    $TzStr = "UTC$Sign$($TimezoneOffset.ToString('hh\:mm'))"
    $Timestamp = $Now.ToString('yyyy-MM-dd HH:mm:ss')
    $StatusStr = if ($Success) { 'OK' } else { 'FAIL' }

    [void]$SB.Append("- $Timestamp ($TzStr) [$StatusStr] $Operation -> $Recipient")
    if ($StatusCode) { [void]$SB.Append(" (HTTP $StatusCode)") }
    [void]$SB.Append("`n")
    if ($Context) {
        [void]$SB.Append("    - $Context`n")
    }
    if ($ErrorMessage) {
        [void]$SB.Append("    - ERROR: $ErrorMessage`n")
    }

    [System.IO.File]::AppendAllText($Path, $SB.ToString(), $UTF8NoBOM)
}

function Get-DiscordDeliveryEntries {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    $Result = [System.Collections.Generic.List[object]]::new()

    if (-not [System.IO.File]::Exists($Path)) {
        return , @($Result)
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($Path, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $Current = $null

    foreach ($Line in $Lines) {
        $Match = $script:DiscordDeliveryPattern.Match($Line)
        if ($Match.Success) {
            if ($null -ne $Current) { $Result.Add($Current) }

            $TsStr = $Match.Groups[1].Value
            $Current = [PSCustomObject]@{
                Timestamp    = [datetime]::ParseExact($TsStr, 'yyyy-MM-dd HH:mm:ss',
                    [System.Globalization.CultureInfo]::InvariantCulture)
                Timezone     = $Match.Groups[2].Value
                Status       = $Match.Groups[3].Value      # 'OK' or 'FAIL'
                Operation    = $Match.Groups[4].Value       # 'PU', 'Intel', etc.
                Recipient    = $Match.Groups[5].Value
                StatusCode   = if ($Match.Groups[6].Success) { [int]$Match.Groups[6].Value } else { $null }
                Context      = $null
                ErrorMessage = $null
            }
            continue
        }

        if ($null -eq $Current) { continue }

        $ErrMatch = $script:DiscordDeliveryErrorPattern.Match($Line)
        if ($ErrMatch.Success) {
            $Current.ErrorMessage = $ErrMatch.Groups[1].Value
            continue
        }

        $CtxMatch = $script:DiscordDeliveryContextPattern.Match($Line)
        if ($CtxMatch.Success) {
            $Current.Context = $CtxMatch.Groups[1].Value
        }
    }

    if ($null -ne $Current) { $Result.Add($Current) }

    return , @($Result)
}

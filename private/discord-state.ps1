<#
    .SYNOPSIS
    JSON state file helpers for Discord delivery tracking.

    .DESCRIPTION
    Non-exported helper functions consumed by Invoke-PlayerCharacterPUAssignment,
    Invoke-DiscordAnnouncementWorkflow, and Get-DiscordDeliveryLog via dot-sourcing.
    Not auto-loaded by robot.psm1 (non-Verb-Noun filename).

    Helpers:
    - Add-DiscordDeliveryEntry:         appends delivery record to JSON state file
    - Get-DiscordDeliveryEntries:       parses JSON state file into structured objects
    - Convert-DiscordDeliveryToJson:    converts legacy discord-delivery.md to JSON

    Module-level data:
    - $script:DiscordDeliveryPattern:        precompiled regex for legacy Markdown parsing (migration only)
    - $script:DiscordDeliveryContextPattern:  precompiled regex for legacy context sub-lines (migration only)
    - $script:DiscordDeliveryErrorPattern:    precompiled regex for legacy error sub-lines (migration only)

    State file (`.robot/res/discord-delivery.json`) uses a structured JSON format:

        {
          "version": 1,
          "entries": [
            {
              "timestamp": "2026-03-01T09:15:22",
              "timezone": "UTC+01:00",
              "status": "OK",
              "operation": "PU",
              "recipient": "Jan",
              "statusCode": 204,
              "context": "2026-02 PU: Solmyr +3.00",
              "errorMessage": null
            }
          ]
        }

    Add-DiscordDeliveryEntry reads or initializes the JSON state, rebuilds
    the entries list as mutable List[object] (ConvertFrom-Json yields
    immutable PSCustomObjects), appends a new timestamped entry, and writes
    back atomically via Save-JsonStateFile.

    Get-DiscordDeliveryEntries returns the same PSCustomObject array as before
    (Timestamp, Timezone, Status, Operation, Recipient, StatusCode, Context,
    ErrorMessage) — all downstream consumers are transparent.

    Convert-DiscordDeliveryToJson is a one-shot migration converter that
    parses the legacy append-only Markdown format (one-line entries with
    optional context/error sub-lines) into the versioned JSON structure.
    Called by phase0-setup.ps1 during repository migration.

    Depends on Save-JsonStateFile / Read-JsonStateFile from admin-state.ps1.
#>

# Legacy regex patterns — preserved for Convert-DiscordDeliveryToJson migration converter
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

    # Initialize or rebuild mutable state — ConvertFrom-Json yields immutable PSCustomObjects
    $State = Read-JsonStateFile -Path $Path
    if ($null -eq $State) {
        $State = [ordered]@{
            version = 1
            entries = [System.Collections.Generic.List[object]]::new()
        }
    } else {
        $EntriesList = [System.Collections.Generic.List[object]]::new()
        if ($State.entries) {
            foreach ($E in @($State.entries)) { [void]$EntriesList.Add($E) }
        }
        $State = [ordered]@{
            version = if ($State.version) { $State.version } else { 1 }
            entries = $EntriesList
        }
    }

    $Now = [datetime]::Now
    $TimezoneOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $Sign = if ($TimezoneOffset -ge [System.TimeSpan]::Zero) { '+' } else { '-' }
    $TzStr = "UTC$Sign$($TimezoneOffset.ToString('hh\:mm'))"

    $NewEntry = [ordered]@{
        timestamp    = $Now.ToString('yyyy-MM-ddTHH:mm:ss')
        timezone     = $TzStr
        status       = if ($Success) { 'OK' } else { 'FAIL' }
        operation    = $Operation
        recipient    = $Recipient
        statusCode   = if ($StatusCode) { $StatusCode } else { $null }
        context      = if ($Context) { $Context } else { $null }
        errorMessage = if ($ErrorMessage) { $ErrorMessage } else { $null }
    }

    if ($State.entries -is [System.Collections.IList]) {
        [void]$State.entries.Add($NewEntry)
    } else {
        $State.entries = @($State.entries) + @($NewEntry)
    }

    Save-JsonStateFile -Path $Path -Data $State
}

function Get-DiscordDeliveryEntries {
    <#
        .SYNOPSIS
        Parses the Discord delivery JSON state file into structured PSCustomObjects.
    #>

    param(
        [Parameter(Mandatory)] [string]$Path
    )

    $Result = [System.Collections.Generic.List[object]]::new()

    $State = Read-JsonStateFile -Path $Path
    if ($null -eq $State -or -not $State.entries) {
        return , @($Result)
    }

    foreach ($Entry in @($State.entries)) {
        # ConvertFrom-Json auto-converts ISO timestamps to DateTime on some PS versions
        $TsRaw = $Entry.timestamp
        $Ts = if ($TsRaw -is [datetime]) {
            $TsRaw
        } else {
            [datetime]::ParseExact($TsRaw, 'yyyy-MM-ddTHH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture)
        }

        [void]$Result.Add([PSCustomObject]@{
            Timestamp    = $Ts
            Timezone     = $Entry.timezone
            Status       = $Entry.status
            Operation    = $Entry.operation
            Recipient    = $Entry.recipient
            StatusCode   = $Entry.statusCode
            Context      = $Entry.context
            ErrorMessage = $Entry.errorMessage
        })
    }

    return , @($Result)
}

# ── Legacy MD → JSON Migration Converter ─────────────────────────────────────

function Convert-DiscordDeliveryToJson {
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [switch]$Force
    )

    if ([System.IO.File]::Exists($TargetPath) -and -not $Force) {
        Write-RobotWarning "[WARN Convert-DiscordDeliveryToJson] Target file already exists: '$TargetPath'. Use -Force to overwrite."
        return $false
    }

    if (-not [System.IO.File]::Exists($SourcePath)) {
        # No delivery history yet — not an error
        return $true
    }

    # Parse existing Markdown using legacy regex patterns
    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($SourcePath, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $MdEntries = [System.Collections.Generic.List[object]]::new()
    $Current = $null

    foreach ($Line in $Lines) {
        $Match = $script:DiscordDeliveryPattern.Match($Line)
        if ($Match.Success) {
            if ($null -ne $Current) { [void]$MdEntries.Add($Current) }

            $TsStr = $Match.Groups[1].Value
            $Current = [PSCustomObject]@{
                Timestamp    = [datetime]::ParseExact($TsStr, 'yyyy-MM-dd HH:mm:ss',
                    [System.Globalization.CultureInfo]::InvariantCulture)
                Timezone     = $Match.Groups[2].Value
                Status       = $Match.Groups[3].Value
                Operation    = $Match.Groups[4].Value
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

    if ($null -ne $Current) { [void]$MdEntries.Add($Current) }

    $Entries = [System.Collections.Generic.List[object]]::new()
    foreach ($E in $MdEntries) {
        [void]$Entries.Add([ordered]@{
            timestamp    = $E.Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
            timezone     = $E.Timezone
            status       = $E.Status
            operation    = $E.Operation
            recipient    = $E.Recipient
            statusCode   = $E.StatusCode
            context      = $E.Context
            errorMessage = $E.ErrorMessage
        })
    }

    $State = [ordered]@{
        version = 1
        entries = @($Entries)
    }

    Save-JsonStateFile -Path $TargetPath -Data $State
    return $true
}

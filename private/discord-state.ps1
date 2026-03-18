<#
    .SYNOPSIS
    JSON state file helpers for Discord delivery tracking.

    .DESCRIPTION
    Non-exported helper functions consumed by Invoke-PlayerCharacterPUAssignment,
    Invoke-DiscordAnnouncementWorkflow, and Get-DiscordDeliveryLog via dot-sourcing.
    Not auto-loaded by Robot.PowerShell.psm1 (non-Verb-Noun filename).

    Helpers:
    - Add-DiscordDeliveryEntry:         appends delivery record to JSON state file
    - Get-DiscordDeliveryEntries:       parses JSON state file into structured objects
    - Convert-DiscordDeliveryToJson:    (moved to migration/phase0-helpers.ps1)

    Module-level data:
    - $script:DiscordDeliveryPattern:        precompiled regex for legacy Markdown parsing (migration only)
    - $script:DiscordDeliveryContextPattern:  precompiled regex for legacy context sub-lines (migration only)
    - $script:DiscordDeliveryErrorPattern:    precompiled regex for legacy error sub-lines (migration only)

    State file (`.robot.local/res/discord-delivery.json`) uses a structured JSON format:

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

    Depends on Save-JsonStateFile / Read-JsonStateFile from admin-state.ps1.
#>

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


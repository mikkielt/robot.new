<#
    .SYNOPSIS
    Discord delivery history reporting function.

    .DESCRIPTION
    This file contains Get-DiscordDeliveryLog which reads and filters the
    Discord delivery state file (.robot/res/discord-delivery.json).

    Complements Get-NotificationLog (which shows notification intent from
    @Intel directives) with actual delivery status from Send-DiscordMessage
    calls.

    Processing pipeline:
    1. Resolve state file path from Get-AdminConfig (or accept explicit -Path).
    2. Parse entries via Get-DiscordDeliveryEntries (discord-state.ps1).
    3. Apply filters: Operation, Recipient, FailedOnly, MinDate, MaxDate.
    4. Sort descending by timestamp (most recent first).

    Return type: array of PSCustomObject with Timestamp, Timezone, Status,
    Operation, Recipient, StatusCode, Context, ErrorMessage fields.

    Dependencies: discord-state.ps1 (dot-sourced), admin-config.ps1 (via
    Get-AdminConfig for ResDir resolution).
#>

. "$script:ModuleRoot/private/discord-state.ps1"

function Get-DiscordDeliveryLog {
    <#
        .SYNOPSIS
        Returns structured Discord delivery history from the state file.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Path to the Discord delivery state file")]
        [string]$Path,

        [Parameter(HelpMessage = "Filter by operation type")]
        [ValidateSet('PU', 'PU-Resend', 'Intel', 'Announcement', 'Custom')]
        [string]$Operation,

        [Parameter(HelpMessage = "Filter by recipient name")]
        [string]$Recipient,

        [Parameter(HelpMessage = "Show only failed deliveries")]
        [switch]$FailedOnly,

        [Parameter(HelpMessage = "Include only deliveries on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only deliveries on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $Path) {
        $Config = Get-AdminConfig
        $Path = [System.IO.Path]::Combine($Config.ResDir, 'discord-delivery.json')
    }

    if (-not [System.IO.File]::Exists($Path)) {
        return @()
    }

    $AllEntries = Get-DiscordDeliveryEntries -Path $Path

    $Filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $AllEntries) {
        if ($Operation -and -not [string]::Equals($Entry.Operation, $Operation, 'OrdinalIgnoreCase')) { continue }
        if ($Recipient -and -not [string]::Equals($Entry.Recipient, $Recipient, 'OrdinalIgnoreCase')) { continue }
        if ($FailedOnly -and $Entry.Status -ne 'FAIL') { continue }
        if ($MinDate -and $Entry.Timestamp -lt $MinDate) { continue }
        if ($MaxDate -and $Entry.Timestamp -gt $MaxDate) { continue }
        $Filtered.Add($Entry)
    }

    # Most recent first (same as Get-PUAssignmentLog)
    $Filtered.Sort([System.Comparison[object]]{
        param($a, $b)
        return $b.Timestamp.CompareTo($a.Timestamp)
    })

    return @($Filtered)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

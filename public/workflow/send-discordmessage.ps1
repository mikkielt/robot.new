<#
    .SYNOPSIS
    Low-level Discord webhook message sender.

    .DESCRIPTION
    This file contains Send-DiscordMessage which POSTs a message to a Discord
    webhook URL via .NET HttpClient.

    Processing pipeline:
    1. Validate webhook URL format against the Discord API prefix to prevent
       accidental data leaks to non-Discord endpoints.
    2. Build JSON payload with 'content' and optional 'username' fields.
    3. Pre-encode to UTF-8 bytes for ByteArrayContent (avoids double-encoding
       that would occur with StringContent + default encoding).
    4. ShouldProcess gate: -WhatIf returns a result object without HTTP I/O.
    5. POST via HttpClient with application/json content type.
    6. Return structured result with Webhook, StatusCode, Success, WhatIf fields.

    No retry logic at this level — retry and delivery tracking are handled
    by the queue system (Invoke-DiscordMessageQueue, Phase 3).

    HttpClient, ByteArrayContent, and Response are disposed in a finally block
    to prevent socket exhaustion during batch sends.
#>

function Send-DiscordMessage {
    <#
        .SYNOPSIS
        Sends a message to a Discord webhook URL.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Discord webhook URL")]
        [string]$Webhook,

        [Parameter(Mandatory, HelpMessage = "Message content to send")]
        [string]$Message,

        [Parameter(HelpMessage = "Bot username displayed in Discord")]
        [string]$Username
    )

    # Reject non-Discord URLs to prevent accidental data leaks to arbitrary endpoints
    if ($Webhook -notlike "https://discord.com/api/webhooks/*") {
        throw "Invalid webhook URL format. Must match 'https://discord.com/api/webhooks/*'. Got: $Webhook"
    }

    # Discord webhook API contract: 'content' is required, 'username' is optional override
    $Payload = [ordered]@{
        content = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        $Payload['username'] = $Username
    }

    # Pre-encode to bytes: ByteArrayContent avoids the double-encoding
    # that StringContent applies when the string contains non-ASCII characters
    $JsonBytes = [System.Text.Encoding]::UTF8.GetBytes(
        ($Payload | ConvertTo-Json -Depth 4 -Compress)
    )

    if (-not $PSCmdlet.ShouldProcess($Webhook, "Send-DiscordMessage: post message (${$Message.Length} chars)")) {
        return [PSCustomObject]@{
            Webhook    = $Webhook
            StatusCode = $null
            Success    = $false
            WhatIf     = $true
        }
    }

    # .NET HttpClient: avoids Invoke-WebRequest's IE-engine dependency on Windows PS 5.1
    $Client = $null
    $Content = $null
    $Response = $null

    try {
        $Client = [System.Net.Http.HttpClient]::new()
        $Content = [System.Net.Http.ByteArrayContent]::new($JsonBytes)
        $Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')

        $Response = $Client.PostAsync($Webhook, $Content).GetAwaiter().GetResult()
        $StatusCode = [int]$Response.StatusCode

        if (-not $Response.IsSuccessStatusCode) {
            $Body = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Discord webhook returned HTTP $StatusCode`: $Body"
        }

        return [PSCustomObject]@{
            Webhook    = $Webhook
            StatusCode = $StatusCode
            Success    = $true
            WhatIf     = $false
        }
    } finally {
        if ($Response) { $Response.Dispose() }
        if ($Content) { $Content.Dispose() }
        if ($Client) { $Client.Dispose() }
    }
}

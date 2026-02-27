<#
    .SYNOPSIS
    Low-level Discord webhook message sender.

    .DESCRIPTION
    This file contains Send-DiscordMessage which POSTs a message to a Discord
    webhook URL. It validates the webhook URL format, builds a JSON payload
    with content and optional username, and sends via .NET HttpClient.

    No retry logic at this level — retry and delivery tracking are handled
    by the queue system (Invoke-DiscordMessageQueue, Phase 3).

    Supports -WhatIf via SupportsShouldProcess.
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

    # Validate webhook URL format
    if ($Webhook -notlike "https://discord.com/api/webhooks/*") {
        throw "Invalid webhook URL format. Must match 'https://discord.com/api/webhooks/*'. Got: $Webhook"
    }

    # Build JSON payload
    $Payload = [ordered]@{
        content = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        $Payload['username'] = $Username
    }

    # Serialize to JSON using .NET
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

    # Send via .NET HttpClient
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

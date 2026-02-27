BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'send-discordmessage.ps1')
}

Describe 'Send-DiscordMessage' {
    It 'throws on invalid webhook URL' {
        { Send-DiscordMessage -Webhook 'https://example.com/not-a-webhook' -Message 'test' } |
            Should -Throw '*Invalid webhook URL format*'
    }

    It 'throws on non-discord webhook URL' {
        { Send-DiscordMessage -Webhook 'https://hooks.slack.com/services/xxx' -Message 'test' } |
            Should -Throw '*Invalid webhook URL format*'
    }

    It 'returns WhatIf result with StatusCode null' {
        $Result = Send-DiscordMessage -Webhook 'https://discord.com/api/webhooks/123456/abcdef' -Message 'Hello' -WhatIf
        $Result.WhatIf | Should -BeTrue
        $Result.StatusCode | Should -BeNullOrEmpty
        $Result.Success | Should -BeFalse
        $Result.Webhook | Should -Be 'https://discord.com/api/webhooks/123456/abcdef'
    }

    It 'accepts Username parameter in WhatIf mode' {
        $Result = Send-DiscordMessage -Webhook 'https://discord.com/api/webhooks/123456/abcdef' -Message 'Hello' -Username 'Bothen' -WhatIf
        $Result.WhatIf | Should -BeTrue
    }

    It 'validates webhook before WhatIf check' {
        # Invalid URL should throw even with -WhatIf
        { Send-DiscordMessage -Webhook 'http://bad-url' -Message 'test' -WhatIf } |
            Should -Throw '*Invalid webhook URL format*'
    }
}

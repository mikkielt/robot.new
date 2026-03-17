@{
    Name              = 'robot-api'
    Version           = '0.1.0'
    Description       = 'RESTful HTTP API with compiled C# server engine for concurrent multi-client access'
    Author            = 'Anward'
    MinCoreVersion    = '2.0.0'
    DependsOn         = @()
    ExportedFunctions = @(
        'Start-RobotApi', 'Stop-RobotApi', 'Get-RobotApiStatus',
        'New-RobotApiToken', 'Remove-RobotApiToken', 'Get-RobotApiToken'
    )
    Config            = @{
        ListenPort = @{
            Description = 'HTTP listening port'
            EnvVar      = 'ROBOT_API_PORT'
            Default     = 8642
            Required    = $false
        }
        ListenAddress = @{
            Description = 'Bind address (localhost or * for all interfaces)'
            EnvVar      = 'ROBOT_API_LISTEN'
            Default     = 'localhost'
            Required    = $false
        }
        AuthToken = @{
            Description = 'Bearer token for API authentication (null = no auth)'
            EnvVar      = 'ROBOT_API_TOKEN'
            Default     = $null
            Required    = $false
        }
        CorsOrigin = @{
            Description = 'Allowed CORS origin (* = all, null = disabled)'
            EnvVar      = 'ROBOT_API_CORS'
            Default     = $null
            Required    = $false
        }
        ReadOnly = @{
            Description = 'Disable write endpoints (true = read-only mode)'
            EnvVar      = 'ROBOT_API_READONLY'
            Default     = $false
            Required    = $false
        }
        WorkerCount = @{
            Description = 'Number of parallel PowerShell runspaces for request handling'
            EnvVar      = 'ROBOT_API_WORKERS'
            Default     = 8
            Required    = $false
        }
        RateLimitPerSecond = @{
            Description = 'Max requests per second per IP (0 = unlimited)'
            EnvVar      = 'ROBOT_API_RATE_LIMIT'
            Default     = 100
            Required    = $false
        }
        MaxRequestBody = @{
            Description = 'Maximum request body size in bytes'
            EnvVar      = $null
            Default     = 65536
            Required    = $false
        }
    }
    Hooks             = @(
        @{
            Operation = 'Write-EntityFile'
            Phase     = 'AfterWrite'
            Handler   = 'Invoke-ApiEventBroadcast'
            Priority  = 999
        }
        @{
            Operation = 'New-Entity'
            Phase     = 'AfterCreate'
            Handler   = 'Invoke-ApiEventBroadcast'
            Priority  = 999
        }
        @{
            Operation = 'New-PlayerCharacter'
            Phase     = 'AfterCreate'
            Handler   = 'Invoke-ApiEventBroadcast'
            Priority  = 999
        }
        @{
            Operation = 'Remove-Entity'
            Phase     = 'AfterWrite'
            Handler   = 'Invoke-ApiEventBroadcast'
            Priority  = 999
        }
        @{
            Operation = 'Set-CurrencyEntity'
            Phase     = 'AfterWrite'
            Handler   = 'Invoke-ApiEventBroadcast'
            Priority  = 999
        }
        @{
            Operation = 'New-Player'
            Phase     = 'AfterCreate'
            Handler   = 'Invoke-ApiEventBroadcast'
            Priority  = 999
        }
    )
    Scopes            = @('admin:all', 'auth:manage')
    MenuCategories    = @('API')
    MenuItems         = @(
        @{
            ID               = 'robot-api:start'
            Label            = 'Uruchom REST API'
            Menu             = 'API'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-ApiStartWorkflow'
        }
        @{
            ID               = 'robot-api:stop'
            Label            = 'Zatrzymaj REST API'
            Menu             = 'API'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-ApiStopWorkflow'
        }
        @{
            ID               = 'robot-api:status'
            Label            = 'Status REST API'
            Menu             = 'API'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-ApiStatusWorkflow'
        }
    )
    HelpContent       = @{
        'API' = @{
            Title = 'REST API - Pomoc'
            Body  = @(
                'Serwer HTTP z kompilowanym silnikiem C# obslugujacy rownolegle zapytania.'
                ''
                'Uruchom REST API - startuje serwer z pula watkow roboczych.'
                'Zatrzymaj REST API - zatrzymuje serwer i zwalnia zasoby.'
                'Status REST API - statystyki serwera, endpointy, polaczenia SSE.'
            )
        }
    }
}

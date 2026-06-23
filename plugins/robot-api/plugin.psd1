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
        DebugMode = @{
            Description = 'Enable debug mode — dashboard emits debug-level console output'
            EnvVar      = 'ROBOT_API_DEBUG'
            Default     = $false
            Required    = $false
        }
        MargonemPublicKeyFile = @{
            Description = 'Path to Margonem account-signing RSA public key PEM (X.509 SPKI). Default lives under .robot.local/.cache/margonem/ which is gitignored module-locally.'
            EnvVar      = 'ROBOT_MARGONEM_KEY'
            Default     = '.robot.local/.cache/margonem/signing-key.pem'
            Required    = $false
        }
        MargonemSessionTtlSeconds = @{
            Description = 'Lifetime of Margonem-minted session tokens (seconds)'
            EnvVar      = 'ROBOT_MARGONEM_TTL'
            Default     = 14400
            Required    = $false
        }
        MargonemFreshnessSeconds = @{
            Description = 'Max abs(server_now - payload_ts) for Margonem signature payloads (seconds)'
            EnvVar      = 'ROBOT_MARGONEM_FRESHNESS'
            Default     = 300
            Required    = $false
        }
        MargonemDefaultScopes = @{
            Description = 'Scopes granted to a freshly-minted Margonem session token'
            EnvVar      = $null
            Default     = @('entity:read', 'session:read', 'player:read')
            Required    = $false
        }
        SessionTokenMaxEntries = @{
            Description = 'Capacity of the in-memory session token store'
            EnvVar      = $null
            Default     = 10000
            Required    = $false
        }
        MargonemKeyUrl = @{
            Description = 'Source URL for POST /auth/margonem/refresh-key (Margonem CDN PEM)'
            EnvVar      = 'ROBOT_MARGONEM_KEY_URL'
            Default     = 'http://staticinfo.margonem.pl/.well-known/signing-key.pem'
            Required    = $false
        }
        MargonemValidateUrl = @{
            Description = 'Probed by GET /auth/margonem/health (Margonem validate endpoint)'
            EnvVar      = 'ROBOT_MARGONEM_VALIDATE_URL'
            Default     = 'https://public-api.margonem.pl/account/validate'
            Required    = $false
        }
        MargonemAuditLogFile = @{
            Description = 'Append-only NDJSON audit log for /auth/margonem outcomes. Inherits .robot.local/.cache/ gitignore protection.'
            EnvVar      = 'ROBOT_MARGONEM_AUDIT_LOG'
            Default     = '.robot.local/.cache/margonem/audit.log'
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
        @{
            Operation = 'Write-EntityFile'
            Phase     = 'AfterWrite'
            Handler   = 'Invoke-MargonemSessionInvalidation'
            Priority  = 990
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

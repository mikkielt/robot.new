<#
    .SYNOPSIS
    REST API server startup with C# engine and PowerShell worker pool.

    .DESCRIPTION
    This file contains Start-RobotApi — the entry point for launching the
    HTTP API server. Orchestrates a multi-phase startup:

    1. Type guard: verifies Robot.ApiServer C# type is available (requires
       PowerShell 7.0+ with .NET Core for HttpListener support).
    2. Config resolution: merges plugin config (plugin.psd1 defaults +
       local.config.psd1 overrides) with parameter-level overrides.
    3. Engine assembly: creates ApiServer, ApiRouter, and ApiMiddleware
       instances, wires middleware settings (auth, CORS, rate limiting).
    4. Route registration: dot-sources api-routes.ps1, calls
       Register-AllApiRoutes to build the compiled route table.
    5. HTTP start: ApiServer.Start() begins accepting connections.
    6. Worker pool: dot-sources api-worker.ps1, launches N runspace threads.

    Module-level data:
    - $script:ApiServerInstance: the active ApiServer reference (shared with
      Stop-RobotApi, Get-RobotApiStatus, and CLI workflows)
#>

function Start-RobotApi {
    <#
        .SYNOPSIS
        Starts the REST API server with the compiled C# engine and PS worker pool.

        .PARAMETER Port
        Override HTTP listening port (default from plugin config: 8642).

        .PARAMETER Address
        Override bind address (default: localhost).

        .PARAMETER Workers
        Override number of parallel PowerShell runspaces (default: 8).

        .PARAMETER ReadOnly
        Disable write endpoints (POST/PUT/DELETE return 403).

        .PARAMETER Quiet
        Suppress informational output.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [int]$Port,
        [string]$Address,
        [int]$Workers,
        [switch]$ReadOnly,
        [switch]$Quiet
    )

    # Verify C# engine compiled
    if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiServer').Type) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    'Robot.ApiServer C# type not available. Requires PowerShell 7.0+ with .NET Core.'),
                'ApiServerTypeNotFound',
                [System.Management.Automation.ErrorCategory]::NotInstalled,
                $null
            )
        )
        return
    }

    # Resolve config from plugin settings + parameter overrides
    $Config = Get-PluginConfig -PluginName 'robot-api'
    if ($Port)    { $Config.ListenPort    = $Port }
    if ($Address) { $Config.ListenAddress = $Address }
    if ($Workers) { $Config.WorkerCount   = $Workers }
    if ($ReadOnly){ $Config.ReadOnly      = $true }

    # Default config values if plugin config not loaded
    if (-not $Config.ListenPort)         { $Config.ListenPort         = 8642 }
    if (-not $Config.ListenAddress)      { $Config.ListenAddress      = 'localhost' }
    if (-not $Config.WorkerCount)        { $Config.WorkerCount        = 8 }
    if (-not $Config.RateLimitPerSecond) { $Config.RateLimitPerSecond = 100 }
    if (-not $Config.MaxRequestBody)     { $Config.MaxRequestBody     = 65536 }

    $Prefix = "http://$($Config.ListenAddress):$($Config.ListenPort)/api/"

    if (-not $PSCmdlet.ShouldProcess($Prefix, 'Start REST API server')) { return }

    # Build C# engine components
    $Server     = [Robot.ApiServer]::new()
    $Router     = [Robot.ApiRouter]::new()
    $Middleware  = [Robot.ApiMiddleware]::new()

    $Middleware.AuthToken          = $Config.AuthToken
    $Middleware.CorsOrigin         = $Config.CorsOrigin
    $Middleware.ReadOnly           = [bool]$Config.ReadOnly
    $Middleware.MaxRequestBody     = [int]$Config.MaxRequestBody
    $Middleware.RateLimitPerSecond = [int]$Config.RateLimitPerSecond
    $Middleware.RateLimitBurst     = [int]$Config.RateLimitPerSecond * 2

    # Register routes
    . "$PSScriptRoot/../private/api-routes.ps1"
    $HandlerMap = Register-AllApiRoutes -Router $Router -Server $Server

    # Start C# HTTP engine
    $Server.Start($Prefix, $Router, $Middleware)
    $script:ApiServerInstance = $Server

    # Start PS worker pool
    . "$PSScriptRoot/../private/api-worker.ps1"
    Start-ApiWorkerPool -Server $Server -HandlerMap $HandlerMap `
        -WorkerCount ([int]$Config.WorkerCount)

    if (-not $Quiet) {
        Write-RobotInfo "[Start-RobotApi] C# engine started on $Prefix"
        Write-RobotInfo "[Start-RobotApi] $($Config.WorkerCount) PowerShell workers active"
        Write-RobotInfo "[Start-RobotApi] Rate limit: $($Config.RateLimitPerSecond) req/s per IP"
    }

    return Get-RobotApiStatus
}

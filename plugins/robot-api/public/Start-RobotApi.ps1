<#
    .SYNOPSIS
    REST API server startup with C# engine and PowerShell worker pool.

    .DESCRIPTION
    This file contains Start-RobotApi — the entry point for launching the
    HTTP API server. Orchestrates a multi-phase startup:

    1. Type guard: verifies [Robot.ApiServer] C# type is available (requires
       PowerShell 7.0+ with .NET Core for HttpListener support).
    2. Config resolution: merges plugin config (plugin.psd1 defaults +
       local.config.psd1 overrides) with parameter-level overrides.
    3. Engine assembly: creates [Robot.ApiServer], [Robot.ApiRouter], and
       [Robot.ApiMiddleware] instances; wires middleware settings (CORS,
       rate limiting, request body limit).
    4. Token store: creates [Robot.ApiTokenStore], loads persistent tokens
       from .psd1 file (with gitignore safety check), falls back to legacy
       single AuthToken if no multi-token store exists.
    5. Route registration: dot-sources api-routes.ps1, calls
       Register-AllApiRoutes to build the compiled route table.
    6. HTTP start: ApiServer.Start() begins accepting connections on the
       configured prefix (e.g. http://localhost:8642/api/).
    7. Response cache: creates [Robot.ApiResponseCache], sets RepoRoot and
       CacheDirectory on the static ApiServer fields for cross-runspace
       sidecar file caching.
    8. Worker pool: dot-sources api-worker.ps1, launches N PowerShell
       runspace threads to process queued requests.

    Helpers (dot-sourced):
    - api-token-helpers.ps1: Resolve-TokenFilePath, Test-TokenFileGitignored,
      Sync-ApiTokenStore
    - api-routes.ps1: Register-AllApiRoutes
    - api-worker.ps1: Start-ApiWorkerPool

    Module-level data:
    - $script:ApiServerInstance: the active [Robot.ApiServer] reference
      (shared with Stop-RobotApi, Get-RobotApiStatus, and CLI workflows)

    C# types:
    - [Robot.ApiServer]: HTTP listener, request queue, SSE manager
    - [Robot.ApiRouter]: compiled route table with pattern matching
    - [Robot.ApiMiddleware]: auth, CORS, rate limiting, body size guard
    - [Robot.ApiTokenStore]: concurrent multi-token store for Bearer auth
    - [Robot.ApiResponseCache]: fingerprint-based sidecar file cache for HTTP responses
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

        .PARAMETER Force
        Stop any existing process listening on the target port before starting.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [int]$Port,
        [string]$Address,
        [int]$Workers,
        [switch]$ReadOnly,
        [switch]$Quiet,
        [switch]$Force,
        [Parameter(HelpMessage = "Enable debug mode — dashboard emits debug-level console output")]
        [switch]$DebugMode
    )

    # Fail early if C# types weren't compiled — avoids cryptic errors downstream
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
    if ($DebugMode){ $Config.DebugMode   = $true }

    # Fallback defaults when plugin.psd1 is missing or incomplete
    if (-not $Config.ListenPort)         { $Config.ListenPort         = 8642 }
    if (-not $Config.ListenAddress)      { $Config.ListenAddress      = 'localhost' }
    if (-not $Config.WorkerCount)        { $Config.WorkerCount        = 8 }
    if (-not $Config.RateLimitPerSecond) { $Config.RateLimitPerSecond = 100 }
    if (-not $Config.MaxRequestBody)     { $Config.MaxRequestBody     = 65536 }  # 64 KB

    $Prefix = "http://$($Config.ListenAddress):$($Config.ListenPort)/api/"

    # Detect port conflict before attempting to bind
    $PortBusy = $false
    try {
        $TcpProbe = [System.Net.Sockets.TcpClient]::new()
        $TcpProbe.Connect('localhost', $Config.ListenPort)
        [void]$TcpProbe.Dispose()
        $PortBusy = $true
    } catch { }

    if ($PortBusy -and -not $Force) {
        $ListenerPid = $null
        if ($IsMacOS -or $IsLinux) {
            $ListenerPid = & lsof -i ":$($Config.ListenPort)" -t -sTCP:LISTEN 2>$null |
                Select-Object -First 1
        }
        $PidHint = if ($ListenerPid) { " (PID $ListenerPid)" } else { '' }
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Port $($Config.ListenPort) is already in use${PidHint}. " +
                    'Use -Force to stop the existing listener and start a new instance.'),
                'ApiPortInUse',
                [System.Management.Automation.ErrorCategory]::ResourceExists,
                $Prefix))
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Prefix, 'Start REST API server')) { return }

    # -Force: stop existing listener before startup
    if ($PortBusy) {
        # If the current process owns the listener, shut down gracefully first
        if ($script:ApiServerInstance -and $script:ApiServerInstance.IsRunning) {
            if (-not $Quiet) {
                Write-RobotInfo "[Start-RobotApi] Stopping in-process API server on port $($Config.ListenPort)"
            }
            Stop-RobotApi
        } else {
            # External process — find and kill by PID
            $ListenerPids = @()
            if ($IsMacOS -or $IsLinux) {
                $ListenerPids = @(& lsof -i ":$($Config.ListenPort)" -t -sTCP:LISTEN 2>$null |
                    Select-Object -Unique)
            } elseif (Get-Command 'Get-NetTCPConnection' -ErrorAction SilentlyContinue) {
                $ListenerPids = @(
                    Get-NetTCPConnection -LocalPort $Config.ListenPort -State Listen `
                        -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty OwningProcess -Unique)
            }
            $MyPid = $PID  # current process — must not kill ourselves
            foreach ($Lpid in $ListenerPids) {
                if ([int]$Lpid -eq $MyPid) { continue }
                if (-not $Quiet) {
                    Write-RobotInfo "[Start-RobotApi] Stopping process $Lpid on port $($Config.ListenPort)"
                }
                Stop-Process -Id ([int]$Lpid) -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 500
    }

    # ── Gitignore protective-entries pre-flight (WP-18) ──────────────
    # Refuse to start if a rule that protects a runtime artifact has
    # been removed or un-ignored. Fail-loud with the exact remediation.
    if (Get-Command 'Test-GitignoreIntegrity' -ErrorAction SilentlyContinue) {
        $Integrity = Test-GitignoreIntegrity
        if (-not $Integrity.Ok) {
            $Parts = @()
            if ($Integrity.Missing.Count -gt 0)   {
                $Parts += "missing rules: $($Integrity.Missing -join ', ')"
            }
            if ($Integrity.Unignored.Count -gt 0) {
                $Parts += "negative overrides: $($Integrity.Unignored -join ', ')"
            }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        ".gitignore protective entries broken ($($Parts -join '; ')). " +
                        "Restore the missing rules from templates/gitignore.required before starting the API server."),
                    'GitignoreIntegrityFailed',
                    [System.Management.Automation.ErrorCategory]::SecurityError,
                    $null))
            return
        }
    }

    # Build C# engine components
    $Server     = [Robot.ApiServer]::new()
    $Router     = [Robot.ApiRouter]::new()
    $Middleware  = [Robot.ApiMiddleware]::new()

    $Middleware.CorsOrigin         = $Config.CorsOrigin
    $Middleware.ReadOnly           = [bool]$Config.ReadOnly
    $Middleware.MaxRequestBody     = [int]$Config.MaxRequestBody
    $Middleware.RateLimitPerSecond = [int]$Config.RateLimitPerSecond
    $Middleware.RateLimitBurst     = [int]$Config.RateLimitPerSecond * 2  # 2x sustained rate as burst headroom

    # Initialize multi-token store — shared with New/Remove-RobotApiToken for hot-reload
    . "$PSScriptRoot/../private/api-token-helpers.ps1"
    $TokenStore = [Robot.ApiTokenStore]::new()
    $Middleware.TokenStore = $TokenStore

    # Load persistent tokens — file may not exist on first run
    $TokenFilePath = Resolve-TokenFilePath
    if ([System.IO.File]::Exists($TokenFilePath)) {
        if (-not (Test-TokenFileGitignored -Path $TokenFilePath)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "SECURITY: Token file '$TokenFilePath' is NOT gitignored. " +
                        "Add it to .gitignore before starting the API server."),
                    'TokenFileNotGitignored',
                    [System.Management.Automation.ErrorCategory]::SecurityError,
                    $TokenFilePath))
            return
        }
        Sync-ApiTokenStore -TokenStore $TokenStore -FilePath $TokenFilePath
    }

    # ── Margonem audit log (WP-16) ──────────────────────────────────────
    # Path published as a static field so worker runspaces (isolated $script:)
    # can pick it up via [Robot.ApiServer]::MargonemAuditLogPath.
    . "$PSScriptRoot/../private/margonem-audit.ps1"
    if ($Config.MargonemAuditLogFile) {
        $AuditRel = [string]$Config.MargonemAuditLogFile
        $AuditPath = if ([System.IO.Path]::IsPathRooted($AuditRel)) {
            $AuditRel
        } else {
            [System.IO.Path]::Combine((Get-RepoRoot), $AuditRel)
        }
        Initialize-MargonemAuditLog -Path $AuditPath
        [Robot.ApiServer]::MargonemAuditLogPath = $AuditPath
    }

    # ── Session token store (Margonem-minted ephemeral tokens, WP-4/5) ──
    $SessionStore = [Robot.ApiSessionTokenStore]::new()
    if ($Config.SessionTokenMaxEntries) {
        $SessionStore.MaxEntries = [int]$Config.SessionTokenMaxEntries
    }
    $Middleware.SessionStore = $SessionStore
    [Robot.ApiServer]::SessionStore = $SessionStore  # cross-runspace access

    # ── Margonem public key (WP-1/7) ────────────────────────────────────
    # Resolve path → repo-root/MargonemPublicKeyFile (default
    # .robot.local/.cache/margonem/signing-key.pem). Load is best-effort
    # at startup; if it fails, /auth/margonem* return 503 until a
    # successful /auth/margonem/refresh-key call or a restart.
    $MargonemKeyPath = $null
    if ($Config.MargonemPublicKeyFile) {
        $KeyRel = [string]$Config.MargonemPublicKeyFile
        if ([System.IO.Path]::IsPathRooted($KeyRel)) {
            $MargonemKeyPath = $KeyRel
        } else {
            $MargonemKeyPath = [System.IO.Path]::Combine((Get-RepoRoot), $KeyRel)
        }
    }
    if ($MargonemKeyPath) {
        if ([System.IO.File]::Exists($MargonemKeyPath)) {
            try {
                [Robot.MargonemPublicKeyCache]::Load($MargonemKeyPath)
                if (-not $Quiet) {
                    Write-RobotInfo "[Start-RobotApi] Margonem public key loaded from $MargonemKeyPath"
                }
            } catch {
                Write-RobotWarning "[Start-RobotApi] Failed to load Margonem public key from ${MargonemKeyPath}: $_"
            }
        } elseif (-not $Quiet) {
            Write-RobotWarning "[Start-RobotApi] Margonem public key not found at $MargonemKeyPath — /auth/margonem will return 503 until refreshed"
        }
    }

    # ── Open-access hardening (WP-14, Option D) ─────────────────────────
    # Refuse to start without auth when:
    #   (a) Margonem is configured (PEM path set, even if missing — signals
    #       this is a gated deployment), OR
    #   (b) bound to a non-loopback interface (signals "exposed to others").
    # Localhost + no auth + no Margonem stays open (dev path preserved).
    $IsLocalBind = $Config.ListenAddress -in @('localhost', '127.0.0.1', '::1')
    $HasAuth     = (-not $TokenStore.IsEmpty) -or [bool]$Config.AuthToken
    $HasMargonem = [bool]$MargonemKeyPath
    if (-not $HasAuth -and ($HasMargonem -or -not $IsLocalBind)) {
        $Why = if ($HasMargonem) {
            'Margonem auth is configured (MargonemPublicKeyFile) but no operator token exists.'
        } else {
            "ListenAddress '$($Config.ListenAddress)' is not loopback and no operator token exists."
        }
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "$Why Refusing to start in open-access mode. " +
                    "Run: New-RobotApiToken -Name 'admin' -Scopes 'admin:all' " +
                    "(or set ROBOT_API_TOKEN env var, or bind ListenAddress to localhost)."),
                'OpenAccessNotPermitted',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                $Config.ListenAddress))
        return
    }

    # Fall back to legacy single AuthToken from config when no multi-token store exists
    if ($Config.AuthToken -and $TokenStore.IsEmpty) {
        $Middleware.AuthToken = $Config.AuthToken
    }

    # Load help sidecar files from help/ directory
    $HelpDir = Join-Path $PSScriptRoot '..' 'help'
    $HelpType = ([System.Management.Automation.PSTypeName]'Robot.ApiHelpRegistry').Type
    if ($HelpType -and (Test-Path $HelpDir)) {
        $HelpType::Load($HelpDir)
    } elseif (-not $Quiet) {
        if (-not $HelpType) {
            Write-RobotWarning '[Start-RobotApi] Robot.ApiHelpRegistry not compiled — /help endpoint unavailable (restart session)'
        } else {
            Write-RobotWarning "[Start-RobotApi] help/ directory not found at $HelpDir — /help endpoint will be empty"
        }
    }

    # Register routes
    . "$PSScriptRoot/../private/api-routes.ps1"
    $HandlerMap = Register-AllApiRoutes -Router $Router -Server $Server

    # Start C# HTTP listener — begins accepting connections and queuing requests
    $Server.Start($Prefix, $Router, $Middleware)
    $script:ApiServerInstance = $Server

    # Initialize response cache — static fields for cross-runspace access
    [Robot.ApiServer]::RepoRoot = Get-RepoRoot
    $ResponseCache = [Robot.ApiResponseCache]::new()
    $ResponseCache.CacheDirectory = [System.IO.Path]::Combine(
        [Robot.ApiServer]::RepoRoot, '.robot.local', '.cache', 'api')
    [Robot.ApiServer]::ResponseCache = $ResponseCache
    [Robot.ApiServer]::Debug = [bool]$Config.DebugMode

    # Launch PowerShell runspace pool to dequeue and process requests
    . "$PSScriptRoot/../private/api-worker.ps1"
    Start-ApiWorkerPool -Server $Server -HandlerMap $HandlerMap `
        -WorkerCount ([int]$Config.WorkerCount)

    if (-not $Quiet) {
        Write-RobotInfo "[Start-RobotApi] C# engine started on $Prefix"
        Write-RobotInfo "[Start-RobotApi] $($Config.WorkerCount) PowerShell workers active"
        Write-RobotInfo "[Start-RobotApi] Rate limit: $($Config.RateLimitPerSecond) req/s per IP"
    }

    if ([Robot.ApiServer]::Debug -and -not $Quiet) {
        Write-RobotInfo "[Start-RobotApi] DEBUG MODE enabled — dashboard will emit debug logs"
    }

    return Get-RobotApiStatus
}

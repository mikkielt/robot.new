<#
    .SYNOPSIS
    Auth API endpoint handlers for token management and identity via REST.

    .DESCRIPTION
    This file contains handlers for the /auth/* endpoints:

    - Invoke-ApiCreateToken: POST /auth/token (auth:manage) — validates
      JSON body for required name/scopes fields, delegates to
      New-RobotApiToken, returns the one-time plaintext token in the 201
      response (only time it is visible).
    - Invoke-ApiDeleteToken: DELETE /auth/token/:name (auth:manage) —
      extracts token name from path parameter, delegates to
      Remove-RobotApiToken.
    - Invoke-ApiGetAuthStatus: GET /auth/status (auth:manage) — enumerates
      all stored tokens via Get-RobotApiToken and returns metadata (name,
      scopes, createdAt) without exposing plaintext token values.
    - Invoke-ApiGetWhoami: GET /auth/whoami (any authenticated token) —
      returns the calling token's name and scopes.

    All handlers follow the standard handler contract: accept a single
    $ApiContext hashtable (PathParams, QueryParams, Body, Method, Path,
    TokenName, TokenScopes) and return a hashtable with StatusCode and
    Body keys. The worker pool serializes Body to JSON before sending
    the HTTP response.
#>

function Invoke-ApiCreateToken {
    <#
        .SYNOPSIS
        Creates a new API token from a JSON body containing name and scopes.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    if (-not $ApiContext.Body) {
        return @{
            StatusCode = 400
            Body = @{ error = 'JSON body required with name and scopes'; status = 400 }
        }
    }

    $Body = $ApiContext.Body
    if (-not $Body.name -or -not $Body.scopes) {
        return @{
            StatusCode = 400
            Body = @{ error = 'name and scopes are required'; status = 400 }
        }
    }

    $TokenName = [string]$Body.name
    $TokenScopes = @($Body.scopes)

    try {
        # -Quiet suppresses Write-RobotWarning; -Confirm:$false bypasses ShouldProcess
        $Result = New-RobotApiToken -Name $TokenName -Scopes $TokenScopes -Quiet -Confirm:$false
        # Return plaintext token — only time it is exposed to the caller
        return @{
            StatusCode = 201
            Body = @{
                name      = $Result.Name
                token     = $Result.Token
                scopes    = $Result.Scopes
                createdAt = $Result.CreatedAt
            }
        }
    } catch {
        return @{
            StatusCode = 422
            Body = @{ error = $_.Exception.Message; status = 422 }
        }
    }
}

function Invoke-ApiDeleteToken {
    <#
        .SYNOPSIS
        Deletes an API token identified by the :name path parameter.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $TokenName = $ApiContext.PathParams['name']
    if (-not $TokenName) {
        return @{
            StatusCode = 400
            Body = @{ error = 'Token name required in path'; status = 400 }
        }
    }

    try {
        Remove-RobotApiToken -Name $TokenName -Quiet -Confirm:$false
        return @{
            StatusCode = 200
            Body = @{ removed = $TokenName }
        }
    } catch {
        return @{
            StatusCode = 422
            Body = @{ error = $_.Exception.Message; status = 422 }
        }
    }
}

function Invoke-ApiGetAuthStatus {
    <#
        .SYNOPSIS
        Returns token store inventory with metadata but no plaintext secrets.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $Tokens = Get-RobotApiToken

    # Project each token to a safe subset — plaintext token value is never included
    $TokenList = [System.Collections.Generic.List[object]]::new()
    foreach ($T in $Tokens) {
        $TokenList.Add(@{
            name      = $T.Name
            scopes    = $T.Scopes
            createdAt = $T.CreatedAt
        })
    }

    return @{
        StatusCode = 200
        Body = @{
            tokenCount = $TokenList.Count
            tokens     = $TokenList.ToArray()
        }
    }
}

function Invoke-ApiGetWhoami {
    <#
        .SYNOPSIS
        Returns the calling token's identity and scopes. Any authenticated
        token can access this endpoint (no specific scope required).
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    return @{
        StatusCode = 200
        Body = @{
            name   = $ApiContext.TokenName
            scopes = @($ApiContext.TokenScopes)
        }
    }
}

function Invoke-ApiAuthMargonem {
    <#
        .SYNOPSIS
        Verifies a Margonem-signed account validation payload and mints
        a short-lived Robot session token bound to the matching Gracz.

        .DESCRIPTION
        Browser add-on calls Margonem's /account/validate with the
        player's cookies, then forwards the response verbatim as
        body.payload. We:
          1. Verify the RSA-SHA256/PKCS#1 signature against the cached
             public key (MargonemValidator — algorithm-pinned).
          2. Reject if abs(server_now - ts) > MargonemFreshnessSeconds.
          3. Map the verified user_id to a Gracz via Resolve-MargonemUser.
          4. Resolve granted scopes via the Resolve-PlayerScopes seam.
          5. Mint a 'rbs_'-prefixed token, register it in
             [Robot.ApiServer]::SessionStore with the configured TTL, and return.

        Never logs the payload, signature, raw bearer, or IP — see
        margonem-audit.ps1 for the audit-log contract.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    . "$PSScriptRoot/margonem-audit.ps1"
    . "$PSScriptRoot/api-token-helpers.ps1"

    $Body = $ApiContext.Body
    if (-not $Body -or -not $Body.payload) {
        Write-MargonemAuditLog -Event 'mint-fail' -Detail @{
            outcome    = 'failure'
            reason     = 'missing-payload'
            httpStatus = 400
        }
        return @{
            StatusCode = 400
            Body = @{ error = 'JSON body with "payload" string required'; status = 400 }
        }
    }

    $Config = Get-PluginConfig -PluginName 'robot-api'
    $FreshnessSeconds = if ($Config.MargonemFreshnessSeconds) {
        [int]$Config.MargonemFreshnessSeconds
    } else { 300 }
    $TtlSeconds = if ($Config.MargonemSessionTtlSeconds) {
        [int]$Config.MargonemSessionTtlSeconds
    } else { 14400 }
    $DefaultScopes = if ($Config.MargonemDefaultScopes) {
        @($Config.MargonemDefaultScopes)
    } else { @('entity:read', 'session:read', 'player:read') }

    $Result = [Robot.MargonemValidator]::Validate(
        [string]$Body.payload, $FreshnessSeconds)

    if (-not $Result.IsValid) {
        $Status = if ($Result.FailureReason -like '*public key is not loaded*') {
            503
        } else { 401 }
        Write-MargonemAuditLog -Event 'mint-fail' -Detail @{
            outcome    = 'failure'
            reason     = $Result.FailureReason
            httpStatus = $Status
        }
        return @{
            StatusCode = $Status
            Body = @{ error = $Result.FailureReason; status = $Status }
        }
    }

    # Map user_id → Player
    try {
        $Player = Resolve-MargonemUser -UserId $Result.UserId
    } catch {
        Write-MargonemAuditLog -Event 'mint-fail' -Detail @{
            outcome        = 'failure'
            reason         = 'ambiguous-mapping'
            margonemUserId = $Result.UserId
            httpStatus     = 409
        }
        return @{
            StatusCode = 409
            Body = @{ error = $_.Exception.Message; status = 409 }
        }
    }
    if (-not $Player) {
        Write-MargonemAuditLog -Event 'mint-fail' -Detail @{
            outcome        = 'failure'
            reason         = 'no-matching-player'
            margonemUserId = $Result.UserId
            httpStatus     = 404
        }
        return @{
            StatusCode = 404
            Body = @{
                error  = "No Robot player registered for Margonem user_id $($Result.UserId)"
                status = 404
            }
        }
    }

    # Scope resolution seam (today: returns defaults unchanged)
    $GrantedScopes = Resolve-PlayerScopes -Player $Player -DefaultScopes $DefaultScopes

    # Mint session token (rbs_-prefixed; distinct namespace from rbt_)
    $TokenValue = New-CryptoToken -Prefix 'rbs_'
    $Now        = [DateTimeOffset]::UtcNow
    $ExpiresAt  = $Now.AddSeconds($TtlSeconds)

    $Info = [Robot.ApiTokenInfo]::new()
    $Info.Name           = "margonem:$($Player.Name)"
    $Info.Scopes         = $GrantedScopes
    $Info.CreatedAt      = $Now.ToString('o')
    $Info.CreatedAtTicks = $Now.UtcTicks
    $Info.ExpiresAt      = $ExpiresAt
    $Info.PlayerName     = $Player.Name
    $Info.MargonemUserId = $Result.UserId

    if (-not [Robot.ApiServer]::SessionStore) {
        return @{
            StatusCode = 503
            Body = @{ error = 'Session store not initialised'; status = 503 }
        }
    }
    if (-not [Robot.ApiServer]::SessionStore.Add($TokenValue, $Info)) {
        return @{
            StatusCode = 500
            Body = @{ error = 'Token collision; retry'; status = 500 }
        }
    }

    Write-MargonemAuditLog -Event 'mint-ok' -Detail @{
        outcome        = 'success'
        tokenName      = $Info.Name
        playerName     = $Player.Name
        margonemUserId = $Result.UserId
        httpStatus     = 201
    }

    return @{
        StatusCode = 201
        Body = @{
            token      = $TokenValue
            name       = $Info.Name
            scopes     = @($GrantedScopes)
            expiresAt  = $ExpiresAt.ToString('o')
            ttlSeconds = $TtlSeconds
            player     = @{
                name       = $Player.Name
                characters = @($Player.Characters | ForEach-Object { @{ name = $_.Name } })
            }
        }
    }
}

function Invoke-ApiGetAuthSessions {
    <#
        .SYNOPSIS
        Lists currently active Margonem session tokens with metadata
        but no raw bearer values. Operator visibility into who is
        currently authenticated.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    if (-not [Robot.ApiServer]::SessionStore) {
        return @{ StatusCode = 200; Body = @{ count = 0; sessions = @() } }
    }
    $List = [Robot.ApiServer]::SessionStore.ListSessions()
    return @{
        StatusCode = 200
        Body = @{
            count    = $List.Count
            sessions = $List.ToArray()
        }
    }
}

function Invoke-ApiRevokePlayerSessions {
    <#
        .SYNOPSIS
        Forcibly invalidates every session token bound to the named player.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    . "$PSScriptRoot/margonem-audit.ps1"

    $PlayerName = $ApiContext.PathParams['player']
    if (-not $PlayerName) {
        return @{
            StatusCode = 400
            Body = @{ error = 'Player name required in path'; status = 400 }
        }
    }
    if (-not [Robot.ApiServer]::SessionStore) {
        return @{ StatusCode = 200; Body = @{ removed = 0; player = $PlayerName } }
    }

    $Removed = [Robot.ApiServer]::SessionStore.RemoveByPlayer($PlayerName)
    Write-MargonemAuditLog -Event 'sessions-invalidated' -Detail @{
        outcome    = 'success'
        reason     = 'operator-revoke'
        playerName = $PlayerName
        removed    = $Removed
        httpStatus = 200
    }
    return @{
        StatusCode = 200
        Body = @{ removed = $Removed; player = $PlayerName }
    }
}

function Invoke-ApiRefreshMargonemKey {
    <#
        .SYNOPSIS
        Fetches the current Margonem account-signing public key from the
        configured CDN URL, validates it parses, atomically replaces the
        on-disk PEM, and hot-reloads the in-memory cache.

        Operator-gated (auth:manage) — outbound HTTPS at refresh time only,
        never on the per-request hot path.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    . "$PSScriptRoot/margonem-audit.ps1"

    $Config = Get-PluginConfig -PluginName 'robot-api'
    $Url = if ($Config.MargonemKeyUrl) {
        [string]$Config.MargonemKeyUrl
    } else { 'http://staticinfo.margonem.pl/.well-known/signing-key.pem' }

    # Resolve PEM path the same way Start-RobotApi does (rooted vs. repo-relative)
    $DestPath = $null
    if ($Config.MargonemPublicKeyFile) {
        $Rel = [string]$Config.MargonemPublicKeyFile
        $DestPath = if ([System.IO.Path]::IsPathRooted($Rel)) {
            $Rel
        } else {
            [System.IO.Path]::Combine((Get-RepoRoot), $Rel)
        }
    }
    if (-not $DestPath) {
        return @{
            StatusCode = 500
            Body = @{ error = 'MargonemPublicKeyFile not configured'; status = 500 }
        }
    }

    $Dir = [System.IO.Path]::GetDirectoryName($DestPath)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $TempPath = "$DestPath.new"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $TempPath -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null
    } catch {
        Write-MargonemAuditLog -Event 'refresh-key' -Detail @{
            outcome    = 'failure'
            reason     = 'upstream-fetch-failed'
            sourceUrl  = $Url
            httpStatus = 502
        }
        return @{
            StatusCode = 502
            Body = @{
                error = "Upstream fetch failed: $($_.Exception.Message)"
                status = 502
                sourceUrl = $Url
            }
        }
    }

    # Validate by loading from temp before swapping in
    try {
        [Robot.MargonemPublicKeyCache]::Load($TempPath)
    } catch {
        try { Remove-Item -LiteralPath $TempPath -ErrorAction Stop } catch { }
        Write-MargonemAuditLog -Event 'refresh-key' -Detail @{
            outcome    = 'failure'
            reason     = 'invalid-pem'
            sourceUrl  = $Url
            httpStatus = 502
        }
        return @{
            StatusCode = 502
            Body = @{
                error = "Downloaded content is not a valid PEM key: $($_.Exception.Message)"
                status = 502
            }
        }
    }

    # Atomic swap (Move overwrites on .NET 5+/PS7 via -Force)
    Move-Item -LiteralPath $TempPath -Destination $DestPath -Force
    # Reload from canonical path so LoadedFromPath is authoritative
    [Robot.MargonemPublicKeyCache]::Load($DestPath)

    Write-MargonemAuditLog -Event 'refresh-key' -Detail @{
        outcome        = 'success'
        sourceUrl      = $Url
        loadedFromPath = [Robot.MargonemPublicKeyCache]::LoadedFromPath
        httpStatus     = 200
    }

    return @{
        StatusCode = 200
        Body = @{
            loadedAt       = [Robot.MargonemPublicKeyCache]::LoadedAt.ToString('o')
            loadedFromPath = [Robot.MargonemPublicKeyCache]::LoadedFromPath
            sourceUrl      = $Url
        }
    }
}

function Invoke-ApiGetMargonemHealth {
    <#
        .SYNOPSIS
        Margonem auth subsystem health probe. Reports local key state,
        reachability of both upstream endpoints, and clock-skew against
        upstream Date header. status: ok | degraded | broken.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $Config = Get-PluginConfig -PluginName 'robot-api'
    $ValidateUrl = if ($Config.MargonemValidateUrl) {
        [string]$Config.MargonemValidateUrl
    } else { 'https://public-api.margonem.pl/account/validate' }
    $KeyUrl = if ($Config.MargonemKeyUrl) {
        [string]$Config.MargonemKeyUrl
    } else { 'http://staticinfo.margonem.pl/.well-known/signing-key.pem' }
    $Freshness = if ($Config.MargonemFreshnessSeconds) {
        [int]$Config.MargonemFreshnessSeconds
    } else { 300 }

    $KeyLoaded = [Robot.MargonemPublicKeyCache]::IsLoaded
    $KeyState = @{
        loaded         = $KeyLoaded
        loadedAt       = if ($KeyLoaded) { [Robot.MargonemPublicKeyCache]::LoadedAt.ToString('o') } else { $null }
        loadedFromPath = if ($KeyLoaded) { [Robot.MargonemPublicKeyCache]::LoadedFromPath } else { $null }
    }

    function _ProbeUrl([string]$Url) {
        $Result = @{ url = $Url; reachable = $false; statusCode = $null; latencyMs = $null; dateHeader = $null; error = $null }
        $SW = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $Resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
            $SW.Stop()
            $Result.reachable  = $true
            $Result.statusCode = [int]$Resp.StatusCode
            $Result.latencyMs  = [int]$SW.ElapsedMilliseconds
            if ($Resp.Headers.Contains('Date')) {
                $Result.dateHeader = ([string[]]$Resp.Headers['Date']) -join ','
            }
        } catch {
            $SW.Stop()
            $Result.latencyMs = [int]$SW.ElapsedMilliseconds
            $Result.error     = $_.Exception.Message
        }
        return $Result
    }

    $ValidateProbe = _ProbeUrl $ValidateUrl
    $KeyProbe      = _ProbeUrl $KeyUrl

    # Clock skew — prefer the validate endpoint's Date
    $Skew = $null
    $SourceDate = if ($ValidateProbe.dateHeader) { $ValidateProbe.dateHeader }
                  elseif ($KeyProbe.dateHeader)  { $KeyProbe.dateHeader }
                  else                            { $null }
    if ($SourceDate) {
        try {
            $UpstreamUtc = [DateTimeOffset]::Parse($SourceDate).ToUniversalTime()
            $Skew = [int]([Math]::Abs(([DateTimeOffset]::UtcNow - $UpstreamUtc).TotalSeconds))
        } catch { }
    }

    $Status = 'ok'
    if (-not $KeyLoaded)                                          { $Status = 'broken' }
    elseif ($null -ne $Skew -and $Skew -gt $Freshness)            { $Status = 'broken' }
    elseif (-not $ValidateProbe.reachable -or -not $KeyProbe.reachable) { $Status = 'degraded' }

    return @{
        StatusCode = 200
        Body = @{
            status                  = $Status
            key                     = $KeyState
            validateEndpoint        = $ValidateProbe
            keyEndpoint             = $KeyProbe
            serverClockSkewSeconds  = $Skew
            freshnessWindowSeconds  = $Freshness
            checkedAt               = ([DateTimeOffset]::UtcNow).ToString('o')
        }
    }
}

function Invoke-ApiVerifyMargonem {
    <#
        .SYNOPSIS
        Verifies a Margonem-signed payload without minting a token.
        Used by cross-service consumers (e.g. log-collector) so they
        don't have to reimplement RSA verification.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    . "$PSScriptRoot/margonem-audit.ps1"

    $Body = $ApiContext.Body
    if (-not $Body -or -not $Body.payload) {
        return @{ StatusCode = 400; Body = @{ error = 'JSON body with "payload" string required'; status = 400 } }
    }

    $Config = Get-PluginConfig -PluginName 'robot-api'
    $Freshness = if ($Config.MargonemFreshnessSeconds) {
        [int]$Config.MargonemFreshnessSeconds
    } else { 300 }

    $Result = [Robot.MargonemValidator]::Validate([string]$Body.payload, $Freshness)

    if (-not $Result.IsValid) {
        $Status = if ($Result.FailureReason -like '*public key is not loaded*') { 503 } else { 401 }
        Write-MargonemAuditLog -Event 'verify-fail' -Detail @{
            outcome    = 'failure'
            reason     = $Result.FailureReason
            httpStatus = $Status
        }
        return @{
            StatusCode = $Status
            Body = @{ valid = $false; reason = $Result.FailureReason; status = $Status }
        }
    }

    Write-MargonemAuditLog -Event 'verify-ok' -Detail @{
        outcome        = 'success'
        margonemUserId = $Result.UserId
        httpStatus     = 200
    }

    return @{
        StatusCode = 200
        Body = @{
            valid            = $true
            userId           = $Result.UserId
            margonemToken    = $Result.Token       # opaque echo — caller already had it
            payloadTimestamp = $Result.Timestamp
            validatedAt      = ([DateTimeOffset]::UtcNow).ToString('o')
        }
    }
}

function Invoke-ApiIntrospectToken {
    <#
        .SYNOPSIS
        RFC 7662–shaped introspection. Accepts a Robot bearer token in
        the body; returns { active, name, scopes, ... } consulting both
        the session and persistent stores.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    . "$PSScriptRoot/margonem-audit.ps1"

    $Body = $ApiContext.Body
    if (-not $Body -or -not $Body.token) {
        return @{ StatusCode = 400; Body = @{ error = 'JSON body with "token" required'; status = 400 } }
    }
    $Subject = [string]$Body.token

    # Session store first (entries can have just expired)
    $Info = $null
    if ([Robot.ApiServer]::SessionStore) {
        $Info = [Robot.ApiServer]::SessionStore.Authenticate($Subject)
    }
    # Persistent store fall-through. The middleware exposes its TokenStore
    # via ApiMiddleware; we reach it through $script:ApiTokenStore which is
    # set in Start-RobotApi and only useful in the main runspace. Workers
    # don't have it, so they only see session tokens — that's acceptable
    # because cross-service introspection is the common case and operators
    # use the persistent flow themselves.
    if ($null -eq $Info -and $script:ApiTokenStore) {
        $Info = $script:ApiTokenStore.Authenticate($Subject)
    }

    Write-MargonemAuditLog -Event 'introspect' -Detail @{
        outcome    = if ($Info) { 'active' } else { 'inactive' }
        tokenName  = if ($Info) { $Info.Name } else { $null }
        httpStatus = 200
    }

    if ($null -eq $Info) {
        return @{ StatusCode = 200; Body = @{ active = $false } }
    }

    $Out = [ordered]@{
        active    = $true
        name      = $Info.Name
        scopes    = @($Info.Scopes)
        createdAt = $Info.CreatedAt
    }
    if ($Info.ExpiresAt)      { $Out.expiresAt      = $Info.ExpiresAt.Value.ToString('o') }
    if ($Info.PlayerName)     { $Out.player         = $Info.PlayerName }
    if ($Info.MargonemUserId) { $Out.margonemUserId = $Info.MargonemUserId.Value }
    return @{ StatusCode = 200; Body = $Out }
}

function Invoke-ApiGetMargonemInfo {
    <#
        .SYNOPSIS
        Public discovery — Margonem auth presence and configuration.
        Unauthenticated; designed for cross-service consumers (log-collector,
        browser add-on) to health-check the integration before credential
        provisioning.

        Returns only public-by-construction information: the PEM SHA-256
        fingerprint (the PEM itself is public), TTL/freshness windows,
        supported endpoints, and the session-token format prefix.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $Config = Get-PluginConfig -PluginName 'robot-api'
    $KeyLoaded = [Robot.MargonemPublicKeyCache]::IsLoaded

    $Fingerprint = $null
    if ($KeyLoaded) {
        try {
            $PemBytes = [System.IO.File]::ReadAllBytes(
                [Robot.MargonemPublicKeyCache]::LoadedFromPath)
            $Sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $Hash = $Sha.ComputeHash($PemBytes)
            } finally { $Sha.Dispose() }
            $Fingerprint = ([BitConverter]::ToString($Hash) -replace '-','').ToLowerInvariant()
        } catch {
            # Best-effort — file may have been deleted between load and now.
            # Leave fingerprint null.
        }
    }

    return @{
        StatusCode = 200
        Body = @{
            margonemAuthEnabled  = $KeyLoaded
            keyFingerprintSha256 = $Fingerprint
            keyLoadedAt          = if ($KeyLoaded) { [Robot.MargonemPublicKeyCache]::LoadedAt.ToString('o') } else { $null }
            freshnessSeconds     = if ($Config.MargonemFreshnessSeconds) {
                [int]$Config.MargonemFreshnessSeconds
            } else { 300 }
            sessionTtlSeconds    = if ($Config.MargonemSessionTtlSeconds) {
                [int]$Config.MargonemSessionTtlSeconds
            } else { 14400 }
            endpoints            = @(
                '/auth/margonem',
                '/auth/margonem/verify',
                '/auth/introspect',
                '/auth/margonem/health',
                '/auth/margonem/refresh-key',
                '/auth/margonem/info'
            )
            tokenFormat          = @{
                prefix   = 'rbs_'
                length   = 48
                alphabet = 'base62'
            }
        }
    }
}

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

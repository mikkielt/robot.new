<#
    .SYNOPSIS
    Creates a new scoped API token and persists it to the token store file.

    .DESCRIPTION
    This file contains New-RobotApiToken which generates a cryptographically
    random Bearer token with a name and set of scopes, writes it to the
    persistent .psd1 token store, and optionally hot-reloads into a running
    API server's in-memory [Robot.ApiTokenStore].

    The raw token value is returned ONCE at creation time. After that, only
    name/scopes/created are retrievable via Get-RobotApiToken.

    Security design:
    - Token file MUST be gitignored — enforced by a pre-flight check that
      throws SecurityError if the file is tracked or unignored.
    - Duplicate token names are rejected (case-insensitive) to prevent
      ambiguity in Remove-RobotApiToken lookups.

    Helpers (dot-sourced from api-token-helpers.ps1):
    - Resolve-TokenFilePath: locates the .psd1 token store path
    - Import-ApiTokenStore / Export-ApiTokenStore: file I/O
    - Test-TokenFileGitignored: gitignore safety pre-flight
    - New-CryptoToken: generates cryptographically random token string

    Module-level data:
    - $script:ApiServerInstance: checked for hot-reload eligibility
    - $script:ApiTokenStore: live [Robot.ApiTokenStore] for in-memory add

    C# types:
    - [Robot.ApiTokenInfo]: token metadata container for ApiTokenStore.Add()

    Supports -WhatIf via SupportsShouldProcess.
#>

function New-RobotApiToken {
    <#
        .SYNOPSIS
        Creates a new scoped API token.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Token name (unique identifier)")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory, HelpMessage = "Scope list (e.g. 'entity:read', 'admin:all')")]
        [ValidateNotNullOrEmpty()]
        [string[]]$Scopes,

        [switch]$Quiet
    )

    . "$PSScriptRoot/../private/api-token-helpers.ps1"

    $TokenFilePath = Resolve-TokenFilePath

    # Refuse to create tokens if the store file would be committed to git
    $TokenDir = [System.IO.Path]::GetDirectoryName($TokenFilePath)
    if ([System.IO.File]::Exists($TokenFilePath) -or [System.IO.Directory]::Exists($TokenDir)) {
        if (-not (Test-TokenFileGitignored -Path $TokenFilePath)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "SECURITY: Token file '$TokenFilePath' is NOT gitignored. " +
                        "Add it to .gitignore before creating tokens."),
                    'TokenFileNotGitignored',
                    [System.Management.Automation.ErrorCategory]::SecurityError,
                    $TokenFilePath))
            return
        }
    }

    # Read existing store and check for duplicate names
    $ExistingTokens = Import-ApiTokenStore -Path $TokenFilePath
    foreach ($T in $ExistingTokens) {
        if ([string]::Equals($T.Name, $Name, 'OrdinalIgnoreCase')) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "Token with name '$Name' already exists."),
                    'DuplicateTokenName',
                    [System.Management.Automation.ErrorCategory]::ResourceExists,
                    $Name))
            return
        }
    }

    # Advisory warning only — custom scopes are stored but won't match any route middleware
    $KnownScopes = @(
        'entity:read', 'entity:write',
        'session:read', 'session:write',
        'player:read', 'player:write',
        'admin:read', 'admin:write', 'admin:all',
        'auth:manage'
    )
    foreach ($S in $Scopes) {
        if ($S -notin $KnownScopes -and -not $Quiet) {
            Write-RobotWarning "[New-RobotApiToken] Unknown scope '$S' — will be stored but may not match any route"
        }
    }

    # Generate token value before ShouldProcess so -WhatIf still validates all preconditions above
    $TokenValue = New-CryptoToken
    $CreatedAt = [DateTime]::UtcNow.ToString('o')  # ISO 8601 round-trip format

    if (-not $PSCmdlet.ShouldProcess($Name, 'Create API token')) { return }

    # Persist new token alongside existing entries (full rewrite of .psd1 file)
    $NewEntry = @{
        Name      = $Name
        Token     = $TokenValue
        Scopes    = @($Scopes)
        CreatedAt = $CreatedAt
    }

    $AllTokens = [System.Collections.Generic.List[object]]::new()
    foreach ($T in $ExistingTokens) { $AllTokens.Add($T) }
    $AllTokens.Add($NewEntry)

    Export-ApiTokenStore -Tokens $AllTokens.ToArray() -Path $TokenFilePath

    # Hot-reload into live server so new token works immediately without restart
    if ($script:ApiServerInstance -and $script:ApiServerInstance.IsRunning) {
        $MW = $null
        # $script:ApiTokenStore is the same ConcurrentDictionary instance that ApiMiddleware uses
        if ($script:ApiTokenStore) {
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = $Name
            $Info.Scopes = @($Scopes)
            $Info.CreatedAt = $CreatedAt
            [void]$script:ApiTokenStore.Add($TokenValue, $Info)
        }
    }

    # Return includes raw Token value — this is the only time it's exposed to the caller
    return [PSCustomObject]@{
        Name      = $Name
        Token     = $TokenValue
        Scopes    = @($Scopes)
        CreatedAt = $CreatedAt
    }
}

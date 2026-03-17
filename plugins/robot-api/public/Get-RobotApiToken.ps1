<#
    .SYNOPSIS
    Lists API tokens from the persistent store (without raw token values).

    .DESCRIPTION
    This file contains Get-RobotApiToken which reads the .psd1 token store
    and returns token metadata (name, scopes, createdAt). Raw token values
    are never exposed — they are only shown once at creation time by
    New-RobotApiToken.

    Reads from the persisted file (not the live ApiTokenStore) so it works
    even when the server is stopped.

    Helpers (dot-sourced from api-token-helpers.ps1):
    - Resolve-TokenFilePath: locates the .psd1 token store path
    - Import-ApiTokenStore: reads and parses the token file

    Supports optional -Name filter for single-token lookup
    (case-insensitive via OrdinalIgnoreCase comparison).
#>

function Get-RobotApiToken {
    <#
        .SYNOPSIS
        Lists API tokens (name, scopes, created — no raw token values).
    #>
    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by token name")]
        [string]$Name
    )

    . "$PSScriptRoot/../private/api-token-helpers.ps1"

    $TokenFilePath = Resolve-TokenFilePath
    $Tokens = Import-ApiTokenStore -Path $TokenFilePath

    # Project into metadata-only objects (strip raw token values for security)
    $Results = [System.Collections.Generic.List[object]]::new()
    foreach ($T in $Tokens) {
        if ($Name -and -not [string]::Equals($T.Name, $Name, 'OrdinalIgnoreCase')) {
            continue
        }
        $Results.Add([PSCustomObject]@{
            Name      = $T.Name
            Scopes    = @($T.Scopes)  # wrapped in @() to guarantee array even for single-scope tokens
            CreatedAt = $T.CreatedAt
        })
    }

    return $Results
}

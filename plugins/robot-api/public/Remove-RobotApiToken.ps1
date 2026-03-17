<#
    .SYNOPSIS
    Removes a named API token from the persistent store and live server.

    .DESCRIPTION
    This file contains Remove-RobotApiToken which finds a token by name in the
    .psd1 token store, removes it from both the file and any running server's
    in-memory [Robot.ApiTokenStore].

    Dual-write removal: the persistent .psd1 file is rewritten without the
    target token, then the live ApiTokenStore (if present) is updated to
    revoke the token immediately without requiring a server restart.

    Helpers (dot-sourced from api-token-helpers.ps1):
    - Resolve-TokenFilePath: locates the .psd1 token store path
    - Import-ApiTokenStore / Export-ApiTokenStore: file I/O

    Module-level data:
    - $script:ApiTokenStore: live [Robot.ApiTokenStore] for in-memory removal

    Supports -WhatIf via SupportsShouldProcess (ConfirmImpact High because
    token removal is irreversible — the raw token value is not recoverable).
#>

function Remove-RobotApiToken {
    <#
        .SYNOPSIS
        Removes a named API token.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param(
        [Parameter(Mandatory, HelpMessage = "Token name to remove")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [switch]$Quiet
    )

    . "$PSScriptRoot/../private/api-token-helpers.ps1"

    $TokenFilePath = Resolve-TokenFilePath
    $ExistingTokens = Import-ApiTokenStore -Path $TokenFilePath

    # Single-pass partition: separate target token from the rest
    $Found = $false
    $Remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($T in $ExistingTokens) {
        if ([string]::Equals($T.Name, $Name, 'OrdinalIgnoreCase')) {
            $Found = $true
        } else {
            $Remaining.Add($T)
        }
    }

    if (-not $Found) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Token with name '$Name' not found."),
                'TokenNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $Name))
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Remove API token')) { return }

    Export-ApiTokenStore -Tokens $Remaining.ToArray() -Path $TokenFilePath

    # Revoke from live server immediately so the token stops working without restart
    if ($script:ApiTokenStore) {
        $RemovedToken = $null
        [void]$script:ApiTokenStore.RemoveByName($Name, [ref]$RemovedToken)  # [ref] out param required by ConcurrentDictionary pattern
    }

    if (-not $Quiet) {
        Write-RobotInfo "[Remove-RobotApiToken] Removed token '$Name'"
    }
}

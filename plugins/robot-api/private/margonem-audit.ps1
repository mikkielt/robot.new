<#
    .SYNOPSIS
    Append-only NDJSON audit log for /auth/margonem outcomes.

    .DESCRIPTION
    Logs the security-relevant events surrounding Margonem auth:
    mint outcomes, verify outcomes, refresh-key actions, session
    invalidations, health probes, and introspect calls.

    Two invariants enforced by callers (not by this helper):
      - NEVER pass the raw payload, signature, or bearer token in $Detail
      - NEVER pass an IP address — operator-confirmed PII boundary

    Initialize-MargonemAuditLog is called once at Start-RobotApi time
    with the resolved file path. Subsequent Write-MargonemAuditLog calls
    are no-ops until Initialize fires (test/dev safety).

    File format: line-delimited compact JSON. Failures to append are
    non-fatal — they emit a warning but never block the request hot
    path, since the audit log is a defence-in-depth tool and losing
    one entry is acceptable.
#>

$script:MargonemAuditPath = $null

function Initialize-MargonemAuditLog {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [string]$Path
    )
    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($Dir -and -not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }
    $script:MargonemAuditPath = $Path
}

function Write-MargonemAuditLog {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [string]$Event,
        [hashtable]$Detail = @{}
    )

    # Worker runspaces don't see the main runspace's $script:MargonemAuditPath —
    # fall through to the static field if present and cache it locally.
    if (-not $script:MargonemAuditPath) {
        if (([System.Management.Automation.PSTypeName]'Robot.ApiServer').Type) {
            $Pinned = [Robot.ApiServer]::MargonemAuditLogPath
            if ($Pinned) { $script:MargonemAuditPath = $Pinned }
        }
    }
    if (-not $script:MargonemAuditPath) { return }  # not initialised (test/dev)

    $Record = [ordered]@{
        ts    = ([DateTimeOffset]::UtcNow).ToString('o')
        event = $Event
    }
    foreach ($K in $Detail.Keys) { $Record[$K] = $Detail[$K] }
    $Line = ConvertTo-Json -InputObject $Record -Compress -Depth 4

    # Append-only; failures are non-fatal (don't break the request hot path)
    try {
        [System.IO.File]::AppendAllText($script:MargonemAuditPath,
            "$Line`n", [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-RobotWarning "[Write-MargonemAuditLog] Append failed: $_"
    }
}

<#
    .SYNOPSIS
    Structured per-run logging for the migration framework.

    .DESCRIPTION
    Generalized from migration/migration-ui.ps1's log helpers — the original
    keyed entries by integer phase number; this version keys by migration ID
    (e.g. "21.3.7-add-currency-tag"). The Polish CLI UI helpers stay in the
    legacy file until WP-13 retires it; here we only own structured plumbing.

    Helpers:
    - Initialize-MigrationLog: opens a fresh log file under .robot.local/res/
    - Write-MigrationLog:      appends a structured entry
    - Flush-MigrationLog:      writes the in-memory buffer to disk

    Module-level data:
    - $script:MigrationLogPath:  absolute path of the active log file
    - $script:MigrationLogLines: in-memory buffer flushed by Flush-MigrationLog

    Log file is overwritten on each Initialize, mirroring the legacy contract:
    the file always reflects the most recent run. For long-term retention,
    operators rely on git history.
#>

$script:MigrationLogPath  = $null
$script:MigrationLogLines = $null

function Initialize-MigrationLog {
    <#
        .SYNOPSIS
        Opens a fresh migration log under <repo>/.robot.local/res/migration-log.txt.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot)

    if (-not $RepoRoot) {
        try { $RepoRoot = Get-RepoRoot } catch { return }
    }

    $ResDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res')
    if (-not [System.IO.Directory]::Exists($ResDir)) {
        [void][System.IO.Directory]::CreateDirectory($ResDir)
    }
    $script:MigrationLogPath  = [System.IO.Path]::Combine($ResDir, 'migration-log.txt')
    $script:MigrationLogLines = [System.Collections.Generic.List[string]]::new(256)

    $Timestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    [void]$script:MigrationLogLines.Add(([string]::new([char]0x2550, 60)))
    [void]$script:MigrationLogLines.Add("  MIGRATION LOG — $Timestamp")
    [void]$script:MigrationLogLines.Add("  This file is overwritten on each run.")
    [void]$script:MigrationLogLines.Add(([string]::new([char]0x2550, 60)))
    [void]$script:MigrationLogLines.Add('')

    Flush-MigrationLog
}

function Write-MigrationLog {
    <#
        .SYNOPSIS
        Appends a structured log entry. Buffered; call Flush to persist.

        .PARAMETER Level
        INFO | WARN | ERROR | ACTION
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('INFO','WARN','ERROR','ACTION')] [string]$Level = 'INFO',
        [string]$MigrationId,
        [Parameter(Mandatory)] [string]$Summary,
        [string[]]$Details
    )

    if (-not $script:MigrationLogLines) {
        # Late initialization (e.g. tests calling Write without Initialize) is a
        # no-op rather than an error — keeps callers terse.
        return
    }

    $Label = if ([string]::IsNullOrWhiteSpace($MigrationId)) { '(framework)' } else { $MigrationId }
    $Timestamp = [datetime]::Now.ToString('HH:mm:ss')
    [void]$script:MigrationLogLines.Add("[$Level] $Timestamp | $Label")
    [void]$script:MigrationLogLines.Add("    $Summary")
    if ($Details) {
        foreach ($Line in $Details) {
            [void]$script:MigrationLogLines.Add("        $Line")
        }
    }
    [void]$script:MigrationLogLines.Add('')
}

function Flush-MigrationLog {
    [CmdletBinding()] param()
    if (-not $script:MigrationLogPath -or -not $script:MigrationLogLines) { return }
    try {
        [System.IO.File]::WriteAllLines(
            $script:MigrationLogPath,
            $script:MigrationLogLines,
            [System.Text.UTF8Encoding]::new($false)
        )
    } catch {
        # Non-fatal — log is best-effort
    }
}

function Get-MigrationLogPath {
    [CmdletBinding()] param()
    return $script:MigrationLogPath
}

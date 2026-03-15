<#
    .SYNOPSIS
    Plugin hook invocation engine and advisory RBAC scope checking.

    .DESCRIPTION
    Non-exported helper functions consumed by core write operations
    (entity-writehelpers.ps1, set-session.ps1) and plugin functions.
    Not auto-loaded by robot.psm1 (non-Verb-Noun filename).

    Contains:
    - Invoke-PluginHook:  dispatches to registered hook handlers in priority order
    - Test-PluginScope:   advisory RBAC scope check for plugin data access

    Hook invocation is designed for zero overhead when no hooks are registered.
    The $script:HookRegistry variable is managed by robot.psm1 during plugin loading.

    Hook phases:
    - BeforeWrite:  can reject by throwing, can mutate data in-place
    - AfterWrite:   side effects only, errors logged but don't abort
    - AfterCreate:  side effects only, errors logged but don't abort

    RBAC is advisory (not a security boundary). When no role configuration exists,
    all access is permitted. Designed for trusted small-team environments.
#>

# Session-scoped cache for RBAC config (local.config.psd1 with Roles/RoleScopes)
$script:CachedRbacConfig     = $null
$script:CachedRbacConfigPath = $null

# Cached command lookups for hook handlers — avoids repeated Get-Command per invocation
$script:HookCommandCache = @{}

function Invoke-PluginHook {
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [ValidateSet('BeforeWrite', 'AfterWrite', 'AfterCreate')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    # Fast path: no hooks registered at all
    if (-not $script:HookRegistry -or $script:HookRegistry.Count -eq 0) { return }

    $HookKey = "${Operation}:${Phase}"
    if (-not $script:HookRegistry.ContainsKey($HookKey)) { return }

    $Handlers = $script:HookRegistry[$HookKey]
    if ($Handlers.Count -eq 0) { return }

    foreach ($Handler in $Handlers) {
        $FuncName = $Handler.Handler

        # Cached command lookup — resolve once per function name, reuse on subsequent invocations
        if ($script:HookCommandCache.ContainsKey($FuncName)) {
            $Cmd = $script:HookCommandCache[$FuncName]
            if ($Cmd -is [System.DBNull]) { continue }
        } else {
            $Cmd = Get-Command $FuncName -ErrorAction SilentlyContinue
            if (-not $Cmd) {
                $script:HookCommandCache[$FuncName] = [DBNull]::Value
                [System.Console]::Error.WriteLine(
                    "[WARN plugin-hooks] Handler '$FuncName' from plugin '$($Handler.Plugin)' not found - skipping")
                continue
            }
            # Safety: handler must be a user-defined Function, not a Cmdlet/Alias/Application
            if ($Cmd.CommandType -ne 'Function') {
                $script:HookCommandCache[$FuncName] = [DBNull]::Value
                [System.Console]::Error.WriteLine(
                    "[WARN plugin-hooks] Handler '$FuncName' is a $($Cmd.CommandType), not a Function - skipping")
                continue
            }
            $script:HookCommandCache[$FuncName] = $Cmd
        }

        try {
            & $Cmd -HookContext $Context
        }
        catch {
            if ($Phase -eq 'BeforeWrite') {
                # Re-throw to abort the write operation
                throw "Plugin '$($Handler.Plugin)' hook '$FuncName' rejected operation: $_"
            }
            # AfterWrite/AfterCreate hooks log errors but don't abort
            [System.Console]::Error.WriteLine(
                "[WARN plugin-hooks] Hook '$FuncName' from plugin '$($Handler.Plugin)' failed: $_")
        }
    }
}

# Advisory RBAC scope check.
# Returns $true if the current user has the required scope, or if no RBAC is configured.
# User identity resolved from $env:ROBOT_USER or git config user.name.
function Test-PluginScope {
    param(
        [Parameter(Mandatory)]
        [string]$RequiredScope,

        [string]$User
    )

    if (-not $User) {
        $User = [System.Environment]::GetEnvironmentVariable('ROBOT_USER')
        if (-not $User) {
            $GitProc = $null
            try {
                $GitProc = [System.Diagnostics.Process]::new()
                $GitProc.StartInfo.FileName = 'git'
                $GitProc.StartInfo.Arguments = 'config user.name'
                $GitProc.StartInfo.UseShellExecute = $false
                $GitProc.StartInfo.RedirectStandardOutput = $true
                $GitProc.StartInfo.CreateNoWindow = $true
                [void]$GitProc.Start()
                $GitUser = $GitProc.StandardOutput.ReadToEnd().Trim()
                $GitProc.WaitForExit()
                if ($GitUser) { $User = $GitUser }
            } catch { }
            finally {
                if ($GitProc) { $GitProc.Dispose() }
            }
        }
    }

    # No user identity -> permissive (trusted environment)
    if (-not $User) { return $true }

    # Load role config from core local.config.psd1
    if (-not $script:ModuleRoot) { return $true }

    $CoreLocalPath = [System.IO.Path]::Combine($script:ModuleRoot, 'local.config.psd1')
    if (-not [System.IO.File]::Exists($CoreLocalPath)) { return $true }

    $CoreLocal = $null
    if ($script:CachedRbacConfigPath -and
        [string]::Equals($script:CachedRbacConfigPath, $CoreLocalPath, 'Ordinal') -and
        $script:CachedRbacConfig) {
        $CoreLocal = $script:CachedRbacConfig
    } else {
        try {
            $CoreLocal = Import-PowerShellDataFile -Path $CoreLocalPath
            $script:CachedRbacConfigPath = $CoreLocalPath
            $script:CachedRbacConfig     = $CoreLocal
        } catch { return $true }
    }

    if (-not $CoreLocal.Roles -or -not $CoreLocal.RoleScopes) { return $true }

    $Role = $CoreLocal.Roles[$User.ToLowerInvariant()]
    if (-not $Role) { return $false }  # Unknown user -> denied

    $Scopes = $CoreLocal.RoleScopes[$Role]
    if (-not $Scopes) { return $false }

    # Check for wildcard admin scope
    if ('admin:all' -in $Scopes) { return $true }

    # Exact scope match
    if ($RequiredScope -in $Scopes) { return $true }

    # Hierarchical match: entity:read:own matches entity:read
    $Parts = $RequiredScope.Split(':')
    for ($i = $Parts.Count; $i -ge 2; $i--) {
        $Partial = ($Parts[0..($i-1)]) -join ':'
        if ($Partial -in $Scopes) { return $true }
    }

    return $false
}

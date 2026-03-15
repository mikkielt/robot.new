<#
    .SYNOPSIS
    Plugin hook invocation engine and advisory RBAC scope checking.

    .DESCRIPTION
    Non-exported helper functions consumed by core write operations
    (entity-writehelpers.ps1, set-session.ps1) and plugin functions.
    Not auto-loaded by robot.psm1 (non-Verb-Noun filename).

    Helpers:
    - Invoke-PluginHook:  dispatches to registered hook handlers in priority order
    - Test-PluginScope:   advisory RBAC scope check for plugin data access

    Module-level data:
    - $script:CachedRbacConfig:     session-scoped cache for local.config.psd1 RBAC data
    - $script:CachedRbacConfigPath: path of the cached config (invalidation key)
    - $script:HookCommandCache:     per-function-name command resolution cache (avoids repeated Get-Command)

    Hook invocation is designed for zero overhead when no hooks are registered:
    three early-return guards (no registry, no key, no handlers) exit before any
    work. When hooks exist, handlers are resolved once per function name and cached
    with [DBNull]::Value as a negative-lookup sentinel.

    Hook phases:
    - BeforeWrite:  can reject by throwing, can mutate data in-place
    - AfterWrite:   side effects only, errors logged but don't abort
    - AfterCreate:  side effects only, errors logged but don't abort

    RBAC is advisory (not a security boundary). When no role configuration exists,
    all access is permitted. Designed for trusted small-team environments. User
    identity resolves from $env:ROBOT_USER first, then falls back to git config
    user.name. Scopes support hierarchical matching (entity:read:own matches
    entity:read) and a wildcard admin:all scope.
#>

$script:CachedRbacConfig     = $null
$script:CachedRbacConfigPath = $null
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

        if ($script:HookCommandCache.ContainsKey($FuncName)) {
            $Cmd = $script:HookCommandCache[$FuncName]
            if ($Cmd -is [System.DBNull]) { continue }  # negative-lookup sentinel
        } else {
            $Cmd = Get-Command $FuncName -ErrorAction SilentlyContinue
            if (-not $Cmd) {
                $script:HookCommandCache[$FuncName] = [DBNull]::Value  # negative-lookup sentinel
                [System.Console]::Error.WriteLine(
                    "[WARN Invoke-PluginHook] Handler '$FuncName' from plugin '$($Handler.Plugin)' not found - skipping")
                continue
            }
            # Safety: handler must be a user-defined Function, not a Cmdlet/Alias/Application
            if ($Cmd.CommandType -ne 'Function') {
                $script:HookCommandCache[$FuncName] = [DBNull]::Value
                [System.Console]::Error.WriteLine(
                    "[WARN Invoke-PluginHook] Handler '$FuncName' is a $($Cmd.CommandType), not a Function - skipping")
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
                "[WARN Invoke-PluginHook] Hook '$FuncName' from plugin '$($Handler.Plugin)' failed: $_")
        }
    }
}

function Test-PluginScope {
    param(
        [Parameter(Mandatory)]
        [string]$RequiredScope,

        [string]$User
    )

    if (-not $User) {
        $User = [System.Environment]::GetEnvironmentVariable('ROBOT_USER')
        if (-not $User) {
            # Use .NET Process to avoid pipeline overhead and module-internal git wrapper dependency
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

    if ('admin:all' -in $Scopes) { return $true }  # wildcard admin bypass
    if ($RequiredScope -in $Scopes) { return $true }

    # Hierarchical match: progressively shorten scope (entity:read:own -> entity:read)
    $Parts = $RequiredScope.Split(':')
    for ($i = $Parts.Count; $i -ge 2; $i--) {
        $Partial = ($Parts[0..($i-1)]) -join ':'
        if ($Partial -in $Scopes) { return $true }
    }

    return $false
}

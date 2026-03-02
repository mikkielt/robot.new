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

        # Verify the function exists (may have failed to load)
        $Cmd = Get-Command $FuncName -ErrorAction SilentlyContinue
        if (-not $Cmd) {
            [System.Console]::Error.WriteLine(
                "[WARN plugin-hooks] Handler '$FuncName' from plugin '$($Handler.Plugin)' not found - skipping")
            continue
        }

        try {
            & $FuncName -HookContext $Context
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
        }
    }

    # No user identity -> permissive (trusted environment)
    if (-not $User) { return $true }

    # Load role config from core local.config.psd1
    if (-not $script:ModuleRoot) { return $true }

    $CoreLocalPath = [System.IO.Path]::Combine($script:ModuleRoot, 'local.config.psd1')
    if (-not [System.IO.File]::Exists($CoreLocalPath)) { return $true }

    $CoreLocal = $null
    try { $CoreLocal = Import-PowerShellDataFile -Path $CoreLocalPath } catch { return $true }

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

<#
    .SYNOPSIS
    Dashboard endpoint handler for serving the assembled HTML SPA.

    .DESCRIPTION
    Invoke-ApiGetDashboard serves the dashboard as a single assembled HTML
    response. Source files are resolved from (in priority order):
    1. Robot.Dashboard/src/ — the standalone dashboard project (sibling of
       Robot.PowerShell in the repository root)
    2. plugins/robot-dashboard/private/ — legacy plugin location (fallback)

    The HTML skeleton, CSS, and JS modules are read from separate source
    files and assembled on first request per worker runspace, then cached
    as a byte array.

    Returns 404 if neither location contains dashboard sources.

    Module-level data:
    - $script:DashboardHtmlBytes: cached byte[] of the assembled HTML,
      populated on first request per worker runspace
    - $script:DashboardJsFiles: ordered list of JS source files to
      concatenate during assembly
#>

# Per-runspace cache — populated on first request, reused for subsequent calls
$script:DashboardHtmlBytes = $null

# JS files loaded in this order during assembly
$script:DashboardJsFiles = @(
    'dashboard-core.js'
    'dashboard-nav.js'
    'dashboard-sessions.js'
    'dashboard-session-create.js'
    'dashboard-entities.js'
    'dashboard-locations.js'
    'dashboard-players.js'
    'dashboard-reports.js'
    'dashboard-tokens.js'
    'dashboard-init.js'
)

# HTML body template for standalone assembly
$script:DashboardBodyHtml = @'
<header>
  <div class="header-top">
    <h1>Nerthus</h1>
    <div class="header-actions">
      <button class="config-toggle" onclick="toggleApiConfig()" title="Ustawienia API">&#x2699;</button>
      <button onclick="toggleTheme()" id="themeBtn" title="Zmie&#x0144; motyw">&#x263E;</button>
      <span id="whoami" class="badge blue"></span>
    </div>
  </div>
  <div id="api-url-bar" class="api-config">
    <span>API:</span>
    <input type="text" id="apiUrl" placeholder="http://localhost:8642/api">
    <input type="password" id="apiToken" placeholder="Token">
    <button onclick="saveApiConfig()" title="Zapisz">&#x2713;</button>
    <button onclick="showWhoami()" title="Kim jestem?">Kim jestem?</button>
  </div>
</header>
<nav id="nav">
  <button class="nav-toggle" id="navToggle" onclick="toggleNav()">Sesje &#x25BE;</button>
  <div class="nav-items" id="navItems"></div>
</nav>
<main id="main">
  <!-- Sections injected by JS based on scopes -->
</main>
'@

function Invoke-ApiGetDashboard {
    <#
        .SYNOPSIS
        Serves the dashboard SPA as text/html via RawBody response path.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    # Assemble and cache HTML on first request per runspace
    if ($null -eq $script:DashboardHtmlBytes) {
        $ModRoot = $script:ModuleRoot
        if (-not $ModRoot) {
            # Fallback: derive from handler file location
            $ModRoot = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
        }

        # Priority 1: Robot.Dashboard/src/ (standalone project)
        $RepoRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($ModRoot, '..'))
        $StandaloneSrc = [System.IO.Path]::Combine($RepoRoot, 'Robot.Dashboard', 'src')
        $StandaloneCss = [System.IO.Path]::Combine($StandaloneSrc, 'css', 'dashboard.css')

        # Priority 2: plugins/robot-dashboard/private/ (legacy)
        $PluginPrivate = [System.IO.Path]::Combine(
            $ModRoot, 'plugins', 'robot-dashboard', 'private')
        $PluginHtml = [System.IO.Path]::Combine($PluginPrivate, 'dashboard.html')

        if ([System.IO.File]::Exists($StandaloneCss)) {
            # Standalone mode — read from Robot.Dashboard/src/
            $Css = [System.IO.File]::ReadAllText($StandaloneCss)

            $JsParts = [System.Collections.Generic.List[string]]::new()
            foreach ($JsFile in $script:DashboardJsFiles) {
                $JsPath = [System.IO.Path]::Combine($StandaloneSrc, 'js', $JsFile)
                if ([System.IO.File]::Exists($JsPath)) {
                    $Content = [System.IO.File]::ReadAllText($JsPath)
                    # Strip per-file 'use strict'; — the assembled wrapper provides it
                    if ($Content.StartsWith("'use strict';")) {
                        $Content = $Content.Substring(14)
                    }
                    [void]$JsParts.Add($Content)
                }
            }

            $Assembled = "<!DOCTYPE html>`n<html lang=`"pl`">`n<head>`n" +
                "<meta charset=`"utf-8`">`n" +
                "<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">`n" +
                "<title>Nerthus Dashboard</title>`n<style>`n$Css`n</style>`n</head>`n<body>`n" +
                $script:DashboardBodyHtml + "`n" +
                "<script>`n'use strict';`n" + ($JsParts -join "`n`n") +
                "`n</script>`n</body>`n</html>"
            $script:DashboardHtmlBytes = [System.Text.Encoding]::UTF8.GetBytes($Assembled)
        }
        elseif ([System.IO.File]::Exists($PluginHtml)) {
            # Legacy plugin mode — read from plugins/robot-dashboard/private/
            $Html = [System.IO.File]::ReadAllText($PluginHtml)

            $CssPath = [System.IO.Path]::Combine($PluginPrivate, 'dashboard.css')
            $Css = if ([System.IO.File]::Exists($CssPath)) {
                [System.IO.File]::ReadAllText($CssPath)
            } else { '' }

            $JsParts = [System.Collections.Generic.List[string]]::new()
            foreach ($JsFile in $script:DashboardJsFiles) {
                $JsPath = [System.IO.Path]::Combine($PluginPrivate, $JsFile)
                if ([System.IO.File]::Exists($JsPath)) {
                    [void]$JsParts.Add([System.IO.File]::ReadAllText($JsPath))
                }
            }

            $Assembled = $Html.Replace('{{CSS}}', $Css).Replace('{{JS}}', ($JsParts -join "`n`n"))
            $script:DashboardHtmlBytes = [System.Text.Encoding]::UTF8.GetBytes($Assembled)
        }
    }

    if ($null -eq $script:DashboardHtmlBytes) {
        return @{
            StatusCode = 404
            Body = @{ error = 'Dashboard not installed'; status = 404 }
        }
    }

    return @{
        StatusCode  = 200
        RawBody     = $script:DashboardHtmlBytes
        ContentType = 'text/html; charset=utf-8'
    }
}

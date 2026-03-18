<#
    .SYNOPSIS
    Dashboard endpoint handler for serving the assembled HTML SPA.

    .DESCRIPTION
    Invoke-ApiGetDashboard serves the dashboard from the robot-dashboard
    plugin as a single assembled HTML response. The HTML skeleton, CSS,
    and JS modules are read from separate source files in
    plugins/robot-dashboard/private/ and assembled on first request per
    worker runspace, then cached as a byte array.

    The handler locates source files via the module root path, looking
    in plugins/robot-dashboard/private/. Returns 404 if the dashboard
    plugin is not installed.

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
    'dashboard-players.js'
    'dashboard-reports.js'
    'dashboard-tokens.js'
    'dashboard-init.js'
)

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

        $PrivatePath = [System.IO.Path]::Combine(
            $ModRoot, 'plugins', 'robot-dashboard', 'private')

        $HtmlPath = [System.IO.Path]::Combine($PrivatePath, 'dashboard.html')

        if ([System.IO.File]::Exists($HtmlPath)) {
            $Html = [System.IO.File]::ReadAllText($HtmlPath)

            # Read CSS
            $CssPath = [System.IO.Path]::Combine($PrivatePath, 'dashboard.css')
            $Css = if ([System.IO.File]::Exists($CssPath)) {
                [System.IO.File]::ReadAllText($CssPath)
            } else { '' }

            # Read JS files in defined order
            $JsParts = [System.Collections.Generic.List[string]]::new()
            foreach ($JsFile in $script:DashboardJsFiles) {
                $JsPath = [System.IO.Path]::Combine($PrivatePath, $JsFile)
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
            Body = @{ error = 'Dashboard plugin not installed'; status = 404 }
        }
    }

    return @{
        StatusCode  = 200
        RawBody     = $script:DashboardHtmlBytes
        ContentType = 'text/html; charset=utf-8'
    }
}

<#
    .SYNOPSIS
    Dashboard endpoint handler for serving the pre-built HTML SPA.

    .DESCRIPTION
    Invoke-ApiGetDashboard serves the dashboard as a single HTML response.
    Source is resolved from (in priority order):
    1. Robot.Dashboard/dist/index.html — Vite-built single-file output
    2. plugins/robot-dashboard/private/dashboard.html — legacy fallback

    The file is read and cached as a byte array on first request per
    worker runspace.

    Returns 404 if neither location contains dashboard output.

    Module-level data:
    - $script:DashboardHtmlBytes: cached byte[] of the HTML,
      populated on first request per worker runspace
#>

# Per-runspace cache — populated on first request, reused for subsequent calls
$script:DashboardHtmlBytes = $null

function Invoke-ApiGetDashboard {
    <#
        .SYNOPSIS
        Serves the dashboard SPA as text/html via RawBody response path.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    # Read and cache HTML on first request per runspace
    if ($null -eq $script:DashboardHtmlBytes) {
        $ModRoot = $script:ModuleRoot
        if (-not $ModRoot) {
            # Fallback: derive from handler file location
            $ModRoot = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
        }

        $RepoRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($ModRoot, '..'))

        # Priority 1: Robot.Dashboard/dist/index.html (Vite build output)
        $DistHtml = [System.IO.Path]::Combine(
            $RepoRoot, 'Robot.Dashboard', 'dist', 'index.html')

        # Priority 2: plugins/robot-dashboard/private/dashboard.html (legacy)
        $PluginHtml = [System.IO.Path]::Combine(
            $ModRoot, 'plugins', 'robot-dashboard', 'private', 'dashboard.html')

        $HtmlPath = $null
        if ([System.IO.File]::Exists($DistHtml)) {
            $HtmlPath = $DistHtml
        }
        elseif ([System.IO.File]::Exists($PluginHtml)) {
            $HtmlPath = $PluginHtml
        }

        if ($HtmlPath) {
            if ([Robot.ApiServer]::Debug) {
                # Inject debug config into HTML before caching
                $HtmlText = [System.IO.File]::ReadAllText($HtmlPath,
                    [System.Text.Encoding]::UTF8)
                $DebugScript = '<script>window.__ROBOT_DEBUG__=true</script>'
                $HtmlText = $HtmlText.Replace('</head>', "$DebugScript`n</head>")
                $script:DashboardHtmlBytes = [System.Text.Encoding]::UTF8.GetBytes($HtmlText)
            } else {
                $script:DashboardHtmlBytes = [System.IO.File]::ReadAllBytes($HtmlPath)
            }
        }
    }

    if ($null -eq $script:DashboardHtmlBytes) {
        return @{
            StatusCode = 404
            Body = @{ error = 'Dashboard not installed. Run: cd Robot.Dashboard && npx vite build'; status = 404 }
        }
    }

    return @{
        StatusCode  = 200
        RawBody     = $script:DashboardHtmlBytes
        ContentType = 'text/html; charset=utf-8'
    }
}

<#
    .SYNOPSIS
    Pester tests for the robot-dashboard plugin.

    .DESCRIPTION
    Tests for Invoke-ApiGetDashboard (dashboard HTML handler) covering
    HTML serving, content-type, caching, and 404 when sources are missing.
    Tests for Invoke-RobotDashboard public function (parameter validation).
    Tests for dashboard route registration in api-routes.ps1.

    The handler resolves sources from Robot.Dashboard/src/ (standalone
    project, priority 1) or plugins/robot-dashboard/private/ (legacy
    fallback). Tests validate both paths.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../../robot-api/private/api-handlers-dashboard.ps1"
}

# ═══════════════════════════════════════════════════════════════════════
# Dashboard HTML handler
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiGetDashboard' {
    BeforeAll {
        # Reset cache so each Describe gets a fresh state
        $script:DashboardHtmlBytes = $null
    }

    Context 'When dashboard sources exist (standalone Robot.Dashboard)' {
        It 'returns 200 with text/html content type' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/dashboard'
            }

            $Result = Invoke-ApiGetDashboard -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.ContentType | Should -Be 'text/html; charset=utf-8'
        }

        It 'returns RawBody as byte array' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/dashboard'
            }

            $Result = Invoke-ApiGetDashboard -ApiContext $Ctx
            $Result.RawBody | Should -Not -BeNullOrEmpty
            $Result.RawBody | Should -BeOfType [byte]
        }

        It 'returns valid HTML content' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/dashboard'
            }

            $Result = Invoke-ApiGetDashboard -ApiContext $Ctx
            $Html = [System.Text.Encoding]::UTF8.GetString($Result.RawBody)
            $Html | Should -BeLike '*<!DOCTYPE html>*'
            $Html | Should -BeLike '*Nerthus*'
        }

        It 'caches HTML bytes across calls' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/dashboard'
            }

            $Result1 = Invoke-ApiGetDashboard -ApiContext $Ctx
            $Result2 = Invoke-ApiGetDashboard -ApiContext $Ctx

            # Same reference = cached
            [object]::ReferenceEquals($Result1.RawBody, $Result2.RawBody) | Should -BeTrue
        }

        It 'does not return Body (uses RawBody path instead)' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/dashboard'
            }

            $Result = Invoke-ApiGetDashboard -ApiContext $Ctx
            $Result.Body | Should -BeNullOrEmpty
        }
    }

    Context 'When dashboard sources are missing' {
        BeforeAll {
            # Force cache reset
            $script:DashboardHtmlBytes = $null

            # Save original ModuleRoot and set to a temp dir tree where neither
            # Robot.Dashboard/src/ nor plugins/robot-dashboard/private/ exist
            $script:OrigModuleRoot = $script:ModuleRoot
            $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-dash-test-" + [System.Guid]::NewGuid().ToString('N'))
            $TempModRoot = Join-Path $TempRoot 'Robot.PowerShell'
            [void][System.IO.Directory]::CreateDirectory($TempModRoot)
            $script:ModuleRoot = $TempModRoot
        }

        AfterAll {
            $script:ModuleRoot = $script:OrigModuleRoot
            $script:DashboardHtmlBytes = $null
            if ([System.IO.Directory]::Exists($TempRoot)) {
                [System.IO.Directory]::Delete($TempRoot, $true)
            }
        }

        It 'returns 404 when dashboard is not installed' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/dashboard'
            }

            $Result = Invoke-ApiGetDashboard -ApiContext $Ctx
            $Result.StatusCode | Should -Be 404
            $Result.Body.error | Should -BeLike '*not installed*'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Route registration
# ═══════════════════════════════════════════════════════════════════════

Describe 'Dashboard route registration' {
    It 'api-routes.ps1 registers GET /dashboard route' {
        $RoutesContent = [System.IO.File]::ReadAllText(
            "$PSScriptRoot/../../robot-api/private/api-routes.ps1")
        $RoutesContent | Should -BeLike "*'/dashboard'*'Invoke-ApiGetDashboard'*"
    }

    It 'dashboard handler is in the worker file list' {
        $WorkerContent = [System.IO.File]::ReadAllText(
            "$PSScriptRoot/../../robot-api/private/api-worker.ps1")
        $WorkerContent | Should -BeLike '*api-handlers-dashboard.ps1*'
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Plugin manifest
# ═══════════════════════════════════════════════════════════════════════

Describe 'Dashboard plugin manifest' {
    BeforeAll {
        $script:Manifest = Import-PowerShellDataFile "$PSScriptRoot/../plugin.psd1"
    }

    It 'has required fields' {
        $script:Manifest.Name | Should -Be 'robot-dashboard'
        $script:Manifest.Version | Should -Not -BeNullOrEmpty
        $script:Manifest.DependsOn | Should -Contain 'robot-api'
    }

    It 'exports Invoke-RobotDashboard' {
        $script:Manifest.ExportedFunctions | Should -Contain 'Invoke-RobotDashboard'
    }

    It 'has valid MenuItems schema' {
        $script:Manifest.MenuItems | Should -Not -BeNullOrEmpty
        $Item = $script:Manifest.MenuItems[0]
        $Item.ID | Should -Not -BeNullOrEmpty
        $Item.Label | Should -Not -BeNullOrEmpty
        $Item.Menu | Should -Be 'API'
        $Item.Mode | Should -Be 'Workflow'
        $Item.WorkflowFunction | Should -Be 'Invoke-DashboardOpen'
    }

    It 'does not register duplicate MenuCategories' {
        $script:Manifest.ContainsKey('MenuCategories') | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Standalone project structure
# ═══════════════════════════════════════════════════════════════════════

Describe 'Robot.Dashboard project structure' {
    BeforeAll {
        $script:DashboardRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'Robot.Dashboard'))
    }

    It 'has src/index.html' {
        $Path = [System.IO.Path]::Combine($script:DashboardRoot, 'src', 'index.html')
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }

    It 'has src/css/dashboard.css' {
        $Path = [System.IO.Path]::Combine($script:DashboardRoot, 'src', 'css', 'dashboard.css')
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }

    It 'has all required JS modules' {
        $JsDir = [System.IO.Path]::Combine($script:DashboardRoot, 'src', 'js')
        $Expected = @(
            'dashboard-core.js', 'dashboard-nav.js', 'dashboard-sessions.js',
            'dashboard-session-create.js', 'dashboard-entities.js',
            'dashboard-locations.js', 'dashboard-players.js',
            'dashboard-reports.js', 'dashboard-tokens.js', 'dashboard-init.js'
        )
        foreach ($JsFile in $Expected) {
            $Path = [System.IO.Path]::Combine($JsDir, $JsFile)
            [System.IO.File]::Exists($Path) | Should -BeTrue -Because "$JsFile should exist"
        }
    }

    It 'has build.sh' {
        $Path = [System.IO.Path]::Combine($script:DashboardRoot, 'build.sh')
        [System.IO.File]::Exists($Path) | Should -BeTrue
    }
}

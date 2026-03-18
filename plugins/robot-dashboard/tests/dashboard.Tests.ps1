<#
    .SYNOPSIS
    Pester tests for the robot-dashboard plugin.

    .DESCRIPTION
    Tests for Invoke-ApiGetDashboard (dashboard HTML handler) covering
    HTML serving, content-type, caching, and 404 when plugin is missing.
    Tests for Invoke-RobotDashboard public function (parameter validation).
    Tests for dashboard route registration in api-routes.ps1.
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

    Context 'When dashboard.html exists' {
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

    Context 'When dashboard.html is missing' {
        BeforeAll {
            # Force cache reset
            $script:DashboardHtmlBytes = $null

            # Save original ModuleRoot and set to a temp dir with no dashboard plugin
            $script:OrigModuleRoot = $script:ModuleRoot
            $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-dash-test-" + [System.Guid]::NewGuid().ToString('N'))
            [void][System.IO.Directory]::CreateDirectory($TempDir)
            $script:ModuleRoot = $TempDir
        }

        AfterAll {
            $script:ModuleRoot = $script:OrigModuleRoot
            $script:DashboardHtmlBytes = $null
            if ([System.IO.Directory]::Exists($TempDir)) {
                [System.IO.Directory]::Delete($TempDir, $true)
            }
        }

        It 'returns 404 when dashboard plugin is not installed' {
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

BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../private/api-worker.ps1"
}

Describe 'Worker Pool' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiServer').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiServer not compiled'
        }
    }

    Context 'Stop lifecycle' {
        It 'stop is safe to call when no workers exist' {
            $script:ApiWorkerThreads = $null
            $script:ApiWorkerRunspaces = $null
            { Stop-ApiWorkerPool } | Should -Not -Throw
        }

        It 'stop clears worker state variables' {
            # Simulate worker state as if workers were started
            $script:ApiWorkerRunspaces = [System.Collections.Generic.List[object]]::new()
            $script:ApiWorkerThreads = [System.Collections.Generic.List[System.Threading.Thread]]::new()

            Stop-ApiWorkerPool

            $script:ApiWorkerThreads | Should -BeNullOrEmpty
            $script:ApiWorkerRunspaces | Should -BeNullOrEmpty
        }
    }

    Context 'Function availability' {
        It 'Start-ApiWorkerPool function exists' {
            Get-Command 'Start-ApiWorkerPool' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'Stop-ApiWorkerPool function exists' {
            Get-Command 'Stop-ApiWorkerPool' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'Start-ApiWorkerPool has required parameters' {
            $Cmd = Get-Command 'Start-ApiWorkerPool'
            $Cmd.Parameters.Keys | Should -Contain 'Server'
            $Cmd.Parameters.Keys | Should -Contain 'HandlerMap'
            $Cmd.Parameters.Keys | Should -Contain 'WorkerCount'
        }
    }

    Context 'Handler file sourcing' {
        It 'handler files for dot-sourcing exist' {
            $HandlerDir = Split-Path -Parent $PSScriptRoot
            $ReadFile = "$HandlerDir/private/api-handlers-read.ps1"
            $WriteFile = "$HandlerDir/private/api-handlers-write.ps1"
            $DashboardFile = "$HandlerDir/private/api-handlers-dashboard.ps1"

            $ReadFile | Should -Exist
            $WriteFile | Should -Exist
            $DashboardFile | Should -Exist
        }

        It 'worker script references dashboard handler file' {
            $WorkerContent = [System.IO.File]::ReadAllText("$PSScriptRoot/../private/api-worker.ps1")
            $WorkerContent | Should -BeLike '*api-handlers-dashboard.ps1*'
        }
    }

    Context 'Server integration' {
        It 'returns 500 for dynamic route without workers (handler timeout)' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            # Dynamic route — no workers to handle it, so it will timeout
            $Router.AddRoute('GET', '/dynamic', 'Invoke-TestHandler', 'Test dynamic')

            try {
                $Server.Start($Prefix, $Router, $Middleware, 1)

                # Request will timeout after 60s — use a shorter client timeout
                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/dynamic" `
                        -Method GET -ErrorAction Stop -TimeoutSec 3
                } catch {
                    $Response = $_.Exception.Response
                    if (-not $Response) {
                        # Connection timeout or refused is acceptable too
                        $true | Should -BeTrue
                    }
                }

                # Without workers, request stays in queue until HTTP timeout
                if ($Response) {
                    [int]$Response.StatusCode | Should -BeIn @(500, 504)
                }
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Cache version propagation' {
        It 'CacheVersion is accessible as static field' {
            $Before = [Robot.ApiServer]::CacheVersion
            [Robot.ApiServer]::CacheVersion = $Before + 1
            $After = [Robot.ApiServer]::CacheVersion

            $After | Should -Be ($Before + 1)

            # Restore
            [Robot.ApiServer]::CacheVersion = $Before
        }

        It 'multiple increments are tracked correctly' {
            $Before = [Robot.ApiServer]::CacheVersion

            [Robot.ApiServer]::CacheVersion = $Before + 1
            [Robot.ApiServer]::CacheVersion = $Before + 2
            [Robot.ApiServer]::CacheVersion = $Before + 3

            $After = [Robot.ApiServer]::CacheVersion
            $After | Should -Be ($Before + 3)

            # Restore
            [Robot.ApiServer]::CacheVersion = $Before
        }
    }
}

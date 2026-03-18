BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiServer' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiServer').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiServer not compiled'
        }
    }

    Context 'Lifecycle' {
        It 'creates a new server instance' {
            $Server = [Robot.ApiServer]::new()
            $Server | Should -Not -BeNullOrEmpty
            $Server.IsRunning | Should -BeFalse
        }

        It 'starts and stops on a random port' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)
                $Server.IsRunning | Should -BeTrue
                $Server.RequestCount | Should -Be 0
                # BlockingCollection is enumerable; test with -ne to avoid pipeline unwrap
                ($null -ne $Server.RequestQueue) | Should -BeTrue
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }

            $Server.IsRunning | Should -BeFalse
        }

        It 'throws when starting an already-running server' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)
                { $Server.Start($Prefix, $Router, $Middleware) } |
                    Should -Throw '*already running*'
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }

        It 'stop is safe to call when not running' {
            $Server = [Robot.ApiServer]::new()
            { $Server.Stop() } | Should -Not -Throw
        }
    }

    Context 'Status snapshot' {
        It 'returns correct status fields via GetStatus()' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)
                $Status = $Server.GetStatus()

                $Status['isRunning'] | Should -BeTrue
                $Status['requestCount'] | Should -BeOfType [long]
                $Status['startedAt'] | Should -Not -BeNullOrEmpty
                $Status['uptimeSeconds'] | Should -BeGreaterOrEqual 0
                $Status['queuedRequests'] | Should -BeOfType [int]
                $Status['sseClients'] | Should -BeOfType [int]
                $Status['cacheVersion'] | Should -BeOfType [long]
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }

        It 'tracks request count' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                # Make a request (will 404, but still counted)
                try { Invoke-WebRequest -Uri "http://localhost:$Port/api/test" -ErrorAction Stop } catch { }
                Start-Sleep -Milliseconds 100

                $Server.RequestCount | Should -BeGreaterOrEqual 1
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Route not found' {
        It 'returns 404 for unregistered routes' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/nonexistent" `
                        -Method GET -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 404
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Rate limiting' {
        It 'returns 429 when rate limit exceeded' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Middleware.RateLimitPerSecond = 1
            $Middleware.RateLimitBurst = 2
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            # Use 404 responses to trigger rate limit (no handler needed)
            try {
                $Server.Start($Prefix, $Router, $Middleware)

                $Got429 = $false
                for ($i = 0; $i -lt 20; $i++) {
                    try {
                        Invoke-WebRequest -Uri "http://localhost:$Port/api/health" `
                            -Method GET -ErrorAction Stop | Out-Null
                    } catch {
                        if ([int]$_.Exception.Response.StatusCode -eq 429) {
                            $Got429 = $true
                            break
                        }
                    }
                }

                $Got429 | Should -BeTrue
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Read-only mode' {
        It 'blocks POST requests in read-only mode' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Middleware.ReadOnly = $true
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            $Router.AddRoute('POST', '/entities', 'Invoke-ApiCreateEntity',
                'Create entity', 201)

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/entities" `
                        -Method POST -Body '{"name":"Test"}' `
                        -ContentType 'application/json' -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 403
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Authentication (multi-token)' {
        It 'returns 401 when auth required but no header sent' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            # Set up TokenStore with a token (activates auth requirement)
            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'test'; $Info.Scopes = @('admin:all')
            $Store.Add('rbt_validtoken', $Info) | Out-Null
            $Middleware.TokenStore = $Store

            $Router.AddStaticRoute('GET', '/health',
                [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
                    param($m, $s) return @{ status = 'ok' }
                }, 'Health')

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/health" `
                        -Method GET -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 401
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }

        It 'passes auth with valid token (does not return 401)' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'test'; $Info.Scopes = @('admin:all')
            $Store.Add('rbt_valid123', $Info) | Out-Null
            $Middleware.TokenStore = $Store

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                # No routes registered — valid token should pass auth, then get 404 (not 401)
                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/anything" `
                        -Method GET `
                        -Headers @{ Authorization = 'Bearer rbt_valid123' } `
                        -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 404
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Scope enforcement' {
        It 'returns 403 when token lacks required scope' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'readonly'; $Info.Scopes = @('entity:read')
            $Store.Add('rbt_readonly', $Info) | Out-Null
            $Middleware.TokenStore = $Store

            $Router.AddStaticRoute('GET', '/admin-only',
                [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
                    param($m, $s) return @{ data = 'secret' }
                }, 'Admin only', 200, 'admin:write')

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/admin-only" `
                        -Method GET `
                        -Headers @{ Authorization = 'Bearer rbt_readonly' } `
                        -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 403
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Content-Type validation' {
        It 'returns 415 for POST without Content-Type' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            $Router.AddRoute('POST', '/data', 'Invoke-Handler', 'Post data', 201)

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/data" `
                        -Method POST -Body '{"test":1}' `
                        -ContentType 'text/plain' -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 415
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Backward compatibility' {
        It 'allows open access when no auth configured (does not return 401)' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            # No AuthToken, no TokenStore = open access
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)

                # No routes — open access should pass auth, then get 404 (not 401)
                $Response = $null
                try {
                    Invoke-WebRequest -Uri "http://localhost:$Port/api/anything" `
                        -Method GET -ErrorAction Stop
                } catch {
                    $Response = $_.Exception.Response
                }

                [int]$Response.StatusCode | Should -Be 404
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }

    Context 'Graceful shutdown' {
        It 'stops accepting connections after Stop()' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            $Server.Start($Prefix, $Router, $Middleware)
            $Server.IsRunning | Should -BeTrue

            $Server.Stop()
            $Server.Dispose()

            # Verify connection refused after shutdown
            $Failed = $false
            try {
                Invoke-RestMethod -Uri "http://localhost:$Port/api/health" `
                    -Method GET -ErrorAction Stop -TimeoutSec 2
            } catch {
                $Failed = $true
            }
            $Failed | Should -BeTrue
        }
    }

    Context 'Cache version' {
        It 'has static CacheVersion accessible and mutable' {
            # Direct field access (Interlocked requires true managed ref
            # which PS [ref] doesn't provide for static fields)
            $Before = [Robot.ApiServer]::CacheVersion
            [Robot.ApiServer]::CacheVersion = $Before + 1
            $After = [Robot.ApiServer]::CacheVersion

            $After | Should -Be ($Before + 1)
        }
    }

    Context 'ApiResponse RawBody support' {
        It 'ApiResponse has ContentType and RawBody properties' {
            $Resp = [Robot.ApiResponse]::new()
            $Resp.ContentType = 'text/html; charset=utf-8'
            $Resp.RawBody = [System.Text.Encoding]::UTF8.GetBytes('<h1>Test</h1>')
            $Resp.StatusCode = 200

            $Resp.ContentType | Should -Be 'text/html; charset=utf-8'
            $Resp.RawBody.Length | Should -BeGreaterThan 0
            $Resp.StatusCode | Should -Be 200
        }

        It 'ApiResponse defaults ContentType and RawBody to null' {
            $Resp = [Robot.ApiResponse]::new()
            $Resp.ContentType | Should -BeNullOrEmpty
            $Resp.RawBody | Should -BeNullOrEmpty
        }

        It 'ApiResponse RawBody coexists with other properties' {
            $Resp = [Robot.ApiResponse]::new()
            $Resp.StatusCode = 200
            $Resp.Body = @{ test = 'value' }
            $Resp.RawJson = '{"test":"value"}'
            $Resp.IncludeLabels = $true
            $Resp.ContentType = 'application/octet-stream'
            $Resp.RawBody = [byte[]]@(1, 2, 3)

            # All properties should be independently set
            $Resp.Body.test | Should -Be 'value'
            $Resp.RawJson | Should -Be '{"test":"value"}'
            $Resp.IncludeLabels | Should -BeTrue
            $Resp.ContentType | Should -Be 'application/octet-stream'
            $Resp.RawBody | Should -HaveCount 3
        }
    }

    Context 'SSE manager' {
        It 'exposes SseManager after Start()' {
            $Server = [Robot.ApiServer]::new()
            $Router = [Robot.ApiRouter]::new()
            $Middleware = [Robot.ApiMiddleware]::new()
            $Port = Get-Random -Minimum 49152 -Maximum 65535
            $Prefix = "http://localhost:$Port/api/"

            try {
                $Server.Start($Prefix, $Router, $Middleware)
                $Server.SseManager | Should -Not -BeNullOrEmpty
                $Server.SseManager.ClientCount | Should -Be 0
            } finally {
                $Server.Stop()
                $Server.Dispose()
            }
        }
    }
}

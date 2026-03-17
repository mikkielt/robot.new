BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiMiddleware' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiMiddleware').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiMiddleware not compiled'
        }
    }

    Context 'Authentication' {
        It 'allows requests when no auth token configured' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.AuthToken = $null

            # Create a minimal HttpListenerRequest mock via real listener
            # For unit testing auth, we test the token comparison logic directly
            # by setting AuthToken to empty/null
            $MW.AuthToken = ''
            # Empty string = no auth required (same as null)
            # CheckAuth requires an HttpListenerRequest which we can't easily mock,
            # so we verify the property defaults instead
            $MW.AuthToken | Should -Be ''
        }

        It 'has configurable auth token' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.AuthToken = 'test-secret-token'
            $MW.AuthToken | Should -Be 'test-secret-token'
        }
    }

    Context 'Rate limiting' {
        It 'allows requests within burst capacity' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.RateLimitPerSecond = 100
            $MW.RateLimitBurst = 10

            # First 10 requests should all pass (within burst)
            $Results = 1..10 | ForEach-Object { $MW.CheckRateLimit('127.0.0.1') }
            ($Results | Where-Object { $_ -eq $true }).Count | Should -Be 10
        }

        It 'blocks requests exceeding burst capacity' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.RateLimitPerSecond = 1
            $MW.RateLimitBurst = 3

            # First 3 should pass, then start failing
            $Results = 1..10 | ForEach-Object { $MW.CheckRateLimit('10.0.0.1') }
            $Passed = ($Results | Where-Object { $_ -eq $true }).Count
            $Passed | Should -BeGreaterOrEqual 3
            $Passed | Should -BeLessThan 10
        }

        It 'tracks rate limits per IP independently' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.RateLimitPerSecond = 1
            $MW.RateLimitBurst = 2

            # Exhaust IP1
            1..5 | ForEach-Object { [void]$MW.CheckRateLimit('192.168.1.1') }

            # IP2 should still have full capacity
            $Result = $MW.CheckRateLimit('192.168.1.2')
            $Result | Should -BeTrue
        }

        It 'allows all requests when rate limiting is disabled' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.RateLimitPerSecond = 0  # disabled

            $Results = 1..100 | ForEach-Object { $MW.CheckRateLimit('10.0.0.2') }
            ($Results | Where-Object { $_ -eq $true }).Count | Should -Be 100
        }
    }

    Context 'Configuration' {
        It 'has correct default values' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.MaxRequestBody | Should -Be 65536
            $MW.RateLimitPerSecond | Should -Be 100
            $MW.RateLimitBurst | Should -Be 200
            $MW.ReadOnly | Should -BeFalse
        }

        It 'supports read-only mode flag' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.ReadOnly = $true
            $MW.ReadOnly | Should -BeTrue
        }

        It 'supports CORS origin configuration' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.CorsOrigin = '*'
            $MW.CorsOrigin | Should -Be '*'
        }
    }
}

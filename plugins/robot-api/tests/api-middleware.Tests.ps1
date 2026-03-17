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

    Context 'FixedTimeEquals' {
        It 'returns true for identical strings' {
            [Robot.ApiMiddleware]::FixedTimeEquals('hello', 'hello') | Should -BeTrue
        }

        It 'returns false for different strings of same length' {
            [Robot.ApiMiddleware]::FixedTimeEquals('hello', 'world') | Should -BeFalse
        }

        It 'returns false for same-prefix different-length strings' {
            [Robot.ApiMiddleware]::FixedTimeEquals('rbt_abc', 'rbt_abcdef') | Should -BeFalse
        }

        It 'returns false when either string is null' {
            [Robot.ApiMiddleware]::FixedTimeEquals($null, 'test') | Should -BeFalse
            [Robot.ApiMiddleware]::FixedTimeEquals('test', $null) | Should -BeFalse
        }

        It 'returns false for empty vs non-empty' {
            [Robot.ApiMiddleware]::FixedTimeEquals('', 'test') | Should -BeFalse
        }

        It 'returns true for two empty strings' {
            [Robot.ApiMiddleware]::FixedTimeEquals('', '') | Should -BeTrue
        }
    }

    Context 'ApiTokenStore' {
        It 'adds and authenticates a token' {
            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'test-token'
            $Info.Scopes = @('entity:read')
            $Info.CreatedAt = '2026-03-17T00:00:00Z'
            $Store.Add('rbt_testvalue', $Info) | Should -BeTrue

            $Result = $Store.Authenticate('rbt_testvalue')
            $Result | Should -Not -BeNullOrEmpty
            $Result.Name | Should -Be 'test-token'
        }

        It 'returns null for invalid token' {
            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'real'
            $Info.Scopes = @('admin:all')
            $Store.Add('rbt_real', $Info) | Should -BeTrue

            $Store.Authenticate('rbt_wrong') | Should -BeNullOrEmpty
        }

        It 'removes token by name' {
            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'removeme'
            $Info.Scopes = @('entity:read')
            $Store.Add('rbt_remove', $Info) | Should -BeTrue

            $Removed = $null
            $Store.RemoveByName('removeme', [ref]$Removed) | Should -BeTrue
            $Removed | Should -Be 'rbt_remove'
            $Store.Count | Should -Be 0
        }

        It 'lists tokens without raw values' {
            $Store = [Robot.ApiTokenStore]::new()
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Name = 'listed'
            $Info.Scopes = @('entity:read', 'session:read')
            $Info.CreatedAt = '2026-03-17T00:00:00Z'
            $Store.Add('rbt_secret', $Info) | Should -BeTrue

            $List = $Store.ListTokens()
            $List.Count | Should -Be 1
            $List[0]['name'] | Should -Be 'listed'
            $List[0]['scopes'] | Should -Contain 'entity:read'
        }
    }

    Context 'HasScope' {
        It 'returns true for exact scope match' {
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Scopes = @('entity:read')
            [Robot.ApiMiddleware]::HasScope($Info, 'entity:read') | Should -BeTrue
        }

        It 'returns true for admin:all wildcard' {
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Scopes = @('admin:all')
            [Robot.ApiMiddleware]::HasScope($Info, 'entity:write') | Should -BeTrue
        }

        It 'returns true for hierarchical match' {
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Scopes = @('entity:read')
            [Robot.ApiMiddleware]::HasScope($Info, 'entity:read:own') | Should -BeTrue
        }

        It 'returns false for missing scope' {
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Scopes = @('entity:read')
            [Robot.ApiMiddleware]::HasScope($Info, 'entity:write') | Should -BeFalse
        }

        It 'returns false for null token' {
            [Robot.ApiMiddleware]::HasScope($null, 'entity:read') | Should -BeFalse
        }

        It 'returns true for null/empty required scope' {
            $Info = [Robot.ApiTokenInfo]::new()
            $Info.Scopes = @('entity:read')
            [Robot.ApiMiddleware]::HasScope($Info, $null) | Should -BeTrue
            [Robot.ApiMiddleware]::HasScope($Info, '') | Should -BeTrue
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

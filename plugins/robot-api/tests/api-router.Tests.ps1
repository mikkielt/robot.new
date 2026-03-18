BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiRouter' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiRouter').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiRouter not compiled'
        }
    }

    Context 'Route matching' {
        It 'matches exact path' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-Handler', 'test')
            $Match = $Router.Match('GET', '/entities')
            $Match | Should -Not -BeNullOrEmpty
            $Match.Route.HandlerName | Should -Be 'Invoke-Handler'
        }

        It 'extracts single path parameter' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities/:name', 'Invoke-Handler', 'test')
            $Match = $Router.Match('GET', '/entities/Solmyr')
            $Match | Should -Not -BeNullOrEmpty
            $Match.PathParams['name'] | Should -Be 'Solmyr'
        }

        It 'extracts multiple path parameters' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/players/:player/characters/:char', 'Invoke-Handler', 'test')
            $Match = $Router.Match('GET', '/players/TestPlayer/characters/TestChar')
            $Match.PathParams['player'] | Should -Be 'TestPlayer'
            $Match.PathParams['char'] | Should -Be 'TestChar'
        }

        It 'URL-decodes path parameters' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities/:name', 'Invoke-Handler', 'test')
            $Match = $Router.Match('GET', '/entities/Ratusz%20Ithan')
            $Match.PathParams['name'] | Should -Be 'Ratusz Ithan'
        }

        It 'returns null for no match' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-Handler', 'test')
            $Match = $Router.Match('GET', '/unknown')
            $Match | Should -BeNullOrEmpty
        }

        It 'filters by HTTP method' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-Handler', 'test')
            $Match = $Router.Match('POST', '/entities')
            $Match | Should -BeNullOrEmpty
        }

        It 'matches case-insensitively' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-Handler', 'test')
            $Match = $Router.Match('get', '/entities')
            $Match | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Static route O(1) lookup' {
        It 'caches routes without parameters for fast lookup' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/health', 'Invoke-Health', 'test')
            $Router.AddRoute('GET', '/entities/:name', 'Invoke-Entity', 'test')

            # Exact-match route should be found via O(1) dictionary lookup
            $Match = $Router.Match('GET', '/health')
            $Match | Should -Not -BeNullOrEmpty
            $Match.Route.HandlerName | Should -Be 'Invoke-Health'
        }
    }

    Context 'ListRoutes' {
        It 'returns all registered routes' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-List', 'List entities')
            $Router.AddRoute('GET', '/entities/:name', 'Invoke-Get', 'Get entity')
            $Router.AddRoute('POST', '/entities', 'Invoke-Create', 'Create entity', 201)

            $Routes = $Router.ListRoutes()
            $Routes.Count | Should -Be 3
            $Routes[0]['method'] | Should -Be 'GET'
            $Routes[0]['pattern'] | Should -Be '/entities'
            $Routes[0]['description'] | Should -Be 'List entities'
        }
    }

    Context 'Route scope' {
        It 'sets RequiredScope on route with scope parameter' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-Handler', 'test', 200, 'entity:read')
            $Match = $Router.Match('GET', '/entities')
            $Match.Route.RequiredScope | Should -Be 'entity:read'
        }

        It 'has null RequiredScope when no scope specified' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/health', 'Invoke-Handler', 'test')
            $Match = $Router.Match('GET', '/health')
            $Match.Route.RequiredScope | Should -BeNullOrEmpty
        }

        It 'includes scope field in ListRoutes output' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddRoute('GET', '/entities', 'Invoke-A', 'List', 200, 'entity:read')
            $Router.AddRoute('GET', '/health', 'Invoke-B', 'Health')

            $Routes = $Router.ListRoutes()
            $Routes[0]['scope'] | Should -Be 'entity:read'
            $Routes[1]['scope'] | Should -BeNullOrEmpty
        }
    }

    Context 'SSE route' {
        It 'registers SSE route with IsSse flag' {
            $Router = [Robot.ApiRouter]::new()
            $Router.AddSseRoute('/events', 'SSE stream')
            $Match = $Router.Match('GET', '/events')
            $Match | Should -Not -BeNullOrEmpty
            $Match.Route.IsSse | Should -BeTrue
        }
    }

    Context 'Static handler route' {
        It 'registers handler function for static routes' {
            $Router = [Robot.ApiRouter]::new()
            $Handler = [Func[Robot.RouteMatch, Robot.ApiServer, object]]{
                param($m, $s) return @{ status = 'ok' }
            }
            $Router.AddStaticRoute('GET', '/test', $Handler, 'test route')
            $Match = $Router.Match('GET', '/test')
            $Match | Should -Not -BeNullOrEmpty
            $Match.Route.StaticHandler | Should -Not -BeNullOrEmpty
        }
    }
}

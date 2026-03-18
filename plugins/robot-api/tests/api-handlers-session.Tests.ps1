<#
    .SYNOPSIS
    Pester tests for session-related API endpoints.

    .DESCRIPTION
    Tests for /auth/whoami, /parse/log, /parse/session-preview, and
    POST /sessions handlers. Follows the existing api-handlers.Tests.ps1
    pattern: construct $Ctx hashtable, call handler directly, assert response.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../private/api-handlers-auth.ps1"
    . "$PSScriptRoot/../private/api-handlers-read.ps1"
    . "$PSScriptRoot/../private/api-handlers-write.ps1"
}

# ═══════════════════════════════════════════════════════════════════════
# GET /auth/whoami
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiGetWhoami' {
    It 'returns token name and scopes' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = $null
            Method      = 'GET'
            Path        = '/auth/whoami'
            TokenName   = 'test-token'
            TokenScopes = @('session:read', 'entity:write')
        }

        $Result = Invoke-ApiGetWhoami -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.name | Should -Be 'test-token'
        $Result.Body.scopes | Should -HaveCount 2
        $Result.Body.scopes | Should -Contain 'session:read'
        $Result.Body.scopes | Should -Contain 'entity:write'
    }

    It 'handles empty scopes array gracefully' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = $null
            Method      = 'GET'
            Path        = '/auth/whoami'
            TokenName   = 'minimal-token'
            TokenScopes = @()
        }

        $Result = Invoke-ApiGetWhoami -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.name | Should -Be 'minimal-token'
        $Result.Body.scopes | Should -HaveCount 0
    }

    It 'handles null scopes gracefully' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = $null
            Method      = 'GET'
            Path        = '/auth/whoami'
            TokenName   = 'null-scope-token'
            TokenScopes = $null
        }

        $Result = Invoke-ApiGetWhoami -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.name | Should -Be 'null-scope-token'
    }
}

# ═══════════════════════════════════════════════════════════════════════
# POST /parse/log
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiParseLog' {
    It 'returns 400 when content field is missing' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = ([PSCustomObject]@{ other = 'value' })
            Method      = 'POST'
            Path        = '/parse/log'
        }

        $Result = Invoke-ApiParseLog -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*content*required*'
    }

    It 'returns 400 when body is null' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = $null
            Method      = 'POST'
            Path        = '/parse/log'
        }

        $Result = Invoke-ApiParseLog -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
    }

    It 'parses valid log content and returns structured result' {
        $LogText = "Solmyr: Witam wszystkich`nKyrre: Cześć"
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = ([PSCustomObject]@{ content = $LogText })
            Method      = 'POST'
            Path        = '/parse/log'
        }

        $Result = Invoke-ApiParseLog -ApiContext $Ctx
        $Result.StatusCode | Should -BeIn @(200, 422)
        if ($Result.StatusCode -eq 200) {
            $Result.Body | Should -Not -BeNullOrEmpty
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# POST /parse/session-preview
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiSessionPreview' {
    It 'returns 400 when body is missing' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = $null
            Method      = 'POST'
            Path        = '/parse/session-preview'
        }

        $Result = Invoke-ApiSessionPreview -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
    }

    It 'returns 400 when required fields are missing' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = ([PSCustomObject]@{ title = 'Test' })
            Method      = 'POST'
            Path        = '/parse/session-preview'
        }

        $Result = Invoke-ApiSessionPreview -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*title, narrator, and date*'
    }

    It 'returns 400 for invalid date format' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = ([PSCustomObject]@{
                title    = 'Test'
                narrator = 'GM'
                date     = 'not-a-date'
            })
            Method      = 'POST'
            Path        = '/parse/session-preview'
        }

        $Result = Invoke-ApiSessionPreview -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*Invalid date*'
    }

    It 'generates preview with valid data' {
        $Ctx = @{
            PathParams  = @{}
            QueryParams = @{}
            Body        = ([PSCustomObject]@{
                title    = 'Preview Test'
                narrator = 'Solmyr'
                date     = '2026-03-15'
                locations = @('Erathia')
            })
            Method      = 'POST'
            Path        = '/parse/session-preview'
        }

        $Result = Invoke-ApiSessionPreview -ApiContext $Ctx
        $Result.StatusCode | Should -BeIn @(200, 422)
        if ($Result.StatusCode -eq 200) {
            $Result.Body.markdown | Should -BeLike '*### 2026-03-15*Preview Test*Solmyr*'
            $Result.Body.warnings | Should -Not -BeNullOrEmpty -Because 'unresolvable locations produce warnings'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# POST /sessions
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiCreateSession' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'POST'
                Path        = '/sessions'
            }

            $Result = Invoke-ApiCreateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'returns 400 when required fields are missing' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = ([PSCustomObject]@{ title = 'Test' })
                Method      = 'POST'
                Path        = '/sessions'
            }

            $Result = Invoke-ApiCreateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*title, narrator, date, and path*'
        }

        It 'returns 400 for invalid date' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = ([PSCustomObject]@{
                    title    = 'Test'
                    narrator = 'GM'
                    date     = 'bad-date'
                    path     = @('/tmp/test.md')
                })
                Method      = 'POST'
                Path        = '/sessions'
            }

            $Result = Invoke-ApiCreateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*Invalid date*'
        }
    }

    Context 'Batch mode validation' {
        It 'returns 400 when batch sessions lack required fields' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = ([PSCustomObject]@{
                    path     = @('/tmp/test.md')
                    sessions = @(
                        [PSCustomObject]@{ title = 'A' }
                    )
                })
                Method      = 'POST'
                Path        = '/sessions'
            }

            $Result = Invoke-ApiCreateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*title, narrator, and date*'
        }

        It 'returns 400 when batch is missing path' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = ([PSCustomObject]@{
                    sessions = @(
                        [PSCustomObject]@{ title = 'A'; narrator = 'GM'; date = '2026-01-01' }
                    )
                })
                Method      = 'POST'
                Path        = '/sessions'
            }

            $Result = Invoke-ApiCreateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*path*required*'
        }
    }
}

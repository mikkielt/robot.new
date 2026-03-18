BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../private/api-token-helpers.ps1"
    . "$PSScriptRoot/../private/api-handlers-auth.ps1"
}

Describe 'Invoke-ApiCreateToken' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/auth/token' }
            $Result = Invoke-ApiCreateToken -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*name and scopes*'
        }

        It 'returns 400 when name is missing' {
            $Body = [PSCustomObject]@{ scopes = @('entity:read') }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/auth/token' }
            $Result = Invoke-ApiCreateToken -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'returns 400 when scopes are missing' {
            $Body = [PSCustomObject]@{ name = 'test-token' }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/auth/token' }
            $Result = Invoke-ApiCreateToken -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }
    }
}

Describe 'Invoke-ApiDeleteToken' {
    Context 'Parameter validation' {
        It 'returns 400 when name is missing from path params' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'DELETE'; Path = '/auth/token/' }
            $Result = Invoke-ApiDeleteToken -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*name required*'
        }

        It 'returns 422 for nonexistent token' {
            $Ctx = @{
                PathParams  = @{ name = 'nonexistent-token-xyz' }
                QueryParams = @{}
                Body        = $null
                Method      = 'DELETE'
                Path        = '/auth/token/nonexistent-token-xyz'
            }
            $Result = Invoke-ApiDeleteToken -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            $Result.Body.error | Should -BeLike '*not found*'
        }
    }
}

Describe 'Invoke-ApiGetAuthStatus' {
    Context 'Response format' {
        It 'returns token count and tokens array' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'GET'; Path = '/auth/status' }
            $Result = Invoke-ApiGetAuthStatus -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.tokenCount | Should -BeOfType [int]
            # tokens may be empty array if no tokens exist, but key must exist
            $Result.Body.ContainsKey('tokens') | Should -BeTrue
        }
    }
}

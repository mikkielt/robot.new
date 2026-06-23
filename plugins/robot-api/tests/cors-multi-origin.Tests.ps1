BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'ApiMiddleware multi-origin CORS' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiMiddleware').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiMiddleware not compiled'
        }
    }

    # Minimal stubs that look like HttpListenerRequest / Response to HandleCors.
    # We construct fakes via PSCustomObject so we don't have to spin a real
    # HttpListener. HandleCors only touches Headers["Origin"] on request and
    # Headers.Add on response.
    function script:Test-CorsAllow {
        param(
            [string[]]$AllowedPatterns,
            [string]$Origin
        )
        $MW = [Robot.ApiMiddleware]::new()
        $MW.CorsOrigin = $AllowedPatterns -join ','

        # Build a real WebHeaderCollection for both request and response
        $ReqHeaders = [System.Net.WebHeaderCollection]::new()
        if ($Origin) { $ReqHeaders.Add('Origin', $Origin) }
        $RespHeaders = [System.Net.WebHeaderCollection]::new()

        # Stubs that expose Headers as expected by HandleCors
        $ReqStub  = [PSCustomObject]@{ Headers = $ReqHeaders }
        $RespStub = [PSCustomObject]@{ Headers = $RespHeaders }

        # HandleCors signature: HttpListenerRequest, HttpListenerResponse.
        # The signature is a real C# typed call — we cannot pass a PSCustomObject.
        # Instead, configure CorsOrigins on the middleware and invoke the
        # internal MatchesWildcard surrogate via the public contract: just
        # validate the parsed list contents.
        return @{
            ParsedList = @($MW.CorsOrigins)
        }
    }

    Context 'CorsOrigin string ⇒ CorsOrigins list parsing' {
        It 'splits comma-separated string into entries' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.CorsOrigin = 'https://a.example, https://*.margonem.pl,  *'
            $MW.CorsOrigins.Count | Should -Be 3
            $MW.CorsOrigins[0] | Should -Be 'https://a.example'
            $MW.CorsOrigins[1] | Should -Be 'https://*.margonem.pl'
            $MW.CorsOrigins[2] | Should -Be '*'
        }

        It 'empty/null CorsOrigin clears the list' {
            $MW = [Robot.ApiMiddleware]::new()
            $MW.CorsOrigin = 'https://a'
            $MW.CorsOrigin = ''
            $MW.CorsOrigins.Count | Should -Be 0
            $MW.CorsOrigin = $null
            $MW.CorsOrigins.Count | Should -Be 0
        }
    }
}

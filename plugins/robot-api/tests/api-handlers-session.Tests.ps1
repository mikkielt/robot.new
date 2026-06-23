<#
    .SYNOPSIS
    Pester tests for session-related API endpoints.

    .DESCRIPTION
    Tests for /auth/whoami, /parse/log, /parse/session-preview, and
    POST /sessions handlers. Follows the existing api-handlers.Tests.ps1
    pattern: construct $Ctx hashtable, call handler directly, assert response.
#>

BeforeAll {
    . "$PSScriptRoot/PluginTestHelpers.ps1"
    Import-RobotModuleForPlugin
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
        # ConvertFrom-LogContent is a pure parser — no repo dependency, always succeeds.
        $Result.StatusCode | Should -Be 200
        $Result.Body | Should -Not -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════════════
# POST /logs/parse (enriched)
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiParseLogEnriched' {
    BeforeAll {
        # Stub the name-index build so the handler does not touch the repo
        Mock Get-NameIndex {
            $InnerIndex = [System.Collections.Generic.Dictionary[string, object]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            $InnerIndex['solmyr'] = [PSCustomObject]@{
                Owner = [PSCustomObject]@{ Name = 'Solmyr'; Type = 'NPC' }
                OwnerType = 'NPC'; Source = 'Solmyr'; Priority = 1; Ambiguous = $false
            }
            $InnerStem = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            return [PSCustomObject]@{ Index = $InnerIndex; StemIndex = $InnerStem; BKTree = $null }
        }
        Mock Get-Entity { @() }
        Mock Get-Player { @() }
        # URL path goes through Get-SessionLog → batch fetch. Stub it so the test
        # does not require a real cache directory or HTTP.
        Mock Get-SessionLog {
            param($Session, $Index, $Cache, $LogDirectory, $DelayMs, $SkipFetch, $SkipMentions)
            return [PSCustomObject]@{
                Logs = @(
                    [PSCustomObject]@{
                        Url              = 'https://example.com/log'
                        Format           = 'Prose'
                        Lines            = @()
                        LocationSegments = @()
                        Speakers         = @()
                        Channels         = $null
                        Mentions         = $null
                        MentionsByLine   = $null
                    }
                )
            }
        }
    }

    It 'returns 400 when body is null' {
        $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
    }

    It 'returns 400 when neither urls nor content provided' {
        $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = [PSCustomObject]@{}; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*urls or content*'
    }

    It 'returns 400 when both urls and content provided' {
        $Body = [PSCustomObject]@{ urls = @('https://example.com/a'); content = 'x' }
        $Ctx  = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*mutually exclusive*'
    }

    It 'returns 400 when urls exceeds 50 entries' {
        $TooMany = 1..51 | ForEach-Object { "https://example.com/$_" }
        $Body = [PSCustomObject]@{ urls = $TooMany }
        $Ctx  = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*1-50*'
    }

    It 'parses inline content with resolve=false' {
        $LogText = "[13:22] [Lokalny] Solmyr: Cześć.`n[13:23] [Lokalny] Ivor: Witam."
        $Body = [PSCustomObject]@{ content = $LogText; resolve = $false }
        $Ctx  = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        @($Result.Body.items).Count | Should -Be 1
        $Item = $Result.Body.items[0]
        $Item.Format | Should -Be 'ChatLog'
        $Item.Speakers | Should -Not -BeNullOrEmpty
        # No index → resolution skipped → Mentions absent
        $Item.Mentions | Should -BeNullOrEmpty
    }

    It 'parses inline content with resolve=true and populates Mentions' {
        # Two timestamps force ChatLog format detection. Use the nominative
        # "Solmyr" in the body so the Stage-1 exact-index hit triggers without
        # requiring stem entries in the mocked NameIndex.
        $LogText = @(
            '[13:00] [Lokalny] Ivor: Solmyr odszedł.'
            '[13:01] [Lokalny] Ivor: Wrócimy do tego.'
        ) -join "`n"
        $Body = [PSCustomObject]@{ content = $LogText; resolve = $true }
        $Ctx  = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Item = $Result.Body.items[0]
        # Mentions array may be empty (no stem index in our mock), but the structure
        # must be present, not $null
        $Item.PSObject.Properties['Mentions'] | Should -Not -BeNullOrEmpty
        # Solmyr resolves directly via the Stage-1 exact index hit
        $Solmyr = $Item.Mentions | Where-Object { $_.Resolved -eq 'Solmyr' }
        $Solmyr | Should -Not -BeNullOrEmpty
    }

    It 'honors includeMentions=false (resolution on, mentions off)' {
        $LogText = "[13:00] [Lokalny] Ivor: Widziałem Solmyra."
        $Body = [PSCustomObject]@{ content = $LogText; resolve = $true; includeMentions = $false }
        $Ctx  = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.items[0].Mentions       | Should -BeNullOrEmpty
        $Result.Body.items[0].MentionsByLine | Should -BeNullOrEmpty
    }

    It 'invokes Get-SessionLog when urls are provided' {
        $Body = [PSCustomObject]@{ urls = @('https://example.com/log'); resolve = $false }
        $Ctx  = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/logs/parse' }
        $Result = Invoke-ApiParseLogEnriched -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        Should -Invoke Get-SessionLog -Times 1
        @($Result.Body.items).Count | Should -Be 1
    }
}

# ═══════════════════════════════════════════════════════════════════════
# POST /parse/session-preview
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiSessionPreview' {
    BeforeAll {
        Mock New-Session { return "### 2026-03-15, Preview Test, Solmyr`n" }
        Mock Resolve-Name { $null }
    }

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
        # New-Session is mocked to a known stub; Resolve-Name returns $null so
        # 'Erathia' resolves as unknown and surfaces in warnings.
        $Result.StatusCode | Should -Be 200
        $Result.Body.markdown | Should -BeLike '*### 2026-03-15*Preview Test*Solmyr*'
        $Result.Body.warnings | Should -Not -BeNullOrEmpty -Because 'unresolvable locations produce warnings'
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

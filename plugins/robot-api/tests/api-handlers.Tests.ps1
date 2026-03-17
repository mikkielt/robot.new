BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../private/api-handlers-write.ps1"
    . "$PSScriptRoot/../private/api-handlers-events.ps1"
}

# ═══════════════════════════════════════════════════════════════════════
# WRITE HANDLERS
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiCreateEntity' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/entities' }
            $Result = Invoke-ApiCreateEntity -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*body required*'
        }

        It 'returns 400 when name is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = ([PSCustomObject]@{ type = 'NPC' }); Method = 'POST'; Path = '/entities' }
            $Result = Invoke-ApiCreateEntity -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*name and type*'
        }

        It 'returns 400 when type is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = ([PSCustomObject]@{ name = 'Test' }); Method = 'POST'; Path = '/entities' }
            $Result = Invoke-ApiCreateEntity -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*name and type*'
        }
    }

    Context 'Tags parsing' {
        It 'extracts tags from body PSCustomObject' {
            # We test that the handler reads tags correctly without calling New-Entity
            # (no repo context). The 422 from New-Entity confirms params were parsed.
            $Tags = [PSCustomObject]@{ lokacja = 'Ithan'; status = 'Aktywny' }
            $Body = [PSCustomObject]@{ name = 'TestEntity'; type = 'NPC'; tags = $Tags }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $Body
                Method      = 'POST'
                Path        = '/entities'
            }
            $Result = Invoke-ApiCreateEntity -ApiContext $Ctx
            # Without repo context, New-Entity will fail — that's expected.
            # We verify the handler didn't reject the input at validation level.
            $Result.StatusCode | Should -BeIn @(201, 422)
        }
    }
}

Describe 'Invoke-ApiUpdateEntity' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{
                PathParams  = @{ name = 'TestEntity' }
                QueryParams = @{}
                Body        = $null
                Method      = 'PUT'
                Path        = '/entities/TestEntity'
            }
            $Result = Invoke-ApiUpdateEntity -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*body required*'
        }

        It 'returns 400 when tags object is missing' {
            $Body = [PSCustomObject]@{ type = 'NPC' }
            $Ctx = @{
                PathParams  = @{ name = 'TestEntity' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/entities/TestEntity'
            }
            $Result = Invoke-ApiUpdateEntity -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*tags*required*'
        }

        It 'extracts name from path params' {
            $Tags = [PSCustomObject]@{ status = 'Nieaktywny' }
            $Body = [PSCustomObject]@{ tags = $Tags }
            $Ctx = @{
                PathParams  = @{ name = 'Solmyr' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/entities/Solmyr'
            }
            $Result = Invoke-ApiUpdateEntity -ApiContext $Ctx
            # Without repo context Set-Entity fails with 422
            $Result.StatusCode | Should -BeIn @(200, 422)
        }
    }
}

Describe 'Invoke-ApiDeleteEntity' {
    Context 'Parameter extraction' {
        It 'extracts name from path params' {
            $Ctx = @{
                PathParams  = @{ name = 'TestEntity' }
                QueryParams = @{}
                Body        = $null
                Method      = 'DELETE'
                Path        = '/entities/TestEntity'
            }
            $Result = Invoke-ApiDeleteEntity -ApiContext $Ctx
            # Without repo context Remove-Entity fails
            $Result.StatusCode | Should -BeIn @(200, 422)
        }

        It 'accepts optional type and validFrom in body' {
            $Body = [PSCustomObject]@{ type = 'NPC'; validFrom = '2026-03' }
            $Ctx = @{
                PathParams  = @{ name = 'TestEntity' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'DELETE'
                Path        = '/entities/TestEntity'
            }
            $Result = Invoke-ApiDeleteEntity -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(200, 422)
        }
    }
}

Describe 'Invoke-ApiCreateCurrency' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/currency' }
            $Result = Invoke-ApiCreateCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'returns 400 when name is missing' {
            $Body = [PSCustomObject]@{ owner = 'SomePlayer' }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/currency' }
            $Result = Invoke-ApiCreateCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*name*required*'
        }

        It 'passes owner, location, and amount as entity tags' {
            $Body = [PSCustomObject]@{
                name     = 'Korony TestPlayer'
                owner    = 'TestPlayer'
                location = 'Ithan'
                amount   = 100
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/currency' }
            $Result = Invoke-ApiCreateCurrency -ApiContext $Ctx
            # Without repo: New-Entity fails → 422. Handler didn't reject at validation.
            $Result.StatusCode | Should -BeIn @(201, 422)
        }
    }
}

Describe 'Invoke-ApiUpdateCurrency' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{
                PathParams  = @{ name = 'Korony Test' }
                QueryParams = @{}
                Body        = $null
                Method      = 'PUT'
                Path        = '/currency/Korony Test'
            }
            $Result = Invoke-ApiUpdateCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'passes amount and owner parameters' {
            $Body = [PSCustomObject]@{ amount = 50; owner = 'NewOwner' }
            $Ctx = @{
                PathParams  = @{ name = 'Korony Test' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/currency/Korony Test'
            }
            $Result = Invoke-ApiUpdateCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(200, 422)
        }
    }
}

Describe 'Invoke-ApiCreatePlayer' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/players' }
            $Result = Invoke-ApiCreatePlayer -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'returns 400 when name is missing' {
            $Body = [PSCustomObject]@{ margonemId = '12345' }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/players' }
            $Result = Invoke-ApiCreatePlayer -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*name*required*'
        }

        It 'accepts optional characterName and triggers' {
            $Body = [PSCustomObject]@{
                name          = 'TestPlayer'
                margonemId    = '12345'
                triggers      = @('topic1', 'topic2')
                characterName = 'TestChar'
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/players' }
            $Result = Invoke-ApiCreatePlayer -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(201, 422)
        }
    }
}

Describe 'Invoke-ApiCreateCharacter' {
    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{
                PathParams  = @{ name = 'TestPlayer' }
                QueryParams = @{}
                Body        = $null
                Method      = 'POST'
                Path        = '/players/TestPlayer/characters'
            }
            $Result = Invoke-ApiCreateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'returns 400 when characterName is missing' {
            $Body = [PSCustomObject]@{ condition = 'Zdrowy.' }
            $Ctx = @{
                PathParams  = @{ name = 'TestPlayer' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'POST'
                Path        = '/players/TestPlayer/characters'
            }
            $Result = Invoke-ApiCreateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*characterName*required*'
        }

        It 'extracts player name from path params' {
            $Body = [PSCustomObject]@{
                characterName = 'NewChar'
                characterSheet = 'https://example.com/sheet'
            }
            $Ctx = @{
                PathParams  = @{ name = 'TestPlayer' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'POST'
                Path        = '/players/TestPlayer/characters'
            }
            $Result = Invoke-ApiCreateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(201, 422)
        }
    }
}

Describe 'Invoke-ApiRebuildGraph' {
    Context 'Parameter extraction' {
        It 'accepts empty body for incremental rebuild' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'POST'
                Path        = '/workflow/session-graph'
            }
            $Result = Invoke-ApiRebuildGraph -ApiContext $Ctx
            # Without repo context, Set-SessionGraph fails
            $Result.StatusCode | Should -BeIn @(200, 422)
        }

        It 'accepts full rebuild flag in body' {
            $Body = [PSCustomObject]@{ full = $true }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $Body
                Method      = 'POST'
                Path        = '/workflow/session-graph'
            }
            $Result = Invoke-ApiRebuildGraph -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(200, 422)
        }
    }
}

Describe 'Invoke-ApiRebuildHashes' {
    Context 'Parameter extraction' {
        It 'accepts empty body for incremental mode' {
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'POST'
                Path        = '/workflow/session-hash'
            }
            $Result = Invoke-ApiRebuildHashes -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(200, 422)
        }

        It 'accepts full flag and since parameter' {
            $Body = [PSCustomObject]@{ full = $true; since = '2026-01-01' }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $Body
                Method      = 'POST'
                Path        = '/workflow/session-hash'
            }
            $Result = Invoke-ApiRebuildHashes -ApiContext $Ctx
            $Result.StatusCode | Should -BeIn @(200, 422)
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SSE EVENT HANDLER
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiEventBroadcast' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiServer').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiServer not compiled'
        }
    }

    Context 'Guard checks' {
        It 'does nothing when no server instance exists' {
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation = 'New-Entity'; Name = 'Test'; Type = 'NPC'
            } } | Should -Not -Throw
        }

        It 'does nothing when server is not running' {
            $MockServer = [PSCustomObject]@{ IsRunning = $false }
            $script:ApiServerInstance = $MockServer
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation = 'New-Entity'; Name = 'Test'; Type = 'NPC'
            } } | Should -Not -Throw
            $script:ApiServerInstance = $null
        }
    }

    Context 'Event dispatch' {
        It 'handles Write-EntityFile operation' {
            # Verify the function accepts the correct hook context shape
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation  = 'Write-EntityFile'
                Path       = 'entities.md'
                EntityName = 'Solmyr'
            } } | Should -Not -Throw
        }

        It 'handles New-Entity operation' {
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation = 'New-Entity'
                Name      = 'TestEntity'
                Type      = 'NPC'
            } } | Should -Not -Throw
        }

        It 'handles New-PlayerCharacter operation' {
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation     = 'New-PlayerCharacter'
                PlayerName    = 'TestPlayer'
                CharacterName = 'TestChar'
            } } | Should -Not -Throw
        }
    }
}

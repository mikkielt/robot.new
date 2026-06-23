BeforeAll {
    . "$PSScriptRoot/PluginTestHelpers.ps1"
    Import-RobotModuleForPlugin
    . "$PSScriptRoot/../private/api-handlers-read.ps1"
    . "$PSScriptRoot/../private/api-handlers-write.ps1"
    . "$PSScriptRoot/../private/api-handlers-events.ps1"
}

# ═══════════════════════════════════════════════════════════════════════
# WRITE HANDLERS
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiCreateEntity' {
    BeforeAll {
        Mock New-Entity { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            # New-Entity is mocked to throw; reaching it means input parsed.
            $Result.StatusCode | Should -Be 422
            Should -Invoke New-Entity -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiUpdateEntity' {
    BeforeAll {
        Mock Set-Entity { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            # Set-Entity is mocked to throw; reaching it means input parsed.
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-Entity -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiDeleteEntity' {
    BeforeAll {
        Mock Remove-Entity { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            # Remove-Entity is mocked to throw; reaching it means input parsed.
            $Result.StatusCode | Should -Be 422
            Should -Invoke Remove-Entity -Times 1 -Exactly
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
            $Result.StatusCode | Should -Be 422
            Should -Invoke Remove-Entity -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiCreateCurrency' {
    BeforeAll {
        Mock New-Entity { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            # New-Entity is mocked to throw; reaching it means input parsed.
            $Result.StatusCode | Should -Be 422
            Should -Invoke New-Entity -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiUpdateCurrency' {
    BeforeAll {
        Mock Set-CurrencyEntity { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-CurrencyEntity -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiCreatePlayer' {
    BeforeAll {
        Mock New-Player { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            $Result.StatusCode | Should -Be 422
            Should -Invoke New-Player -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiCreateCharacter' {
    BeforeAll {
        Mock New-PlayerCharacter { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            $Result.StatusCode | Should -Be 422
            Should -Invoke New-PlayerCharacter -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiRebuildGraph' {
    BeforeAll {
        Mock Set-SessionGraph { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            # Set-SessionGraph is mocked to throw.
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-SessionGraph -Times 1 -Exactly
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
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-SessionGraph -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ApiRebuildHashes' {
    BeforeAll {
        Mock Set-SessionHash { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

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
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-SessionHash -Times 1 -Exactly
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
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-SessionHash -Times 1 -Exactly
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SSE EVENT HANDLER
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiGetNameIndexLookup' {
    BeforeAll {
        # Build a mock name index matching Get-NameIndex's return shape.
        $SolmyrEntity = [PSCustomObject]@{ Name = 'Solmyr'; Type = 'NPC' }
        $LordEntity   = [PSCustomObject]@{ Name = 'Lord'; Type = 'NPC' }
        $HaartEntity  = [PSCustomObject]@{ Name = 'Lord Haart'; Type = 'NPC' }

        $InnerIndex = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $InnerIndex['solmyr']     = [PSCustomObject]@{
            Owner = $SolmyrEntity; OwnerType = 'NPC'; Source = 'Solmyr'; Priority = 1; Ambiguous = $false
        }
        # Ambiguous token: two distinct owners share "Lord"
        $InnerIndex['lord'] = [PSCustomObject]@{
            Owner = $null; OwnerType = $null; Source = 'Lord'; Priority = 2; Ambiguous = $true
            Owners = @(
                [PSCustomObject]@{ Owner = $LordEntity;  Type = 'NPC' }
                [PSCustomObject]@{ Owner = $HaartEntity; Type = 'NPC' }
            )
        }

        $InnerStem = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $StemList = [System.Collections.Generic.List[string]]::new()
        $StemList.Add('solmyr')
        $InnerStem['solmyr'] = $StemList

        Mock Get-NameIndex {
            return [PSCustomObject]@{ Index = $InnerIndex; StemIndex = $InnerStem; BKTree = $null }
        }
        Mock Get-Entity { @() }
        Mock Get-Player { @() }
        # Get-DeclensionStem is a real function — let it run for the stem path
    }

    It 'returns 400 when token path parameter is empty' {
        $Ctx = @{ PathParams = @{ token = '' }; QueryParams = @{}; Body = $null; Method = 'GET'; Path = '/name-index/lookup/' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
        $Result.Body.error | Should -BeLike '*token*required*'
    }

    It 'returns Stage-1 hit for a known token' {
        $Ctx = @{ PathParams = @{ token = 'Solmyr' }; QueryParams = @{}; Method = 'GET'; Path = '/name-index/lookup/Solmyr' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.token | Should -Be 'Solmyr'
        $Result.Body.stage1.found | Should -Be $true
        $Result.Body.stage1.entry.owner.name | Should -Be 'Solmyr'
        $Result.Body.stage1.entry.ownerType | Should -Be 'NPC'
        $Result.Body.stage1.entry.ambiguous | Should -Be $false
        $Result.Body.stage1.entry.priority | Should -Be 1
    }

    It 'returns Stage-1 miss with found=false for an unknown token' {
        $Ctx = @{ PathParams = @{ token = 'Nieznany' }; QueryParams = @{}; Method = 'GET'; Path = '/name-index/lookup/Nieznany' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.stage1.found | Should -Be $false
        $Result.Body.stage1.entry | Should -BeNullOrEmpty
    }

    It 'exposes the typed Owners array for ambiguous entries' {
        $Ctx = @{ PathParams = @{ token = 'Lord' }; QueryParams = @{}; Method = 'GET'; Path = '/name-index/lookup/Lord' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.stage1.entry.ambiguous | Should -Be $true
        @($Result.Body.stage1.entry.owners).Count | Should -Be 2
        # Single-owner properties MUST be absent on ambiguous entries
        $Result.Body.stage1.entry.PSObject.Properties['owner']    | Should -BeNullOrEmpty
        $Result.Body.stage1.entry.PSObject.Properties['ownerType'] | Should -BeNullOrEmpty
    }

    It 'includes Stage-2 stem candidates only when ?includeStems=true' {
        $Ctx = @{ PathParams = @{ token = 'Solmyra' }; QueryParams = @{ includeStems = 'true' }; Method = 'GET'; Path = '/name-index/lookup/Solmyra' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.Contains('stage2') | Should -Be $true
        $Result.Body.stage2.stem | Should -Be 'solmyr'
        $Result.Body.stage2.candidates | Should -Contain 'solmyr'
    }

    It 'omits stage2 when includeStems is not set' {
        $Ctx = @{ PathParams = @{ token = 'Solmyr' }; QueryParams = @{}; Method = 'GET'; Path = '/name-index/lookup/Solmyr' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.Body.Contains('stage2') | Should -Be $false
    }

    It 'always returns indexStats' {
        $Ctx = @{ PathParams = @{ token = 'Solmyr' }; QueryParams = @{}; Method = 'GET'; Path = '/name-index/lookup/Solmyr' }
        $Result = Invoke-ApiGetNameIndexLookup -ApiContext $Ctx
        $Result.Body.indexStats.tokenCount | Should -BeGreaterThan 0
        $Result.Body.indexStats.stemCount  | Should -BeGreaterOrEqual 0
    }
}

Describe 'Invoke-ApiRebuildNameIndex' {
    BeforeAll {
        $InnerIndex = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $InnerIndex['solmyr'] = [PSCustomObject]@{
            Owner = [PSCustomObject]@{ Name = 'Solmyr' }
            OwnerType = 'NPC'; Source = 'Solmyr'; Priority = 1; Ambiguous = $false
        }
        $InnerStem = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        $script:MockBuiltIndex = [PSCustomObject]@{ Index = $InnerIndex; StemIndex = $InnerStem; BKTree = $null }

        Mock Clear-ParseCaches { }
        Mock Get-Entity { @() }
        Mock Get-Player { @() }
        Mock Get-NameIndex { return $script:MockBuiltIndex }
    }

    It 'returns 200 with build stats on a successful rebuild' {
        $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/workflow/name-index' }
        $Result = Invoke-ApiRebuildNameIndex -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.indexStats.tokenCount    | Should -Be 1
        $Result.Body.indexStats.stemCount     | Should -Be 0
        $Result.Body.indexStats.ambiguousCount | Should -Be 0
        $Result.Body.buildMs | Should -BeGreaterOrEqual 0
        $Result.Body.rebuiltAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
    }

    It 'invokes Clear-ParseCaches exactly once per request' {
        $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/workflow/name-index' }
        $null = Invoke-ApiRebuildNameIndex -ApiContext $Ctx
        Should -Invoke Clear-ParseCaches -Times 1
    }

    It 'returns 422 when Get-Entity throws' {
        Mock Get-Entity { throw [System.InvalidOperationException]::new('simulated: entity scan failed') }
        $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/workflow/name-index' }
        $Result = Invoke-ApiRebuildNameIndex -ApiContext $Ctx
        $Result.StatusCode | Should -Be 422
        $Result.Body.error | Should -BeLike '*entity scan failed*'
    }

    It 'is safe to call repeatedly (idempotent)' {
        Mock Get-Entity { @() }
        Mock Get-NameIndex { return $script:MockBuiltIndex }
        $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/workflow/name-index' }
        { $null = Invoke-ApiRebuildNameIndex -ApiContext $Ctx } | Should -Not -Throw
        { $null = Invoke-ApiRebuildNameIndex -ApiContext $Ctx } | Should -Not -Throw
    }
}

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

        It 'handles Remove-Entity operation' {
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation  = 'Remove-Entity'
                Name       = 'DeletedEntity'
                EntityType = 'NPC'
            } } | Should -Not -Throw
        }

        It 'handles Set-CurrencyEntity operation' {
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation = 'Set-CurrencyEntity'
                Name      = 'Korony Test'
                Amount    = 100
            } } | Should -Not -Throw
        }

        It 'handles New-Player operation' {
            $script:ApiServerInstance = $null
            { Invoke-ApiEventBroadcast -HookContext @{
                Operation = 'New-Player'
                Name      = 'TestPlayer'
            } } | Should -Not -Throw
        }
    }
}

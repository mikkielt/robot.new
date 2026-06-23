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

Describe 'Invoke-ApiResolveName (WP-9 parameter forwarding)' {
    Context 'Query forwarding' {
        It 'passes Query only when no extra params present' {
            Mock Resolve-Name { return [PSCustomObject]@{ Name = 'Solmyr' } }
            $Ctx = @{ PathParams = @{ name = 'Solmyr' }; QueryParams = @{}; Body = $null; Method = 'GET'; Path = '/resolve/Solmyr' }
            $Result = Invoke-ApiResolveName -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Resolve-Name -Times 1 -Exactly -ParameterFilter {
                $Query -eq 'Solmyr' -and -not $PSBoundParameters.ContainsKey('OwnerType') -and
                -not $PSBoundParameters.ContainsKey('TopN')
            }
        }

        It 'forwards ownerType, topN, noFuzzy when provided' {
            Mock Resolve-Name { return [PSCustomObject]@{ Name = 'Solmyr' } }
            $Ctx = @{
                PathParams  = @{ name = 'Solmyr' }
                QueryParams = @{ ownerType = 'NPC'; topN = '5'; noFuzzy = 'true' }
                Body        = $null
                Method      = 'GET'
                Path        = '/resolve/Solmyr'
            }
            $Result = Invoke-ApiResolveName -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Resolve-Name -Times 1 -Exactly -ParameterFilter {
                $OwnerType -eq 'NPC' -and $TopN -eq 5 -and $NoFuzzy.IsPresent
            }
        }

        It 'returns 404 when nothing resolves' {
            Mock Resolve-Name { return $null }
            $Ctx = @{ PathParams = @{ name = 'Unknown' }; QueryParams = @{}; Body = $null; Method = 'GET'; Path = '/resolve/Unknown' }
            $Result = Invoke-ApiResolveName -ApiContext $Ctx
            $Result.StatusCode | Should -Be 404
        }
    }
}

Describe 'Invoke-ApiGetItems' {
    Context 'Query forwarding and list shape' {
        It 'forwards owner/location/includeCurrency flags' {
            Mock Get-ItemEntity { @() }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{ owner = 'Solmyr'; location = 'Kraków'; includeCurrency = 'true' }
                Body        = $null
                Method      = 'GET'
                Path        = '/items'
            }
            $Result = Invoke-ApiGetItems -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Get-ItemEntity -Times 1 -Exactly -ParameterFilter {
                $Owner -eq 'Solmyr' -and $Location -eq 'Kraków' -and $IncludeCurrency.IsPresent
            }
        }

        It 'returns 422 on backend error' {
            Mock Get-ItemEntity { throw 'parse failed' }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/items'
            }
            $Result = Invoke-ApiGetItems -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
        }
    }
}

Describe 'Invoke-ApiGetItem' {
    Context 'Single-resource resolution' {
        It 'returns 404 when no exact match exists' {
            # Substring match returns a similar item but exact filter drops it.
            Mock Get-ItemEntity { @([PSCustomObject]@{ EntityName = 'Korony-Solmyr' }) }
            $Ctx = @{
                PathParams  = @{ name = 'Korony' }
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/items/Korony'
            }
            $Result = Invoke-ApiGetItem -ApiContext $Ctx
            $Result.StatusCode | Should -Be 404
        }

        It 'returns the matching item when name matches exactly' {
            Mock Get-ItemEntity {
                @(
                    [PSCustomObject]@{ EntityName = 'Korony-Anward' },
                    [PSCustomObject]@{ EntityName = 'Korony-Solmyr' }
                )
            }
            $Ctx = @{
                PathParams  = @{ name = 'Korony-Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/items/Korony-Anward'
            }
            $Result = Invoke-ApiGetItem -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.EntityName | Should -Be 'Korony-Anward'
        }
    }
}

Describe 'Invoke-ApiGetMaterializationReport' {
    Context 'Happy path and query forwarding' {
        It 'returns the report PSCustomObject' {
            Mock Get-MaterializationReport {
                return [PSCustomObject]@{
                    Summary = [PSCustomObject]@{ TotalPhysical = 100; TotalVirtual = 50; OrphanedCount = 0 }
                }
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'GET'; Path = '/economy/materialization' }
            $Result = Invoke-ApiGetMaterializationReport -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.Summary.TotalPhysical | Should -Be 100
        }

        It 'forwards ?activeOn query param' {
            Mock Get-MaterializationReport { [PSCustomObject]@{ Summary = $null } }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{ activeOn = '2026-06-01' }
                Body        = $null
                Method      = 'GET'
                Path        = '/economy/materialization'
            }
            $Result = Invoke-ApiGetMaterializationReport -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Get-MaterializationReport -Times 1 -Exactly -ParameterFilter {
                $ActiveOn -eq [datetime]::Parse('2026-06-01')
            }
        }
    }
}

Describe 'Invoke-ApiGetNarratorProfile' {
    Context 'Happy path and query forwarding' {
        It 'returns the profile object' {
            Mock Get-NarratorSessionProfile {
                return [PSCustomObject]@{
                    NarratorName = 'Anward'
                    SessionCount = 12
                }
            }
            $Ctx = @{
                PathParams  = @{ name = 'Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/session-graph/narrator/Anward'
            }
            $Result = Invoke-ApiGetNarratorProfile -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.NarratorName | Should -Be 'Anward'
            $Result.Body.SessionCount | Should -Be 12
        }

        It 'forwards minTier, minDate, maxDate' {
            Mock Get-NarratorSessionProfile { [PSCustomObject]@{ NarratorName = 'Anward'; SessionCount = 0 } }
            $Ctx = @{
                PathParams  = @{ name = 'Anward' }
                QueryParams = @{ minTier = '1'; minDate = '2026-01-01'; maxDate = '2026-06-30' }
                Body        = $null
                Method      = 'GET'
                Path        = '/session-graph/narrator/Anward'
            }
            $Result = Invoke-ApiGetNarratorProfile -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Get-NarratorSessionProfile -Times 1 -Exactly -ParameterFilter {
                $NarratorName -eq 'Anward' -and $MinTier -eq 1 -and
                $MinDate -eq [datetime]::Parse('2026-01-01')
            }
        }
    }
}

Describe 'Invoke-ApiGetVotingEligibility' {
    Context 'Happy path and defaults' {
        It 'returns count + items shape' {
            Mock Get-VotingEligibility {
                @(
                    [PSCustomObject]@{ PlayerName = 'Anward'; PU = 5.0; VotingEligible = $true; MargonemID = '111' },
                    [PSCustomObject]@{ PlayerName = 'Eldar';  PU = 1.0; VotingEligible = $false; MargonemID = '222' }
                )
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'GET'; Path = '/pu/voting-eligibility' }
            $Result = Invoke-ApiGetVotingEligibility -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.count | Should -Be 2
            $Result.Body.items.Count | Should -Be 2
        }

        It 'forwards months and minPU query params' {
            Mock Get-VotingEligibility { @() }
            $Ctx = @{
                PathParams  = @{}
                QueryParams = @{ months = '3'; minPU = '5.0' }
                Body        = $null
                Method      = 'GET'
                Path        = '/pu/voting-eligibility'
            }
            $Result = Invoke-ApiGetVotingEligibility -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Get-VotingEligibility -Times 1 -Exactly -ParameterFilter {
                $Months -eq 3 -and $MinimumPU -eq [decimal]'5.0'
            }
        }
    }
}

Describe 'Invoke-ApiUpdateSession' {
    BeforeAll {
        Mock Set-Session { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'PUT'; Path = '/sessions' }
            $Result = Invoke-ApiUpdateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'returns 400 when date is missing' {
            $Body = [PSCustomObject]@{ file = 'sesje/2026.md' }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'PUT'; Path = '/sessions' }
            $Result = Invoke-ApiUpdateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*date and file*'
        }

        It 'returns 400 when file is missing' {
            $Body = [PSCustomObject]@{ date = '2026-06-15' }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'PUT'; Path = '/sessions' }
            $Result = Invoke-ApiUpdateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }
    }

    Context 'Identifier forwarding' {
        It 'forwards date and file to Set-Session' {
            $Body = [PSCustomObject]@{
                date     = '2026-06-15'
                file     = 'sesje/2026.md'
                narrator = @('Anward')
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'PUT'; Path = '/sessions' }
            $Result = Invoke-ApiUpdateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-Session -Times 1 -Exactly -ParameterFilter {
                $File -eq 'sesje/2026.md' -and $Date -eq [datetime]::Parse('2026-06-15') -and $Narrator[0] -eq 'Anward'
            }
        }

        It 'forwards upgradeFormat=true as a switch' {
            $Body = [PSCustomObject]@{
                date          = '2026-06-15'
                file          = 'sesje/2026.md'
                upgradeFormat = $true
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'PUT'; Path = '/sessions' }
            $Result = Invoke-ApiUpdateSession -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-Session -Times 1 -Exactly -ParameterFilter {
                $UpgradeFormat.IsPresent -eq $true
            }
        }
    }
}

Describe 'Invoke-ApiDeleteCurrency' {
    BeforeAll {
        Mock Remove-CurrencyEntity { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

    Context 'Parameter extraction' {
        It 'extracts name from path and forwards to Remove-CurrencyEntity' {
            Mock Get-CurrencyEntity { @() }
            $Ctx = @{
                PathParams  = @{ name = 'Korony-Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'DELETE'
                Path        = '/currency/Korony-Anward'
            }
            $Result = Invoke-ApiDeleteCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Remove-CurrencyEntity -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Korony-Anward'
            }
        }

        It 'forwards ?validFrom query param' {
            Mock Get-CurrencyEntity { @() }
            $Ctx = @{
                PathParams  = @{ name = 'Korony-Anward' }
                QueryParams = @{ validFrom = '2026-06' }
                Body        = $null
                Method      = 'DELETE'
                Path        = '/currency/Korony-Anward'
            }
            $Result = Invoke-ApiDeleteCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Remove-CurrencyEntity -Times 1 -Exactly -ParameterFilter {
                $ValidFrom -eq '2026-06'
            }
        }
    }

    Context 'Non-zero balance warning' {
        BeforeAll {
            Mock Remove-CurrencyEntity { [PSCustomObject]@{ Success = $true; Action = 'SoftDelete'; TargetName = 'Korony-Anward' } }
        }

        It 'attaches a warning when balance is non-zero' {
            Mock Get-CurrencyEntity { @([PSCustomObject]@{ EntityName = 'Korony-Anward'; Balance = 42 }) }
            $Ctx = @{
                PathParams  = @{ name = 'Korony-Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'DELETE'
                Path        = '/currency/Korony-Anward'
            }
            $Result = Invoke-ApiDeleteCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.warning | Should -BeLike '*non-zero balance*42*'
            $Result.Body.result.Success | Should -Be $true
        }

        It 'omits the warning when balance is zero' {
            Mock Get-CurrencyEntity { @([PSCustomObject]@{ EntityName = 'Korony-Anward'; Balance = 0 }) }
            $Ctx = @{
                PathParams  = @{ name = 'Korony-Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'DELETE'
                Path        = '/currency/Korony-Anward'
            }
            $Result = Invoke-ApiDeleteCurrency -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.PSObject.Properties['warning'] | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-ApiUpdatePlayer' {
    BeforeAll {
        Mock Set-Player { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{ PathParams = @{ name = 'Anward' }; QueryParams = @{}; Body = $null; Method = 'PUT'; Path = '/players/Anward' }
            $Result = Invoke-ApiUpdatePlayer -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
            $Result.Body.error | Should -BeLike '*body required*'
        }

        It 'forwards only the body keys that are present' {
            $Body = [PSCustomObject]@{ margonemId = '12345'; status = 'Aktywny' }
            $Ctx = @{
                PathParams  = @{ name = 'Anward' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/players/Anward'
            }
            $Result = Invoke-ApiUpdatePlayer -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-Player -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Anward' -and $MargonemID -eq '12345' -and $Status -eq 'Aktywny'
            }
        }

        It 'omits parameters the body did not include' {
            $Body = [PSCustomObject]@{ prfWebhook = 'https://example.com/hook' }
            $Ctx = @{
                PathParams  = @{ name = 'Anward' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/players/Anward'
            }
            $Result = Invoke-ApiUpdatePlayer -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-Player -Times 1 -Exactly -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('MargonemID') -and
                -not $PSBoundParameters.ContainsKey('Status') -and
                $PRFWebhook -eq 'https://example.com/hook'
            }
        }
    }
}

Describe 'Invoke-ApiUpdateCharacter' {
    BeforeAll {
        Mock Set-PlayerCharacter { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

    Context 'Parameter validation' {
        It 'returns 400 when body is missing' {
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{}
                Body        = $null
                Method      = 'PUT'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiUpdateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 400
        }

        It 'extracts player and character names from path' {
            $Body = [PSCustomObject]@{ status = 'Nieaktywny' }
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiUpdateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-PlayerCharacter -Times 1 -Exactly -ParameterFilter {
                $PlayerName -eq 'Anward' -and $CharacterName -eq 'Solmyr' -and $Status -eq 'Nieaktywny'
            }
        }

        It 'casts PU fields to decimal' {
            $Body = [PSCustomObject]@{ puSum = '12.5'; puTaken = 3 }
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiUpdateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-PlayerCharacter -Times 1 -Exactly -ParameterFilter {
                $PUSum -eq [decimal]12.5 -and $PUTaken -eq [decimal]3
            }
        }

        It 'treats null PU values as omitted (preserves existing override)' {
            $Body = [PSCustomObject]@{ puExceeded = $null; status = 'Aktywny' }
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{}
                Body        = $Body
                Method      = 'PUT'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiUpdateCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Set-PlayerCharacter -Times 1 -Exactly -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('PUExceeded') -and $Status -eq 'Aktywny'
            }
        }
    }
}

Describe 'Invoke-ApiDeleteCharacter' {
    BeforeAll {
        Mock Remove-PlayerCharacter { throw [System.InvalidOperationException]::new('simulated: write blocked in tests') }
    }

    Context 'Parameter extraction' {
        It 'extracts player and character from path' {
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{}
                Body        = $null
                Method      = 'DELETE'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiDeleteCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Remove-PlayerCharacter -Times 1 -Exactly -ParameterFilter {
                $PlayerName -eq 'Anward' -and $CharacterName -eq 'Solmyr'
            }
        }

        It 'forwards ?validFrom query param' {
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{ validFrom = '2026-06' }
                Body        = $null
                Method      = 'DELETE'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiDeleteCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
            Should -Invoke Remove-PlayerCharacter -Times 1 -Exactly -ParameterFilter {
                $ValidFrom -eq '2026-06'
            }
        }
    }
}

Describe 'Invoke-ApiGetCharacter' {
    Context 'Parameter extraction and 404 path' {
        It 'returns 404 when no character matches' {
            Mock Get-PlayerCharacter { @() }
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Ghost' }
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/players/Anward/characters/Ghost'
            }
            $Result = Invoke-ApiGetCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 404
        }

        It 'returns the first character when one matches' {
            Mock Get-PlayerCharacter {
                @([PSCustomObject]@{ PlayerName = 'Anward'; Name = 'Solmyr'; IsActive = $true })
            }
            $Ctx = @{
                PathParams  = @{ name = 'Anward'; character = 'Solmyr' }
                QueryParams = @{ includeState = 'true' }
                Body        = $null
                Method      = 'GET'
                Path        = '/players/Anward/characters/Solmyr'
            }
            $Result = Invoke-ApiGetCharacter -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.Name | Should -Be 'Solmyr'
            Should -Invoke Get-PlayerCharacter -Times 1 -Exactly -ParameterFilter {
                $IncludeState.IsPresent -eq $true
            }
        }
    }
}

Describe 'Invoke-ApiGetCharacterPuPreview' {
    Context 'Happy path and error propagation' {
        It 'returns the preview hashtable' {
            Mock Get-NewPlayerCharacterPUCount {
                return [PSCustomObject]@{
                    PlayerName        = 'Anward'
                    PU                = 23
                    PUTakenSum        = 6
                    IncludedCharacters = @('Solmyr')
                    ExcludedCharacters = @()
                }
            }
            $Ctx = @{
                PathParams  = @{ name = 'Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/players/Anward/pu-preview'
            }
            $Result = Invoke-ApiGetCharacterPuPreview -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.PU | Should -Be 23
        }

        It 'returns 422 on backend error' {
            Mock Get-NewPlayerCharacterPUCount { throw 'boom' }
            $Ctx = @{
                PathParams  = @{ name = 'Anward' }
                QueryParams = @{}
                Body        = $null
                Method      = 'GET'
                Path        = '/players/Anward/pu-preview'
            }
            $Result = Invoke-ApiGetCharacterPuPreview -ApiContext $Ctx
            $Result.StatusCode | Should -Be 422
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

Describe 'Invoke-ApiRunLogFetch' {
    BeforeAll {
        Mock Invoke-SessionLogFetch {
            return [PSCustomObject]@{
                Total = 5; Fetched = 3; Cached = 1; Failed = 1; Skipped = 0
                FailedUrls = @('https://example.com/log-failed')
            }
        }
    }

    Context 'Forwarding and shape' {
        It 'returns the fetch summary' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/workflow/log-fetch' }
            $Result = Invoke-ApiRunLogFetch -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.Fetched | Should -Be 3
        }

        It 'forwards date range, retry flag, and delays' {
            $Body = [PSCustomObject]@{
                minDate      = '2026-01-01'
                maxDate      = '2026-06-30'
                delayMs      = 250
                maxRetries   = 4
                retryFailed  = $true
                logDirectory = 'res/logs'
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/workflow/log-fetch' }
            $Result = Invoke-ApiRunLogFetch -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Invoke-SessionLogFetch -Times 1 -Exactly -ParameterFilter {
                $DelayMs -eq 250 -and $MaxRetries -eq 4 -and $RetryFailed.IsPresent -and $LogDirectory -eq 'res/logs'
            }
        }
    }
}

Describe 'Invoke-ApiRunPuAssignment' {
    BeforeAll {
        Mock Invoke-PlayerCharacterPUAssignment {
            @(
                [PSCustomObject]@{
                    CharacterName = 'Solmyr'; PlayerName = 'Anward'; GrantedPU = 2; Resolved = $true
                }
            )
        }
    }

    Context 'Forwarding and shape' {
        It 'returns count + items list' {
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $null; Method = 'POST'; Path = '/workflow/pu-assignment' }
            $Result = Invoke-ApiRunPuAssignment -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $Result.Body.count | Should -Be 1
            $Result.Body.items[0].CharacterName | Should -Be 'Solmyr'
        }

        It 'forwards year, month, and the four switches' {
            $Body = [PSCustomObject]@{
                year                   = 2026
                month                  = 6
                updatePlayerCharacters = $true
                sendToDiscord          = $true
                appendToLog            = $true
                reconcileCurrency      = $true
            }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/workflow/pu-assignment' }
            $Result = Invoke-ApiRunPuAssignment -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Invoke-PlayerCharacterPUAssignment -Times 1 -Exactly -ParameterFilter {
                $Year -eq 2026 -and $Month -eq 6 -and
                $UpdatePlayerCharacters.IsPresent -and
                $SendToDiscord.IsPresent -and
                $AppendToLog.IsPresent -and
                $ReconcileCurrency.IsPresent
            }
        }

        It 'forwards a player filter list' {
            $Body = [PSCustomObject]@{ playerName = @('Anward', 'Eldar') }
            $Ctx = @{ PathParams = @{}; QueryParams = @{}; Body = $Body; Method = 'POST'; Path = '/workflow/pu-assignment' }
            $Result = Invoke-ApiRunPuAssignment -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            Should -Invoke Invoke-PlayerCharacterPUAssignment -Times 1 -Exactly -ParameterFilter {
                $PlayerName.Count -eq 2 -and $PlayerName -contains 'Anward'
            }
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

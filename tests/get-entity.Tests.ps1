<#
    .SYNOPSIS
    Pester tests for get-entity.ps1.

    .DESCRIPTION
    Tests for ConvertFrom-ValidityString, Resolve-PartialDate,
    Test-TemporalActivity, Get-LastActiveValue, Get-AllActiveValues,
    Resolve-EntityCN, Get-Entity, and Get-NestedBulletText covering
    entity parsing, temporal logic, CN resolution, and entity merging
    across multiple entity files.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
}

Describe 'ConvertFrom-ValidityString' {
    It 'parses "Value (2025-02:)" into Text + ValidFrom + open ValidTo' {
        $Result = ConvertFrom-ValidityString -InputText 'Orrin (2024-01:)'
        $Result.Text | Should -Be 'Orrin'
        $Result.ValidFrom | Should -Be ([datetime]::new(2024, 1, 1))
        $Result.ValidTo | Should -BeNullOrEmpty
    }

    It 'parses "Value (:2025-01)" into open ValidFrom + ValidTo' {
        $Result = ConvertFrom-ValidityString -InputText 'OldAlias (:2025-01)'
        $Result.Text | Should -Be 'OldAlias'
        $Result.ValidFrom | Should -BeNullOrEmpty
        $Result.ValidTo | Should -Be ([datetime]::new(2025, 1, 31))
    }

    It 'parses full range "Value (2024-06:2025-01)"' {
        $Result = ConvertFrom-ValidityString -InputText 'Something (2024-06:2025-01)'
        $Result.Text | Should -Be 'Something'
        $Result.ValidFrom | Should -Be ([datetime]::new(2024, 6, 1))
        $Result.ValidTo | Should -Be ([datetime]::new(2025, 1, 31))
    }

    It 'returns plain text when no validity range present' {
        $Result = ConvertFrom-ValidityString -InputText 'PlainValue'
        $Result.Text | Should -Be 'PlainValue'
        $Result.ValidFrom | Should -BeNullOrEmpty
        $Result.ValidTo | Should -BeNullOrEmpty
    }

    It 'trims whitespace' {
        $Result = ConvertFrom-ValidityString -InputText '  Trimmed  '
        $Result.Text | Should -Be 'Trimmed'
    }
}

Describe 'Resolve-PartialDate' {
    It 'resolves YYYY start to January 1' {
        $Result = Resolve-PartialDate -DateStr '2024' -IsEnd $false
        $Result | Should -Be ([datetime]::new(2024, 1, 1))
    }

    It 'resolves YYYY end to December 31' {
        $Result = Resolve-PartialDate -DateStr '2024' -IsEnd $true
        $Result | Should -Be ([datetime]::new(2024, 12, 31))
    }

    It 'resolves YYYY-MM start to first day' {
        $Result = Resolve-PartialDate -DateStr '2024-06' -IsEnd $false
        $Result | Should -Be ([datetime]::new(2024, 6, 1))
    }

    It 'resolves YYYY-MM end to last day of month' {
        $Result = Resolve-PartialDate -DateStr '2024-02' -IsEnd $true
        $Result | Should -Be ([datetime]::new(2024, 2, 29))
    }

    It 'returns $null for empty string' {
        $Result = Resolve-PartialDate -DateStr '' -IsEnd $false
        $Result | Should -BeNullOrEmpty
    }

    It 'returns $null for whitespace-only' {
        $Result = Resolve-PartialDate -DateStr '   ' -IsEnd $false
        $Result | Should -BeNullOrEmpty
    }

    It 'handles full date YYYY-MM-DD' {
        $Result = Resolve-PartialDate -DateStr '2024-06-15' -IsEnd $false
        $Result | Should -Be ([datetime]::new(2024, 6, 15))
    }
}

Describe 'Test-TemporalActivity' {
    It 'returns $true when ActiveOn is $null (no filter)' {
        $Item = [PSCustomObject]@{ ValidFrom = [datetime]::new(2025, 1, 1); ValidTo = [datetime]::new(2025, 12, 31) }
        Test-TemporalActivity -Item $Item -ActiveOn $null | Should -BeTrue
    }

    It 'returns $true when Item has no bounds' {
        $Item = [PSCustomObject]@{ ValidFrom = $null; ValidTo = $null }
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2025, 6, 1)) | Should -BeTrue
    }

    It 'returns $false when ActiveOn is before ValidFrom' {
        $Item = [PSCustomObject]@{ ValidFrom = [datetime]::new(2025, 6, 1); ValidTo = $null }
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2025, 1, 1)) | Should -BeFalse
    }

    It 'returns $false when ActiveOn is after ValidTo' {
        $Item = [PSCustomObject]@{ ValidFrom = $null; ValidTo = [datetime]::new(2025, 6, 30) }
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2025, 12, 1)) | Should -BeFalse
    }

    It 'returns $true when ActiveOn is within range' {
        $Item = [PSCustomObject]@{ ValidFrom = [datetime]::new(2024, 1, 1); ValidTo = [datetime]::new(2025, 12, 31) }
        Test-TemporalActivity -Item $Item -ActiveOn ([datetime]::new(2025, 6, 15)) | Should -BeTrue
    }
}

Describe 'Get-LastActiveValue' {
    It 'returns last active entry property' {
        $History = [System.Collections.Generic.List[object]]::new()
        $History.Add([PSCustomObject]@{ Location = 'A'; ValidFrom = $null; ValidTo = $null })
        $History.Add([PSCustomObject]@{ Location = 'B'; ValidFrom = $null; ValidTo = $null })
        Get-LastActiveValue -History $History -PropertyName 'Location' -ActiveOn $null | Should -Be 'B'
    }

    It 'filters by ActiveOn date' {
        $History = [System.Collections.Generic.List[object]]::new()
        $History.Add([PSCustomObject]@{ Location = 'Old'; ValidFrom = $null; ValidTo = [datetime]::new(2024, 6, 30) })
        $History.Add([PSCustomObject]@{ Location = 'New'; ValidFrom = [datetime]::new(2025, 1, 1); ValidTo = $null })
        Get-LastActiveValue -History $History -PropertyName 'Location' -ActiveOn ([datetime]::new(2024, 3, 1)) | Should -Be 'Old'
    }

    It 'returns $null for empty history' {
        $History = [System.Collections.Generic.List[object]]::new()
        Get-LastActiveValue -History $History -PropertyName 'Location' -ActiveOn $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-AllActiveValues' {
    It 'returns all active entries as string array' {
        $History = [System.Collections.Generic.List[object]]::new()
        $History.Add([PSCustomObject]@{ Group = 'GroupA'; ValidFrom = $null; ValidTo = $null })
        $History.Add([PSCustomObject]@{ Group = 'GroupB'; ValidFrom = $null; ValidTo = $null })
        $Result = Get-AllActiveValues -History $History -PropertyName 'Group' -ActiveOn $null
        $Result.Count | Should -Be 2
        $Result | Should -Contain 'GroupA'
        $Result | Should -Contain 'GroupB'
    }

    It 'returns empty array for empty history' {
        $History = [System.Collections.Generic.List[object]]::new()
        $Result = Get-AllActiveValues -History $History -PropertyName 'Group' -ActiveOn $null
        $Result.Count | Should -Be 0
    }
}

Describe 'Resolve-EntityCN' {
    It 'non-location entity gets Type/Name CN' {
        $Entity = [PSCustomObject]@{ Name = 'TestNPC'; Type = 'NPC'; LocationHistory = [System.Collections.Generic.List[object]]::new(); Doors = @() }
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Result = Resolve-EntityCN -Entity $Entity -Visited $Visited -EntityByName @{} -ActiveOn $null -CNCache @{}
        $Result | Should -Be 'NPC/TestNPC'
    }

    It 'top-level location gets Lokacja/Name' {
        $Entity = [PSCustomObject]@{ Name = 'Enroth'; Type = 'Lokacja'; LocationHistory = [System.Collections.Generic.List[object]]::new(); Doors = @() }
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Result = Resolve-EntityCN -Entity $Entity -Visited $Visited -EntityByName @{} -ActiveOn $null -CNCache @{}
        $Result | Should -Be 'Lokacja/Enroth'
    }
}

Describe 'Get-Entity' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
    }

    It 'parses all entities from fixtures' {
        $script:Entities.Count | Should -BeGreaterThan 10
    }

    It 'parses NPC type correctly' {
        $Orrin = $script:Entities | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin | Should -Not -BeNullOrEmpty
        $Orrin.Type | Should -Be 'NPC'
    }

    It 'parses Lokacja type correctly' {
        $Erathia = $script:Entities | Where-Object { $_.Name -eq 'Erathia' }
        $Erathia | Should -Not -BeNullOrEmpty
        $Erathia.Type | Should -Be 'Lokacja'
    }

    It 'parses Organizacja type correctly' {
        $Kupcy = $script:Entities | Where-Object { $_.Name -eq 'Kupcy Erathii' }
        $Kupcy | Should -Not -BeNullOrEmpty
        $Kupcy.Type | Should -Be 'Organizacja'
    }

    It 'parses Postać type correctly' {
        $Xeron = $script:Entities | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron | Should -Not -BeNullOrEmpty
        $Xeron.Type | Should -Be 'Postać'
    }

    It 'parses Przedmiot type correctly' {
        $Miecz = $script:Entities | Where-Object { $_.Name -eq 'Miecz Armagedonu' }
        $Miecz | Should -Not -BeNullOrEmpty
        $Miecz.Type | Should -Be 'Przedmiot'
    }

    It 'resolves @alias with temporal range' {
        $Rion = $script:Entities | Where-Object { $_.Name -eq 'Rion' }
        $Rion.Aliases.Count | Should -BeGreaterThan 0
        $Rion.Names | Should -Contain 'Arcymag Rion'
    }

    It 'resolves @lokacja with temporal data' {
        $Rion = $script:Entities | Where-Object { $_.Name -eq 'Rion' }
        $Rion.LocationHistory.Count | Should -BeGreaterOrEqual 2
    }

    It 'resolves @grupa membership' {
        $Rion = $script:Entities | Where-Object { $_.Name -eq 'Rion' }
        $Rion.GroupHistory.Count | Should -BeGreaterOrEqual 1
    }

    It 'resolves @status' {
        $Thant = $script:Entities | Where-Object { $_.Name -eq 'Thant' }
        $Thant.StatusHistory.Count | Should -BeGreaterOrEqual 1
    }

    It 'resolves @należy_do ownership' {
        $Xeron = $script:Entities | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Owner | Should -Be 'Solmyr'
    }

    It 'resolves @zawiera' {
        $Erathia = $script:Entities | Where-Object { $_.Name -eq 'Erathia' }
        $Erathia.Contains | Should -Contain 'Ratusz Erathii'
    }

    It 'stores generic overrides (e.g. @pu_startowe)' {
        $Xeron = $script:Entities | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Overrides.ContainsKey('pu_startowe') | Should -BeTrue
    }

    It 'merges entities across files - entities-100-ent.md has highest primacy' {
        $Xeron = $script:Entities | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron.Overrides['pu_suma'] | Should -Contain '26'
    }

    It 'merges entities-200-ent.md adds new entity (Adrienne Darkfire)' {
        $Adrienne = $script:Entities | Where-Object { $_.Name -eq 'Adrienne Darkfire' }
        $Adrienne | Should -Not -BeNullOrEmpty
    }

    It 'merges entities-200-ent.md adds alias to existing entity (Kupiec Orrin)' {
        $Orrin = $script:Entities | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin.Names | Should -Contain 'Stary Orrin'
    }

    It 'builds hierarchical CN for nested locations' {
        $RatuszErathii = $script:Entities | Where-Object { $_.Name -eq 'Ratusz Erathii' }
        $RatuszErathii.CN | Should -BeLike 'Lokacja/Enroth/Erathia/Ratusz Erathii'
    }

    It 'builds flat CN for top-level locations' {
        $Enroth = $script:Entities | Where-Object { $_.Name -eq 'Enroth' }
        $Enroth.CN | Should -Be 'Lokacja/Enroth'
    }

    It 'builds flat CN for non-location entities' {
        $Orrin = $script:Entities | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin.CN | Should -Be 'NPC/Kupiec Orrin'
    }

    It 'default status is Aktywny when no @status present' {
        $Orrin = $script:Entities | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin.Status | Should -Be 'Aktywny'
    }

    It 'parses multi-line @info via nested bullets' {
        $Orrin = $script:Entities | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin.Overrides.ContainsKey('info') | Should -BeTrue
    }

    It 'returns empty list for empty directory' {
        $EmptyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-empty-" + [System.Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($EmptyDir)
        try {
            $Result = Get-Entity -Path $EmptyDir
            $Result.Count | Should -Be 0
        } finally {
            [System.IO.Directory]::Delete($EmptyDir, $true)
        }
    }

    It 'parses @generyczne_nazwy into GenericNames list' {
        $Straznik = $script:Entities | Where-Object { $_.Name -eq 'Strażnik Bramy' }
        $Straznik | Should -Not -BeNullOrEmpty
        $Straznik.GenericNames | Should -Contain 'Strażnik Miasta'
        $Straznik.GenericNames | Should -Contain 'Wartownik'
    }

    It 'adds @generyczne_nazwy values to Names for resolution' {
        $Straznik = $script:Entities | Where-Object { $_.Name -eq 'Strażnik Bramy' }
        $Straznik.Names | Should -Contain 'Strażnik Miasta'
        $Straznik.Names | Should -Contain 'Wartownik'
    }

    It 'initializes GenericNames as empty list when no tag present' {
        $Orrin = $script:Entities | Where-Object { $_.Name -eq 'Kupiec Orrin' }
        $Orrin.GenericNames.Count | Should -Be 0
    }
}

Describe 'Get-NestedBulletText' {
    BeforeAll {
        $script:BulletParent = [PSCustomObject]@{ Text = 'Parent' }
        $script:ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($script:BulletParent)
    }

    It 'returns null when parent has no children' {
        $ChildrenOf = @{}
        $Result = Get-NestedBulletText -ParentBullet $script:BulletParent -ChildrenOf $ChildrenOf -ActiveOn $null
        $Result | Should -BeNullOrEmpty
    }

    It 'returns null when children list is empty' {
        $ChildrenOf = @{ $script:ParentId = @() }
        $Result = Get-NestedBulletText -ParentBullet $script:BulletParent -ChildrenOf $ChildrenOf -ActiveOn $null
        $Result | Should -BeNullOrEmpty
    }

    It 'returns joined text for active children without temporal filter' {
        $Children = @(
            [PSCustomObject]@{ Text = 'Child1' },
            [PSCustomObject]@{ Text = 'Child2' }
        )
        $ChildrenOf = @{ $script:ParentId = $Children }
        $Result = Get-NestedBulletText -ParentBullet $script:BulletParent -ChildrenOf $ChildrenOf -ActiveOn $null
        $Result | Should -Be "Child1`nChild2"
    }

    It 'filters children by temporal activity' {
        $Children = @(
            [PSCustomObject]@{ Text = 'Active (2024-01:)' },
            [PSCustomObject]@{ Text = 'Expired (:2023-06)' }
        )
        $ChildrenOf = @{ $script:ParentId = $Children }
        $Result = Get-NestedBulletText -ParentBullet $script:BulletParent -ChildrenOf $ChildrenOf -ActiveOn ([datetime]::new(2025, 1, 1))
        $Result | Should -Be 'Active'
    }

    It 'returns null when all children are temporally inactive' {
        $Children = @(
            [PSCustomObject]@{ Text = 'Gone (:2020-01)' }
        )
        $ChildrenOf = @{ $script:ParentId = $Children }
        $Result = Get-NestedBulletText -ParentBullet $script:BulletParent -ChildrenOf $ChildrenOf -ActiveOn ([datetime]::new(2025, 1, 1))
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-EntityCN' {
    BeforeAll {
        $script:Entities = Get-Entity -Path $script:FixturesRoot
        $script:EntityByName = @{}
        foreach ($E in $script:Entities) {
            foreach ($N in $E.Names) {
                $script:EntityByName[$N] = $E
            }
        }
    }

    It 'returns Lokacja/Parent/Child for nested location' {
        $Erathia = $script:EntityByName['Erathia']
        $Ratusz = $script:EntityByName['Ratusz Erathii']
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Result = Resolve-EntityCN -Entity $Ratusz -Visited $Visited -EntityByName $script:EntityByName -ActiveOn $null -CNCache @{}
        $Result | Should -BeLike 'Lokacja/Enroth/Erathia/Ratusz Erathii'
    }

    It 'returns flat CN for non-location entity' {
        $Orrin = $script:EntityByName['Kupiec Orrin']
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Result = Resolve-EntityCN -Entity $Orrin -Visited $Visited -EntityByName $script:EntityByName -ActiveOn $null -CNCache @{}
        $Result | Should -Be 'NPC/Kupiec Orrin'
    }

    It 'returns Lokacja/Name for top-level location without parent' {
        $Enroth = $script:EntityByName['Enroth']
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Result = Resolve-EntityCN -Entity $Enroth -Visited $Visited -EntityByName $script:EntityByName -ActiveOn $null -CNCache @{}
        $Result | Should -Be 'Lokacja/Enroth'
    }

    It 'uses CNCache for repeated lookups' {
        $Cache = @{}
        $Erathia = $script:EntityByName['Erathia']
        $V1 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $R1 = Resolve-EntityCN -Entity $Erathia -Visited $V1 -EntityByName $script:EntityByName -ActiveOn $null -CNCache $Cache
        $Cache.ContainsKey('Erathia') | Should -BeTrue
        $V2 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $R2 = Resolve-EntityCN -Entity $Erathia -Visited $V2 -EntityByName $script:EntityByName -ActiveOn $null -CNCache $Cache
        $R2 | Should -Be $R1
    }

    It 'handles parent not in entity registry' {
        $Orphan = [PSCustomObject]@{
            Name            = 'TestOrphan'
            Type            = 'Lokacja'
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory = [System.Collections.Generic.List[object]]::new()
            Doors           = [System.Collections.Generic.List[object]]::new()
        }
        [void]$Orphan.Names.Add('TestOrphan')
        $Orphan.LocationHistory.Add([PSCustomObject]@{ Location = 'UnknownParent'; ValidFrom = $null; ValidTo = $null })
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Result = Resolve-EntityCN -Entity $Orphan -Visited $Visited -EntityByName $script:EntityByName -ActiveOn $null -CNCache @{}
        $Result | Should -Be 'Lokacja/UnknownParent/TestOrphan'
    }
}

Describe 'Get-Entity with single file path' {
    It 'loads entities when given a direct file path' {
        $FilePath = Join-Path $script:FixturesRoot 'entities.md'
        $Result = Get-Entity -Path $FilePath
        $Result | Should -Not -BeNullOrEmpty
        $Result.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-Entity @drzwi and @typ parsing' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-drzwi-typ.md')
    }

    It 'parses @drzwi into DoorHistory' {
        $Room = $script:Entities | Where-Object { $_.Name -eq 'Komnata Prób' }
        $Room.DoorHistory.Count | Should -BeGreaterThan 0
        $Room.DoorHistory[0].Location | Should -Be 'Wielka Sala'
    }

    It 'parses @typ into TypeHistory' {
        $Room = $script:Entities | Where-Object { $_.Name -eq 'Komnata Prób' }
        $Room.TypeHistory.Count | Should -BeGreaterThan 0
        $Room.TypeHistory[0].Type | Should -Be 'Loch'
    }
}

Describe 'Get-Entity - unicode entity names' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-unicode-names.md')
    }

    It 'parses entity with Polish diacritics in name' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Śćiółka Żółwia' }
        $E | Should -Not -BeNullOrEmpty
        $E.Type | Should -Be 'NPC'
    }

    It 'parses alias with Polish diacritics' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Śćiółka Żółwia' }
        $E.Names | Should -Contain 'Źrebak Ćmy'
    }

    It 'parses location with Polish diacritics' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Śćiółka Żółwia' }
        $E.Location | Should -Be 'Łąka Ościennych'
    }

    It 'parses info with diacritics' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Śćiółka Żółwia' }
        $E.Overrides.ContainsKey('info') | Should -BeTrue
    }

    It 'parses all entities from unicode file' {
        $script:Entities.Count | Should -Be 5
    }
}

Describe 'Get-Entity - empty entity sections' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-empty-sections.md')
    }

    It 'parses entities with no tags' {
        $script:Entities.Count | Should -Be 3
    }

    It 'entities without tags default to Aktywny' {
        foreach ($E in $script:Entities) {
            $E.Status | Should -Be 'Aktywny'
        }
    }

    It 'entities without tags have empty location history' {
        foreach ($E in $script:Entities) {
            $E.LocationHistory.Count | Should -Be 0
        }
    }
}

Describe 'Get-Entity - many aliases' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-many-aliases.md')
    }

    It 'parses entity with many aliases' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Aliasami' }
        $E | Should -Not -BeNullOrEmpty
        $E.Aliases.Count | Should -Be 6
    }

    It 'includes expired aliases in Names set' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Aliasami' }
        $E.Names | Should -Contain 'Szpieg Tunnelów'
    }

    It 'includes current aliases in Names set' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Aliasami' }
        $E.Names | Should -Contain 'Alias Pierwszy'
        $E.Names | Should -Contain 'Alias Piąty'
    }

    It 'filters aliases by ActiveOn date' {
        $Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-many-aliases.md') -ActiveOn ([datetime]::ParseExact('2023-12-15', 'yyyy-MM-dd', $null))
        $E = $Entities | Where-Object { $_.Name -eq 'NPC z Aliasami' }
        $E | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-Entity - deep nested locations' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-deep-locations.md')
    }

    It 'parses all locations from deep hierarchy' {
        $script:Entities.Count | Should -Be 7
    }

    It 'builds 3-level deep CN for Ratusz Steadwicku' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Ratusz Steadwicku' }
        $E.CN | Should -BeLike 'Lokacja/Kontynent Antagarich/Królestwo Erathii/Miasto Steadwick/Ratusz Steadwicku'
    }

    It 'builds 3-level deep CN for Wieża Obserwacyjna' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Wieża Obserwacyjna' }
        $E.CN | Should -BeLike 'Lokacja/Kontynent Antagarich/Królestwo Erathii/Twierdza Gryfów/Wieża Obserwacyjna'
    }

    It 'parses @zawiera for mid-level locations' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Miasto Steadwick' }
        $E.Contains | Should -Contain 'Ratusz Steadwicku'
        $E.Contains | Should -Contain 'Koszary Królewskie'
    }

    It 'builds top-level CN for root location' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Kontynent Antagarich' }
        $E.CN | Should -Be 'Lokacja/Kontynent Antagarich'
    }
}

Describe 'Get-Entity - many groups' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-many-groups.md')
    }

    It 'parses NPC with four group memberships' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Wieloma Grupami' }
        $E.GroupHistory.Count | Should -Be 4
    }

    It 'includes expired group in history' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Wieloma Grupami' }
        $Groups = $E.GroupHistory | ForEach-Object { $_.Group }
        $Groups | Should -Contain 'Gildia Wojowników'
    }

    It 'includes all active groups' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Wieloma Grupami' }
        $Groups = $E.GroupHistory | ForEach-Object { $_.Group }
        $Groups | Should -Contain 'Zakon Gryfów'
        $Groups | Should -Contain 'Rada Starszych'
        $Groups | Should -Contain 'Straż Nocna'
    }

    It 'parses organization aliases' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Gildia Wojowników' }
        $E.Names | Should -Contain 'Gildia'
    }
}

Describe 'Get-Entity - duplicate names across types' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-duplicate-names.md')
    }

    It 'parses all entities with same name but different types' {
        $Dupes = $script:Entities | Where-Object { $_.Name -eq 'NPC Duplikat' }
        $Dupes.Count | Should -Be 3
    }

    It 'assigns correct type to each entity' {
        $Types = ($script:Entities | Where-Object { $_.Name -eq 'NPC Duplikat' }).Type
        $Types | Should -Contain 'NPC'
        $Types | Should -Contain 'Lokacja'
        $Types | Should -Contain 'Organizacja'
    }
}

Describe 'Get-Entity - multiline info' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-multiline-info.md')
    }

    It 'parses multi-line @info via nested bullets' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Info Wieloliniowe' }
        $E.Overrides.ContainsKey('info') | Should -BeTrue
        $InfoText = $E.Overrides['info'] -join ' '
        $InfoText | Should -BeLike '*Pierwszy akapit*'
        $InfoText | Should -BeLike '*Trzecia linia*'
    }

    It 'parses single-line @info' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'NPC z Info Jednolinijkowe' }
        $E.Overrides.ContainsKey('info') | Should -BeTrue
    }
}

Describe 'Get-Entity - currency edge cases' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-currency-edge.md')
    }

    It 'parses very large @ilość value' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Korony Bogatego Kupca' }
        $E.Quantity | Should -Be '999999'
    }

    It 'parses zero @ilość value' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Talary Zerowe' }
        $E.Quantity | Should -Be '0'
    }

    It 'parses negative @ilość value' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Korony Zadłużonego' }
        $E.Quantity | Should -Be '-100'
    }

    It 'parses entity with multiple @ilość temporal values' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Kogi Mieszane' }
        $E.QuantityHistory.Count | Should -Be 3
        $E.Quantity | Should -Be '75'
    }

    It 'resolves @generyczne_nazwy for all currency entities' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Korony Bogatego Kupca' }
        $E.GenericNames | Should -Contain 'Korony Elanckie'
    }
}

Describe 'Get-Entity - BRAK PU values' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-brak-pu.md')
    }

    It 'parses character with all BRAK PU overrides' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Postać BRAK' }
        $E | Should -Not -BeNullOrEmpty
        $E.Overrides['pu_startowe'] | Should -Contain 'BRAK'
        $E.Overrides['pu_suma'] | Should -Contain 'BRAK'
        $E.Overrides['pu_zdobyte'] | Should -Contain 'BRAK'
        $E.Overrides['pu_nadmiar'] | Should -Contain 'BRAK'
    }
}

Describe 'Get-Entity - many characters per player' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-many-characters.md')
    }

    It 'parses five character entities' {
        $Characters = $script:Entities | Where-Object { $_.Type -eq 'Postać' }
        $Characters.Count | Should -Be 5
    }

    It 'all characters belong to same player' {
        $Characters = $script:Entities | Where-Object { $_.Type -eq 'Postać' }
        foreach ($C in $Characters) {
            $C.Owner | Should -Be 'Solmyr'
        }
    }

    It 'parses PU nadmiar for last character' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Bohater Piąty' }
        $E.Overrides['pu_nadmiar'] | Should -Contain '2.5'
    }

    It 'character with zero PU zdobyte has correct value' {
        $E = $script:Entities | Where-Object { $_.Name -eq 'Bohater Czwarty' }
        $E.Overrides['pu_zdobyte'] | Should -Contain '0'
    }
}

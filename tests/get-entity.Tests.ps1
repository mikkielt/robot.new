BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
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

    It 'parses Postać (Gracz) type correctly' {
        $Xeron = $script:Entities | Where-Object { $_.Name -eq 'Xeron Demonlord' }
        $Xeron | Should -Not -BeNullOrEmpty
        $Xeron.Type | Should -Be 'Postać (Gracz)'
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

    It 'merges entities across files — entities-100-ent.md has highest primacy' {
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
        [System.IO.Directory]::CreateDirectory($EmptyDir) | Out-Null
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

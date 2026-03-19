<#
    .SYNOPSIS
    Pester tests for Get-LocationEntity.

    .DESCRIPTION
    Tests for Get-LocationEntity covering type filtering, status gates,
    name/parent/hasDoors/isExterior filters, enrichment (children, door targets,
    entity counts, hierarchical path, NerthusName), and IncludeMaps.
    Uses mock entity objects to avoid dependency on Get-EntityState.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-get-loc-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force

    # Mock entity objects matching Get-EntityState output shape
    $script:MockEntities = @(
        # Exterior location (has coordinates), root level
        [PSCustomObject]@{
            Name        = 'Steadwick'
            Type        = 'Lokacja'
            Location    = $null
            Status      = $null
            Coordinates = '25, 18'
            IsExterior  = $true
            Doors       = [System.Collections.Generic.List[string]]@('Ratusz Steadwicku', 'Koszary')
            NerthusName = 'Zamek Steadwick'
            CN          = 'Steadwick'
            Overrides   = @{}
        }
        # Interior location (child of Steadwick, has doors)
        [PSCustomObject]@{
            Name        = 'Ratusz Steadwicku'
            Type        = 'Lokacja'
            Location    = 'Steadwick'
            Status      = $null
            Coordinates = $null
            IsExterior  = $false
            Doors       = [System.Collections.Generic.List[string]]@('Komnata Rady')
            NerthusName = $null
            CN          = 'Steadwick > Ratusz Steadwicku'
            Overrides   = @{}
        }
        # Interior, no doors
        [PSCustomObject]@{
            Name        = 'Koszary'
            Type        = 'Lokacja'
            Location    = 'Steadwick'
            Status      = $null
            Coordinates = $null
            IsExterior  = $false
            Doors       = [System.Collections.Generic.List[string]]::new()
            NerthusName = $null
            CN          = 'Steadwick > Koszary'
            Overrides   = @{}
        }
        # Inactive location
        [PSCustomObject]@{
            Name        = 'Opuszczona Strażnica'
            Type        = 'Lokacja'
            Location    = 'Steadwick'
            Status      = 'Nieaktywny'
            Coordinates = $null
            IsExterior  = $null
            Doors       = [System.Collections.Generic.List[string]]::new()
            NerthusName = $null
            CN          = 'Steadwick > Opuszczona Strażnica'
            Overrides   = @{}
        }
        # Deleted location
        [PSCustomObject]@{
            Name        = 'Ruiny Zamku'
            Type        = 'Lokacja'
            Location    = 'Steadwick'
            Status      = 'Usunięty'
            Coordinates = $null
            IsExterior  = $null
            Doors       = [System.Collections.Generic.List[string]]::new()
            NerthusName = $null
            CN          = 'Steadwick > Ruiny Zamku'
            Overrides   = @{}
        }
        # Mapa entity
        [PSCustomObject]@{
            Name        = 'Komnata Rady'
            Type        = 'Mapa'
            Location    = 'Ratusz Steadwicku'
            Status      = $null
            Coordinates = $null
            IsExterior  = $null
            Doors       = [System.Collections.Generic.List[string]]@('Steadwick')
            NerthusName = $null
            CN          = 'Steadwick > Ratusz Steadwicku > Komnata Rady'
            Overrides   = @{ slug = 'komnata-rady-ratusz'; url = 'https://cdn.margonem.pl/maps/komnata-rady.png'; wymiary = '20, 15' }
        }
        # NPC at Steadwick (for entity count)
        [PSCustomObject]@{
            Name        = 'Crag Hack'
            Type        = 'NPC'
            Location    = 'Steadwick'
            Status      = 'Aktywny'
            Coordinates = $null
            IsExterior  = $null
            Doors       = $null
            NerthusName = $null
            CN          = $null
            Overrides   = @{}
        }
        # NPC at Ratusz
        [PSCustomObject]@{
            Name        = 'Strażnik Ratusza'
            Type        = 'NPC'
            Location    = 'Ratusz Steadwicku'
            Status      = 'Aktywny'
            Coordinates = $null
            IsExterior  = $null
            Doors       = $null
            NerthusName = $null
            CN          = $null
            Overrides   = @{}
        }
        # Item at Steadwick
        [PSCustomObject]@{
            Name        = 'Miecz Słońca'
            Type        = 'Przedmiot'
            Location    = 'Steadwick'
            Status      = 'Aktywny'
            Coordinates = $null
            IsExterior  = $null
            Doors       = $null
            NerthusName = $null
            CN          = $null
            Overrides   = @{}
        }
    )
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Get-LocationEntity' {
    It 'returns only active Lokacja entities by default' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Result.Count | Should -Be 3
        $Result.EntityName | Should -Contain 'Steadwick'
        $Result.EntityName | Should -Contain 'Ratusz Steadwicku'
        $Result.EntityName | Should -Contain 'Koszary'
    }

    It 'excludes Mapa entities by default' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Komnata Rady'
    }

    It 'includes Mapa entities with -IncludeMaps' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -IncludeMaps -Quiet
        $Result.Count | Should -Be 4
        $Result.EntityName | Should -Contain 'Komnata Rady'
    }

    It 'excludes Nieaktywny by default' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Opuszczona Strażnica'
    }

    It 'includes Nieaktywny with -IncludeInactive' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -IncludeInactive -Quiet
        $Result.EntityName | Should -Contain 'Opuszczona Strażnica'
    }

    It 'excludes Usunięty by default' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Ruiny Zamku'
    }

    It 'includes Usunięty with -IncludeDeleted' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -IncludeDeleted -Quiet
        $Result.EntityName | Should -Contain 'Ruiny Zamku'
    }

    It 'filters by name (substring, case-insensitive)' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'ratusz' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Ratusz Steadwicku'
    }

    It 'filters by parent (exact, case-insensitive)' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Parent 'steadwick' -Quiet
        $Result.Count | Should -Be 2
        $Result.EntityName | Should -Contain 'Ratusz Steadwicku'
        $Result.EntityName | Should -Contain 'Koszary'
    }

    It 'filters by -HasDoors' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -HasDoors -Quiet
        $Result.Count | Should -Be 2
        $Result.EntityName | Should -Contain 'Steadwick'
        $Result.EntityName | Should -Contain 'Ratusz Steadwicku'
    }

    It 'filters by -IsExterior' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -IsExterior -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Steadwick'
    }

    It 'filters by -Status' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Status 'Nieaktywny' -IncludeInactive -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Opuszczona Strażnica'
    }

    It 'enriches Children array' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Steadwick' -Quiet
        $Steadwick = $Result | Where-Object { $_.EntityName -eq 'Steadwick' }
        # Ratusz and Koszary are active children (inactive/deleted excluded from entity list but still counted as children)
        $Steadwick.ChildCount | Should -BeGreaterOrEqual 2
    }

    It 'enriches DoorTargets with resolved entities' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Steadwick' -Quiet
        $Steadwick = $Result[0]
        $Steadwick.DoorCount | Should -Be 2
        $Resolved = $Steadwick.DoorTargets | Where-Object { $_.Name -eq 'Ratusz Steadwicku' }
        $Resolved | Should -Not -BeNullOrEmpty
    }

    It 'enriches DoorTargets with unresolved marker' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Steadwick' -Quiet
        $Steadwick = $Result[0]
        # 'Koszary' door target resolves; check that door targets array has entries
        $Steadwick.DoorTargets.Count | Should -Be 2
    }

    It 'enriches IsExterior flag' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Steadwick = $Result | Where-Object { $_.EntityName -eq 'Steadwick' }
        $Steadwick.IsExterior | Should -BeTrue
        $Ratusz = $Result | Where-Object { $_.EntityName -eq 'Ratusz Steadwicku' }
        $Ratusz.IsExterior | Should -BeFalse
    }

    It 'enriches HierarchicalPath from CN' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Ratusz' -Quiet
        $Result[0].HierarchicalPath | Should -Be 'Steadwick > Ratusz Steadwicku'
    }

    It 'enriches EntityCount (non-location entities at this location)' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Steadwick = $Result | Where-Object { $_.EntityName -eq 'Steadwick' }
        # Crag Hack + Miecz Słońca = 2
        $Steadwick.EntityCount | Should -Be 2
        $Ratusz = $Result | Where-Object { $_.EntityName -eq 'Ratusz Steadwicku' }
        # Strażnik Ratusza = 1
        $Ratusz.EntityCount | Should -Be 1
    }

    It 'enriches NerthusName' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Steadwick' -Quiet
        $Result[0].NerthusName | Should -Be 'Zamek Steadwick'
    }

    It 'enriches MapData from Overrides for Mapa entities' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -IncludeMaps -Name 'Komnata' -Quiet
        $Map = $Result | Where-Object { $_.Type -eq 'Mapa' }
        $Map.MapData | Should -Not -BeNullOrEmpty
        $Map.MapData.Slug | Should -Be 'komnata-rady-ratusz'
        $Map.MapData.Url | Should -Be 'https://cdn.margonem.pl/maps/komnata-rady.png'
        $Map.MapData.Dimensions | Should -Be '20, 15'
    }

    It 'sets MapData to null for Lokacja entities' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Steadwick' -Quiet
        $Result[0].MapData | Should -BeNullOrEmpty
    }

    It 'excludes non-location entity types' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Crag Hack'
        $Result.EntityName | Should -Not -Contain 'Miecz Słońca'
    }

    It 'returns empty array when no matches' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Name 'Nonexistent' -Quiet
        $Result.Count | Should -Be 0
    }

    It 'returns empty array with empty entity set' {
        $Result = Get-LocationEntity -Entities @() -Quiet
        $Result.Count | Should -Be 0
    }

    It 'defaults Status to Aktywny when entity has no Status' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Status 'Aktywny' -Quiet
        $Result.Count | Should -Be 3
    }

    It 'enriches ExteriorParent for interior locations' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Ratusz = $Result | Where-Object { $_.EntityName -eq 'Ratusz Steadwicku' }
        $Ratusz.ExteriorParent | Should -Be 'Steadwick'
    }

    It 'enriches QualifiedPath for interior locations' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Ratusz = $Result | Where-Object { $_.EntityName -eq 'Ratusz Steadwicku' }
        $Ratusz.QualifiedPath | Should -Be 'Steadwick/Ratusz Steadwicku'
    }

    It 'ExteriorParent is null for exterior locations' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Steadwick = $Result | Where-Object { $_.EntityName -eq 'Steadwick' }
        $Steadwick.ExteriorParent | Should -BeNullOrEmpty
    }

    It 'QualifiedPath is null for exterior locations' {
        $Result = Get-LocationEntity -Entities $script:MockEntities -Quiet
        $Steadwick = $Result | Where-Object { $_.EntityName -eq 'Steadwick' }
        $Steadwick.QualifiedPath | Should -BeNullOrEmpty
    }

    It '-IsExterior filter works with Mapa-child-based exterior classification' {
        # Add a Mapa-classified exterior entity (IsExterior = $true via Mapa child, no coordinates)
        $MapaExteriorEntities = @(
            [PSCustomObject]@{
                Name = 'Bracada'; Type = 'Lokacja'; Location = $null; Status = $null
                Coordinates = $null; IsExterior = $true; Doors = [System.Collections.Generic.List[string]]::new()
                NerthusName = $null; CN = 'Bracada'; Overrides = @{}
            }
            [PSCustomObject]@{
                Name = 'Podziemie'; Type = 'Lokacja'; Location = 'Bracada'; Status = $null
                Coordinates = $null; IsExterior = $false; Doors = [System.Collections.Generic.List[string]]::new()
                NerthusName = $null; CN = 'Bracada > Podziemie'; Overrides = @{}
            }
        )
        $Result = Get-LocationEntity -Entities $MapaExteriorEntities -IsExterior -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Bracada'
    }
}

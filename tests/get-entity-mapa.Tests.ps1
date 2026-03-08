<#
    .SYNOPSIS
    Pester tests for Mapa entity parsing, @slug resolution, and hierarchical CN.

    .DESCRIPTION
    Tests Get-Entity parsing of ## Mapa sections, @slug tag indexing in Names,
    @url/@url_nerthus storage in Overrides, hierarchical CN via @lokacja chain,
    @drzwi door-path names on Mapa, and duplicate Mapa name handling.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
}

Describe 'Get-Entity - Mapa type parsing' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-mapa.md')
    }

    It 'parses ## Mapa section entities as Type = Mapa' {
        $Maps = $script:Entities | Where-Object { $_.Type -eq 'Mapa' }
        $Maps.Count | Should -Be 2  # Komnata Rady (merged) + Piwnica Ratusza
    }

    It 'merges duplicate Komnata Rady into one entity' {
        $Maps = $script:Entities | Where-Object { $_.Name -eq 'Komnata Rady' -and $_.Type -eq 'Mapa' }
        $Maps.Count | Should -Be 1  # same type+name → merged
    }

    It 'stores @url in Overrides' {
        $Map = $script:Entities | Where-Object { $_.Name -eq 'Piwnica Ratusza' -and $_.Type -eq 'Mapa' }
        $Map | Should -Not -BeNullOrEmpty
        $Map.Overrides.ContainsKey('url') | Should -BeTrue
        $Map.Overrides['url'][-1] | Should -Be 'https://cdn.margonem.pl/maps/piwnica-ratusza.png'
    }

    It 'stores @url_nerthus in Overrides' {
        $Map = $script:Entities | Where-Object { $_.Name -eq 'Komnata Rady' -and $_.Type -eq 'Mapa' }
        $Map.Overrides.ContainsKey('url_nerthus') | Should -BeTrue
        $Map.Overrides['url_nerthus'][-1] | Should -Be 'https://nerthus.margonem.pl/maps/komnata-rady.png'
    }

    It 'stores @wymiary in Overrides' {
        $Map = $script:Entities | Where-Object { $_.Name -eq 'Komnata Rady' -and $_.Type -eq 'Mapa' }
        $Map.Overrides.ContainsKey('wymiary') | Should -BeTrue
    }

    It 'stores @info in Overrides' {
        $Map = $script:Entities | Where-Object { $_.Name -eq 'Piwnica Ratusza' -and $_.Type -eq 'Mapa' }
        $Map.Overrides.ContainsKey('info') | Should -BeTrue
        $Map.Overrides['info'][-1] | Should -Be 'Podziemia ratusza.'
    }

    It 'parses Lokacja entities alongside Mapa' {
        $Locs = $script:Entities | Where-Object { $_.Type -eq 'Lokacja' }
        $Locs.Count | Should -Be 2
    }

    It 'parses NPC entities alongside Mapa' {
        $NPCs = $script:Entities | Where-Object { $_.Type -eq 'NPC' }
        $NPCs.Count | Should -Be 1
    }
}

Describe 'Get-Entity - Mapa hierarchical CN via @lokacja' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-mapa.md')
    }

    It 'Mapa entity gets hierarchical CN via @lokacja chain' {
        $Map = $script:Entities | Where-Object { $_.Name -eq 'Piwnica Ratusza' -and $_.Type -eq 'Mapa' }
        $Map.CN | Should -BeLike 'Lokacja/Steadwick/Ratusz/Piwnica Ratusza'
    }

    It 'top-level Lokacja still gets flat CN' {
        $Loc = $script:Entities | Where-Object { $_.Name -eq 'Steadwick' -and $_.Type -eq 'Lokacja' }
        $Loc.CN | Should -Be 'Lokacja/Steadwick'
    }

    It 'NPC entity gets flat CN' {
        $NPC = $script:Entities | Where-Object { $_.Name -eq 'Strażnik Ratusza' }
        $NPC.CN | Should -Be 'NPC/Strażnik Ratusza'
    }
}

Describe 'Get-Entity - @drzwi door-path names on Mapa' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-mapa.md')
    }

    It 'Mapa entity with @drzwi gets door-path name in Names' {
        $Map = $script:Entities | Where-Object { $_.Name -eq 'Komnata Rady' -and $_.Type -eq 'Mapa' }
        $Map.Doors.Count | Should -BeGreaterThan 0
        $Map.Names | Should -Contain 'Steadwick/Komnata Rady'
    }
}

Describe 'Get-Entity - @slug tag' {
    BeforeAll {
        $script:MapaEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-mapa.md')
        $script:SlugEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-slug.md')
    }

    It '@slug value appears in Mapa entity Names set' {
        $Map = $script:MapaEntities | Where-Object { $_.Name -eq 'Komnata Rady' -and $_.Type -eq 'Mapa' }
        $Map.Names | Should -Contain 'komnata-rady-ratusz'
    }

    It '@slug value appears in NPC entity Names set' {
        $NPC = $script:SlugEntities | Where-Object { $_.Name -eq 'Kupiec Clancy' }
        $NPC.Names | Should -Contain 'clancy-kupiec'
    }

    It '@slug value appears in Lokacja entity Names set' {
        $Loc = $script:SlugEntities | Where-Object { $_.Name -eq 'Targ Główny' }
        $Loc.Names | Should -Contain 'targ-glowny-steadwick'
    }

    It 'merged Mapa entity contains both @slug values in Names' {
        $Map = $script:MapaEntities | Where-Object { $_.Name -eq 'Komnata Rady' -and $_.Type -eq 'Mapa' }
        $Map.Names | Should -Contain 'komnata-rady-ratusz'
        $Map.Names | Should -Contain 'komnata-rady-steadwick'
    }
}

Describe 'Get-NameIndex - @slug indexing' {
    BeforeAll {
        $script:SlugEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-slug.md')
        $script:IndexResult = Get-NameIndex -Players @() -Entities $script:SlugEntities
        $script:Index = $script:IndexResult.Index
    }

    It 'indexes @slug value at priority 1' {
        $script:Index.ContainsKey('clancy-kupiec') | Should -BeTrue
        $script:Index['clancy-kupiec'].Priority | Should -Be 1
        $script:Index['clancy-kupiec'].Owner.Name | Should -Be 'Kupiec Clancy'
    }

    It 'indexes location @slug value' {
        $script:Index.ContainsKey('targ-glowny-steadwick') | Should -BeTrue
        $script:Index['targ-glowny-steadwick'].Owner.Name | Should -Be 'Targ Główny'
    }
}

Describe 'Resolve-Name - @slug resolution' {
    BeforeAll {
        $script:SlugEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-slug.md')
        $script:IndexResult = Get-NameIndex -Players @() -Entities $script:SlugEntities
    }

    It 'resolves slug to correct entity' {
        $Result = Resolve-Name -Query 'clancy-kupiec' `
            -Index $script:IndexResult.Index `
            -StemIndex $script:IndexResult.StemIndex `
            -BKTree $script:IndexResult.BKTree
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Kupiec Clancy'
    }
}

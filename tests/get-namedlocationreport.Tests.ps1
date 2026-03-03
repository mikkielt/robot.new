<#
    .SYNOPSIS
    Pester tests for Get-NamedLocationReport RouteEdges output.

    .DESCRIPTION
    Tests that RouteEdges are correctly extracted from session metadata
    route separators (->).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'string-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-namedlocationreport.ps1')
}

Describe 'Get-NamedLocationReport RouteEdges' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-route-edges.md')
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-koordynaty.md')
        $script:Report = Get-NamedLocationReport -Sessions $script:Sessions -Entities $script:Entities -Quiet
    }

    It 'returns object with Locations property' {
        $script:Report.PSObject.Properties['Locations'] | Should -Not -BeNullOrEmpty
        $script:Report.Locations | Should -Not -BeNullOrEmpty
    }

    It 'returns object with RouteEdges property' {
        $script:Report.PSObject.Properties['RouteEdges'] | Should -Not -BeNullOrEmpty
    }

    It 'extracts route edges from -> separators' {
        $script:Report.RouteEdges.Count | Should -BeGreaterThan 0
    }

    It 'produces correct source-target pairs' {
        $Edge1 = $script:Report.RouteEdges | Where-Object {
            $_.Source -eq 'Zamek Gryfów' -and $_.Target -eq 'Przełęcz Gryfów'
        }
        $Edge1 | Should -Not -BeNullOrEmpty

        $Edge2 = $script:Report.RouteEdges | Where-Object {
            $_.Source -eq 'Przełęcz Gryfów' -and $_.Target -eq 'Steadwick'
        }
        $Edge2 | Should -Not -BeNullOrEmpty
    }

    It 'includes session metadata in edges' {
        $Edge = $script:Report.RouteEdges[0]
        $Edge.PSObject.Properties['Source'] | Should -Not -BeNullOrEmpty
        $Edge.PSObject.Properties['Target'] | Should -Not -BeNullOrEmpty
        $Edge.PSObject.Properties['SessionDate'] | Should -Not -BeNullOrEmpty
        $Edge.PSObject.Properties['Header'] | Should -Not -BeNullOrEmpty
        $Edge.PSObject.Properties['FilePath'] | Should -Not -BeNullOrEmpty
    }

    It 'does not produce route edges for single location sessions' {
        # Session "Eksploracja Podziemi" has only one location "Zamek Gryfów"
        $SingleLocEdges = $script:Report.RouteEdges | Where-Object {
            $_.Header -like '*Eksploracja*'
        }
        $SingleLocEdges | Should -BeNullOrEmpty
    }
}

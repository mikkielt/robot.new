<#
    .SYNOPSIS
    Pester tests for Get-LocationGraph.

    .DESCRIPTION
    Tests the location graph reporting function that merges entity registry,
    session metadata routes, and log transitions into a unified graph.
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
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-locationgraph.ps1')
}

Describe 'Get-LocationGraph' {
    Context 'Containment edges from entity @lokacja chains' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-deep-locations.md')
            $script:Graph = Get-LocationGraph -Entities $script:Entities -Sessions @() -Quiet
        }

        It 'produces containment edges from @lokacja' {
            $script:Graph.Summary.ContainmentEdges | Should -BeGreaterThan 0
        }

        It 'contains expected parent-child containment edge' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Source -eq 'Królestwo Erathii' -and $_.Target -eq 'Miasto Steadwick' -and $_.Type -eq 'Containment'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'builds nodes from edge endpoints' {
            $script:Graph.Summary.NodeCount | Should -BeGreaterThan 0
            $script:Graph.Nodes | Should -Not -BeNullOrEmpty
        }

        It 'resolves nodes against entity index' {
            $script:Graph.Summary.ResolvedNodes | Should -BeGreaterThan 0
        }
    }

    Context 'Door edges from @drzwi' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-koordynaty.md')
            $script:Graph = Get-LocationGraph -Entities $script:Entities -Sessions @() -Quiet
        }

        It 'produces door edges' {
            $script:Graph.Summary.DoorEdges | Should -BeGreaterThan 0
        }

        It 'contains expected door edge' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Source -eq 'Zamek Gryfów' -and $_.Target -eq 'Podziemia Gryfów' -and $_.Type -eq 'Door'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Node coordinates from @koordynaty' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-koordynaty.md')
            $script:Graph = Get-LocationGraph -Entities $script:Entities -Sessions @() -Quiet
        }

        It 'marks exterior nodes with coordinates' {
            $GryfowNode = $script:Graph.Nodes | Where-Object { $_.Name -eq 'Zamek Gryfów' }
            $GryfowNode | Should -Not -BeNullOrEmpty
            $GryfowNode.Coordinates | Should -Not -BeNullOrEmpty
            $GryfowNode.IsExterior | Should -BeTrue
        }

        It 'marks interior nodes without coordinates' {
            $PodzNode = $script:Graph.Nodes | Where-Object { $_.Name -eq 'Podziemia Gryfów' }
            $PodzNode | Should -Not -BeNullOrEmpty
            $PodzNode.Coordinates | Should -BeNullOrEmpty
            $PodzNode.IsExterior | Should -BeFalse
        }

        It 'counts exterior and interior nodes' {
            $script:Graph.Summary.ExteriorNodes | Should -BeGreaterThan 0
            $script:Graph.Summary.InteriorNodes | Should -BeGreaterThan 0
        }
    }

    Context 'Empty input handling' {
        It 'returns a valid summary with all properties' {
            $Graph = Get-LocationGraph -Entities @() -Sessions @() -Quiet
            $Graph.Summary | Should -Not -BeNullOrEmpty
            $Graph.Summary.PSObject.Properties['NodeCount'] | Should -Not -BeNullOrEmpty
            $Graph.Summary.PSObject.Properties['EdgeCount'] | Should -Not -BeNullOrEmpty
        }

        It 'node count matches nodes array length' {
            $Graph = Get-LocationGraph -Entities @() -Sessions @() -Quiet
            $Graph.Summary.NodeCount | Should -Be $Graph.Nodes.Count
        }
    }

    Context 'MapTraversalGraph parameter' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-deep-locations.md')
            # Simulate a MapTraversalGraph with projected LocationEdges
            $script:MockTraversal = [PSCustomObject]@{
                LocationEdges = @(
                    [PSCustomObject]@{
                        Source        = 'Królestwo Erathii'
                        Target        = 'Miasto Steadwick'
                        Weight        = 3
                        FirstSeenDate = '2024-01-01'
                        LastSeenDate  = '2024-06-01'
                    }
                )
                MapEdges        = @()
                Segments        = @()
                UnresolvedNames = @()
                TotalSegments   = 0
                ResolvedCount   = 0
                UnresolvedCount = 0
            }
            $script:Graph = Get-LocationGraph -Entities $script:Entities -Sessions @() `
                -IncludeMovementEdges -MapTraversalGraph $script:MockTraversal -Quiet
        }

        It 'creates movement or teleport edges from MapTraversalGraph LocationEdges' {
            $MovTeleEdges = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -or $_.Type -eq 'Teleport'
            }
            $MovTeleEdges | Should -Not -BeNullOrEmpty
        }

        It 'uses MapTraversal as data source' {
            $MovTeleEdges = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -or $_.Type -eq 'Teleport'
            }
            $MovTeleEdges[0].Sources | Should -Contain 'MapTraversal'
        }

        It 'counts movement or teleport edges in summary' {
            ($script:Graph.Summary.MovementEdges + $script:Graph.Summary.TeleportEdges) | Should -BeGreaterThan 0
        }
    }

    Context 'Summary structure' {
        BeforeAll {
            $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-koordynaty.md')
            $script:Graph = Get-LocationGraph -Entities $script:Entities -Sessions @() -Quiet
        }

        It 'has all expected summary properties' {
            $S = $script:Graph.Summary
            $S.PSObject.Properties['NodeCount'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['EdgeCount'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['ContainmentEdges'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['DoorEdges'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['RouteEdges'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['MovementEdges'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['InferredEdges'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['ResolvedNodes'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['UnresolvedNodes'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['ExteriorNodes'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['InteriorNodes'] | Should -Not -BeNullOrEmpty
            $S.PSObject.Properties['PossiblyStaleEdges'] | Should -Not -BeNullOrEmpty
        }
    }
}

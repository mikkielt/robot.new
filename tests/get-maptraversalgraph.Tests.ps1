<#
    .SYNOPSIS
    Pester tests for Get-MapTraversalGraph.

    .DESCRIPTION
    Tests the map traversal graph builder: resolution stages (exact, alias,
    suffix strip, word drop, unresolved), edge building, Lokacja projection,
    self-transition filtering, and edge weight accumulation.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'location-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'get-maptraversalgraph.ps1')

    # Load entities from the map traversal fixture
    $script:MapTraversalEntities = Get-Entity -Path (Join-Path $script:FixturesRoot 'map-traversal-logs.md')
}

Describe 'Get-MapTraversalGraph' {
    Context 'Exact resolution' {
        BeforeAll {
            # Session with raw names matching Mapa entity names exactly
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-01-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'resolves exact map names' {
            $Exact = $script:Result.Segments | Where-Object { $_.Stage -eq 'Exact' }
            $Exact.Count | Should -Be 2
        }

        It 'produces a MapEdge between resolved maps' {
            $script:Result.MapEdges.Count | Should -Be 1
            $Edge = $script:Result.MapEdges[0]
            $Edge.Source | Should -Be 'Steadwick'
            $Edge.Target | Should -Be 'Gryfów'
            $Edge.Weight | Should -Be 1
        }

        It 'projects to LocationEdge between parent Lokacje' {
            $script:Result.LocationEdges.Count | Should -Be 1
            $LocEdge = $script:Result.LocationEdges[0]
            $LocEdge.Source | Should -Be 'Miasto Steadwick'
            $LocEdge.Target | Should -Be 'Twierdza Gryfów'
        }
    }

    Context 'Alias resolution' {
        BeforeAll {
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-02-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick City' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'resolves alias to the primary map name' {
            $Alias = $script:Result.Segments | Where-Object { $_.Raw -eq 'Steadwick City' }
            $Alias | Should -Not -BeNullOrEmpty
            $Alias.Resolved | Should -Be 'Steadwick'
            $Alias.Stage | Should -Be 'Exact'
        }
    }

    Context 'Suffix strip resolution' {
        BeforeAll {
            # "Steadwick p.2 - sala 1" is an entity itself, but "Gryfów p.3 - sala 1" is not.
            # After suffix stripping "Gryfów p.3 - sala 1" → "Gryfów" → resolves
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-03-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Gryfów p.3 - sala 1' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'resolves via suffix stripping' {
            $Seg = $script:Result.Segments | Where-Object { $_.Raw -eq 'Gryfów p.3 - sala 1' }
            $Seg | Should -Not -BeNullOrEmpty
            $Seg.Resolved | Should -Be 'Gryfów'
            $Seg.Stage | Should -Be 'SuffixStrip'
            $Seg.StrippedName | Should -Be 'Gryfów'
        }
    }

    Context 'Word drop resolution' {
        BeforeAll {
            # "Steadwick wielki bazar" → after suffix strip still "Steadwick wielki bazar" (no suffix)
            # Word drop: "Steadwick wielki" → no match, "Steadwick" → match
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-04-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick wielki bazar' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'resolves via progressive word drop' {
            $Seg = $script:Result.Segments | Where-Object { $_.Raw -eq 'Steadwick wielki bazar' }
            $Seg | Should -Not -BeNullOrEmpty
            $Seg.Resolved | Should -Be 'Steadwick'
            $Seg.Stage | Should -Be 'WordDrop'
        }
    }

    Context 'Unresolved names' {
        BeforeAll {
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-05-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'NieistniejącaMapa' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'records unresolved names' {
            $script:Result.UnresolvedNames | Should -Contain 'NieistniejącaMapa'
            $script:Result.UnresolvedCount | Should -Be 1
        }

        It 'marks segment as Unresolved stage' {
            $Seg = $script:Result.Segments | Where-Object { $_.Raw -eq 'NieistniejącaMapa' }
            $Seg.Stage | Should -Be 'Unresolved'
            $Seg.Resolved | Should -BeNullOrEmpty
        }
    }

    Context 'Self-transition skip' {
        BeforeAll {
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-06-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'does not produce self-transition MapEdge' {
            $SelfEdge = $script:Result.MapEdges | Where-Object {
                $_.Source -eq 'Steadwick' -and $_.Target -eq 'Steadwick'
            }
            $SelfEdge | Should -BeNullOrEmpty
        }

        It 'produces edge from last occurrence to next distinct map' {
            $script:Result.MapEdges.Count | Should -Be 1
            $script:Result.MapEdges[0].Source | Should -Be 'Steadwick'
            $script:Result.MapEdges[0].Target | Should -Be 'Gryfów'
        }
    }

    Context 'Lokacja projection collapses same-parent maps' {
        BeforeAll {
            # Both Steadwick and "Steadwick p.2 - sala 1" belong to Miasto Steadwick
            # Transition between them should not produce a LocationEdge (same parent)
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-07-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Steadwick p.2 - sala 1' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'produces a MapEdge between sub-maps' {
            $script:Result.MapEdges.Count | Should -Be 1
        }

        It 'does not produce a LocationEdge (same parent Lokacja)' {
            $script:Result.LocationEdges.Count | Should -Be 0
        }
    }

    Context 'Cross-Lokacja projection' {
        BeforeAll {
            # Steadwick (Miasto Steadwick) → Darkshire (Zamek Darkshire)
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-08-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Darkshire' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'produces LocationEdge between different parent Lokacje' {
            $script:Result.LocationEdges.Count | Should -Be 1
            $LocEdge = $script:Result.LocationEdges[0]
            $LocEdge.Source | Should -Be 'Miasto Steadwick'
            $LocEdge.Target | Should -Be 'Zamek Darkshire'
        }
    }

    Context 'Edge weight accumulation' {
        BeforeAll {
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-01-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Gryfów' },
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                },
                [PSCustomObject]@{
                    SessionDate = '2024-09-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'accumulates weight for repeated transitions' {
            $Edge = $script:Result.MapEdges | Where-Object {
                $_.Source -eq 'Steadwick' -and $_.Target -eq 'Gryfów'
            }
            $Edge | Should -Not -BeNullOrEmpty
            $Edge.Weight | Should -Be 3
        }

        It 'tracks first and last seen dates' {
            $Edge = $script:Result.MapEdges | Where-Object {
                $_.Source -eq 'Steadwick' -and $_.Target -eq 'Gryfów'
            }
            $Edge.FirstSeenDate | Should -Be '2024-01-01'
            $Edge.LastSeenDate | Should -Be '2024-09-01'
        }
    }

    Context 'Summary counts' {
        BeforeAll {
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-10-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'NieistniejącaMapa' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'reports correct total segment count' {
            $script:Result.TotalSegments | Should -Be 3
        }

        It 'reports correct resolved count' {
            $script:Result.ResolvedCount | Should -Be 2
        }

        It 'reports correct unresolved count' {
            $script:Result.UnresolvedCount | Should -Be 1
        }
    }

    Context 'Unresolved segment breaks consecutive chain' {
        BeforeAll {
            # Steadwick → [unresolved] → Gryfów: no edge because chain is broken
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = '2024-11-01'
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'NieistniejącaMapa' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'does not produce edge across unresolved gap' {
            $script:Result.MapEdges.Count | Should -Be 0
        }
    }

    Context 'DateTime SessionDate handling' {
        BeforeAll {
            $script:SessionLog = @(
                [PSCustomObject]@{
                    SessionDate = [datetime]::new(2024, 12, 25)
                    Logs = @(
                        [PSCustomObject]@{
                            LocationSegments = @(
                                [PSCustomObject]@{ Raw = 'Steadwick' },
                                [PSCustomObject]@{ Raw = 'Gryfów' }
                            )
                        }
                    )
                }
            )
            $script:Result = Get-MapTraversalGraph -SessionLog $script:SessionLog -Entities $script:MapTraversalEntities -Quiet
        }

        It 'converts datetime SessionDate to string' {
            $script:Result.MapEdges[0].FirstSeenDate | Should -Be '2024-12-25'
        }
    }

    Context 'Empty input' {
        It 'handles empty session log' {
            $Result = Get-MapTraversalGraph -SessionLog @(
                [PSCustomObject]@{
                    SessionDate = '2024-01-01'
                    Logs = @()
                }
            ) -Entities $script:MapTraversalEntities -Quiet
            $Result.TotalSegments | Should -Be 0
            $Result.MapEdges.Count | Should -Be 0
        }

        It 'handles session with no LocationSegments' {
            $Result = Get-MapTraversalGraph -SessionLog @(
                [PSCustomObject]@{
                    SessionDate = '2024-01-01'
                    Logs = @(
                        [PSCustomObject]@{ LocationSegments = $null }
                    )
                }
            ) -Entities $script:MapTraversalEntities -Quiet
            $Result.TotalSegments | Should -Be 0
        }
    }
}

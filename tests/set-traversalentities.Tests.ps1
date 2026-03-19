<#
    .SYNOPSIS
    Pester tests for Set-TraversalEntities.

    .DESCRIPTION
    Tests @drzwi candidate discovery from Teleport edges, bidirectional insertion,
    existing-door skip, containment exclusion, weight threshold, ReportOnly, WhatIf,
    Mapa suggestions, delta mode, and empty input handling.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'location-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'entity-writehelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'entity-findhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-sessionlog.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'location' 'set-traversalentities.ps1')

    # Load entities from fixture
    $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'map-traversal-logs.md')

    # Shared mock sessions (minimal — Set-TraversalEntities just passes them through)
    $script:MockSessions = @([PSCustomObject]@{ Date = [datetime]'2024-01-01'; Title = 'Test' })

    # Helper: build a Graph edge PSCustomObject
    function New-MockEdge {
        param(
            [string]$Source, [string]$Target, [string]$Type,
            [int]$Weight = 1, [datetime]$FirstSeen, [datetime]$LastSeen,
            [bool]$PossiblyStale = $false
        )
        if (-not $FirstSeen) { $FirstSeen = [datetime]'2024-01-01' }
        if (-not $LastSeen) { $LastSeen = $FirstSeen }
        return [PSCustomObject]@{
            Source        = $Source
            Target        = $Target
            Type          = $Type
            Weight        = $Weight
            Sources       = [System.Collections.Generic.List[string]]::new([string[]]@('MapTraversal'))
            FirstSeen     = $FirstSeen
            LastSeen      = $LastSeen
            PossiblyStale = $PossiblyStale
            StaleReason   = $null
        }
    }

    # Helper: build a MapTraversal result with optional unresolved segments
    function New-MockMapTraversal {
        param(
            [object[]]$Segments = @(),
            [string[]]$UnresolvedNames = @()
        )
        return [PSCustomObject]@{
            MapEdges        = @()
            LocationEdges   = @()
            Segments        = $Segments
            UnresolvedNames = $UnresolvedNames
            TotalSegments   = $Segments.Count
            ResolvedCount   = @($Segments | Where-Object { $_.Stage -ne 'Unresolved' }).Count
            UnresolvedCount = @($Segments | Where-Object { $_.Stage -eq 'Unresolved' }).Count
        }
    }

    # Helper: build a Graph result
    function New-MockGraph {
        param([object[]]$Edges = @())
        return [PSCustomObject]@{
            Edges   = $Edges
            Nodes   = @()
            Summary = [PSCustomObject]@{
                NodeCount = 0
                EdgeCount = $Edges.Count
            }
        }
    }
}

Describe 'Set-TraversalEntities' {

    BeforeEach {
        # Default mocks — override per-context as needed
        Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
        Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
        Mock Get-LocationGraph { return (New-MockGraph) }
        Mock Set-SessionGraphStale {}
        Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }
    }

    Context '@drzwi discovery from Teleport edges' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    # Structural edges
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Miasto Steadwick' -Type 'Containment')
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Twierdza Gryfów' -Type 'Containment')
                    (New-MockEdge -Source 'Cesarstwo Krewlodu' -Target 'Zamek Darkshire' -Type 'Containment')
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Cesarstwo Krewlodu' -Type 'Door')
                    (New-MockEdge -Source 'Cesarstwo Krewlodu' -Target 'Królestwo Erathii' -Type 'Door')
                    # Teleport edge — structurally disconnected pair
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 5 `
                        -FirstSeen ([datetime]'2024-01-01') -LastSeen ([datetime]'2024-06-01'))
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        It 'discovers candidates from Teleport edges' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }

        It 'candidate has correct source and target' {
            $C = $script:Result.DoorCandidates[0]
            # Canonical order: alphabetical
            $C.Source | Should -Be 'Miasto Steadwick'
            $C.Target | Should -Be 'Zamek Darkshire'
        }

        It 'candidate preserves weight and dates' {
            $C = $script:Result.DoorCandidates[0]
            $C.Weight | Should -Be 5
            $C.FirstSeen | Should -Be ([datetime]'2024-01-01')
            $C.LastSeen | Should -Be ([datetime]'2024-06-01')
        }
    }

    Context 'Bidirectional insertion' {
        BeforeAll {
            $script:TempDir = New-TestTempDir
            $script:TempFile = Copy-FixtureToTemp -FixtureName 'map-traversal-logs.md' -DestName 'entities.md'

            $script:TempEntities = Get-Entity -Path $script:TempFile

            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Miasto Steadwick' -Type 'Containment')
                    (New-MockEdge -Source 'Cesarstwo Krewlodu' -Target 'Zamek Darkshire' -Type 'Containment')
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 4 `
                        -FirstSeen ([datetime]'2024-03-01'))
                ))
            }
            $script:StaleCallCount = 0
            Mock Set-SessionGraphStale { $script:StaleCallCount++ }
            Mock Get-AdminConfig { return @{ ResDir = $script:TempDir; EntitiesFile = $script:TempFile } }

            $script:Result = Set-TraversalEntities -Entities $script:TempEntities `
                -Sessions $script:MockSessions -Quiet
        }

        AfterAll {
            Remove-TestTempDir
        }

        It 'applies the candidate pair' {
            $script:Result.DoorsApplied.Count | Should -Be 1
        }

        It 'writes A→B @drzwi tag' {
            $Content = [System.IO.File]::ReadAllText($script:TempFile)
            $Content | Should -Match '@drzwi: Zamek Darkshire'
        }

        It 'writes B→A @drzwi tag' {
            $Content = [System.IO.File]::ReadAllText($script:TempFile)
            $Content | Should -Match '@drzwi: Miasto Steadwick'
        }

        It 'includes temporal annotation' {
            $Content = [System.IO.File]::ReadAllText($script:TempFile)
            $Content | Should -Match '@drzwi: Zamek Darkshire \(2024-03:\)'
        }

        It 'invalidates graph cache after writes' {
            $script:StaleCallCount | Should -BeGreaterThan 0
        }
    }

    Context 'Existing door skip' {
        BeforeAll {
            $script:TempDir = New-TestTempDir
            $script:TempFile = Copy-FixtureToTemp -FixtureName 'map-traversal-logs.md' -DestName 'entities.md'
            $script:TempEntities = Get-Entity -Path $script:TempFile

            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            # Inject Teleport edge for pair that has existing @drzwi in entity
            # (Królestwo Erathii has @drzwi: Cesarstwo Krewlodu in fixture)
            # No Door edge in mock — tests belt-and-suspenders entity-level check
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Cesarstwo Krewlodu' -Type 'Teleport' -Weight 5)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:TempDir; EntitiesFile = $script:TempFile } }

            $script:OrigContent = [System.IO.File]::ReadAllText($script:TempFile)
            $script:Result = Set-TraversalEntities -Entities $script:TempEntities `
                -Sessions $script:MockSessions -Quiet
        }

        AfterAll {
            Remove-TestTempDir
        }

        It 'candidate is discovered' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }

        It 'pair is in DoorsSkipped' {
            $script:Result.DoorsSkipped.Count | Should -Be 1
            $script:Result.DoorsSkipped[0].Source | Should -Be 'Cesarstwo Krewlodu'
        }

        It 'pair is NOT in DoorsApplied' {
            $script:Result.DoorsApplied.Count | Should -Be 0
        }

        It 'file is not modified' {
            $NewContent = [System.IO.File]::ReadAllText($script:TempFile)
            $NewContent | Should -Be $script:OrigContent
        }
    }

    Context 'Containment pair exclusion' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            # Teleport edge between parent/child — should be excluded by containment filter
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Miasto Steadwick' -Type 'Containment')
                    (New-MockEdge -Source 'Królestwo Erathii' -Target 'Miasto Steadwick' -Type 'Teleport' -Weight 10)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        It 'containment pairs are excluded from candidates' {
            $script:Result.DoorCandidates.Count | Should -Be 0
        }
    }

    Context 'Weight threshold' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    # Weight 2 — below default MinDoorWeight of 3
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 2)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -MinDoorWeight 3 -ReportOnly -Quiet
        }

        It 'candidates below MinDoorWeight are excluded' {
            $script:Result.DoorCandidates.Count | Should -Be 0
        }
    }

    Context 'Weight threshold with custom MinDoorWeight' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 2)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -ReportOnly -MinDoorWeight 1 -Quiet
        }

        It 'candidates at or above custom threshold are included' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }
    }

    Context 'ReportOnly mode' {
        BeforeAll {
            $script:TempDir = New-TestTempDir
            $script:TempFile = Copy-FixtureToTemp -FixtureName 'map-traversal-logs.md' -DestName 'entities.md'
            $script:TempEntities = Get-Entity -Path $script:TempFile

            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 5)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:TempDir; EntitiesFile = $script:TempFile } }

            $script:OrigContent = [System.IO.File]::ReadAllText($script:TempFile)
            $script:Result = Set-TraversalEntities -Entities $script:TempEntities `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        AfterAll {
            Remove-TestTempDir
        }

        It 'DoorCandidates is populated' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }

        It 'DoorsApplied is empty' {
            $script:Result.DoorsApplied.Count | Should -Be 0
        }

        It 'file is not modified' {
            $NewContent = [System.IO.File]::ReadAllText($script:TempFile)
            $NewContent | Should -Be $script:OrigContent
        }

        It 'Set-SessionGraphStale is not called' {
            Should -Invoke Set-SessionGraphStale -Times 0 -Exactly
        }
    }

    Context 'WhatIf mode' {
        BeforeAll {
            $script:TempDir = New-TestTempDir
            $script:TempFile = Copy-FixtureToTemp -FixtureName 'map-traversal-logs.md' -DestName 'entities.md'
            $script:TempEntities = Get-Entity -Path $script:TempFile

            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 5)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:TempDir; EntitiesFile = $script:TempFile } }

            $script:OrigContent = [System.IO.File]::ReadAllText($script:TempFile)
            $script:Result = Set-TraversalEntities -Entities $script:TempEntities `
                -Sessions $script:MockSessions -WhatIf -Quiet
        }

        AfterAll {
            Remove-TestTempDir
        }

        It 'DoorCandidates is populated' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }

        It 'file is not modified' {
            $NewContent = [System.IO.File]::ReadAllText($script:TempFile)
            $NewContent | Should -Be $script:OrigContent
        }
    }

    Context 'Mapa suggestions' {
        BeforeAll {
            # Build segments: 6 unresolved with same base name, plus resolved neighbors
            $script:UnresolvedSegs = @()
            for ($i = 0; $i -lt 6; $i++) {
                $script:UnresolvedSegs += [PSCustomObject]@{
                    Raw            = 'Nieznana Jaskinia'
                    Resolved       = $null
                    Stage          = 'Unresolved'
                    StrippedName   = $null
                    ParentLocation = $null
                    SessionIndex   = 0
                }
            }
            # Add resolved neighbors for parent inference
            $ResolvedBefore = [PSCustomObject]@{
                Raw            = 'Steadwick'
                Resolved       = 'Steadwick'
                Stage          = 'Exact'
                StrippedName   = $null
                ParentLocation = 'Miasto Steadwick'
                SessionIndex   = 0
            }
            $AllSegments = @($ResolvedBefore) + $script:UnresolvedSegs

            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph {
                return (New-MockMapTraversal -Segments $AllSegments -UnresolvedNames @('Nieznana Jaskinia'))
            }
            Mock Get-LocationGraph { return (New-MockGraph) }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -SkipDoors -Quiet
        }

        It 'produces Mapa suggestions' {
            $script:Result.MapSuggestions.Count | Should -Be 1
        }

        It 'suggestion has correct base name' {
            $script:Result.MapSuggestions[0].BaseName | Should -Be 'Nieznana Jaskinia'
        }

        It 'suggestion has correct count' {
            $script:Result.MapSuggestions[0].Count | Should -Be 6
        }

        It 'suggestion infers parent from nearest resolved segment' {
            $script:Result.MapSuggestions[0].InferredParent | Should -Be 'Miasto Steadwick'
        }
    }

    Context 'Mapa suggestions below threshold' {
        BeforeAll {
            $FewSegments = @()
            for ($i = 0; $i -lt 3; $i++) {
                $FewSegments += [PSCustomObject]@{
                    Raw = 'Rzadka Mapa'; Resolved = $null; Stage = 'Unresolved'
                    StrippedName = $null; ParentLocation = $null; SessionIndex = 0
                }
            }

            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph {
                return (New-MockMapTraversal -Segments $FewSegments -UnresolvedNames @('Rzadka Mapa'))
            }
            Mock Get-LocationGraph { return (New-MockGraph) }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -SkipDoors -Quiet
        }

        It 'excludes suggestions below MinMapWeight' {
            $script:Result.MapSuggestions.Count | Should -Be 0
        }
    }

    Context 'Delta mode' {
        BeforeAll {
            $script:CapturedMinDate = $null
            Mock Get-Session {
                $script:CapturedMinDate = $MinDate
                return @([PSCustomObject]@{ Date = [datetime]'2024-06-01'; Title = 'Recent' })
            }
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-06-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph { return (New-MockGraph) }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -MinDate ([datetime]'2024-05-01') -ReportOnly -Quiet
        }

        It 'passes MinDate to Get-Session' {
            $script:CapturedMinDate | Should -Be ([datetime]'2024-05-01')
        }

        It 'returns valid result' {
            $script:Result | Should -Not -BeNullOrEmpty
            $script:Result.DoorCandidates.Count | Should -Be 0
            $script:Result.TraversalSummary | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Empty input — no sessions' {
        BeforeAll {
            Mock Get-Session { return @() }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities -Quiet
        }

        It 'returns valid empty result' {
            $script:Result | Should -Not -BeNullOrEmpty
            $script:Result.DoorCandidates.Count | Should -Be 0
            $script:Result.DoorsApplied.Count | Should -Be 0
            $script:Result.DoorsSkipped.Count | Should -Be 0
            $script:Result.MapSuggestions.Count | Should -Be 0
        }

        It 'TraversalSummary has zero counts' {
            $script:Result.TraversalSummary.TotalSegments | Should -Be 0
        }
    }

    Context 'Empty input — no entities' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'X' -Target 'Y' -Type 'Teleport' -Weight 5)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            # Empty entities — Teleport edges reference unknown entities
            $script:Result = Set-TraversalEntities -Entities @() `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        It 'returns valid empty candidates (entities not found)' {
            $script:Result.DoorCandidates.Count | Should -Be 0
        }
    }

    Context 'SkipDoors flag' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 5)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -SkipDoors -Quiet
        }

        It 'skips door discovery entirely' {
            $script:Result.DoorCandidates.Count | Should -Be 0
        }
    }

    Context 'Weight aggregation across duplicate edges' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    # Two edges for the same pair (A→B and B→A), weight 2 each
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 2 `
                        -FirstSeen ([datetime]'2024-01-01') -LastSeen ([datetime]'2024-03-01'))
                    (New-MockEdge -Source 'Zamek Darkshire' -Target 'Miasto Steadwick' -Type 'Teleport' -Weight 2 `
                        -FirstSeen ([datetime]'2024-02-01') -LastSeen ([datetime]'2024-06-01'))
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        It 'merges bidirectional edges into one candidate' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }

        It 'aggregates weight' {
            $script:Result.DoorCandidates[0].Weight | Should -Be 4
        }

        It 'takes earliest FirstSeen' {
            $script:Result.DoorCandidates[0].FirstSeen | Should -Be ([datetime]'2024-01-01')
        }

        It 'takes latest LastSeen' {
            $script:Result.DoorCandidates[0].LastSeen | Should -Be ([datetime]'2024-06-01')
        }
    }

    Context 'Bootstrap — no structural edges auto-lowers MinDoorWeight' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                # No Containment or Door edges — pure bootstrap
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 1)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        It 'detects bootstrap mode' {
            $script:Result.TraversalSummary.IsBootstrap | Should -BeTrue
        }

        It 'auto-lowers EffectiveMinDoorWeight to 1' {
            $script:Result.TraversalSummary.EffectiveMinDoorWeight | Should -Be 1
        }

        It 'discovers candidates with Weight=1 in bootstrap mode' {
            $script:Result.DoorCandidates.Count | Should -Be 1
        }
    }

    Context 'Bootstrap — explicit MinDoorWeight overrides auto-lower' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 2)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -MinDoorWeight 5 -ReportOnly -Quiet
        }

        It 'respects explicit MinDoorWeight even in bootstrap' {
            $script:Result.TraversalSummary.EffectiveMinDoorWeight | Should -Be 5
        }

        It 'excludes candidates below explicit threshold' {
            $script:Result.DoorCandidates.Count | Should -Be 0
        }
    }

    Context 'Non-bootstrap — structural edges present' {
        BeforeAll {
            Mock Get-SessionLog { return @([PSCustomObject]@{ SessionDate = '2024-01-01'; Logs = @() }) }
            Mock Get-MapTraversalGraph { return (New-MockMapTraversal) }
            Mock Get-LocationGraph {
                return (New-MockGraph -Edges @(
                    # One structural edge makes this non-bootstrap
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Containment' -Weight 1)
                    (New-MockEdge -Source 'Miasto Steadwick' -Target 'Zamek Darkshire' -Type 'Teleport' -Weight 2)
                ))
            }
            Mock Set-SessionGraphStale {}
            Mock Get-AdminConfig { return @{ ResDir = $script:FixturesRoot } }

            $script:Result = Set-TraversalEntities -Entities $script:Entities `
                -Sessions $script:MockSessions -ReportOnly -Quiet
        }

        It 'is not bootstrap' {
            $script:Result.TraversalSummary.IsBootstrap | Should -BeFalse
        }

        It 'uses default MinDoorWeight=3' {
            $script:Result.TraversalSummary.EffectiveMinDoorWeight | Should -Be 3
        }

        It 'excludes Weight=2 with default threshold' {
            $script:Result.DoorCandidates.Count | Should -Be 0
        }
    }
}

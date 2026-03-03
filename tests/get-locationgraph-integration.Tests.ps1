<#
    .SYNOPSIS
    Comprehensive tests for the location graph pipeline:
    log parsing → LocationSegments → TransitionEdges → Get-LocationGraph.

    .DESCRIPTION
    Validates the full pipeline from raw session logs through to the unified
    location graph, including:
    - Location segment extraction from ChatLog and Prose fixtures
    - Floor/room variant resolution (maps.md naming: "p.1", "- sala 2")
    - Transition edge generation with self-transition skip
    - Slash-path resolution ("AvLee/Twierdza Elfów" → "Twierdza Elfów")
    - Get-LocationGraph integration with -IncludeMovementEdges
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    . (Join-Path $script:ModuleRoot 'private' 'parse-logcontent.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'string-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'location-helpers.ps1')

    # ---- Entities fixture ----
    $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-location-graph.md')
    $script:NameIdx  = Get-NameIndex -Entities $script:Entities -Players @()
    $script:Cache    = @{}

    # ---- Parse all three log fixtures ----
    $RouteContent   = [System.IO.File]::ReadAllText((Join-Path $script:FixturesRoot 'log-chatlog-route.txt'))
    $DungeonContent = [System.IO.File]::ReadAllText((Join-Path $script:FixturesRoot 'log-prose-dungeon.txt'))
    $AvLeeContent   = [System.IO.File]::ReadAllText((Join-Path $script:FixturesRoot 'log-chatlog-avlee.txt'))

    $script:ParsedRoute   = ConvertFrom-ChatLogContent -Content $RouteContent
    $script:ParsedDungeon = ConvertFrom-ProseContent   -Content $DungeonContent
    $script:ParsedAvLee   = ConvertFrom-ChatLogContent -Content $AvLeeContent

    # ---- Sessions fixture ----
    $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-location-graph.md') `
        -Entities $script:Entities -Players @()

    # ---- Helper: build mock SessionLog entry ----
    function New-MockSessionLog {
        param([string]$Url, [object]$Parsed)
        return [PSCustomObject]@{
            Logs = @(
                [PSCustomObject]@{
                    Url              = $Url
                    Format           = $Parsed.Format
                    Lines            = $Parsed.Lines
                    LocationSegments = $Parsed.LocationSegments
                    Speakers         = @()
                    Channels         = @()
                }
            )
        }
    }
}

# ====================================================================
# 1. Location Segment Extraction
# ====================================================================
Describe 'LocationSegment extraction from log fixtures' {

    Context 'ChatLog route fixture (linear overland travel)' {
        It 'extracts 5 location segments' {
            $script:ParsedRoute.LocationSegments.Count | Should -Be 5
        }

        It 'identifies correct location names in order' {
            $Names = $script:ParsedRoute.LocationSegments | ForEach-Object { $_.Raw }
            $Names[0] | Should -Be 'Steadwick'
            $Names[1] | Should -Be 'Koszary Steadwicku'
            $Names[2] | Should -Be 'Droga przez Erathię'
            $Names[3] | Should -Be 'Przełęcz Behemotów'
            $Names[4] | Should -Be 'AvLee'
        }

        It 'detects ChatLog format' {
            $script:ParsedRoute.Format | Should -Be 'ChatLog'
        }
    }

    Context 'Prose dungeon fixture (multi-floor with revisits)' {
        It 'extracts 7 location segments including revisits' {
            $script:ParsedDungeon.LocationSegments.Count | Should -Be 7
        }

        It 'identifies floor variants matching maps.md naming' {
            $Names = $script:ParsedDungeon.LocationSegments | ForEach-Object { $_.Raw }
            $Names[0] | Should -Be 'Piekielna Grota p.1'
            $Names[1] | Should -Be 'Piekielna Grota p.2'
            $Names[2] | Should -Be 'Piekielna Grota p.3 - sala 1'
            $Names[3] | Should -Be 'Piekielna Grota p.3 - sala 2'
            $Names[4] | Should -Be 'Piekielna Grota p.3 - sala 1'
            $Names[5] | Should -Be 'Piekielna Grota p.2'
            $Names[6] | Should -Be 'Piekielna Grota p.1'
        }

        It 'detects Prose format' {
            $script:ParsedDungeon.Format | Should -Be 'Prose'
        }
    }

    Context 'ChatLog AvLee fixture (multi-floor fortress + self-repeat + teleport)' {
        It 'extracts 7 location segments' {
            $script:ParsedAvLee.LocationSegments.Count | Should -Be 7
        }

        It 'identifies location names including floor variants and teleport target' {
            $Names = $script:ParsedAvLee.LocationSegments | ForEach-Object { $_.Raw }
            $Names[0] | Should -Be 'AvLee'
            $Names[1] | Should -Be 'Twierdza Elfów p.1'
            $Names[2] | Should -Be 'Twierdza Elfów p.2'
            $Names[3] | Should -Be 'Twierdza Elfów p.1'
            $Names[4] | Should -Be 'AvLee'
            $Names[5] | Should -Be 'AvLee'
            $Names[6] | Should -Be 'Piekielna Grota'
        }

        It 'captures the self-repeat of AvLee before teleport' {
            $Segs = $script:ParsedAvLee.LocationSegments
            $Segs[4].Raw | Should -Be 'AvLee'
            $Segs[5].Raw | Should -Be 'AvLee'
        }
    }
}

# ====================================================================
# 2. Name Resolution for Map Location Variants
# ====================================================================
Describe 'Name resolution of maps.md floor/room variants' {

    Context 'short floor suffixes ("p.N") resolve to base entity via fuzzy' {
        It 'resolves "Piekielna Grota p.1" to "Piekielna Grota"' {
            $R = Resolve-Name -Query 'Piekielna Grota p.1' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Piekielna Grota'
        }

        It 'resolves "Piekielna Grota p.2" to "Piekielna Grota"' {
            $R = Resolve-Name -Query 'Piekielna Grota p.2' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Piekielna Grota'
        }

        It 'resolves "Twierdza Elfów p.1" to "Twierdza Elfów"' {
            $R = Resolve-Name -Query 'Twierdza Elfów p.1' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Twierdza Elfów'
        }

        It 'resolves "Twierdza Elfów p.2" to "Twierdza Elfów"' {
            $R = Resolve-Name -Query 'Twierdza Elfów p.2' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Twierdza Elfów'
        }
    }

    Context 'long floor+room suffixes ("p.N - sala N") exceed fuzzy threshold' {
        It '"Piekielna Grota p.3 - sala 1" does NOT resolve (too distant)' {
            $R = Resolve-Name -Query 'Piekielna Grota p.3 - sala 1' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -BeNullOrEmpty
        }

        It '"Piekielna Grota p.3 - sala 2" does NOT resolve (too distant)' {
            $R = Resolve-Name -Query 'Piekielna Grota p.3 - sala 2' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -BeNullOrEmpty
        }
    }

    Context 'exact entity names resolve directly' {
        It 'resolves "Steadwick" exactly' {
            $R = Resolve-Name -Query 'Steadwick' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Steadwick'
        }

        It 'resolves "Koszary Steadwicku" exactly' {
            $R = Resolve-Name -Query 'Koszary Steadwicku' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Koszary Steadwicku'
        }

        It 'resolves "Piekielna Grota" exactly' {
            $R = Resolve-Name -Query 'Piekielna Grota' `
                -Index $script:NameIdx.Index `
                -StemIndex $script:NameIdx.StemIndex `
                -BKTree $script:NameIdx.BKTree `
                -Cache $script:Cache
            $R | Should -Not -BeNullOrEmpty
            $R.Name | Should -Be 'Piekielna Grota'
        }
    }
}

# ====================================================================
# 2b. Get-MapBaseName suffix stripping
# ====================================================================
Describe 'Get-MapBaseName suffix stripping' {

    Context 'floor suffixes (p.N)' {
        It 'strips "p.1" from "Piekielna Grota p.1"' {
            $R = Get-MapBaseName -Name 'Piekielna Grota p.1'
            $R | Should -Contain 'Piekielna Grota'
        }

        It 'strips "p.2" from "Twierdza Elfów p.2"' {
            $R = Get-MapBaseName -Name 'Twierdza Elfów p.2'
            $R | Should -Contain 'Twierdza Elfów'
        }
    }

    Context 'floor + room suffixes (p.N - sala N, p.N s.N)' {
        It 'strips "p.3 - sala 1" from "Piekielna Grota p.3 - sala 1"' {
            $R = Get-MapBaseName -Name 'Piekielna Grota p.3 - sala 1'
            $R | Should -Contain 'Piekielna Grota'
        }

        It 'strips "p.1 s.2" from "Krypty Bezsennych p.1 s.2"' {
            $R = Get-MapBaseName -Name 'Krypty Bezsennych p.1 s.2'
            $R | Should -Contain 'Krypty Bezsennych'
        }
    }

    Context 'floor + named room (p.N - Sala [Name])' {
        It 'strips "p.2 - Sala Magicznego Błota"' {
            $R = Get-MapBaseName -Name 'Zabłocona Jama p.2 - Sala Magicznego Błota'
            $R | Should -Contain 'Zabłocona Jama'
        }
    }

    Context 'floor + direction (p.N - północ/południe)' {
        It 'strips "p.1 - północ"' {
            $R = Get-MapBaseName -Name 'Erem Czarnego Słońca p.1 - północ'
            $R | Should -Contain 'Erem Czarnego Słońca'
        }
    }

    Context 'standalone room (s.N)' {
        It 'strips "s.2" from "Grota Arbor s.2"' {
            $R = Get-MapBaseName -Name 'Grota Arbor s.2'
            $R | Should -Contain 'Grota Arbor'
        }
    }

    Context 'directional/type suffixes after dash' {
        It 'strips "- wschód"' {
            $R = Get-MapBaseName -Name 'Komnaty Czarnej Gwardii - wschód'
            $R | Should -Contain 'Komnaty Czarnej Gwardii'
        }

        It 'strips "- piętro"' {
            $R = Get-MapBaseName -Name 'Dom Roana - piętro'
            $R | Should -Contain 'Dom Roana'
        }

        It 'strips "- przedsionek"' {
            $R = Get-MapBaseName -Name 'Nawiedzone Komnaty - przedsionek'
            $R | Should -Contain 'Nawiedzone Komnaty'
        }

        It 'strips "- skarbiec"' {
            $R = Get-MapBaseName -Name 'Bandyckie Chowisko - skarbiec'
            $R | Should -Contain 'Bandyckie Chowisko'
        }
    }

    Context 'difficulty level (poziom:)' {
        It 'strips "(poziom: trudny)"' {
            $R = Get-MapBaseName -Name 'Lezysko Baraniego Kanoniera (poziom: trudny)'
            $R | Should -Contain 'Lezysko Baraniego Kanoniera'
        }
    }

    Context 'no stripping needed' {
        It 'returns empty for base names like "Steadwick"' {
            $R = Get-MapBaseName -Name 'Steadwick'
            $R.Count | Should -Be 0
        }

        It 'returns empty for base names like "AvLee"' {
            $R = Get-MapBaseName -Name 'AvLee'
            $R.Count | Should -Be 0
        }
    }

    Context 'complex multi-level stripping' {
        It 'strips floor from tower variant, leaving tower name' {
            $R = Get-MapBaseName -Name 'Klasztor Różanitów - wieża płn.-wsch. p.1'
            $R | Should -Contain 'Klasztor Różanitów - wieża płn.-wsch.'
        }

        It 'strips floor + descriptor' {
            $R = Get-MapBaseName -Name 'Mrówcza Kolonia p.3 - lewa komora jaj'
            $R | Should -Contain 'Mrówcza Kolonia'
        }
    }
}
Describe 'Get-NamedLogLocationReport transition edges' {

    Context 'Route fixture (linear travel, all locations resolve)' {
        BeforeAll {
            $script:RouteLog = New-MockSessionLog -Url 'https://example.com/raw/route-log' -Parsed $script:ParsedRoute
            $script:RouteSession = $script:Sessions | Where-Object { $_.Title -eq 'Wyprawa przez Erathię' }
            $script:RouteReport = Get-NamedLogLocationReport `
                -SessionLog $script:RouteLog `
                -Session $script:RouteSession `
                -Index $script:NameIdx `
                -Cache $script:Cache
        }

        It 'resolves 5 of 5 locations' {
            $Entry = @($script:RouteReport)[0]
            $Entry.Summary.Total | Should -Be 5
            $Entry.Summary.Resolved | Should -Be 5
        }

        It 'generates 4 transitions (linear chain)' {
            $Entry = @($script:RouteReport)[0]
            $Entry.Transitions.Count | Should -Be 4
        }

        It 'first transition is Steadwick → Koszary Steadwicku' {
            $Entry = @($script:RouteReport)[0]
            $Entry.Transitions[0].Source | Should -Be 'Steadwick'
            $Entry.Transitions[0].Target | Should -Be 'Koszary Steadwicku'
        }

        It 'last transition is Przełęcz Behemotów → AvLee' {
            $Entry = @($script:RouteReport)[0]
            $Entry.Transitions[-1].Source | Should -Be 'Przełęcz Behemotów'
            $Entry.Transitions[-1].Target | Should -Be 'AvLee'
        }

        It 'marks Steadwick as InSessionMeta (listed in @Lokacje)' {
            $Entry = @($script:RouteReport)[0]
            $SteadwickLoc = $Entry.Locations | Where-Object { $_.Raw -eq 'Steadwick' }
            $SteadwickLoc.InSessionMeta | Should -Be $true
        }

        It 'marks Koszary Steadwicku as NOT InSessionMeta (intermediate)' {
            $Entry = @($script:RouteReport)[0]
            $KoszaryLoc = $Entry.Locations | Where-Object { $_.Raw -eq 'Koszary Steadwicku' }
            $KoszaryLoc.InSessionMeta | Should -Be $false
        }

        It 'all transitions carry LogUrl and SessionTitle' {
            $Entry = @($script:RouteReport)[0]
            foreach ($T in $Entry.Transitions) {
                $T.LogUrl | Should -Be 'https://example.com/raw/route-log'
                $T.SessionTitle | Should -Be 'Wyprawa przez Erathię'
            }
        }
    }

    Context 'Dungeon fixture (floor variants, resolved self-transitions skipped)' {
        BeforeAll {
            $script:DungeonLog = New-MockSessionLog -Url 'https://example.com/raw/dungeon-log' -Parsed $script:ParsedDungeon
            $script:DungeonSession = $script:Sessions | Where-Object { $_.Title -eq 'Podziemia Piekielnej Groty' }
            $script:DungeonReport = Get-NamedLogLocationReport `
                -SessionLog $script:DungeonLog `
                -Session $script:DungeonSession `
                -Index $script:NameIdx `
                -Cache $script:Cache
        }

        It 'reports 7 total location segments' {
            $Entry = @($script:DungeonReport)[0]
            $Entry.Summary.Total | Should -Be 7
        }

        It 'resolves all 7 segments via direct match or map-suffix stripping' {
            $Entry = @($script:DungeonReport)[0]
            $Resolved = $Entry.Locations | Where-Object { $null -ne $_.Resolved }
            $Resolved.Count | Should -Be 7
        }

        It 'skips all transitions (all floors resolve to same entity)' {
            # All 7 segments resolve to "Piekielna Grota" → all self-transitions → 0 edges
            $Entry = @($script:DungeonReport)[0]
            $Entry.Transitions.Count | Should -Be 0
        }

        It 'no transition has Source equal to Target' {
            $Entry = @($script:DungeonReport)[0]
            foreach ($T in $Entry.Transitions) {
                $T.Source | Should -Not -Be $T.Target
            }
        }

        It 'marks Piekielna Grota as InSessionMeta (exact entity in @Lokacje)' {
            $Entry = @($script:DungeonReport)[0]
            # p.1 resolves to "Piekielna Grota" which is in session @Lokacje
            $P1 = $Entry.Locations | Where-Object { $_.Raw -eq 'Piekielna Grota p.1' } | Select-Object -First 1
            $P1.InSessionMeta | Should -Be $true
        }
    }

    Context 'AvLee fixture (multi-floor fortress + self-repeat skip)' {
        BeforeAll {
            $script:AvLeeLog = New-MockSessionLog -Url 'https://example.com/raw/avlee-log' -Parsed $script:ParsedAvLee
            $script:AvLeeSession = $script:Sessions | Where-Object { $_.Title -eq 'Patrol leśny' }
            $script:AvLeeReport = Get-NamedLogLocationReport `
                -SessionLog $script:AvLeeLog `
                -Session $script:AvLeeSession `
                -Index $script:NameIdx `
                -Cache $script:Cache
        }

        It 'reports 7 total location segments' {
            $Entry = @($script:AvLeeReport)[0]
            $Entry.Summary.Total | Should -Be 7
        }

        It 'resolves all 7 segments (all within fuzzy range)' {
            $Entry = @($script:AvLeeReport)[0]
            $Entry.Summary.Resolved | Should -Be 7
        }

        It 'generates exactly 3 transitions (self-repeats and floor-changes skipped)' {
            # Sequence (resolved): AvLee, Twierdza Elfów, Twierdza Elfów, Twierdza Elfów, AvLee, AvLee, Piekielna Grota
            # AvLee → Twierdza Elfów → EDGE
            # Twierdza Elfów → Twierdza Elfów → skip (self, floors resolve same)
            # Twierdza Elfów → Twierdza Elfów → skip (self)
            # Twierdza Elfów → AvLee → EDGE
            # AvLee → AvLee → skip (self-repeat)
            # AvLee → Piekielna Grota → EDGE (teleport)
            $Entry = @($script:AvLeeReport)[0]
            $Entry.Transitions.Count | Should -Be 3
        }

        It 'transitions include AvLee↔Twierdza Elfów and AvLee→Piekielna Grota' {
            $Entry = @($script:AvLeeReport)[0]
            $Entry.Transitions[0].Source | Should -Be 'AvLee'
            $Entry.Transitions[0].Target | Should -Be 'Twierdza Elfów'
            $Entry.Transitions[1].Source | Should -Be 'Twierdza Elfów'
            $Entry.Transitions[1].Target | Should -Be 'AvLee'
            $Entry.Transitions[2].Source | Should -Be 'AvLee'
            $Entry.Transitions[2].Target | Should -Be 'Piekielna Grota'
        }

        It 'slash-path "AvLee/Twierdza Elfów" marks Twierdza Elfów as InSessionMeta' {
            $Entry = @($script:AvLeeReport)[0]
            # Session has @Lokacje: AvLee, AvLee/Twierdza Elfów
            # The slash-path leaf "Twierdza Elfów" should match resolved name
            $FortressLoc = $Entry.Locations | Where-Object { $_.Resolved -eq 'Twierdza Elfów' } | Select-Object -First 1
            $FortressLoc.InSessionMeta | Should -Be $true
        }

        It 'AvLee self-repeat is visible in segments but not in transitions' {
            $Entry = @($script:AvLeeReport)[0]
            $AvLeeSegments = $Entry.Locations | Where-Object { $_.Resolved -eq 'AvLee' }
            $AvLeeSegments.Count | Should -Be 3
            # But no self-transition for AvLee→AvLee
            $SelfTrans = $Entry.Transitions | Where-Object { $_.Source -eq 'AvLee' -and $_.Target -eq 'AvLee' }
            $SelfTrans | Should -BeNullOrEmpty
        }
    }
}

# ====================================================================
# 4. Get-LocationGraph Integration with Movement Edges
# ====================================================================
Describe 'Get-LocationGraph with movement edges from session logs' {

    BeforeAll {
        # Build combined SessionLog array for all 3 logs
        $RouteLog   = New-MockSessionLog -Url 'https://example.com/raw/route-log'   -Parsed $script:ParsedRoute
        $DungeonLog = New-MockSessionLog -Url 'https://example.com/raw/dungeon-log' -Parsed $script:ParsedDungeon
        $AvLeeLog   = New-MockSessionLog -Url 'https://example.com/raw/avlee-log'   -Parsed $script:ParsedAvLee

        # Get transition reports for all 3 sessions
        $AllSessions = $script:Sessions
        $AllLogReports = @()

        $RouteSession   = $AllSessions | Where-Object { $_.Title -eq 'Wyprawa przez Erathię' }
        $DungeonSession = $AllSessions | Where-Object { $_.Title -eq 'Podziemia Piekielnej Groty' }
        $AvLeeSession   = $AllSessions | Where-Object { $_.Title -eq 'Patrol leśny' }

        $RR = Get-NamedLogLocationReport -SessionLog $RouteLog   -Session $RouteSession   -Index $script:NameIdx -Cache $script:Cache
        $DR = Get-NamedLogLocationReport -SessionLog $DungeonLog -Session $DungeonSession -Index $script:NameIdx -Cache $script:Cache
        $AR = Get-NamedLogLocationReport -SessionLog $AvLeeLog   -Session $AvLeeSession   -Index $script:NameIdx -Cache $script:Cache

        $AllLogReports = @($RR) + @($DR) + @($AR)

        $script:Graph = Get-LocationGraph `
            -Entities $script:Entities `
            -Sessions $AllSessions `
            -SessionLog $AllLogReports `
            -IncludeMovementEdges `
            -Quiet
    }

    Context 'Graph structure' {
        It 'returns Nodes, Edges, and Summary' {
            $script:Graph.PSObject.Properties['Nodes'] | Should -Not -BeNullOrEmpty
            $script:Graph.PSObject.Properties['Edges'] | Should -Not -BeNullOrEmpty
            $script:Graph.PSObject.Properties['Summary'] | Should -Not -BeNullOrEmpty
        }

        It 'has at least the entity-based nodes' {
            $script:Graph.Summary.NodeCount | Should -BeGreaterOrEqual 5
        }

        It 'has at least the entity-based edges (containment + door)' {
            $script:Graph.Summary.EdgeCount | Should -BeGreaterOrEqual 5
        }
    }

    Context 'Containment edges from entity @lokacja' {
        It 'creates containment edges for child locations' {
            $ContainmentEdges = $script:Graph.Edges | Where-Object { $_.Type -eq 'Containment' }
            $ContainmentEdges.Count | Should -BeGreaterOrEqual 3
        }

        It 'includes Steadwick→Koszary Steadwicku containment' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Containment' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Koszary Steadwicku'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'includes Steadwick→Ratusz Steadwicku containment' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Containment' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Ratusz Steadwicku'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'includes AvLee→Twierdza Elfów containment' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Containment' -and $_.Source -eq 'AvLee' -and $_.Target -eq 'Twierdza Elfów'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Door edges from entity @drzwi' {
        It 'creates door edges' {
            $DoorEdges = $script:Graph.Edges | Where-Object { $_.Type -eq 'Door' }
            $DoorEdges.Count | Should -BeGreaterOrEqual 1
        }

        It 'includes Steadwick→Ratusz Steadwicku door' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Door' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Ratusz Steadwicku'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'includes Steadwick→Koszary Steadwicku door' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Door' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Koszary Steadwicku'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Movement edges from session logs' {
        It 'summary reports movement edge count > 0' {
            $script:Graph.Summary.MovementEdges | Should -BeGreaterThan 0
        }

        It 'creates Movement-type edges' {
            $MovEdges = $script:Graph.Edges | Where-Object { $_.Type -eq 'Movement' }
            $MovEdges.Count | Should -BeGreaterThan 0
        }

        It 'includes Steadwick→Koszary Steadwicku movement from route log' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Koszary Steadwicku'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'includes Przełęcz Behemotów→AvLee movement' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'Przełęcz Behemotów' -and $_.Target -eq 'AvLee'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'includes AvLee→Twierdza Elfów movement from avlee log' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'AvLee' -and $_.Target -eq 'Twierdza Elfów'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'includes Twierdza Elfów→AvLee movement (return trip)' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'Twierdza Elfów' -and $_.Target -eq 'AvLee'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'does NOT contain self-loop Movement or Teleport edges' {
            $SelfLoops = $script:Graph.Edges | Where-Object {
                ($_.Type -eq 'Movement' -or $_.Type -eq 'Teleport') -and $_.Source -eq $_.Target
            }
            $SelfLoops | Should -BeNullOrEmpty
        }
    }

    Context 'Teleport detection (non-adjacent transitions)' {
        It 'classifies AvLee→Piekielna Grota as Teleport (no structural path)' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Teleport' -and $_.Source -eq 'AvLee' -and $_.Target -eq 'Piekielna Grota'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'does NOT classify AvLee→Piekielna Grota as Movement' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'AvLee' -and $_.Target -eq 'Piekielna Grota'
            }
            $Edge | Should -BeNullOrEmpty
        }

        It 'classifies walkable transitions as Movement (Steadwick→Koszary via containment)' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Koszary Steadwicku'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'classifies sibling transition as Movement (Koszary→Droga via shared neighbor Steadwick)' {
            # Koszary Steadwicku (@lokacja: Steadwick) and Droga przez Erathię (@drzwi: Steadwick)
            # share neighbor Steadwick → distance ≤ 2 → Movement
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'Koszary Steadwicku' -and $_.Target -eq 'Droga przez Erathię'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'classifies door-connected transition as Movement (Droga→Przełęcz via @drzwi)' {
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'Droga przez Erathię' -and $_.Target -eq 'Przełęcz Behemotów'
            }
            $Edge | Should -Not -BeNullOrEmpty
        }

        It 'summary TeleportEdges count > 0' {
            $script:Graph.Summary.TeleportEdges | Should -BeGreaterThan 0
        }

        It 'TeleportEdges count matches actual Teleport-type edges' {
            $ActualTeleport = @($script:Graph.Edges | Where-Object { $_.Type -eq 'Teleport' }).Count
            $script:Graph.Summary.TeleportEdges | Should -Be $ActualTeleport
        }
    }

    Context 'Map-stripped dungeon rooms resolve via suffix stripping' {
        It 'movement edges use resolved entity name, not raw map name' {
            # All "Piekielna Grota p.3 - sala N" now resolve to "Piekielna Grota"
            # so no edge contains the raw sala names — all become self-transitions (skipped)
            $SalaEdge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and
                ($_.Source -match 'sala' -or $_.Target -match 'sala')
            }
            $SalaEdge | Should -BeNullOrEmpty
        }

        It '"Piekielna Grota p.3 - sala 1" resolves to "Piekielna Grota" via MapStrip' {
            $DungeonLog = New-MockSessionLog -Url 'https://example.com/raw/dungeon-log' -Parsed $script:ParsedDungeon
            $DungeonSession = $script:Sessions | Where-Object { $_.Title -eq 'Podziemia Piekielnej Groty' }
            $DR = Get-NamedLogLocationReport -SessionLog $DungeonLog -Session $DungeonSession -Index $script:NameIdx -Cache @{}
            $Sala = @($DR)[0].Locations | Where-Object { $_.Raw -eq 'Piekielna Grota p.3 - sala 1' } | Select-Object -First 1
            $Sala.Resolved | Should -Be 'Piekielna Grota'
            $Sala.Stage | Should -Be 'MapStrip'
            # StrippedName records the candidate that resolved (may be intermediate, not fully stripped)
            $Sala.StrippedName | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Node properties' {
        It 'Steadwick node has coordinates' {
            $Node = $script:Graph.Nodes | Where-Object { $_.Name -eq 'Steadwick' }
            $Node | Should -Not -BeNullOrEmpty
            $Node.Coordinates | Should -Not -BeNullOrEmpty
            $Node.IsExterior | Should -Be $true
        }

        It 'AvLee node has coordinates' {
            $Node = $script:Graph.Nodes | Where-Object { $_.Name -eq 'AvLee' }
            $Node | Should -Not -BeNullOrEmpty
            $Node.Coordinates | Should -Not -BeNullOrEmpty
            $Node.IsExterior | Should -Be $true
        }

        It 'Koszary Steadwicku node has no coordinates (interior)' {
            $Node = $script:Graph.Nodes | Where-Object { $_.Name -eq 'Koszary Steadwicku' }
            $Node | Should -Not -BeNullOrEmpty
            $Node.IsExterior | Should -Be $false
        }

        It 'map-stripped nodes resolve to their base entity' {
            # "Piekielna Grota p.3 - sala 1" would have been unresolved before stripping
            # Now it resolves to "Piekielna Grota" entity — no unresolved sala nodes in graph
            $SalaNode = $script:Graph.Nodes | Where-Object { $_.Name -match 'sala' }
            $SalaNode | Should -BeNullOrEmpty
        }

        It 'resolved nodes have EntityMatch' {
            $Node = $script:Graph.Nodes | Where-Object { $_.Name -eq 'Steadwick' }
            $Node.EntityMatch | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Edge weight accumulation' {
        It 'movement edge weight increases with duplicate transitions across sessions' {
            # AvLee→Twierdza Elfów appears in avlee log
            # but could potentially appear in multiple logs if data supported it
            $Edge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Movement' -and $_.Source -eq 'AvLee' -and $_.Target -eq 'Twierdza Elfów'
            }
            $Edge.Weight | Should -BeGreaterOrEqual 1
        }

        It 'containment edges have weight 1 (static, no accumulation)' {
            $ContEdge = $script:Graph.Edges | Where-Object {
                $_.Type -eq 'Containment' -and $_.Source -eq 'Steadwick' -and $_.Target -eq 'Koszary Steadwicku'
            }
            $ContEdge.Weight | Should -Be 1
        }
    }

    Context 'Summary counts' {
        It 'MovementEdges count matches actual Movement-type edges' {
            $ActualMovement = ($script:Graph.Edges | Where-Object { $_.Type -eq 'Movement' }).Count
            $script:Graph.Summary.MovementEdges | Should -Be $ActualMovement
        }

        It 'ContainmentEdges count matches actual Containment-type edges' {
            $ActualCont = ($script:Graph.Edges | Where-Object { $_.Type -eq 'Containment' }).Count
            $script:Graph.Summary.ContainmentEdges | Should -Be $ActualCont
        }

        It 'DoorEdges count matches actual Door-type edges' {
            $ActualDoor = ($script:Graph.Edges | Where-Object { $_.Type -eq 'Door' }).Count
            $script:Graph.Summary.DoorEdges | Should -Be $ActualDoor
        }

        It 'NodeCount matches Nodes array length' {
            $script:Graph.Summary.NodeCount | Should -Be $script:Graph.Nodes.Count
        }

        It 'EdgeCount matches Edges array length' {
            $script:Graph.Summary.EdgeCount | Should -Be $script:Graph.Edges.Count
        }
    }
}

# ====================================================================
# 5. Get-LocationGraph WITHOUT movement edges (default)
# ====================================================================
Describe 'Get-LocationGraph without -IncludeMovementEdges' {
    BeforeAll {
        $script:GraphNoMovement = Get-LocationGraph `
            -Entities $script:Entities `
            -Sessions $script:Sessions `
            -Quiet
    }

    It 'reports 0 movement edges' {
        $script:GraphNoMovement.Summary.MovementEdges | Should -Be 0
    }

    It 'reports 0 teleport edges' {
        $script:GraphNoMovement.Summary.TeleportEdges | Should -Be 0
    }

    It 'still has containment and door edges' {
        $script:GraphNoMovement.Summary.ContainmentEdges | Should -BeGreaterThan 0
        $script:GraphNoMovement.Summary.DoorEdges | Should -BeGreaterThan 0
    }

    It 'has fewer total edges than graph with movement' {
        $script:GraphNoMovement.Summary.EdgeCount | Should -BeLessThan $script:Graph.Summary.EdgeCount
    }
}

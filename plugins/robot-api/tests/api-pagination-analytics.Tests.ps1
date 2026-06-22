BeforeAll {
    . "$PSScriptRoot/PluginTestHelpers.ps1"
    Import-RobotModuleForPlugin
    . "$PSScriptRoot/../private/api-handlers-read.ps1"
    . "$PSScriptRoot/../private/api-handlers-analytics.ps1"
}

# ═══════════════════════════════════════════════════════════════════════
# WP-1: ApiQueryParser generic methods
# ═══════════════════════════════════════════════════════════════════════

Describe 'Robot.ApiQueryParser generic methods (WP-1)' {
    Context 'GetObjectField' {
        It 'reads property from PSCustomObject' {
            $O = [PSCustomObject]@{ Name = 'Alpha'; Type = 'NPC' }
            [Robot.ApiQueryParser]::GetObjectField($O, 'Name') | Should -Be 'Alpha'
            [Robot.ApiQueryParser]::GetObjectField($O, 'Type') | Should -Be 'NPC'
        }

        It 'is case-insensitive for field names' {
            $O = [PSCustomObject]@{ Name = 'Alpha' }
            [Robot.ApiQueryParser]::GetObjectField($O, 'NAME') | Should -Be 'Alpha'
            [Robot.ApiQueryParser]::GetObjectField($O, 'name') | Should -Be 'Alpha'
        }

        It 'returns null for missing field' {
            $O = [PSCustomObject]@{ Name = 'Alpha' }
            [Robot.ApiQueryParser]::GetObjectField($O, 'NonExistent') | Should -BeNullOrEmpty
        }

        It 'reads from hashtable' {
            $H = @{ Owner = 'Player1'; Status = 'Aktywny' }
            [Robot.ApiQueryParser]::GetObjectField($H, 'Owner') | Should -Be 'Player1'
        }

        It 'handles null object' {
            [Robot.ApiQueryParser]::GetObjectField($null, 'Name') | Should -BeNullOrEmpty
        }
    }

    Context 'FilterList' {
        It 'filters PSCustomObject list by simple equality' {
            $Items = [System.Collections.Generic.List[object]]::new()
            $Items.Add([PSCustomObject]@{ Name = 'A'; Type = 'NPC' })
            $Items.Add([PSCustomObject]@{ Name = 'B'; Type = 'Lokacja' })
            $Items.Add([PSCustomObject]@{ Name = 'C'; Type = 'NPC' })
            $Groups = [Robot.ApiQueryParser]::ParseFilter('Type==NPC')
            $Result = [Robot.ApiQueryParser]::FilterList($Items, $Groups, $null)
            $Result.Count | Should -Be 2
        }

        It 'returns full list when groups are empty' {
            $Items = [System.Collections.Generic.List[object]]::new()
            $Items.Add([PSCustomObject]@{ Name = 'A' })
            $Items.Add([PSCustomObject]@{ Name = 'B' })
            $Result = [Robot.ApiQueryParser]::FilterList(
                $Items, [System.Collections.Generic.List[Robot.FilterGroup]]::new(), $null)
            $Result.Count | Should -Be 2
        }
    }

    Context 'SortList' {
        It 'sorts ascending by name' {
            $Items = [System.Collections.Generic.List[object]]::new()
            $Items.Add([PSCustomObject]@{ Name = 'Charlie' })
            $Items.Add([PSCustomObject]@{ Name = 'Alpha' })
            $Items.Add([PSCustomObject]@{ Name = 'Bravo' })
            $Sort = [Robot.ApiQueryParser]::ParseSort('Name')
            [Robot.ApiQueryParser]::SortList($Items, $Sort, $null)
            $Items[0].Name | Should -Be 'Alpha'
            $Items[2].Name | Should -Be 'Charlie'
        }

        It 'sorts descending with - prefix' {
            $Items = [System.Collections.Generic.List[object]]::new()
            $Items.Add([PSCustomObject]@{ Name = 'Alpha' })
            $Items.Add([PSCustomObject]@{ Name = 'Bravo' })
            $Sort = [Robot.ApiQueryParser]::ParseSort('-Name')
            [Robot.ApiQueryParser]::SortList($Items, $Sort, $null)
            $Items[0].Name | Should -Be 'Bravo'
        }
    }

    Context 'PaginateList' {
        It 'returns first page with hasMore flag' {
            $Items = [System.Collections.Generic.List[object]]::new()
            1..10 | ForEach-Object {
                $Items.Add([PSCustomObject]@{ Name = "Item$($_.ToString('D2'))" })
            }
            $Page = [Robot.PageParams]::new()
            $Page.Size = 3
            $Result = [Robot.ApiQueryParser]::PaginateList($Items, $Page, $null, 'Name')
            $Result.Items.Count | Should -Be 3
            $Result.TotalCount | Should -Be 10
            $Result.HasMore | Should -Be $true
            $Result.NextCursor | Should -Not -BeNullOrEmpty
        }

        It 'returns empty page with HasMore=false at end' {
            $Items = [System.Collections.Generic.List[object]]::new()
            1..3 | ForEach-Object {
                $Items.Add([PSCustomObject]@{ Name = "Item$_" })
            }
            $Page = [Robot.PageParams]::new()
            $Page.Size = 5
            $Result = [Robot.ApiQueryParser]::PaginateList($Items, $Page, $null, 'Name')
            $Result.Items.Count | Should -Be 3
            $Result.HasMore | Should -Be $false
            $Result.NextCursor | Should -BeNullOrEmpty
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# WP-2: Invoke-ApiObjectListQuery helper
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiObjectListQuery (WP-2)' {
    Context 'Basic envelope' {
        It 'returns full envelope with count/pageSize/hasMore/nextCursor/items' {
            $Items = 1..10 | ForEach-Object {
                [PSCustomObject]@{ Name = "Item$($_.ToString('D2'))"; Value = $_ }
            }
            $Ctx = @{ QueryParams = @{} }
            $Result = Invoke-ApiObjectListQuery -ApiContext $Ctx -Items $Items
            $Result.StatusCode | Should -Be 200
            $Result.Body.count | Should -Be 10
            $Result.Body.pageSize | Should -Be 50
            $Result.Body.hasMore | Should -Be $false
            $Result.Body.items.Count | Should -Be 10
        }

        It 'honors page[size]' {
            $Items = 1..20 | ForEach-Object {
                [PSCustomObject]@{ Name = "Item$($_.ToString('D2'))" }
            }
            $Ctx = @{ QueryParams = @{ 'page[size]' = '5' } }
            $Result = Invoke-ApiObjectListQuery -ApiContext $Ctx -Items $Items
            $Result.Body.items.Count | Should -Be 5
            $Result.Body.count | Should -Be 20
            $Result.Body.hasMore | Should -Be $true
        }

        It 'honors sort=-Name' {
            $Items = @(
                [PSCustomObject]@{ Name = 'Alpha' }
                [PSCustomObject]@{ Name = 'Charlie' }
                [PSCustomObject]@{ Name = 'Bravo' }
            )
            $Ctx = @{ QueryParams = @{ sort = '-Name' } }
            $Result = Invoke-ApiObjectListQuery -ApiContext $Ctx -Items $Items
            $Result.Body.items[0].Name | Should -Be 'Charlie'
        }

        It 'honors fields= sparse projection' {
            $Items = @(
                [PSCustomObject]@{ Name = 'A'; Type = 'NPC'; Status = 'Aktywny' }
            )
            $Ctx = @{ QueryParams = @{ fields = 'Name,Type' } }
            $Result = Invoke-ApiObjectListQuery -ApiContext $Ctx -Items $Items
            $First = $Result.Body.items[0]
            $First.PSObject.Properties.Name | Should -Contain 'Name'
            $First.PSObject.Properties.Name | Should -Contain 'Type'
            $First.PSObject.Properties.Name | Should -Not -Contain 'Status'
        }

        It 'returns empty envelope for empty input' {
            $Ctx = @{ QueryParams = @{} }
            $Result = Invoke-ApiObjectListQuery -ApiContext $Ctx -Items @()
            $Result.Body.count | Should -Be 0
            $Result.Body.items.Count | Should -Be 0
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# WP-3 + WP-4: Invoke-ApiGetSessions array normalization
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiGetSessions array normalization (WP-3)' {
    Context 'Array field shapes' {
        BeforeEach {
            # Mock Get-Session to return synthetic data with PowerShell-unwrapped
            # array fields (single-element bare object, empty dict).
            Mock Get-Session {
                @(
                    [PSCustomObject]@{
                        Header    = '### 2025-06-01, Test, Anward'
                        Date      = [datetime]'2025-06-01'
                        Title     = 'Test'
                        Narrator  = $null
                        Format    = 'Gen4'
                        # Single-element PU as bare object (PowerShell unwrap)
                        PU        = [PSCustomObject]@{ Character = 'Solo'; Value = 0.5 }
                        # Empty Locations as empty hashtable
                        Locations = @{}
                        # Normal array
                        Logs      = @('https://example.com/1')
                        # Null Changes
                        Changes   = $null
                    }
                )
            } -ParameterFilter { $true }
        }

        It 'wraps single-element PU in an array' {
            $Ctx = @{ QueryParams = @{} }
            $Result = Invoke-ApiGetSessions -ApiContext $Ctx
            $Result.StatusCode | Should -Be 200
            $S = $Result.Body.items[0]
            $S.PU.GetType().Name | Should -Match '(Object\[\]|List`1)'
            $S.PU.Count | Should -Be 1
            $S.PU[0].Character | Should -Be 'Solo'
        }

        It 'converts empty Locations dict to empty array' {
            $Ctx = @{ QueryParams = @{} }
            $Result = Invoke-ApiGetSessions -ApiContext $Ctx
            $S = $Result.Body.items[0]
            $S.Locations.GetType().Name | Should -Match '(Object\[\]|List`1)'
            $S.Locations.Count | Should -Be 0
        }

        It 'converts null Changes to empty array' {
            $Ctx = @{ QueryParams = @{} }
            $Result = Invoke-ApiGetSessions -ApiContext $Ctx
            $S = $Result.Body.items[0]
            $S.Changes.GetType().Name | Should -Match '(Object\[\]|List`1)'
            $S.Changes.Count | Should -Be 0
        }
    }

    Context 'Pagination' {
        BeforeEach {
            Mock Get-Session {
                # Build 50 sessions across 2 months (max 28 per month) to avoid invalid dates
                $Out = @()
                for ($D = 1; $D -le 25; $D++) {
                    $Out += [PSCustomObject]@{
                        Header   = "### 2025-01-$($D.ToString('D2')), S1_$D, Anward"
                        Date     = [datetime]"2025-01-$($D.ToString('D2'))"
                        Title    = "S1_$D"
                        Narrator = $null
                        Format   = 'Gen4'
                        PU       = @()
                        Locations = @()
                    }
                }
                for ($D = 1; $D -le 25; $D++) {
                    $Out += [PSCustomObject]@{
                        Header   = "### 2025-02-$($D.ToString('D2')), S2_$D, Anward"
                        Date     = [datetime]"2025-02-$($D.ToString('D2'))"
                        Title    = "S2_$D"
                        Narrator = $null
                        Format   = 'Gen4'
                        PU       = @()
                        Locations = @()
                    }
                }
                $Out
            } -ParameterFilter { $true }
        }

        It 'paginates with page[size]=10' {
            $Ctx = @{ QueryParams = @{ 'page[size]' = '10' } }
            $Result = Invoke-ApiGetSessions -ApiContext $Ctx
            $Result.Body.count | Should -Be 50
            $Result.Body.items.Count | Should -Be 10
            $Result.Body.hasMore | Should -Be $true
        }

        It 'supports fields projection' {
            $Ctx = @{ QueryParams = @{ fields = 'Header,Date' } }
            $Result = Invoke-ApiGetSessions -ApiContext $Ctx
            $First = $Result.Body.items[0]
            $First.PSObject.Properties.Name | Should -Contain 'Header'
            $First.PSObject.Properties.Name | Should -Not -Contain 'Title'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Analytics handlers — sampled validation
# ═══════════════════════════════════════════════════════════════════════

Describe 'Invoke-ApiAnalyticsPuByCharacter (WP-6)' {
    BeforeEach {
        Mock Get-Session {
            @(
                [PSCustomObject]@{
                    Header = '### 2025-06-01, S1, Anward'
                    Date = [datetime]'2025-06-01'
                    Narrator = $null
                    PU = @(
                        [PSCustomObject]@{ Character = 'Karendar'; Value = 0.3 }
                        [PSCustomObject]@{ Character = 'Glieve'; Value = 0.5 }
                    )
                    Locations = @('Werbin')
                }
                [PSCustomObject]@{
                    Header = '### 2025-06-15, S2, Anward'
                    Date = [datetime]'2025-06-15'
                    Narrator = $null
                    PU = @(
                        [PSCustomObject]@{ Character = 'Karendar'; Value = 0.5 }
                    )
                    Locations = @('Werbin')
                }
            )
        } -ParameterFilter { $true }
        Mock Resolve-Name { $null }
    }

    It 'returns top characters sorted by totalPU' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-06-01'; maxDate = '2025-06-30'
        } }
        $Result = Invoke-ApiAnalyticsPuByCharacter -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.items.Count | Should -Be 2
        $Result.Body.items[0].character | Should -Be 'Karendar'
        $Result.Body.items[0].totalPU | Should -Be 0.8
        $Result.Body.items[0].sessionCount | Should -Be 2
        $Result.Body.totalPU | Should -Be 1.3
        $Result.Body.puEntryCount | Should -Be 3
    }

    It 'filters by location' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-06-01'; maxDate = '2025-06-30'; location = 'Werbin'
        } }
        $Result = Invoke-ApiAnalyticsPuByCharacter -ApiContext $Ctx
        $Result.Body.items.Count | Should -Be 2
    }

    It 'returns empty items when location filter excludes all' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-06-01'; maxDate = '2025-06-30'; location = 'NoSuchPlace'
        } }
        $Result = Invoke-ApiAnalyticsPuByCharacter -ApiContext $Ctx
        $Result.Body.items.Count | Should -Be 0
        $Result.Body.puEntryCount | Should -Be 0
    }
}

Describe 'Invoke-ApiAnalyticsCoEngagement (WP-8)' {
    BeforeEach {
        Mock Get-Session {
            @(
                [PSCustomObject]@{
                    Header = '### 2025-06-01, S1, Anward'
                    Date = [datetime]'2025-06-01'
                    Narrator = $null
                    PU = @(
                        [PSCustomObject]@{ Character = 'Karendar'; Value = 0.3 }
                        [PSCustomObject]@{ Character = 'Glieve'; Value = 0.5 }
                    )
                    Locations = @('Werbin')
                }
                [PSCustomObject]@{
                    Header = '### 2025-06-02, S2, Anward'
                    Date = [datetime]'2025-06-02'
                    Narrator = $null
                    PU = @(
                        [PSCustomObject]@{ Character = 'Karendar'; Value = 0.3 }
                        [PSCustomObject]@{ Character = 'Glieve'; Value = 0.3 }
                    )
                    Locations = @('Werbin')
                }
            )
        } -ParameterFilter { $true }
    }

    It 'returns paired character co-occurrences' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-06-01'; maxDate = '2025-06-30'; minSessions = '1'
        } }
        $Result = Invoke-ApiAnalyticsCoEngagement -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.items.Count | Should -Be 1
        $Result.Body.items[0].sessions | Should -Be 2
    }
}

Describe 'Invoke-ApiAnalyticsPuByNarrator (WP-11)' {
    BeforeEach {
        $N1 = [PSCustomObject]@{ Narrators = @([PSCustomObject]@{ Name = 'Anward' }) }
        Mock Get-Session {
            @(
                [PSCustomObject]@{
                    Header = '### 2025-06-01, S1, Anward'
                    Date = [datetime]'2025-06-01'
                    Narrator = $N1
                    PU = @([PSCustomObject]@{ Character = 'Karendar'; Value = 0.5 })
                    Locations = @()
                }
            )
        } -ParameterFilter { $true }
    }

    It 'aggregates per narrator' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-06-01'; maxDate = '2025-06-30'
        } }
        $Result = Invoke-ApiAnalyticsPuByNarrator -ApiContext $Ctx
        $Result.Body.items.Count | Should -Be 1
        $Result.Body.items[0].narrator | Should -Be 'Anward'
    }
}

Describe 'Invoke-ApiAnalyticsEntityLifecycle (WP-14)' {
    BeforeEach {
        $Hist = New-Object System.Collections.Generic.List[object]
        $Hist.Add([PSCustomObject]@{ Value = 'Aktywny'; ValidFrom = [datetime]'2025-01-01' })
        $Hist.Add([PSCustomObject]@{ Value = 'Nieaktywny'; ValidFrom = [datetime]'2025-06-15' })
        Mock Get-EntityState {
            @(
                [PSCustomObject]@{
                    Name = 'Solmyr'; Type = 'NPC'; CN = 'NPC/Solmyr'
                    StatusHistory = $Hist
                }
            )
        } -ParameterFilter { $true }
    }

    It 'detects status transition within window' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-01-01'; maxDate = '2025-12-31'
            property = 'status'
        } }
        $Result = Invoke-ApiAnalyticsEntityLifecycle -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.transitionCount | Should -Be 1
        $Result.Body.items[0].entity | Should -Be 'Solmyr'
        $Result.Body.items[0].transitions[0].from | Should -Be 'Aktywny'
        $Result.Body.items[0].transitions[0].to | Should -Be 'Nieaktywny'
    }

    It 'rejects unknown property' {
        $Ctx = @{ QueryParams = @{ property = 'nonexistent' } }
        $Result = Invoke-ApiAnalyticsEntityLifecycle -ApiContext $Ctx
        $Result.StatusCode | Should -Be 400
    }
}

Describe 'Invoke-ApiAnalyticsPuTimeline (WP-10)' {
    BeforeEach {
        Mock Get-Session {
            @(
                [PSCustomObject]@{
                    Header = '### 2025-03-15, S1, Anward'
                    Date = [datetime]'2025-03-15'
                    Narrator = $null
                    PU = @([PSCustomObject]@{ Character = 'A'; Value = 0.5 })
                    Locations = @()
                }
                [PSCustomObject]@{
                    Header = '### 2025-04-10, S2, Anward'
                    Date = [datetime]'2025-04-10'
                    Narrator = $null
                    PU = @([PSCustomObject]@{ Character = 'A'; Value = 0.3 })
                    Locations = @()
                }
            )
        } -ParameterFilter { $true }
    }

    It 'requires minDate and maxDate' {
        $Result = Invoke-ApiAnalyticsPuTimeline -ApiContext @{ QueryParams = @{} }
        $Result.StatusCode | Should -Be 400
    }

    It 'buckets sessions by month' {
        $Ctx = @{ QueryParams = @{
            minDate = '2025-01-01'; maxDate = '2025-12-31'; bucket = 'month'
        } }
        $Result = Invoke-ApiAnalyticsPuTimeline -ApiContext $Ctx
        $Result.StatusCode | Should -Be 200
        $Result.Body.items.Count | Should -Be 2
        $Result.Body.items[0].period | Should -Be '2025-03'
        $Result.Body.items[1].period | Should -Be '2025-04'
    }
}

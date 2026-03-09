<#
    .SYNOPSIS
    Tests for engine components — chrome, menu, table, detail, overlays, wizard step.

    .DESCRIPTION
    Validates component creation, filter pipeline, responsive columns,
    match highlighting, detail value formatting, help search, and
    wizard step input. Uses Pattern C (standalone helper dot-sourcing).

    Tests the data layer only — no rendering is tested.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Dot-source dependencies in order
    . "$script:ModuleRoot/private/cli/cli-primitives.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-engine.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-buffer.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-input.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-chrome.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-menulist.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-table.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-detail.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-overlays.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-wizard-step.ps1"

    $script:ScreenWidth  = 80
    $script:ScreenHeight = 24
    Build-Regions
    Initialize-Buffers
}

Describe 'New-MenuListComponent' {

    It 'creates component with correct type' {
        $Items = @(
            [PSCustomObject]@{ ID = '1'; Label = 'One'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        $C = New-MenuListComponent -Items $Items
        $C.Type | Should -Be 'MenuList'
    }

    It 'populates selectable indices (skips disabled)' {
        $Items = @(
            [PSCustomObject]@{ ID = '1'; Label = 'One'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
            [PSCustomObject]@{ ID = '2'; Label = 'Two'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $true }
            [PSCustomObject]@{ ID = '3'; Label = 'Three'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        $C = New-MenuListComponent -Items $Items
        $C.SelectableIndices.Count | Should -Be 2
        $C.SelectableIndices[0] | Should -Be 0
        $C.SelectableIndices[1] | Should -Be 2
    }

    It 'sets filterable to true' {
        $Items = @(
            [PSCustomObject]@{ ID = '1'; Label = 'One'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        $C = New-MenuListComponent -Items $Items
        $C.Filterable | Should -BeTrue
    }

    It 'stores filter prefixes' {
        $Items = @(
            [PSCustomObject]@{ ID = '1'; Label = 'One'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        $Prefixes = @{ 'npc' = 'NPC'; 'lok' = 'Lokacja' }
        $C = New-MenuListComponent -Items $Items -FilterPrefixes $Prefixes
        $C.FilterPrefixes['npc'] | Should -Be 'NPC'
    }

    It 'initializes SelectedPos to 0' {
        $Items = @(
            [PSCustomObject]@{ ID = '1'; Label = 'One'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        $C = New-MenuListComponent -Items $Items
        $C.SelectedPos | Should -Be 0
    }
}

Describe 'Invoke-MenuFilter' {

    BeforeAll {
        $script:TestItems = @(
            [PSCustomObject]@{ ID = 'sandro'; Label = 'Sandro'; Description = 'NPC'; RoleTag = 'N'; InfoText = $null; Disabled = $false; Type = 'NPC' }
            [PSCustomObject]@{ ID = 'erathia'; Label = 'Erathia'; Description = 'Lokacja'; RoleTag = $null; InfoText = $null; Disabled = $false; Type = 'Lokacja' }
            [PSCustomObject]@{ ID = 'bracada'; Label = 'Bracada'; Description = 'Lokacja'; RoleTag = $null; InfoText = $null; Disabled = $false; Type = 'Lokacja' }
            [PSCustomObject]@{ ID = 'thar'; Label = 'Thar-Khanan'; Description = 'NPC'; RoleTag = 'N'; InfoText = $null; Disabled = $false; Type = 'NPC' }
        )
    }

    It 'filters by prefix match' {
        $C = New-MenuListComponent -Items $script:TestItems
        Invoke-MenuFilter -Component $C -FilterText 'San'
        $C.Items.Count | Should -Be 1
        $C.Items[0].ID | Should -Be 'sandro'
    }

    It 'filters by contains match' {
        $C = New-MenuListComponent -Items $script:TestItems
        Invoke-MenuFilter -Component $C -FilterText 'khan'
        $C.Items.Count | Should -Be 1
        $C.Items[0].ID | Should -Be 'thar'
    }

    It 'returns all items for empty filter' {
        $C = New-MenuListComponent -Items $script:TestItems
        Invoke-MenuFilter -Component $C -FilterText ''
        $C.Items.Count | Should -Be 4
    }

    It 'returns zero items for no match' {
        $C = New-MenuListComponent -Items $script:TestItems
        Invoke-MenuFilter -Component $C -FilterText 'zzzzz'
        $C.Items.Count | Should -Be 0
    }

    It 'resets SelectedPos to 0 after filter' {
        $C = New-MenuListComponent -Items $script:TestItems
        $C.SelectedPos = 2
        Invoke-MenuFilter -Component $C -FilterText 'San'
        $C.SelectedPos | Should -Be 0
    }

    It 'updates FilteredCount' {
        $C = New-MenuListComponent -Items $script:TestItems
        Invoke-MenuFilter -Component $C -FilterText 'a'
        $C.FilteredCount | Should -Be 4  # Sandro, Erathia, Bracada, Thar-Khanan (all contain 'a')
    }

    It 'case-insensitive matching' {
        $C = New-MenuListComponent -Items $script:TestItems
        Invoke-MenuFilter -Component $C -FilterText 'SANDRO'
        $C.Items.Count | Should -Be 1
    }
}

Describe 'New-ResultTableComponent' {

    It 'creates component with correct type' {
        $Data = @([PSCustomObject]@{ Name = 'A'; Type = 'NPC' })
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        $C.Type | Should -Be 'ResultTable'
    }

    It 'initializes SelectedAbs to 0' {
        $Data = @([PSCustomObject]@{ Name = 'A'; Type = 'NPC' })
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        $C.SelectedAbs | Should -Be 0
    }

    It 'uses default widths when not provided' {
        $Data = @([PSCustomObject]@{ Name = 'A'; Type = 'NPC' })
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        $C.Widths.Count | Should -Be 2
        $C.Widths[0] | Should -Be 20
    }

    It 'sets filterable to true' {
        $Data = @([PSCustomObject]@{ Name = 'A'; Type = 'NPC' })
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        $C.Filterable | Should -BeTrue
    }
}

Describe 'Invoke-TableFilter' {

    It 'filters table rows by column content' {
        $Data = @(
            [PSCustomObject]@{ Name = 'Sandro'; Type = 'NPC' }
            [PSCustomObject]@{ Name = 'Erathia'; Type = 'Lokacja' }
            [PSCustomObject]@{ Name = 'Bracada'; Type = 'Lokacja' }
        )
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        Invoke-TableFilter -Component $C -FilterText 'san'
        $C.Data.Count | Should -Be 1
        $C.Data[0].Name | Should -Be 'Sandro'
    }

    It 'matches against any column' {
        $Data = @(
            [PSCustomObject]@{ Name = 'Sandro'; Type = 'NPC' }
            [PSCustomObject]@{ Name = 'Erathia'; Type = 'Lokacja' }
        )
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        Invoke-TableFilter -Component $C -FilterText 'Lok'
        $C.Data.Count | Should -Be 1
        $C.Data[0].Name | Should -Be 'Erathia'
    }

    It 'resets SelectedAbs after filter' {
        $Data = @(
            [PSCustomObject]@{ Name = 'A'; Type = 'NPC' }
            [PSCustomObject]@{ Name = 'B'; Type = 'NPC' }
        )
        $C = New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') -Headers @('Nazwa', 'Typ')
        $C.SelectedAbs = 1
        Invoke-TableFilter -Component $C -FilterText 'A'
        $C.SelectedAbs | Should -Be 0
    }
}

Describe 'Resolve-VisibleColumns' {

    It 'returns all columns when width is sufficient' {
        $Result = Resolve-VisibleColumns -Columns @('Name', 'Type', 'Status') `
            -Headers @('Nazwa', 'Typ', 'Status') `
            -Widths @(20, 10, 10) `
            -ColumnPriority @(1, 2, 3) `
            -AvailableWidth 100
        $Result.Count | Should -Be 3
    }

    It 'hides priority 3 columns first at narrow width' {
        $Result = Resolve-VisibleColumns -Columns @('Name', 'Type', 'Status') `
            -Headers @('Nazwa', 'Typ', 'Status') `
            -Widths @(20, 10, 10) `
            -ColumnPriority @(1, 2, 3) `
            -AvailableWidth 35
        $Result.Count | Should -Be 2
        $Result[0].Column | Should -Be 'Name'
        $Result[1].Column | Should -Be 'Type'
    }

    It 'hides priority 2 and 3 at very narrow width' {
        $Result = Resolve-VisibleColumns -Columns @('Name', 'Type', 'Status') `
            -Headers @('Nazwa', 'Typ', 'Status') `
            -Widths @(20, 10, 10) `
            -ColumnPriority @(1, 2, 3) `
            -AvailableWidth 20
        $Result.Count | Should -Be 1
        $Result[0].Column | Should -Be 'Name'
    }

    It 'treats null priority as priority 1' {
        $Result = Resolve-VisibleColumns -Columns @('Name', 'Type') `
            -Headers @('Nazwa', 'Typ') `
            -Widths @(20, 10) `
            -ColumnPriority $null `
            -AvailableWidth 100
        $Result.Count | Should -Be 2
    }
}

Describe 'New-DetailCardComponent' {

    It 'creates component with correct type' {
        $Data = [PSCustomObject]@{ Name = 'Sandro'; Type = 'NPC' }
        $C = New-DetailCardComponent -Data $Data
        $C.Type | Should -Be 'DetailCard'
    }

    It 'extracts displayable properties' {
        $Data = [PSCustomObject]@{ Name = 'Sandro'; Type = 'NPC'; Status = 'Aktywny' }
        $C = New-DetailCardComponent -Data $Data
        $C.Properties.Count | Should -BeGreaterOrEqual 3
    }

    It 'sets filterable to false' {
        $Data = [PSCustomObject]@{ Name = 'Sandro' }
        $C = New-DetailCardComponent -Data $Data
        $C.Filterable | Should -BeFalse
    }

    It 'initializes ScrollOffset to 0' {
        $Data = [PSCustomObject]@{ Name = 'Sandro' }
        $C = New-DetailCardComponent -Data $Data
        $C.ScrollOffset | Should -Be 0
    }

    It 'skips Path and CN properties' {
        $Data = [PSCustomObject]@{ Name = 'Sandro'; Path = '/some/path'; CN = 'cn-123'; Type = 'NPC' }
        $C = New-DetailCardComponent -Data $Data
        $PropNames = $C.Properties | ForEach-Object { $_.Name }
        $PropNames | Should -Contain 'Name'
        $PropNames | Should -Contain 'Type'
        $PropNames | Should -Not -Contain 'Path'
        $PropNames | Should -Not -Contain 'CN'
    }

    It 'skips PS-prefixed properties' {
        $Data = [PSCustomObject]@{ Name = 'Test' }
        # PSComputerName, PSShowComputerName are PS-prefixed internals
        $Data | Add-Member -NotePropertyName 'PSComputerName' -NotePropertyValue 'localhost'
        $C = New-DetailCardComponent -Data $Data
        $PropNames = $C.Properties | ForEach-Object { $_.Name }
        $PropNames | Should -Contain 'Name'
        $PropNames | Should -Not -Contain 'PSComputerName'
    }
}

Describe 'Format-DetailValue' {

    It 'returns (brak) for null' {
        Format-DetailValue -Value $null | Should -Be '(brak)'
    }

    It 'returns Tak for true' {
        Format-DetailValue -Value $true | Should -Be 'Tak'
    }

    It 'returns Nie for false' {
        Format-DetailValue -Value $false | Should -Be 'Nie'
    }

    It 'formats datetime as yyyy-MM-dd' {
        $D = [datetime]::new(2024, 6, 15)
        Format-DetailValue -Value $D | Should -Be '2024-06-15'
    }

    It 'returns string representation for simple values' {
        Format-DetailValue -Value 42 | Should -Be '42'
        Format-DetailValue -Value 'hello' | Should -Be 'hello'
    }

    It 'returns (brak) for empty array' {
        Format-DetailValue -Value @() | Should -Be '(brak)'
    }

    It 'joins small scalar arrays with comma' {
        $Result = Format-DetailValue -Value @('A', 'B', 'C')
        $Result | Should -Be 'A, B, C'
    }

    It 'returns bullet list for large scalar arrays' {
        $Result = @(Format-DetailValue -Value @('A', 'B', 'C', 'D', 'E'))
        $Result.Count | Should -Be 5
        $Result[0] | Should -BeLike '*A*'
    }

    It 'formats dictionary as nested key-value lines' {
        $Dict = @{ 'status' = 'Aktywny'; 'lokacja' = 'Erathia' }
        $Result = @(Format-DetailValue -Value $Dict)
        $Result.Count | Should -Be 2
    }

    It 'truncates arrays at 8 items with summary' {
        $BigArray = 1..12 | ForEach-Object { "Item$_" }
        $Result = @(Format-DetailValue -Value $BigArray)
        $Result.Count | Should -Be 9  # 8 items + "... i 4 wiecej"
        $Result[-1] | Should -BeLike '*wiecej*'
    }

    It 'formats HashSet[string] inline for 3 or fewer items' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([string[]]@('A', 'B', 'C'))
        $Result = Format-DetailValue -Value $Set
        $Result | Should -BeOfType [string]
        $Result | Should -BeLike '*A*'
        $Result | Should -BeLike '*B*'
        $Result | Should -BeLike '*C*'
    }

    It 'formats HashSet[string] as bullet list for more than 3 items' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([string[]]@('A', 'B', 'C', 'D', 'E'))
        $Result = @(Format-DetailValue -Value $Set)
        $Result.Count | Should -Be 5
        $Result[0] | Should -BeLike "*$([char]0x2022)*"
    }

    It 'returns (brak) for empty HashSet[string]' {
        $Set = [System.Collections.Generic.HashSet[string]]::new()
        Format-DetailValue -Value $Set | Should -Be '(brak)'
    }

    It 'formats temporal objects preferring Text property' {
        $Data = @(
            [PSCustomObject]@{ Text = 'Kapitan'; ValidFrom = '2024-01-01'; ValidTo = '2024-12-31' }
        )
        $Result = @(Format-DetailValue -Value $Data)
        $Result.Count | Should -Be 1
        $Result[0] | Should -BeLike 'Kapitan*'
        $Result[0] | Should -BeLike '*2024-01-01*'
    }

    It 'formats temporal objects falling back to Value property' {
        $Data = @(
            [PSCustomObject]@{ Value = 100; ValidFrom = '2024-06-01' }
        )
        $Result = @(Format-DetailValue -Value $Data)
        $Result.Count | Should -Be 1
        $Result[0] | Should -BeLike '100*'
    }

    It 'formats temporal objects falling back to first scalar property' {
        $Data = @(
            [PSCustomObject]@{ Rank = 'Major'; ValidFrom = '2024-01-01' }
        )
        $Result = @(Format-DetailValue -Value $Data)
        $Result.Count | Should -Be 1
        $Result[0] | Should -BeLike 'Major*'
    }

    It 'formats generic PSCustomObject arrays with multi-property display' {
        $Data = @(
            [PSCustomObject]@{ Name = 'Sandro'; Role = 'NPC'; Status = 'Active' }
            [PSCustomObject]@{ Name = 'Erathia'; Role = 'Location'; Status = 'Active' }
        )
        $Result = @(Format-DetailValue -Value $Data)
        $Result.Count | Should -Be 2
        $Result[0] | Should -BeLike "*$([char]0x2022)*"
        $Result[0] | Should -BeLike '*Sandro*'
    }

    It 'truncates generic PSCustomObject arrays at 8 items' {
        $Data = 1..12 | ForEach-Object {
            [PSCustomObject]@{ Name = "Item$_"; Value = $_ }
        }
        $Result = @(Format-DetailValue -Value $Data)
        $Result.Count | Should -Be 9  # 8 items + overflow message
        $Result[-1] | Should -BeLike '*wiecej*'
    }
}

Describe 'New-HelpOverlayComponent' {

    It 'creates component with correct type' {
        $C = New-HelpOverlayComponent -Content @('Line 1', 'Line 2')
        $C.Type | Should -Be 'HelpOverlay'
    }

    It 'stores content lines' {
        $C = New-HelpOverlayComponent -Content @('A', 'B', 'C')
        $C.Content.Count | Should -BeGreaterOrEqual 3
    }

    It 'sets filterable to false' {
        $C = New-HelpOverlayComponent -Content @('A')
        $C.Filterable | Should -BeFalse
    }

    It 'sets custom title' {
        $C = New-HelpOverlayComponent -Title 'My Help' -Content @('A')
        $C.Title | Should -Be 'My Help'
    }
}

Describe 'New-HealthDashboardComponent' {

    It 'creates component with correct type' {
        $State = [PSCustomObject]@{
            HealthCache = @{
                PU = $null; Currency = $null; Integrity = $null; Graph = $null
                CheckedAt = Get-Date; Errors = @()
            }
        }
        $C = New-HealthDashboardComponent -State $State
        $C.Type | Should -Be 'HealthDashboard'
    }

    It 'sets filterable to false' {
        $State = [PSCustomObject]@{
            HealthCache = @{
                PU = $null; Currency = $null; Integrity = $null; Graph = $null
                CheckedAt = Get-Date; Errors = @()
            }
        }
        $C = New-HealthDashboardComponent -State $State
        $C.Filterable | Should -BeFalse
    }
}

Describe 'Split-HighlightSegments' {

    It 'highlights prefix match at start of text' {
        $MI = @{ Type = 'prefix'; Start = 0; Length = 3 }
        $Segs = Split-HighlightSegments -Text 'Sandro' -NormalColor 'White' -HighlightColor 'Cyan' -MatchInfo $MI
        $Segs.Count | Should -Be 2
        $Segs[0].Text  | Should -Be 'San'
        $Segs[0].Color | Should -Be 'Cyan'
        $Segs[0].Bold  | Should -BeTrue
        $Segs[1].Text  | Should -Be 'dro'
        $Segs[1].Color | Should -Be 'White'
    }

    It 'highlights contains match in the middle' {
        $MI = @{ Type = 'contains'; Start = 2; Length = 3 }
        $Segs = Split-HighlightSegments -Text 'Nocturnus' -NormalColor 'White' -HighlightColor 'Cyan' -MatchInfo $MI
        $Segs.Count | Should -Be 3
        $Segs[0].Text | Should -Be 'No'
        $Segs[1].Text | Should -Be 'ctu'
        $Segs[1].Bold | Should -BeTrue
        $Segs[2].Text | Should -Be 'rnus'
    }

    It 'returns fuzzy symbol for fuzzy match' {
        $MI = @{ Type = 'fuzzy'; Start = -1; Length = 0 }
        $Segs = Split-HighlightSegments -Text 'Sandro' -NormalColor 'White' -HighlightColor 'Cyan' -MatchInfo $MI
        $Segs.Count | Should -Be 2
        $Segs[0].Text | Should -Match ([char]0x2248)
        $Segs[1].Text | Should -Be 'Sandro'
    }

    It 'returns single segment for invalid match start' {
        $MI = @{ Type = 'contains'; Start = 100; Length = 3 }
        $Segs = Split-HighlightSegments -Text 'Short' -NormalColor 'White' -HighlightColor 'Cyan' -MatchInfo $MI
        $Segs.Count | Should -Be 1
        $Segs[0].Text | Should -Be 'Short'
    }

    It 'clamps match length to text boundary' {
        $MI = @{ Type = 'prefix'; Start = 0; Length = 100 }
        $Segs = Split-HighlightSegments -Text 'Hi' -NormalColor 'White' -HighlightColor 'Cyan' -MatchInfo $MI
        $Segs.Count | Should -Be 1
        $Segs[0].Text | Should -Be 'Hi'
        $Segs[0].Bold | Should -BeTrue
    }
}

Describe 'Invoke-MenuFilter — match info tracking' {

    BeforeAll {
        function New-TestMenuItems {
            return @(
                @{ Label = 'Alpha'; ID = 'a'; Disabled = $false }
                @{ Label = 'Beta'; ID = 'b'; Disabled = $false }
                @{ Label = 'AlphaBeta'; ID = 'ab'; Disabled = $false }
                @{ Label = 'Gamma'; ID = 'g'; Disabled = $false }
            )
        }
    }

    It 'stores prefix match info' {
        $C = New-MenuListComponent -Items (New-TestMenuItems)
        Invoke-MenuFilter -Component $C -FilterText 'Alpha'
        $C.MatchInfoList.Count | Should -Be 2
        $C.MatchInfoList[0].Type | Should -Be 'prefix'
        $C.MatchInfoList[0].Start | Should -Be 0
        $C.MatchInfoList[0].Length | Should -Be 5
    }

    It 'stores contains match info' {
        $C = New-MenuListComponent -Items (New-TestMenuItems)
        Invoke-MenuFilter -Component $C -FilterText 'Beta'
        # 'Beta' is prefix of Beta, contains of AlphaBeta
        $BetaIdx = -1
        $ABIdx = -1
        for ($I = 0; $I -lt $C.Items.Count; $I++) {
            if ($C.Items[$I].Label -eq 'Beta') { $BetaIdx = $I }
            if ($C.Items[$I].Label -eq 'AlphaBeta') { $ABIdx = $I }
        }
        $C.MatchInfoList[$BetaIdx].Type | Should -Be 'prefix'
        $C.MatchInfoList[$ABIdx].Type | Should -Be 'contains'
    }

    It 'stores null match info for empty query' {
        $C = New-MenuListComponent -Items (New-TestMenuItems)
        Invoke-MenuFilter -Component $C -FilterText ''
        foreach ($MI in $C.MatchInfoList) {
            $MI | Should -BeNullOrEmpty
        }
    }

    It 'clears MatchInfoList on FilterClear' {
        $C = New-MenuListComponent -Items (New-TestMenuItems)
        Invoke-MenuFilter -Component $C -FilterText 'Alpha'
        $C.MatchInfoList.Count | Should -BeGreaterThan 0

        # Simulate HandleKey FilterClear
        & $C.HandleKey @{ Type = 'FilterClear' } $null $C
        $C.MatchInfoList.Count | Should -Be 0
    }
}

Describe 'Invoke-MenuFuzzyExtend' {

    It 'appends fuzzy matches from callback' {
        $Items = @(
            @{ Label = 'Sandro'; ID = 's'; Disabled = $false }
            @{ Label = 'Nocturnus'; ID = 'n'; Disabled = $false }
            @{ Label = 'Erathia'; ID = 'e'; Disabled = $false }
        )

        $FuzzyCb = {
            param([string]$Query, [object[]]$Remaining)
            # Simulate fuzzy matching: return items containing 'a' (fuzzy-like)
            return @($Remaining | Where-Object { $_.Label -match 'a' })
        }

        $C = New-MenuListComponent -Items $Items -FuzzyCallback $FuzzyCb
        # Stage 1+2: filter for 'San'
        Invoke-MenuFilter -Component $C -FilterText 'San'
        $PreCount = $C.Items.Count  # Should be 1 (Sandro)

        # Stage 3: fuzzy extend
        Invoke-MenuFuzzyExtend -Component $C -FilterText 'San'
        $C.Items.Count | Should -BeGreaterThan $PreCount
        # Erathia should be added (has 'a', fuzzy match)
        $Labels = $C.Items | ForEach-Object { $_.Label }
        $Labels | Should -Contain 'Erathia'
    }

    It 'does nothing when FuzzyCallback is null' {
        $Items = @(
            @{ Label = 'Alpha'; ID = 'a'; Disabled = $false }
        )
        $C = New-MenuListComponent -Items $Items
        Invoke-MenuFilter -Component $C -FilterText 'Al'
        $Before = $C.Items.Count

        Invoke-MenuFuzzyExtend -Component $C -FilterText 'Al'
        $C.Items.Count | Should -Be $Before
    }

    It 'marks fuzzy results with fuzzy match type' {
        $Items = @(
            @{ Label = 'Alpha'; ID = 'a'; Disabled = $false }
            @{ Label = 'Beta'; ID = 'b'; Disabled = $false }
        )

        $FuzzyCb = {
            param([string]$Query, [object[]]$Remaining)
            return @($Remaining)
        }

        $C = New-MenuListComponent -Items $Items -FuzzyCallback $FuzzyCb
        Invoke-MenuFilter -Component $C -FilterText 'Alp'
        Invoke-MenuFuzzyExtend -Component $C -FilterText 'Alp'

        # Last item should have fuzzy match info
        $LastMI = $C.MatchInfoList[$C.MatchInfoList.Count - 1]
        $LastMI.Type | Should -Be 'fuzzy'
    }
}

Describe 'Search-HelpTopics' {

    It 'finds matching topics in HelpFull' {
        $Registry = @(
            @{
                ID = 'test-entry'
                Label = 'Test'
                Overrides = @{
                    HelpFull = @('This describes PU assignment', 'And other things')
                }
            }
            @{
                ID = 'other'
                Label = 'Other'
                Overrides = @{
                    HelpFull = @('Nothing relevant here')
                }
            }
        )

        $Results = Search-HelpTopics -Query 'PU' -Registry $Registry
        $Results.Count | Should -Be 1
        $Results[0].ID | Should -Be 'test-entry'
    }

    It 'finds matching topics in step-level help' {
        $Registry = @(
            @{
                ID = 'pu-assign'
                Label = 'PU'
                Overrides = @{
                    Date = @{
                        HelpBrief = 'Data sesji w formacie RRRR-MM-DD'
                    }
                }
            }
        )

        $Results = Search-HelpTopics -Query 'sesji' -Registry $Registry
        $Results.Count | Should -Be 1
    }

    It 'returns empty for no matches' {
        $Registry = @(
            @{
                ID = 'x'
                Label = 'X'
                Overrides = @{ HelpFull = @('nothing') }
            }
        )

        $Results = Search-HelpTopics -Query 'zzzzz' -Registry $Registry
        $Results.Count | Should -Be 0
    }

    It 'searches case-insensitively' {
        $Registry = @(
            @{
                ID = 'test'
                Label = 'Test'
                Overrides = @{ HelpFull = @('Contains WALUTA info') }
            }
        )

        $Results = Search-HelpTopics -Query 'waluta' -Registry $Registry
        $Results.Count | Should -Be 1
    }
}

Describe 'Get-AutoStepHelp' {

    It 'returns empty for non-existent function' {
        $Result = Get-AutoStepHelp -FunctionName 'NoSuchFunction12345' -ParameterName 'X'
        $Result.Count | Should -Be 0
    }

    It 'returns type hint for known parameter types' {
        # Get-Date has a -Date parameter of DateTime type
        $Result = Get-AutoStepHelp -FunctionName 'Get-Date' -ParameterName 'Date'
        # Should return some help lines (at least type info)
        $Result.Count | Should -BeGreaterThan 0
    }
}

# ── MenuListComponent HandleKey ──────────────────────────────────────────────

Describe 'MenuListComponent HandleKey — Navigate' {

    BeforeAll {
        function New-ThreeItemMenu {
            $Items = @(
                [PSCustomObject]@{ ID = 'a'; Label = 'Alpha'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                [PSCustomObject]@{ ID = 'b'; Label = 'Beta'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                [PSCustomObject]@{ ID = 'c'; Label = 'Gamma'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
            )
            return (New-MenuListComponent -Items $Items)
        }
    }

    It 'moves SelectedPos down on Navigate Down' {
        $C = New-ThreeItemMenu
        $C.SelectedPos | Should -Be 0
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedPos | Should -Be 1
    }

    It 'moves SelectedPos up on Navigate Up' {
        $C = New-ThreeItemMenu
        $C.SelectedPos = 2
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Up' } $null $C
        $C.SelectedPos | Should -Be 1
    }

    It 'does not go below 0 on Navigate Up at top' {
        $C = New-ThreeItemMenu
        $C.SelectedPos = 0
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Up' } $null $C
        $C.SelectedPos | Should -Be 0
    }

    It 'does not exceed max on Navigate Down at bottom' {
        $C = New-ThreeItemMenu
        $C.SelectedPos = 2
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedPos | Should -Be 2
    }

    It 'skips disabled items in selectable indices' {
        $Items = @(
            [PSCustomObject]@{ ID = 'a'; Label = 'A'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
            [PSCustomObject]@{ ID = 'b'; Label = 'B'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $true }
            [PSCustomObject]@{ ID = 'c'; Label = 'C'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        )
        $C = New-MenuListComponent -Items $Items
        # Navigate down once should go from index 0 (item A) to index 1 (item C, since B is disabled)
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $SelIdx = $C.SelectableIndices[$C.SelectedPos]
        $C.Items[$SelIdx].ID | Should -Be 'c'
    }

    It 'returns item ID on Select' {
        $C = New-ThreeItemMenu
        $C.SelectedPos = 1
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result.Type  | Should -Be 'Return'
        $Result.Value | Should -Be 'b'
    }
}

# ── ResultTableComponent HandleKey ───────────────────────────────────────────

Describe 'ResultTableComponent HandleKey — Navigate and Select' {

    BeforeAll {
        function New-TestTable {
            param([int]$RowCount = 30)
            $Data = @()
            for ($I = 1; $I -le $RowCount; $I++) {
                $Data += [PSCustomObject]@{ Name = "Row$I"; Type = 'NPC' }
            }
            return (New-ResultTableComponent -Data $Data -Columns @('Name', 'Type') `
                -Headers @('Nazwa', 'Typ') -PageSize 10)
        }
    }

    It 'moves SelectedAbs down on Navigate Down' {
        $C = New-TestTable
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedAbs | Should -Be 1
    }

    It 'moves SelectedAbs up on Navigate Up' {
        $C = New-TestTable
        $C.SelectedAbs = 5
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Up' } $null $C
        $C.SelectedAbs | Should -Be 4
    }

    It 'does not go below 0' {
        $C = New-TestTable
        $C.SelectedAbs = 0
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Up' } $null $C
        $C.SelectedAbs | Should -Be 0
    }

    It 'does not exceed data count' {
        $C = New-TestTable -RowCount 5
        $C.SelectedAbs = 4
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedAbs | Should -Be 4
    }

    It 'pages right with Navigate Right' {
        $C = New-TestTable -RowCount 30
        $C.SelectedAbs = 5  # on page 0
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Right' } $null $C
        $C.SelectedAbs | Should -Be 10  # start of page 1
    }

    It 'pages left with Navigate Left' {
        $C = New-TestTable -RowCount 30
        $C.SelectedAbs = 15  # on page 1
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Left' } $null $C
        $C.SelectedAbs | Should -Be 0   # start of page 0
    }

    It 'does not page left from first page' {
        $C = New-TestTable -RowCount 30
        $C.SelectedAbs = 3
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Left' } $null $C
        $C.SelectedAbs | Should -Be 3
    }

    It 'does not page right from last page' {
        $C = New-TestTable -RowCount 25
        $C.SelectedAbs = 20  # on last page (page 2)
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Right' } $null $C
        $C.SelectedAbs | Should -Be 20
    }

    It 'returns selected row on Select' {
        $C = New-TestTable -RowCount 5
        $C.SelectedAbs = 2
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result.Type  | Should -Be 'Return'
        $Result.Value.Name | Should -Be 'Row3'
    }
}

# ── WizardStepComponent ─────────────────────────────────────────────────────

Describe 'New-WizardStepComponent' {

    It 'creates component with correct type' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 3
        $C.Type | Should -Be 'WizardStep'
    }

    It 'stores step metadata' {
        $C = New-WizardStepComponent -Label 'Data sesji' -StepNumber 2 -TotalSteps 5 -StepType 'date' -Required
        $C.Label      | Should -Be 'Data sesji'
        $C.StepNumber | Should -Be 2
        $C.TotalSteps | Should -Be 5
        $C.StepType   | Should -Be 'date'
        $C.Required   | Should -BeTrue
    }

    It 'sets filterable to false' {
        $C = New-WizardStepComponent -Label 'Test' -StepNumber 1 -TotalSteps 1
        $C.Filterable | Should -BeFalse
    }

    It 'initializes InputBuffer empty when no default' {
        $C = New-WizardStepComponent -Label 'Test' -StepNumber 1 -TotalSteps 1
        $C.InputBuffer.ToString() | Should -BeNullOrEmpty
    }

    It 'initializes InputBuffer with default value' {
        $C = New-WizardStepComponent -Label 'Test' -StepNumber 1 -TotalSteps 1 -DefaultValue '2024-01-15'
        $C.InputBuffer.ToString() | Should -Be '2024-01-15'
    }

    It 'stores options for selection type' {
        $C = New-WizardStepComponent -Label 'Typ' -StepNumber 1 -TotalSteps 1 -StepType 'selection' -Options @('NPC', 'Lokacja', 'Grupa')
        $C.Options.Count | Should -Be 3
        $C.SelectedOption | Should -Be 0
    }
}

Describe 'WizardStepComponent HandleKey — selection type' {

    It 'navigates options with Up/Down' {
        $C = New-WizardStepComponent -Label 'Typ' -StepNumber 1 -TotalSteps 1 -StepType 'selection' -Options @('A', 'B', 'C')
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedOption | Should -Be 1
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedOption | Should -Be 2
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedOption | Should -Be 2  # clamped
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Up' } $null $C
        $C.SelectedOption | Should -Be 1
    }

    It 'returns selected option on Select' {
        $C = New-WizardStepComponent -Label 'Typ' -StepNumber 1 -TotalSteps 1 -StepType 'selection' -Options @('NPC', 'Lokacja')
        $C.SelectedOption = 1
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result.Type  | Should -Be 'Return'
        $Result.Value | Should -Be 'Lokacja'
    }
}

Describe 'WizardStepComponent HandleKey — yesno type' {

    It 'toggles between yes and no' {
        $C = New-WizardStepComponent -Label 'Pewny?' -StepNumber 1 -TotalSteps 1 -StepType 'yesno'
        $C.SelectedOption | Should -Be 0  # starts at Yes
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedOption | Should -Be 1  # now No
        & $C.HandleKey @{ Type = 'Navigate'; Value = 'Down' } $null $C
        $C.SelectedOption | Should -Be 0  # toggled back
    }

    It 'returns boolean on Select' {
        $C = New-WizardStepComponent -Label 'Pewny?' -StepNumber 1 -TotalSteps 1 -StepType 'yesno'
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result.Type  | Should -Be 'Return'
        $Result.Value | Should -BeTrue

        $C.SelectedOption = 1
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result.Value | Should -BeFalse
    }
}

Describe 'WizardStepComponent HandleKey — text type' {

    It 'returns input buffer text on Select' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1 -DefaultValue 'Sandro'
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result.Type  | Should -Be 'Return'
        $Result.Value | Should -Be 'Sandro'
    }

    It 'rejects empty required field on Select' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1 -Required
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result | Should -BeNullOrEmpty
    }

    It 'appends text via FilterStart' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1
        & $C.HandleKey @{ Type = 'FilterStart'; Value = 'X' } $null $C
        $C.InputBuffer.ToString() | Should -Be 'X'
    }

    It 'appends text via TextInput' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1
        & $C.HandleKey @{ Type = 'TextInput'; Value = 'A' } $null $C
        & $C.HandleKey @{ Type = 'TextInput'; Value = 'B' } $null $C
        $C.InputBuffer.ToString() | Should -Be 'AB'
    }

    It 'deletes char via TextBackspace' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1 -DefaultValue 'Hello'
        & $C.HandleKey @{ Type = 'TextBackspace' } $null $C
        $C.InputBuffer.ToString() | Should -Be 'Hell'
    }

    It 'does nothing on TextBackspace when buffer empty' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1
        & $C.HandleKey @{ Type = 'TextBackspace' } $null $C
        $C.InputBuffer.ToString() | Should -BeNullOrEmpty
    }

    It 'sets ErrorMessage on empty required field' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1 -Required
        $Result = & $C.HandleKey @{ Type = 'Select' } $null $C
        $Result | Should -BeNullOrEmpty
        $C.ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'clears ErrorMessage on TextInput' {
        $C = New-WizardStepComponent -Label 'Nazwa' -StepNumber 1 -TotalSteps 1 -Required
        & $C.HandleKey @{ Type = 'Select' } $null $C  # triggers error
        $C.ErrorMessage | Should -Not -BeNullOrEmpty
        & $C.HandleKey @{ Type = 'TextInput'; Value = 'X' } $null $C
        $C.ErrorMessage | Should -BeNullOrEmpty
    }

    It 'sets TextInputMode for text types' {
        $C = New-WizardStepComponent -Label 'Test' -StepNumber 1 -TotalSteps 1 -StepType 'text'
        $C.TextInputMode | Should -BeTrue
    }

    It 'sets TextInputMode for number type' {
        $C = New-WizardStepComponent -Label 'Count' -StepNumber 1 -TotalSteps 1 -StepType 'number'
        $C.TextInputMode | Should -BeTrue
    }

    It 'sets TextInputMode for decimal type' {
        $C = New-WizardStepComponent -Label 'Amount' -StepNumber 1 -TotalSteps 1 -StepType 'decimal'
        $C.TextInputMode | Should -BeTrue
    }

    It 'sets TextInputMode for date type' {
        $C = New-WizardStepComponent -Label 'Date' -StepNumber 1 -TotalSteps 1 -StepType 'date'
        $C.TextInputMode | Should -BeTrue
    }

    It 'does not set TextInputMode for selection types' {
        $C = New-WizardStepComponent -Label 'Test' -StepNumber 1 -TotalSteps 1 -StepType 'selection' -Options @('A', 'B')
        $C.TextInputMode | Should -BeFalse
    }

    It 'does not set TextInputMode for yesno types' {
        $C = New-WizardStepComponent -Label 'Test' -StepNumber 1 -TotalSteps 1 -StepType 'yesno'
        $C.TextInputMode | Should -BeFalse
    }

    It 'preserves externally set ErrorMessage' {
        $C = New-WizardStepComponent -Label 'Count' -StepNumber 1 -TotalSteps 1 -StepType 'number'
        $C.ErrorMessage = "Nieprawidłowa liczba: 'abc'"
        $C.ErrorMessage | Should -Be "Nieprawidłowa liczba: 'abc'"
    }

    It 'hides step counter when StepNumber and TotalSteps are 0' {
        $C = New-WizardStepComponent -Label 'Filter' -StepNumber 0 -TotalSteps 0
        $C.StepNumber | Should -Be 0
        $C.TotalSteps | Should -Be 0
    }

    It 'clears ErrorMessage on subsequent TextInput after validation failure' {
        $C = New-WizardStepComponent -Label 'Count' -StepNumber 1 -TotalSteps 1 -StepType 'number' -Required
        # Trigger required field error
        & $C.HandleKey @{ Type = 'Select' } $null $C
        $C.ErrorMessage | Should -Not -BeNullOrEmpty
        # External code sets custom error (number validation)
        $C.ErrorMessage = "Nieprawidłowa liczba: 'abc'"
        # User starts typing → error clears
        & $C.HandleKey @{ Type = 'TextInput'; Value = '1' } $null $C
        $C.ErrorMessage | Should -BeNullOrEmpty
    }
}

# ── Render-FilterBar command palette ─────────────────────────────────────────

Describe 'Render-FilterBar — command palette mode' {

    It 'writes command palette segments when CommandMode is active' {
        $script:CommandMode = $true
        [void]$script:CommandBuffer.Clear()
        [void]$script:CommandBuffer.Append('h')

        $MockState = [PSCustomObject]@{}
        $MockComponent = @{ FilterPrefixes = $null }
        Render-FilterBar -State $MockState -Component $MockComponent

        $FilterRegion = Get-Region -Name 'Filter'
        $Line = $script:BackBuffer[$FilterRegion.StartRow]
        $Line | Should -Not -BeNullOrEmpty
        $Line.Count | Should -BeGreaterThan 0

        # First segment should contain '/'
        $AllText = ($Line | ForEach-Object { $_.Text }) -join ''
        $AllText | Should -BeLike '*/*'
        $AllText | Should -BeLike '*h*'

        # Cleanup
        $script:CommandMode = $false
        [void]$script:CommandBuffer.Clear()
    }

    It 'renders without error when command buffer is empty' {
        $script:CommandMode = $true
        [void]$script:CommandBuffer.Clear()

        $MockState = [PSCustomObject]@{}
        $MockComponent = @{ FilterPrefixes = $null }
        { Render-FilterBar -State $MockState -Component $MockComponent } | Should -Not -Throw

        $FilterRegion = Get-Region -Name 'Filter'
        $Line = $script:BackBuffer[$FilterRegion.StartRow]
        $AllText = ($Line | ForEach-Object { $_.Text }) -join ''
        $AllText | Should -BeLike '*>*/*'

        # Cleanup
        $script:CommandMode = $false
        [void]$script:CommandBuffer.Clear()
    }
}

# ── Render-FilterBar idle placeholder ────────────────────────────────────────

Describe 'Render-FilterBar — idle placeholder' {

    It 'shows placeholder input field when component is filterable' {
        $script:CommandMode = $false
        $script:FilterActive = $false

        $MockState = [PSCustomObject]@{}
        $MockComponent = @{ Filterable = $true; FilterPrefixes = $null }
        Render-FilterBar -State $MockState -Component $MockComponent

        $FilterRegion = Get-Region -Name 'Filter'
        $Line = $script:BackBuffer[$FilterRegion.StartRow]
        $Line | Should -Not -BeNullOrEmpty
        $AllText = ($Line | ForEach-Object { $_.Text }) -join ''
        $AllText | Should -BeLike '*>*'
        $AllText | Should -BeLike '*filtrowac*'
        $AllText | Should -BeLike '*/ polecenia*'
    }

    It 'shows blank line when component is not filterable' {
        $script:CommandMode = $false
        $script:FilterActive = $false

        $MockState = [PSCustomObject]@{}
        $MockComponent = @{ Filterable = $false; FilterPrefixes = $null }
        Render-FilterBar -State $MockState -Component $MockComponent

        $FilterRegion = Get-Region -Name 'Filter'
        $Line = $script:BackBuffer[$FilterRegion.StartRow]
        # Blank line — empty or null segments
        if ($Line) {
            $AllText = ($Line | ForEach-Object { $_.Text }) -join ''
            $AllText.Trim() | Should -BeNullOrEmpty
        }
    }
}

# ── Render-Line Dim passthrough ──────────────────────────────────────────────

Describe 'Render-Line — Dim segment passthrough' {

    It 'Render-Segment receives Dim property from buffer segment' {
        # Verify that Set-BufferLine + the segment structure preserves Dim
        $Buffer = New-ScreenBuffer -Height 5
        $Seg = @{ Text = '---'; Color = 'DarkGray'; Bold = $false; Dim = $true }
        Set-BufferLine -Buffer $Buffer -Row 0 -Segments @($Seg)
        $Buffer[0][0].Dim | Should -BeTrue
    }
}

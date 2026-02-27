BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'get-session.ps1')
}

Describe 'ConvertFrom-SessionHeader' {
    BeforeAll {
        $script:DateRegex = [regex]::new('\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b')
    }

    It 'parses standard yyyy-MM-dd date' {
        $Result = ConvertFrom-SessionHeader -Header '2024-06-15, Sesja, Narrator' -DateRegex $script:DateRegex
        $Result | Should -Not -BeNullOrEmpty
        $Result.Date | Should -Be ([datetime]::new(2024, 6, 15))
        $Result.DateEnd | Should -BeNullOrEmpty
    }

    It 'parses date range yyyy-MM-dd/DD' {
        $Result = ConvertFrom-SessionHeader -Header '2024-06-15/17, Sesja, Narrator' -DateRegex $script:DateRegex
        $Result.Date | Should -Be ([datetime]::new(2024, 6, 15))
        $Result.DateEnd | Should -Be ([datetime]::new(2024, 6, 17))
    }

    It 'returns $null for header without date' {
        $Result = ConvertFrom-SessionHeader -Header 'No date header' -DateRegex $script:DateRegex
        $Result | Should -BeNullOrEmpty
    }

    It 'returns $null for malformed date' {
        $Result = ConvertFrom-SessionHeader -Header '2024-1-5, Sesja, Narrator' -DateRegex $script:DateRegex
        $Result | Should -BeNullOrEmpty
    }
}

Describe 'Get-SessionTitle' {
    It 'extracts title from header with narrator' {
        $DateInfo = @{ Date = [datetime]::new(2024, 6, 15); DateStr = '2024-06-15'; EndDayStr = $null }
        $Title = Get-SessionTitle -Header '2024-06-15, Ucieczka z Erathii, Solmyr' -DateInfo $DateInfo
        $Title | Should -Be 'Ucieczka z Erathii'
    }

    It 'handles header with no narrator (single comma)' {
        $DateInfo = @{ Date = [datetime]::new(2024, 6, 15); DateStr = '2024-06-15'; EndDayStr = $null }
        $Title = Get-SessionTitle -Header '2024-06-15, Sesja bez narratora' -DateInfo $DateInfo
        $Title | Should -Be 'Sesja bez narratora'
    }
}

Describe 'Get-SessionFormat' {
    It 'detects Gen2 from italic location line' {
        $Format = Get-SessionFormat -FirstNonEmptyLine '*Lokalizacja: Erathia*' -SectionLists @()
        $Format | Should -Be 'Gen2'
    }

    It 'detects Gen1 when no structured metadata' {
        $Format = Get-SessionFormat -FirstNonEmptyLine 'Plain text content' -SectionLists @()
        $Format | Should -Be 'Gen1'
    }

    It 'detects Gen4 from @-prefixed list items' {
        $MockLI = [PSCustomObject]@{ Text = '@Lokacje:'; Indent = 0 }
        $Format = Get-SessionFormat -FirstNonEmptyLine $null -SectionLists @($MockLI)
        $Format | Should -Be 'Gen4'
    }

    It 'detects Gen3 from PU list items' {
        $MockLI = [PSCustomObject]@{ Text = 'PU:'; Indent = 0 }
        $Format = Get-SessionFormat -FirstNonEmptyLine $null -SectionLists @($MockLI)
        $Format | Should -Be 'Gen3'
    }
}

Describe 'Get-Session — Gen1' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen1.md')
    }

    It 'parses Gen1 sessions' {
        $script:Sessions.Count | Should -Be 2
    }

    It 'detects Gen1 format' {
        $script:Sessions[0].Format | Should -Be 'Gen1'
    }

    It 'extracts log URL via plain text fallback' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen1-1'
    }

    It 'parses date correctly' {
        $script:Sessions[0].Date | Should -Be ([datetime]::new(2022, 3, 10))
    }

    It 'extracts title' {
        $script:Sessions[0].Title | Should -Be 'Początek przygody'
    }
}

Describe 'Get-Session — Gen2' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen2.md')
    }

    It 'parses Gen2 sessions' {
        $script:Sessions.Count | Should -Be 2
    }

    It 'detects Gen2 format' {
        $script:Sessions[0].Format | Should -Be 'Gen2'
    }

    It 'extracts locations from italic line' {
        $script:Sessions[0].Locations | Should -Contain 'Erathia'
        $script:Sessions[0].Locations | Should -Contain 'Steadwick'
    }

    It 'extracts log URL via plain text fallback' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen2-1'
    }
}

Describe 'Get-Session — Gen3' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md')
    }

    It 'parses Gen3 sessions' {
        $script:Sessions.Count | Should -Be 3
    }

    It 'detects Gen3 format' {
        $script:Sessions[0].Format | Should -Be 'Gen3'
    }

    It 'extracts locations from list items' {
        $script:Sessions[0].Locations | Should -Contain 'Erathia'
        $script:Sessions[0].Locations | Should -Contain 'Ratusz Erathii'
    }

    It 'extracts PU values' {
        $PU = $script:Sessions[0].PU
        $PU.Count | Should -Be 2
        $XeronPU = $PU | Where-Object { $_.Character -eq 'Xeron Demonlord' }
        $XeronPU.Value | Should -Be 0.3
    }

    It 'extracts log URLs' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen3-1'
    }

    It 'extracts Zmiany (entity state changes)' {
        $Session2 = $script:Sessions[1]
        $Session2.Changes.Count | Should -BeGreaterThan 0
        $RionChange = $Session2.Changes | Where-Object { $_.EntityName -eq 'Rion' }
        $RionChange | Should -Not -BeNullOrEmpty
    }

    It 'resolves narrator' {
        $script:Sessions[0].Narrator | Should -Not -BeNullOrEmpty
        $script:Sessions[0].Narrator.Narrators.Count | Should -Be 1
    }
}

Describe 'Get-Session — Gen4' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen4.md')
    }

    It 'parses Gen4 sessions' {
        $script:Sessions.Count | Should -Be 2
    }

    It 'detects Gen4 format' {
        $script:Sessions[0].Format | Should -Be 'Gen4'
    }

    It 'extracts @Lokacje locations' {
        $script:Sessions[0].Locations | Should -Contain 'Erathia'
        $script:Sessions[0].Locations | Should -Contain 'Ratusz Erathii'
    }

    It 'extracts @PU values' {
        $PU = $script:Sessions[0].PU
        $PU.Count | Should -Be 2
    }

    It 'extracts @Logi URLs' {
        $script:Sessions[0].Logs | Should -Contain 'https://example.com/log-gen4-1'
    }

    It 'extracts @Zmiany' {
        $script:Sessions[0].Changes.Count | Should -BeGreaterThan 0
    }

    It 'extracts @Intel entries' {
        $script:Sessions[0].Intel.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-Session — date filtering' {
    It 'MinDate filters out sessions before the date' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md') -MinDate ([datetime]::new(2024, 7, 1))
        $Sessions.Count | Should -BeLessThan 3
        foreach ($S in $Sessions) {
            $S.Date | Should -BeGreaterOrEqual ([datetime]::new(2024, 7, 1))
        }
    }

    It 'MaxDate filters out sessions after the date' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md') -MaxDate ([datetime]::new(2024, 7, 1))
        foreach ($S in $Sessions) {
            $S.Date | Should -BeLessOrEqual ([datetime]::new(2024, 7, 1))
        }
    }
}

Describe 'Get-Session — deduplication' {
    It 'merges duplicate sessions across files' {
        $Sessions = Get-Session -Directory $script:FixturesRoot
        $Ucieczka = $Sessions | Where-Object { $_.Title -eq 'Ucieczka z Erathii' }
        # Should be deduplicated into a single session
        $Ucieczka.Count | Should -Be 1
    }

    It 'merged session has IsMerged = $true when duplicates exist' {
        $Sessions = Get-Session -Directory $script:FixturesRoot
        $Ucieczka = $Sessions | Where-Object { $_.Title -eq 'Ucieczka z Erathii' }
        $Ucieczka.IsMerged | Should -BeTrue
        $Ucieczka.DuplicateCount | Should -BeGreaterThan 1
    }

    It 'merged session combines locations from all sources' {
        $Sessions = Get-Session -Directory $script:FixturesRoot
        $Ucieczka = $Sessions | Where-Object { $_.Title -eq 'Ucieczka z Erathii' }
        $Ucieczka.Locations | Should -Contain 'Erathia'
    }
}

Describe 'Get-Session — failed sessions' {
    It 'excludes failed sessions by default' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-failed.md')
        $Sessions.Count | Should -Be 0
    }

    It 'includes failed sessions with -IncludeFailed' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-failed.md') -IncludeFailed
        $Failed = $Sessions | Where-Object { $null -eq $_.Date }
        $Failed.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-Session — IncludeContent' {
    It 'includes content text when -IncludeContent is set' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md') -IncludeContent
        $Sessions[0].Content | Should -Not -BeNullOrEmpty
    }

    It 'content is $null by default' {
        $Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-gen3.md')
        $Sessions[0].Content | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-EntityWebhook' {
    It 'returns entity prfwebhook override when present' {
        $Entity = [PSCustomObject]@{
            Name      = 'Xeron'
            Type      = 'Postać (Gracz)'
            Owner     = 'Kilgor'
            Overrides = @{ 'prfwebhook' = @('https://discord.com/api/webhooks/111/abc') }
        }
        $Result = Resolve-EntityWebhook -Entity $Entity -Players @()
        $Result | Should -Be 'https://discord.com/api/webhooks/111/abc'
    }

    It 'uses last value when multiple prfwebhook overrides exist' {
        $Entity = [PSCustomObject]@{
            Name      = 'Xeron'
            Type      = 'Postać (Gracz)'
            Owner     = 'Kilgor'
            Overrides = @{ 'prfwebhook' = @('https://discord.com/api/webhooks/111/old', 'https://discord.com/api/webhooks/222/new') }
        }
        $Result = Resolve-EntityWebhook -Entity $Entity -Players @()
        $Result | Should -Be 'https://discord.com/api/webhooks/222/new'
    }

    It 'falls back to owning player webhook for character entities' {
        $Entity = [PSCustomObject]@{
            Name      = 'Xeron'
            Type      = 'Postać (Gracz)'
            Owner     = 'Kilgor'
            Overrides = @{}
        }
        $Players = @(
            [PSCustomObject]@{ Name = 'Kilgor'; PRFWebhook = 'https://discord.com/api/webhooks/333/player' }
        )
        $Result = Resolve-EntityWebhook -Entity $Entity -Players $Players
        $Result | Should -Be 'https://discord.com/api/webhooks/333/player'
    }

    It 'uses entity Name as player name for Gracz type' {
        $Entity = [PSCustomObject]@{
            Name      = 'Kilgor'
            Type      = 'Gracz'
            Owner     = $null
            Overrides = @{}
        }
        $Players = @(
            [PSCustomObject]@{ Name = 'Kilgor'; PRFWebhook = 'https://discord.com/api/webhooks/444/gracz' }
        )
        $Result = Resolve-EntityWebhook -Entity $Entity -Players $Players
        $Result | Should -Be 'https://discord.com/api/webhooks/444/gracz'
    }

    It 'returns null when no webhook can be resolved' {
        $Entity = [PSCustomObject]@{
            Name      = 'Dragon'
            Type      = 'NPC'
            Owner     = $null
            Overrides = @{}
        }
        $Result = Resolve-EntityWebhook -Entity $Entity -Players @()
        $Result | Should -BeNullOrEmpty
    }

    It 'returns PRFWebhook from Player object directly' {
        $Entity = [PSCustomObject]@{
            Name       = 'Kilgor'
            Type       = 'Player'
            PRFWebhook = 'https://discord.com/api/webhooks/555/direct'
            Overrides  = @{}
        }
        $Result = Resolve-EntityWebhook -Entity $Entity -Players @()
        $Result | Should -Be 'https://discord.com/api/webhooks/555/direct'
    }

    It 'ignores prfwebhook override that is not a valid Discord URL' {
        $Entity = [PSCustomObject]@{
            Name      = 'Xeron'
            Type      = 'Postać (Gracz)'
            Owner     = 'Kilgor'
            Overrides = @{ 'prfwebhook' = @('not-a-webhook-url') }
        }
        $Players = @(
            [PSCustomObject]@{ Name = 'Kilgor'; PRFWebhook = 'https://discord.com/api/webhooks/666/fallback' }
        )
        $Result = Resolve-EntityWebhook -Entity $Entity -Players $Players
        $Result | Should -Be 'https://discord.com/api/webhooks/666/fallback'
    }
}

Describe 'Test-LocationMatch' {
    It 'returns true for exact match' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$Set.Add('Erathia')
        Test-LocationMatch -LocationValue 'Erathia' -LocationSet $Set | Should -BeTrue
    }

    It 'returns false when no match' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$Set.Add('Erathia')
        Test-LocationMatch -LocationValue 'Enroth' -LocationSet $Set | Should -BeFalse
    }

    It 'matches slash-separated path segments' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$Set.Add('Ratusz Ithan')
        Test-LocationMatch -LocationValue 'Ithan/Ratusz Ithan' -LocationSet $Set | Should -BeTrue
    }

    It 'matches first segment of slash path' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$Set.Add('Ithan')
        Test-LocationMatch -LocationValue 'Ithan/Ratusz Ithan' -LocationSet $Set | Should -BeTrue
    }

    It 'returns false for slash path with no matching segments' {
        $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$Set.Add('Enroth')
        Test-LocationMatch -LocationValue 'Ithan/Ratusz Ithan' -LocationSet $Set | Should -BeFalse
    }
}

Describe 'Get-SessionLocations' {
    BeforeAll {
        $script:LocItalicRegex = [regex]::new('\*Lokalizacj[ae]?:\s*(.+?)\*')
    }

    It 'extracts locations from Gen2 italic format' {
        $Locations = Get-SessionLocations -Format 'Gen2' `
            -FirstNonEmptyLine '*Lokalizacja: Erathia, Steadwick*' `
            -SectionLists @() `
            -LocItalicRegex $script:LocItalicRegex `
            -Index $null
        $Locations | Should -Contain 'Erathia'
        $Locations | Should -Contain 'Steadwick'
    }

    It 'extracts locations from Gen3 tag-based fallback' {
        $ParentItem = [PSCustomObject]@{ Indent = 0; Text = 'Lokalizacje:'; ParentListItem = $null }
        $ChildItem = [PSCustomObject]@{ Indent = 1; Text = 'Erathia'; ParentListItem = $ParentItem }
        $SectionLists = @($ParentItem, $ChildItem)
        $Locations = Get-SessionLocations -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -SectionLists $SectionLists `
            -LocItalicRegex $script:LocItalicRegex `
            -Index $null
        $Locations | Should -Contain 'Erathia'
    }

    It 'extracts locations from Gen4 @Lokacje tag' {
        $ParentItem = [PSCustomObject]@{ Indent = 0; Text = '@Lokacje:'; ParentListItem = $null }
        $ChildItem1 = [PSCustomObject]@{ Indent = 1; Text = 'Steadwick'; ParentListItem = $ParentItem }
        $ChildItem2 = [PSCustomObject]@{ Indent = 1; Text = 'Erathia'; ParentListItem = $ParentItem }
        $SectionLists = @($ParentItem, $ChildItem1, $ChildItem2)
        $Locations = Get-SessionLocations -Format 'Gen4' `
            -FirstNonEmptyLine '' `
            -SectionLists $SectionLists `
            -LocItalicRegex $script:LocItalicRegex `
            -Index $null
        $Locations | Should -Contain 'Steadwick'
        $Locations | Should -Contain 'Erathia'
    }

    It 'extracts inline comma-separated locations from tag fallback' {
        $ParentItem = [PSCustomObject]@{ Indent = 0; Text = 'Lokalizacje: Erathia, Steadwick'; ParentListItem = $null }
        $SectionLists = @($ParentItem)
        $Locations = Get-SessionLocations -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -SectionLists $SectionLists `
            -LocItalicRegex $script:LocItalicRegex `
            -Index $null
        $Locations | Should -Contain 'Erathia'
        $Locations | Should -Contain 'Steadwick'
    }

    It 'returns empty list for Gen1 format' {
        $Locations = Get-SessionLocations -Format 'Gen1' `
            -FirstNonEmptyLine 'Some text' `
            -SectionLists @() `
            -LocItalicRegex $script:LocItalicRegex `
            -Index $null
        $Locations.Count | Should -Be 0
    }

    It 'uses entity resolution strategy when Index available' {
        $Index = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Index['Erathia'] = [PSCustomObject]@{
            Owner     = [PSCustomObject]@{ Name = 'Erathia'; Type = 'Lokacja' }
            OwnerType = 'Lokacja'
            Ambiguous = $false
        }
        $ParentItem = [PSCustomObject]@{ Indent = 0; Text = 'Punkty:'; ParentListItem = $null }
        $ChildItem = [PSCustomObject]@{ Indent = 1; Text = 'Erathia'; ParentListItem = $ParentItem }
        $SectionLists = @($ParentItem, $ChildItem)
        $Locations = Get-SessionLocations -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -SectionLists $SectionLists `
            -LocItalicRegex $script:LocItalicRegex `
            -Index $Index
        $Locations | Should -Contain 'Erathia'
    }
}

Describe 'Resolve-IntelTargets' {
    BeforeAll {
        . (Join-Path $script:ModuleRoot 'get-entity.ps1')
        $script:Index = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:StemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $script:EntityXeron = [PSCustomObject]@{
            Name            = 'Xeron'
            Type            = 'Postać (Gracz)'
            Owner           = 'Kilgor'
            Names           = @('Xeron')
            GroupHistory    = @()
            LocationHistory = @()
            Overrides       = @{ 'prfwebhook' = @('https://discord.com/api/webhooks/100/xe') }
        }
        $script:EntityDragon = [PSCustomObject]@{
            Name            = 'Dragon'
            Type            = 'NPC'
            Owner           = $null
            Names           = @('Dragon')
            GroupHistory    = @()
            LocationHistory = @()
            Overrides       = @{}
        }

        $script:Index['Xeron'] = [PSCustomObject]@{ Owner = $script:EntityXeron; OwnerType = 'Postać (Gracz)'; Ambiguous = $false }
        $script:Index['Dragon'] = [PSCustomObject]@{ Owner = $script:EntityDragon; OwnerType = 'NPC'; Ambiguous = $false }
    }

    It 'resolves Direct intel target' {
        $Intel = [System.Collections.Generic.List[object]]::new()
        $Intel.Add([PSCustomObject]@{ RawTarget = 'Xeron'; Message = 'Secret info' })

        $Result = Resolve-IntelTargets -RawIntel $Intel -SessionDate ([datetime]::new(2024, 6, 15)) `
            -Entities @($script:EntityXeron, $script:EntityDragon) `
            -Index $script:Index -StemIndex $script:StemIndex `
            -Players @() -ResolveCache @{}

        $Result.Count | Should -Be 1
        $Result[0].Directive | Should -Be 'Direct'
        $Result[0].Recipients.Count | Should -Be 1
        $Result[0].Recipients[0].Name | Should -Be 'Xeron'
    }

    It 'resolves comma-separated Direct targets' {
        $Intel = [System.Collections.Generic.List[object]]::new()
        $Intel.Add([PSCustomObject]@{ RawTarget = 'Xeron, Dragon'; Message = 'Multi info' })

        $Result = Resolve-IntelTargets -RawIntel $Intel -SessionDate ([datetime]::new(2024, 6, 15)) `
            -Entities @($script:EntityXeron, $script:EntityDragon) `
            -Index $script:Index -StemIndex $script:StemIndex `
            -Players @() -ResolveCache @{}

        $Result[0].Directive | Should -Be 'Direct'
        $Result[0].Recipients.Count | Should -Be 2
    }

    It 'handles Grupa/ directive with group members' {
        $Guild = [PSCustomObject]@{
            Name            = 'Gwardia'
            Type            = 'Grupa'
            Owner           = $null
            Names           = @('Gwardia')
            GroupHistory    = @()
            LocationHistory = @()
            Overrides       = @{}
        }
        $Member = [PSCustomObject]@{
            Name            = 'Xeron'
            Type            = 'Postać (Gracz)'
            Owner           = 'Kilgor'
            Names           = @('Xeron')
            GroupHistory    = @(
                [PSCustomObject]@{ Group = 'Gwardia'; StartDate = [datetime]::new(2024, 1, 1); EndDate = $null }
            )
            LocationHistory = @()
            Overrides       = @{}
        }

        $Idx = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Idx['Gwardia'] = [PSCustomObject]@{ Owner = $Guild; OwnerType = 'Grupa'; Ambiguous = $false }

        $Intel = [System.Collections.Generic.List[object]]::new()
        $Intel.Add([PSCustomObject]@{ RawTarget = 'Grupa/Gwardia'; Message = 'Guild intel' })

        $Result = Resolve-IntelTargets -RawIntel $Intel -SessionDate ([datetime]::new(2024, 6, 15)) `
            -Entities @($Guild, $Member) `
            -Index $Idx -StemIndex $script:StemIndex `
            -Players @() -ResolveCache @{}

        $Result[0].Directive | Should -Be 'Grupa'
        $Result[0].TargetName | Should -Be 'Gwardia'
        $Result[0].Recipients.Count | Should -Be 2
    }

    It 'handles Lokacja/ directive with location tree' {
        $CityEntity = [PSCustomObject]@{
            Name            = 'Steadwick'
            Type            = 'Lokacja'
            Owner           = $null
            Names           = @('Steadwick')
            GroupHistory    = @()
            LocationHistory = @()
            Overrides       = @{}
        }
        $SublocEntity = [PSCustomObject]@{
            Name            = 'Ratusz'
            Type            = 'Lokacja'
            Owner           = $null
            Names           = @('Ratusz')
            GroupHistory    = @()
            LocationHistory = @(
                [PSCustomObject]@{ Location = 'Steadwick'; StartDate = [datetime]::new(2024, 1, 1); EndDate = $null }
            )
            Overrides       = @{}
        }
        $ResidentEntity = [PSCustomObject]@{
            Name            = 'Merchant'
            Type            = 'NPC'
            Owner           = $null
            Names           = @('Merchant')
            GroupHistory    = @()
            LocationHistory = @(
                [PSCustomObject]@{ Location = 'Steadwick'; StartDate = [datetime]::new(2024, 1, 1); EndDate = $null }
            )
            Overrides       = @{}
        }

        $Idx = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Idx['Steadwick'] = [PSCustomObject]@{ Owner = $CityEntity; OwnerType = 'Lokacja'; Ambiguous = $false }

        $Intel = [System.Collections.Generic.List[object]]::new()
        $Intel.Add([PSCustomObject]@{ RawTarget = 'Lokacja/Steadwick'; Message = 'Location intel' })

        $Result = Resolve-IntelTargets -RawIntel $Intel -SessionDate ([datetime]::new(2024, 6, 15)) `
            -Entities @($CityEntity, $SublocEntity, $ResidentEntity) `
            -Index $Idx -StemIndex $script:StemIndex `
            -Players @() -ResolveCache @{}

        $Result[0].Directive | Should -Be 'Lokacja'
        $Result[0].TargetName | Should -Be 'Steadwick'
        # Should include: Steadwick (target), Ratusz (sublocation), Merchant (resident)
        $Result[0].Recipients.Count | Should -Be 3
    }

    It 'warns and skips unresolved targets' {
        $Intel = [System.Collections.Generic.List[object]]::new()
        $Intel.Add([PSCustomObject]@{ RawTarget = 'NonExistent'; Message = 'Unknown' })

        $EmptyIndex = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $Result = Resolve-IntelTargets -RawIntel $Intel -SessionDate ([datetime]::new(2024, 6, 15)) `
            -Entities @() `
            -Index $EmptyIndex -StemIndex $script:StemIndex `
            -Players @() -ResolveCache @{}

        $Result[0].Recipients.Count | Should -Be 0
    }
}

Describe 'Get-SessionMentions' {
    BeforeAll {
        $script:MentionIndex = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:MentionStemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $script:MentionEntity = [PSCustomObject]@{ Name = 'Xeron'; Type = 'Postać (Gracz)' }
        $script:MentionIndex['Xeron'] = [PSCustomObject]@{
            Owner     = $script:MentionEntity
            OwnerType = 'Postać (Gracz)'
            Ambiguous = $false
        }
    }

    It 'extracts entity mentions from paragraph text' {
        $Content = "Xeron went to the market and bought supplies."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @() `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron'
    }

    It 'excludes PU list items from mention scanning' {
        $PUItem = [PSCustomObject]@{ Indent = 0; Text = 'PU:'; ParentListItem = $null }
        $PUChild = [PSCustomObject]@{ Indent = 1; Text = 'Xeron: 0.3'; ParentListItem = $PUItem }

        $Content = "Some other text without entities."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @($PUItem, $PUChild) `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}

        # Xeron should NOT appear since it's only in excluded PU list
        $MentionNames = $Result | ForEach-Object { $_.Name }
        $MentionNames | Should -Not -Contain 'Xeron'
    }

    It 'excludes Logi, Lokalizacje, Zmiany, Intel list items' {
        $LogiItem = [PSCustomObject]@{ Indent = 0; Text = 'Logi:'; ParentListItem = $null }
        $LocItem = [PSCustomObject]@{ Indent = 0; Text = 'Lokalizacje:'; ParentListItem = $null }
        $ZmianyItem = [PSCustomObject]@{ Indent = 0; Text = 'Zmiany:'; ParentListItem = $null }
        $IntelItem = [PSCustomObject]@{ Indent = 0; Text = 'Intel:'; ParentListItem = $null }

        $Content = "Body text."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @($LogiItem, $LocItem, $ZmianyItem, $IntelItem) `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        # No entity mentions in body text
        $Result.Count | Should -Be 0
    }

    It 'skips Gen2 italic location first line' {
        $Content = "*Lokalizacja: Erathia*`nXeron walked around."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @() `
            -Format 'Gen2' `
            -FirstNonEmptyLine '*Lokalizacja: Erathia*' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron'
    }

    It 'extracts mentions from markdown links' {
        $Content = "The hero [Xeron](http://wiki.example.com/Xeron) arrived."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @() `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron'
    }

    It 'excludes children of excluded list items' {
        $PUItem = [PSCustomObject]@{ Indent = 0; Text = 'PU:'; ParentListItem = $null }
        $PUChild = [PSCustomObject]@{ Indent = 1; Text = 'Xeron: 0.3'; ParentListItem = $PUItem }
        $PUGrandchild = [PSCustomObject]@{ Indent = 2; Text = 'bonus Xeron'; ParentListItem = $PUChild }

        $Content = "No entities here."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @($PUItem, $PUChild, $PUGrandchild) `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        $MentionNames = $Result | ForEach-Object { $_.Name }
        $MentionNames | Should -Not -Contain 'Xeron'
    }

    It 'includes non-excluded list items in scan' {
        $OtherItem = [PSCustomObject]@{ Indent = 0; Text = 'Objaśnienia:'; ParentListItem = $null }
        $OtherChild = [PSCustomObject]@{ Indent = 1; Text = 'Xeron got a reward'; ParentListItem = $OtherItem }

        $Content = "Some body."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @($OtherItem, $OtherChild) `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        $MentionNames = $Result | ForEach-Object { $_.Name }
        $MentionNames | Should -Contain 'Xeron'
    }

    It 'uses resolve cache to speed up repeated lookups' {
        $Cache = @{}
        $Content = "Xeron met Xeron again."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @() `
            -Format 'Gen3' `
            -FirstNonEmptyLine '' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache $Cache
        $Result.Count | Should -Be 1
        $Cache.ContainsKey('Xeron') | Should -BeTrue
    }

    It 'skips Logi: plain text lines' {
        $Content = "Logi: https://example.com/log`nXeron was present."
        $Result = Get-SessionMentions -Content $Content `
            -SectionLists @() `
            -Format 'Gen1' `
            -FirstNonEmptyLine 'Logi: https://example.com/log' `
            -Index $script:MentionIndex `
            -StemIndex $script:MentionStemIndex `
            -ResolveCache @{}
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron'
    }
}

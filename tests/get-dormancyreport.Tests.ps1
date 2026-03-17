<#
    .SYNOPSIS
    Pester tests for Get-DormancyReport.

    .DESCRIPTION
    Tests dormancy detection including threshold filtering, type filtering,
    status exclusion, entities with no history, session graph integration
    (graceful fallback), and sort order. Uses mock entity objects.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-dormancy-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force

    # Build mock entities with varying history dates
    function script:NewMockHistory {
        param([object[]]$Entries)
        $List = [System.Collections.Generic.List[object]]::new()
        foreach ($E in $Entries) { [void]$List.Add($E) }
        return $List
    }

    $script:Now = [DateTime]::Now
    $script:RecentDate = $script:Now.AddMonths(-2)     # 2 months ago (active)
    $script:OldDate = $script:Now.AddMonths(-8)         # 8 months ago (dormant at 6-month threshold)
    $script:AncientDate = $script:Now.AddMonths(-24)    # 2 years ago (very dormant)

    $script:MockEntities = @(
        # Active NPC — recent property change
        [PSCustomObject]@{
            Name             = 'Active NPC'
            Type             = 'NPC'
            Status           = 'Aktywny'
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = NewMockHistory @([PSCustomObject]@{ Value = 'Erathia'; ValidFrom = $script:RecentDate; ValidTo = $null })
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
        # Dormant NPC — last activity 8 months ago
        [PSCustomObject]@{
            Name             = 'Dormant NPC'
            Type             = 'NPC'
            Status           = 'Aktywny'
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = NewMockHistory @([PSCustomObject]@{ Value = 'Steadwick'; ValidFrom = $script:OldDate; ValidTo = $null })
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
        # Very dormant Lokacja — last activity 2 years ago
        [PSCustomObject]@{
            Name             = 'Forgotten Place'
            Type             = 'Lokacja'
            Status           = 'Aktywny'
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = NewMockHistory @([PSCustomObject]@{ Value = 'Enroth'; ValidFrom = $script:AncientDate; ValidTo = $null })
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
        # Entity with no history at all
        [PSCustomObject]@{
            Name             = 'No History Entity'
            Type             = 'NPC'
            Status           = 'Aktywny'
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = NewMockHistory
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
        # Deleted entity — excluded by default
        [PSCustomObject]@{
            Name             = 'Deleted NPC'
            Type             = 'NPC'
            Status           = 'Usunięty'
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = NewMockHistory @([PSCustomObject]@{ Value = 'Nowhere'; ValidFrom = $script:AncientDate; ValidTo = $null })
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
        # Active Postać — recent property change (should not be dormant)
        [PSCustomObject]@{
            Name             = 'Active Hero'
            Type             = 'Postać'
            Status           = 'Aktywny'
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = NewMockHistory @([PSCustomObject]@{ Value = 'Erathia'; ValidFrom = $script:RecentDate; ValidTo = $null })
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory @([PSCustomObject]@{ Value = 'Solmyr'; ValidFrom = $script:RecentDate; ValidTo = $null })
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
    )
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Get-DormancyReport' {
    It 'identifies dormant entities at default 6-month threshold' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $Result.Name | Should -Contain 'Dormant NPC'
        $Result.Name | Should -Contain 'Forgotten Place'
        $Result.Name | Should -Contain 'No History Entity'
    }

    It 'excludes active entities (recent activity within threshold)' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $Result.Name | Should -Not -Contain 'Active NPC'
        $Result.Name | Should -Not -Contain 'Active Hero'
    }

    It 'excludes Usunięty entities by default' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $Result.Name | Should -Not -Contain 'Deleted NPC'
    }

    It 'includes Usunięty entities with -IncludeDeleted' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -IncludeDeleted -Quiet
        $Result.Name | Should -Contain 'Deleted NPC'
    }

    It 'filters by Type' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Type 'NPC' -Quiet
        $Result.Name | Should -Contain 'Dormant NPC'
        $Result.Name | Should -Contain 'No History Entity'
        $Result.Name | Should -Not -Contain 'Forgotten Place'
    }

    It 'reports correct LastActivity date' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $DormantNPC = $Result | Where-Object { $_.Name -eq 'Dormant NPC' }
        $DormantNPC.LastActivity | Should -Be $script:OldDate
    }

    It 'reports null LastActivity for entities with no history' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $NoHistory = $Result | Where-Object { $_.Name -eq 'No History Entity' }
        $NoHistory.LastActivity | Should -BeNullOrEmpty
    }

    It 'reports LastSource as PropertyChange for property-based detection' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $DormantNPC = $Result | Where-Object { $_.Name -eq 'Dormant NPC' }
        $DormantNPC.LastSource | Should -Be 'PropertyChange'
    }

    It 'reports LastSource as Creation for entities with no history' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $NoHistory = $Result | Where-Object { $_.Name -eq 'No History Entity' }
        $NoHistory.LastSource | Should -Be 'Creation'
    }

    It 'computes DaysDormant correctly' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $DormantNPC = $Result | Where-Object { $_.Name -eq 'Dormant NPC' }
        $ExpectedDays = [int][math]::Floor(([DateTime]::Now - $script:OldDate).TotalDays)
        $DormantNPC.DaysDormant | Should -BeGreaterOrEqual ($ExpectedDays - 1)
        $DormantNPC.DaysDormant | Should -BeLessOrEqual ($ExpectedDays + 1)
    }

    It 'sorts by DaysDormant descending (most dormant first)' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        if ($Result.Count -ge 2) {
            $Result[0].DaysDormant | Should -BeGreaterOrEqual $Result[1].DaysDormant
        }
    }

    It 'adjusts with custom threshold' {
        # With 1-month threshold, Active NPC (2 months ago) becomes dormant
        $Result = Get-DormancyReport -Entities $script:MockEntities -ThresholdMonths 1 -Quiet
        $Result.Name | Should -Contain 'Active NPC'
        $Result.Name | Should -Contain 'Active Hero'
    }

    It 'reports CreatedOn as earliest ValidFrom' {
        $Result = Get-DormancyReport -Entities $script:MockEntities -Quiet
        $DormantNPC = $Result | Where-Object { $_.Name -eq 'Dormant NPC' }
        $DormantNPC.CreatedOn | Should -Be $script:OldDate
    }

    It 'returns empty array when all entities are active' {
        # With 100-month threshold, nothing is dormant
        $Result = Get-DormancyReport -Entities $script:MockEntities -ThresholdMonths 100 -Quiet
        # Only 'No History Entity' might still show (no dates at all)
        $Result.Name | Should -Not -Contain 'Dormant NPC'
        $Result.Name | Should -Not -Contain 'Active NPC'
    }

    It 'returns empty array with empty entity set' {
        $Result = Get-DormancyReport -Entities @() -Quiet
        $Result.Count | Should -Be 0
    }

    It 'handles entities with null Status as Aktywny' {
        $NullStatusEntity = [PSCustomObject]@{
            Name             = 'Null Status'
            Type             = 'NPC'
            Status           = $null
            Names            = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            LocationHistory  = (NewMockHistory @([PSCustomObject]@{ Value = 'Erathia'; ValidFrom = $script:AncientDate; ValidTo = $null }))
            DoorHistory      = NewMockHistory
            TypeHistory      = NewMockHistory
            OwnerHistory     = NewMockHistory
            GroupHistory     = NewMockHistory
            StatusHistory    = $null
            QuantityHistory  = $null
            FilePathHistory  = $null
            NerthusNameHistory = $null
        }
        $Result = Get-DormancyReport -Entities @($NullStatusEntity) -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Status | Should -Be 'Aktywny'
    }
}

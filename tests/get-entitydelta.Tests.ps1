<#
    .SYNOPSIS
    Pester tests for Get-EntityDelta.

    .DESCRIPTION
    Tests entity temporal diff including scalar property changes, multi-valued
    property diffs (Groups, Doors), no-change scenarios, entity not found,
    and pre-computed entity state optimization. Uses mock entity objects.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-delta-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force

    # Build mock entity "snapshots" at two points in time
    # FromEntity: state at 2025-01-01
    $script:FromEntity = [PSCustomObject]@{
        Name       = 'Kupiec Orrin'
        Type       = 'NPC'
        Owner      = $null
        Location   = 'Erathia'
        Status     = 'Aktywny'
        Quantity   = $null
        NerthusName = $null
        Groups     = @('Kupcy Erathii')
        Doors      = @('Brama Zachodnia')
        Names      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$script:FromEntity.Names.Add('Kupiec Orrin')
    [void]$script:FromEntity.Names.Add('Orrin')

    # ToEntity: state at 2025-06-01 (location, status, groups changed)
    $script:ToEntity = [PSCustomObject]@{
        Name       = 'Kupiec Orrin'
        Type       = 'NPC'
        Owner      = $null
        Location   = 'Bracada'
        Status     = 'Nieaktywny'
        Quantity   = '5'
        NerthusName = $null
        Groups     = @('Kupcy Erathii', 'Rada Handlowa')
        Doors      = @('Brama Zachodnia')
        Names      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$script:ToEntity.Names.Add('Kupiec Orrin')
    [void]$script:ToEntity.Names.Add('Orrin')

    # Unchanged entity
    $script:UnchangedEntity = [PSCustomObject]@{
        Name       = 'Static NPC'
        Type       = 'NPC'
        Owner      = $null
        Location   = 'Erathia'
        Status     = 'Aktywny'
        Quantity   = $null
        NerthusName = $null
        Groups     = @()
        Doors      = @()
        Names      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$script:UnchangedEntity.Names.Add('Static NPC')

    # Build two "snapshots" (entity arrays at different times)
    $script:FromEntities = @($script:FromEntity, $script:UnchangedEntity)
    $script:ToEntities = @($script:ToEntity, $script:UnchangedEntity)
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Get-EntityDelta' {
    It 'detects scalar Location change' {
        $Result = Get-EntityDelta -Name 'Kupiec Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $LocChange = $Result | Where-Object { $_.Property -eq 'Lokacja' }
        $LocChange | Should -Not -BeNullOrEmpty
        $LocChange.Before | Should -Be 'Erathia'
        $LocChange.After | Should -Be 'Bracada'
    }

    It 'detects scalar Status change' {
        $Result = Get-EntityDelta -Name 'Kupiec Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $StatusChange = $Result | Where-Object { $_.Property -eq 'Status' }
        $StatusChange | Should -Not -BeNullOrEmpty
        $StatusChange.Before | Should -Be 'Aktywny'
        $StatusChange.After | Should -Be 'Nieaktywny'
    }

    It 'detects scalar Quantity change (null -> value)' {
        $Result = Get-EntityDelta -Name 'Kupiec Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $QtyChange = $Result | Where-Object { $_.Property -eq 'Ilość' }
        $QtyChange | Should -Not -BeNullOrEmpty
        $QtyChange.Before | Should -BeNullOrEmpty
        $QtyChange.After | Should -Be '5'
    }

    It 'detects multi-valued Groups change' {
        $Result = Get-EntityDelta -Name 'Kupiec Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $GroupChange = $Result | Where-Object { $_.Property -eq 'Grupy' }
        $GroupChange | Should -Not -BeNullOrEmpty
        $GroupChange.Before.Count | Should -Be 1
        $GroupChange.After.Count | Should -Be 2
        $GroupChange.After | Should -Contain 'Rada Handlowa'
    }

    It 'does not report unchanged properties' {
        $Result = Get-EntityDelta -Name 'Kupiec Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        # Type and Owner did not change
        $TypeChange = $Result | Where-Object { $_.Property -eq 'Typ' }
        $TypeChange | Should -BeNullOrEmpty

        $OwnerChange = $Result | Where-Object { $_.Property -eq 'Właściciel' }
        $OwnerChange | Should -BeNullOrEmpty
    }

    It 'does not report unchanged Doors' {
        $Result = Get-EntityDelta -Name 'Kupiec Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $DoorChange = $Result | Where-Object { $_.Property -eq 'Drzwi' }
        $DoorChange | Should -BeNullOrEmpty
    }

    It 'returns empty array for entity with no changes' {
        $Result = Get-EntityDelta -Name 'Static NPC' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $Result.Count | Should -Be 0
    }

    It 'returns empty array when entity not found in either snapshot' {
        $Result = Get-EntityDelta -Name 'Nonexistent' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $Result.Count | Should -Be 0
    }

    It 'handles entity appearing only in ToEntities (new entity)' {
        $NewEntity = [PSCustomObject]@{
            Name = 'New NPC'; Type = 'NPC'; Owner = $null; Location = 'Erathia'
            Status = 'Aktywny'; Quantity = $null; NerthusName = $null
            Groups = @(); Doors = @()
            Names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$NewEntity.Names.Add('New NPC')

        $Result = Get-EntityDelta -Name 'New NPC' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities @() -ToEntities @($NewEntity) -Quiet

        # Location, Status, Type should show as changed (null -> value)
        $Result.Count | Should -BeGreaterThan 0
        $LocChange = $Result | Where-Object { $_.Property -eq 'Lokacja' }
        $LocChange | Should -Not -BeNullOrEmpty
        $LocChange.Before | Should -BeNullOrEmpty
        $LocChange.After | Should -Be 'Erathia'
    }

    It 'handles entity disappearing from ToEntities (deleted entity)' {
        $OldEntity = [PSCustomObject]@{
            Name = 'Old NPC'; Type = 'NPC'; Owner = $null; Location = 'Deyja'
            Status = 'Aktywny'; Quantity = $null; NerthusName = $null
            Groups = @('Rebels'); Doors = @()
            Names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$OldEntity.Names.Add('Old NPC')

        $Result = Get-EntityDelta -Name 'Old NPC' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities @($OldEntity) -ToEntities @() -Quiet

        # Properties should show as changed (value -> null)
        $LocChange = $Result | Where-Object { $_.Property -eq 'Lokacja' }
        $LocChange | Should -Not -BeNullOrEmpty
        $LocChange.Before | Should -Be 'Deyja'
        $LocChange.After | Should -BeNullOrEmpty
    }

    It 'resolves entity by alias name' {
        $Result = Get-EntityDelta -Name 'Orrin' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities $script:FromEntities -ToEntities $script:ToEntities -Quiet

        $Result.Count | Should -BeGreaterThan 0
        $LocChange = $Result | Where-Object { $_.Property -eq 'Lokacja' }
        $LocChange.Before | Should -Be 'Erathia'
        $LocChange.After | Should -Be 'Bracada'
    }

    It 'detects Groups change from empty to populated' {
        $From = [PSCustomObject]@{
            Name = 'JoinedGroup'; Type = 'NPC'; Owner = $null; Location = $null
            Status = $null; Quantity = $null; NerthusName = $null
            Groups = @(); Doors = @()
            Names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$From.Names.Add('JoinedGroup')
        $To = [PSCustomObject]@{
            Name = 'JoinedGroup'; Type = 'NPC'; Owner = $null; Location = $null
            Status = $null; Quantity = $null; NerthusName = $null
            Groups = @('Rada'); Doors = @()
            Names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$To.Names.Add('JoinedGroup')

        $Result = Get-EntityDelta -Name 'JoinedGroup' -FromDate ([datetime]'2025-01-01') -ToDate ([datetime]'2025-06-01') `
            -FromEntities @($From) -ToEntities @($To) -Quiet

        $GroupChange = $Result | Where-Object { $_.Property -eq 'Grupy' }
        $GroupChange | Should -Not -BeNullOrEmpty
        $GroupChange.Before.Count | Should -Be 0
        $GroupChange.After | Should -Contain 'Rada'
    }
}

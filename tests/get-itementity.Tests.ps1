<#
    .SYNOPSIS
    Pester tests for Get-ItemEntity.

    .DESCRIPTION
    Tests for Get-ItemEntity covering filtering by owner, location, name,
    status exclusion, currency exclusion/inclusion, owner type resolution,
    quantity parsing, and enriched return objects. Uses mock entity objects
    to avoid dependency on Get-EntityState.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-get-item-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/Robot.PowerShell.psd1 -Force

    # Build mock entity objects matching the shape of Get-Entity output
    # Uses comma operator to prevent PowerShell single-element unwrapping
    function script:NewMockGenericNames {
        param([string[]]$Names)
        $List = [System.Collections.Generic.List[string]]::new()
        foreach ($N in $Names) { [void]$List.Add($N) }
        return ,$List
    }

    function script:NewMockHistory {
        param([object[]]$Entries)
        $List = [System.Collections.Generic.List[object]]::new()
        foreach ($E in $Entries) { [void]$List.Add($E) }
        return $List
    }

    # Owner entities (for OwnerType resolution)
    $script:MockEntities = @(
        # Postać (Physical owner)
        [PSCustomObject]@{
            Name            = 'Erdamon'
            Type            = 'Postać'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Solmyr'
            Location        = 'Erathia'
            Quantity        = $null
            QuantityHistory = $null
            Status          = 'Aktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # NPC (Virtual owner)
        [PSCustomObject]@{
            Name            = 'Kupiec Orrin'
            Type            = 'NPC'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = $null
            Location        = 'Erathia'
            Quantity        = $null
            QuantityHistory = $null
            Status          = 'Aktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # Gracz (Virtual owner)
        [PSCustomObject]@{
            Name            = 'Solmyr'
            Type            = 'Gracz'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = $null
            Location        = $null
            Quantity        = $null
            QuantityHistory = $null
            Status          = $null
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # Non-currency item owned by Postać
        [PSCustomObject]@{
            Name            = 'Miecz Słońca'
            Type            = 'Przedmiot'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = $null
            QuantityHistory = $null
            Status          = 'Aktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory @([PSCustomObject]@{ Value = 'Erdamon'; ValidFrom = [datetime]'2024-06-01'; ValidTo = $null })
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # Stackable non-currency item with explicit quantity
        [PSCustomObject]@{
            Name            = 'Mikstury Leczenia'
            Type            = 'Przedmiot'
            GenericNames    = NewMockGenericNames 'Mikstura Leczenia'
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Erdamon'
            Location        = 'Erathia'
            Quantity        = '5'
            QuantityHistory = NewMockHistory @([PSCustomObject]@{ Value = '5'; ValidFrom = [datetime]'2024-08-01'; ValidTo = $null })
            Status          = 'Aktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory @([PSCustomObject]@{ Value = 'Erdamon'; ValidFrom = [datetime]'2024-06-01'; ValidTo = $null })
            LocationHistory = NewMockHistory @([PSCustomObject]@{ Value = 'Erathia'; ValidFrom = [datetime]'2024-06-01'; ValidTo = $null })
            StatusHistory   = $null
        }
        # Non-currency item owned by NPC
        [PSCustomObject]@{
            Name            = 'Zwój Handlowy'
            Type            = 'Przedmiot'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Kupiec Orrin'
            Location        = 'Erathia'
            Quantity        = '10'
            QuantityHistory = $null
            Status          = 'Aktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # Currency entity (should be excluded by default)
        [PSCustomObject]@{
            Name            = 'Korony Erdamona'
            Type            = 'Przedmiot'
            GenericNames    = NewMockGenericNames 'Korony Elanckie'
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = '50'
            QuantityHistory = $null
            Status          = 'Aktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # Deleted item
        [PSCustomObject]@{
            Name            = 'Stary Miecz'
            Type            = 'Przedmiot'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = $null
            QuantityHistory = $null
            Status          = 'Usunięty'
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
        # Inactive item
        [PSCustomObject]@{
            Name            = 'Zardzewiały Topór'
            Type            = 'Przedmiot'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Names           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = $null
            QuantityHistory = $null
            Status          = 'Nieaktywny'
            Groups          = @()
            OwnerHistory    = NewMockHistory
            LocationHistory = NewMockHistory
            StatusHistory   = $null
        }
    )
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Get-ItemEntity' {
    It 'returns all active non-currency items by default' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Quiet
        $Result.Count | Should -Be 3
        $Result.EntityName | Should -Contain 'Miecz Słońca'
        $Result.EntityName | Should -Contain 'Mikstury Leczenia'
        $Result.EntityName | Should -Contain 'Zwój Handlowy'
    }

    It 'excludes currency entities by default' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Korony Erdamona'
    }

    It 'includes currency entities with -IncludeCurrency' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -IncludeCurrency -Quiet
        $Result.Count | Should -Be 4
        $Result.EntityName | Should -Contain 'Korony Erdamona'
    }

    It 'excludes Usunięty by default' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Stary Miecz'
    }

    It 'includes Usunięty with -IncludeDeleted' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -IncludeDeleted -Quiet
        $Result.EntityName | Should -Contain 'Stary Miecz'
    }

    It 'excludes Nieaktywny by default' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Zardzewiały Topór'
    }

    It 'includes Nieaktywny with -IncludeInactive' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -IncludeInactive -Quiet
        $Result.EntityName | Should -Contain 'Zardzewiały Topór'
    }

    It 'filters by owner' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Owner 'Kupiec Orrin' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Zwój Handlowy'
    }

    It 'filters by location' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Location 'Erathia' -Quiet
        $Result.Count | Should -Be 2
        $Result.EntityName | Should -Contain 'Mikstury Leczenia'
        $Result.EntityName | Should -Contain 'Zwój Handlowy'
    }

    It 'filters by name (substring, case-insensitive)' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'miecz' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Miecz Słońca'
    }

    It 'resolves OwnerType Physical for Postać owner' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'Miecz Słońca' -Quiet
        $Result[0].OwnerType | Should -Be 'Physical'
    }

    It 'resolves OwnerType Virtual for NPC owner' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Owner 'Kupiec Orrin' -Quiet
        $Result[0].OwnerType | Should -Be 'Virtual'
    }

    It 'defaults Quantity to 1 when @ilość is absent' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'Miecz Słońca' -Quiet
        $Result[0].Quantity | Should -Be 1
    }

    It 'parses Quantity from @ilość tag' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'Mikstury' -Quiet
        $Result[0].Quantity | Should -Be 5
    }

    It 'sets IsCurrency=false for non-currency items' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'Miecz Słońca' -Quiet
        $Result[0].IsCurrency | Should -BeFalse
    }

    It 'sets IsCurrency=true for currency items when included' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -IncludeCurrency -Name 'Korony' -Quiet
        $Result[0].IsCurrency | Should -BeTrue
        $Result[0].Denomination | Should -Be 'Korony Elanckie'
    }

    It 'sets Denomination to null for non-currency items' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'Miecz Słońca' -Quiet
        $Result[0].Denomination | Should -BeNullOrEmpty
    }

    It 'returns empty array when no matches' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Owner 'Nonexistent' -Quiet
        $Result.Count | Should -Be 0
    }

    It 'returns empty array with empty entity set' {
        $Result = Get-ItemEntity -Entities @() -Quiet
        $Result.Count | Should -Be 0
    }

    It 'combines multiple filters with AND logic' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Owner 'Erdamon' -Location 'Erathia' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Mikstury Leczenia'
    }

    It 'excludes non-Przedmiot entities' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Quiet
        $Result.EntityName | Should -Not -Contain 'Erdamon'
        $Result.EntityName | Should -Not -Contain 'Kupiec Orrin'
        $Result.EntityName | Should -Not -Contain 'Solmyr'
    }

    It 'returns LastChangeDate from history' {
        $Result = Get-ItemEntity -Entities $script:MockEntities -Name 'Mikstury' -Quiet
        $Result[0].LastChangeDate | Should -Not -BeNullOrEmpty
        $Result[0].LastChangeDate | Should -Be ([datetime]'2024-08-01')
    }
}

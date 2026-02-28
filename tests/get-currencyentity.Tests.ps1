<#
    .SYNOPSIS
    Pester tests for Get-CurrencyEntity.

    .DESCRIPTION
    Tests for Get-CurrencyEntity covering filtering by owner, denomination,
    name, status exclusion, and enriched return objects. Uses mock entity
    objects to avoid dependency on Get-EntityState.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-get-currency-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force

    # Build mock entity objects matching the shape of Get-Entity output
    function script:NewMockGenericNames {
        param([string[]]$Names)
        $List = [System.Collections.Generic.List[string]]::new()
        foreach ($N in $Names) { [void]$List.Add($N) }
        return $List
    }

    $script:MockEntities = @(
        [PSCustomObject]@{
            Name            = 'Korony Erdamon'
            Type            = 'Przedmiot'
            GenericNames    = NewMockGenericNames 'Korony Elanckie'
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = '50'
            QuantityHistory = @()
            Status          = 'Aktywny'
        }
        [PSCustomObject]@{
            Name            = 'Talary Erdamon'
            Type            = 'Przedmiot'
            GenericNames    = NewMockGenericNames 'Talary Hirońskie'
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = '200'
            QuantityHistory = @()
            Status          = 'Aktywny'
        }
        [PSCustomObject]@{
            Name            = 'Korony Kupiec Orrin'
            Type            = 'Przedmiot'
            GenericNames    = NewMockGenericNames 'Korony Elanckie'
            Owner           = 'Kupiec Orrin'
            Location        = $null
            Quantity        = '1000'
            QuantityHistory = @()
            Status          = 'Aktywny'
        }
        [PSCustomObject]@{
            Name            = 'Kogi Stare'
            Type            = 'Przedmiot'
            GenericNames    = NewMockGenericNames 'Kogi Skeltvorskie'
            Owner           = 'Kupiec Orrin'
            Location        = $null
            Quantity        = '0'
            QuantityHistory = @()
            Status          = 'Usunięty'
        }
        [PSCustomObject]@{
            Name            = 'Miecz Słońca'
            Type            = 'Przedmiot'
            GenericNames    = [System.Collections.Generic.List[string]]::new()
            Owner           = 'Erdamon'
            Location        = $null
            Quantity        = $null
            QuantityHistory = @()
            Status          = 'Aktywny'
        }
    )
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Get-CurrencyEntity' {
    It 'returns all active currency entities' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities
        $Result.Count | Should -Be 3
        $Result.EntityName | Should -Contain 'Korony Erdamon'
        $Result.EntityName | Should -Contain 'Talary Erdamon'
        $Result.EntityName | Should -Contain 'Korony Kupiec Orrin'
    }

    It 'excludes non-currency entities' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities
        $Result.EntityName | Should -Not -Contain 'Miecz Słońca'
    }

    It 'excludes Usunięty by default' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities
        $Result.EntityName | Should -Not -Contain 'Kogi Stare'
    }

    It 'includes Usunięty with -IncludeInactive' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -IncludeInactive
        $Result.Count | Should -Be 4
        $Result.EntityName | Should -Contain 'Kogi Stare'
    }

    It 'filters by owner' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -Owner 'Erdamon'
        $Result.Count | Should -Be 2
        $Result.EntityName | Should -Contain 'Korony Erdamon'
        $Result.EntityName | Should -Contain 'Talary Erdamon'
    }

    It 'filters by denomination' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -Denomination 'Korony'
        $Result.Count | Should -Be 2
        $Result.EntityName | Should -Contain 'Korony Erdamon'
        $Result.EntityName | Should -Contain 'Korony Kupiec Orrin'
    }

    It 'filters by name' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -Name 'Korony Erdamon'
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Korony Erdamon'
    }

    It 'returns enriched objects with denomination metadata' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -Name 'Korony Erdamon'
        $Result[0].Denomination | Should -Be 'Korony Elanckie'
        $Result[0].DenomShort | Should -Be 'Korony'
        $Result[0].Tier | Should -Be 'Gold'
        $Result[0].Balance | Should -Be 50
        $Result[0].Owner | Should -Be 'Erdamon'
        $Result[0].Status | Should -Be 'Aktywny'
    }

    It 'throws on unknown denomination filter' {
        { Get-CurrencyEntity -Entities $script:MockEntities -Denomination 'Złotówki' } |
            Should -Throw '*Unknown currency denomination*'
    }

    It 'resolves denomination by stem' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -Denomination 'tal'
        $Result.Count | Should -Be 1
        $Result[0].EntityName | Should -Be 'Talary Erdamon'
    }

    It 'returns empty array when no matches' {
        $Result = Get-CurrencyEntity -Entities $script:MockEntities -Owner 'Nonexistent'
        $Result.Count | Should -Be 0
    }
}

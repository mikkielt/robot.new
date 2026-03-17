<#
    .SYNOPSIS
    Pester tests for Resolve-Entity.

    .DESCRIPTION
    Tests for Resolve-Entity covering filtering by Owner, Location, Group,
    Type, Status, Name, and combinations. Verifies status defaults (excludes
    Usunięty/Nieaktywny), -IncludeInactive, -IncludeDeleted switches, name
    substring matching, and empty result sets. Uses mock entity objects.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-resolve-ent-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)

    function Get-RepoRoot { return $script:TempRoot }

    Import-Module $script:ModuleRoot/robot.psd1 -Force

    $script:MockEntities = @(
        [PSCustomObject]@{
            Name     = 'Kupiec Orrin'
            Type     = 'NPC'
            Owner    = $null
            Location = 'Erathia'
            Status   = 'Aktywny'
            Groups   = @('Kupcy Erathii')
        }
        [PSCustomObject]@{
            Name     = 'Rion'
            Type     = 'NPC'
            Owner    = $null
            Location = 'Erathia'
            Status   = 'Aktywny'
            Groups   = @('Rada Czarodziejów')
        }
        [PSCustomObject]@{
            Name     = 'Thant'
            Type     = 'NPC'
            Owner    = $null
            Location = 'Steadwick'
            Status   = 'Nieaktywny'
            Groups   = @()
        }
        [PSCustomObject]@{
            Name     = 'Erathia'
            Type     = 'Lokacja'
            Owner    = $null
            Location = 'Enroth'
            Status   = 'Aktywny'
            Groups   = @()
        }
        [PSCustomObject]@{
            Name     = 'Steadwick'
            Type     = 'Lokacja'
            Owner    = $null
            Location = 'Enroth'
            Status   = 'Aktywny'
            Groups   = @()
        }
        [PSCustomObject]@{
            Name     = 'Xeron Demonlord'
            Type     = 'Postać'
            Owner    = 'Solmyr'
            Location = 'Erathia'
            Status   = 'Aktywny'
            Groups   = @('Rada Czarodziejów')
        }
        [PSCustomObject]@{
            Name     = 'Miecz Armagedonu'
            Type     = 'Przedmiot'
            Owner    = 'Xeron Demonlord'
            Location = $null
            Status   = 'Aktywny'
            Groups   = @()
        }
        [PSCustomObject]@{
            Name     = 'Kupcy Erathii'
            Type     = 'Grupa'
            Owner    = $null
            Location = 'Erathia'
            Status   = 'Aktywny'
            Groups   = @()
        }
        [PSCustomObject]@{
            Name     = 'Stary NPC'
            Type     = 'NPC'
            Owner    = $null
            Location = 'Deyja'
            Status   = 'Usunięty'
            Groups   = @()
        }
        [PSCustomObject]@{
            Name     = 'Solmyr'
            Type     = 'Gracz'
            Owner    = $null
            Location = $null
            Status   = $null
            Groups   = @()
        }
    )
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Resolve-Entity' {
    It 'returns all active entities with no filters' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Quiet
        # Excludes Nieaktywny (Thant) and Usunięty (Stary NPC), includes null-status (Solmyr)
        $Result.Count | Should -Be 8
    }

    It 'excludes Usunięty by default' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Quiet
        $Result.Name | Should -Not -Contain 'Stary NPC'
    }

    It 'excludes Nieaktywny by default' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Quiet
        $Result.Name | Should -Not -Contain 'Thant'
    }

    It 'includes Usunięty with -IncludeDeleted' {
        $Result = Resolve-Entity -Entities $script:MockEntities -IncludeDeleted -Quiet
        $Result.Name | Should -Contain 'Stary NPC'
    }

    It 'includes Nieaktywny with -IncludeInactive' {
        $Result = Resolve-Entity -Entities $script:MockEntities -IncludeInactive -Quiet
        $Result.Name | Should -Contain 'Thant'
    }

    It 'filters by Type' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Type 'NPC' -Quiet
        $Result.Count | Should -Be 2
        $Result.Name | Should -Contain 'Kupiec Orrin'
        $Result.Name | Should -Contain 'Rion'
    }

    It 'filters by Type (Lokacja)' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Type 'Lokacja' -Quiet
        $Result.Count | Should -Be 2
        $Result.Name | Should -Contain 'Erathia'
        $Result.Name | Should -Contain 'Steadwick'
    }

    It 'filters by Location' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Location 'Erathia' -Quiet
        $Result.Count | Should -Be 4
        $Result.Name | Should -Contain 'Kupiec Orrin'
        $Result.Name | Should -Contain 'Rion'
        $Result.Name | Should -Contain 'Xeron Demonlord'
        $Result.Name | Should -Contain 'Kupcy Erathii'
    }

    It 'filters by Owner' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Owner 'Solmyr' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron Demonlord'
    }

    It 'filters by Owner (item owner)' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Owner 'Xeron Demonlord' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Miecz Armagedonu'
    }

    It 'filters by Group membership' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Group 'Rada Czarodziejów' -Quiet
        $Result.Count | Should -Be 2
        $Result.Name | Should -Contain 'Rion'
        $Result.Name | Should -Contain 'Xeron Demonlord'
    }

    It 'filters by Status value' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Status 'Nieaktywny' -IncludeInactive -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Thant'
    }

    It 'filters by Name (substring, case-insensitive)' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Name 'kupiec' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Kupiec Orrin'
    }

    It 'Name filter matches substring anywhere' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Name 'demon' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron Demonlord'
    }

    It 'combines Type and Location filters with AND logic' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Type 'NPC' -Location 'Erathia' -Quiet
        $Result.Count | Should -Be 2
        $Result.Name | Should -Contain 'Kupiec Orrin'
        $Result.Name | Should -Contain 'Rion'
    }

    It 'combines Owner and Type filters' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Owner 'Solmyr' -Type 'Postać' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Xeron Demonlord'
    }

    It 'combines Group and Location filters' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Group 'Kupcy Erathii' -Location 'Erathia' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Kupiec Orrin'
    }

    It 'returns original entity objects (passthrough)' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Name 'Xeron' -Quiet
        $Result[0] | Should -Be $script:MockEntities[5]
    }

    It 'returns empty array when no matches' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Owner 'Nonexistent' -Quiet
        $Result.Count | Should -Be 0
    }

    It 'returns empty array with empty entity set' {
        $Result = Resolve-Entity -Entities @() -Quiet
        $Result.Count | Should -Be 0
    }

    It 'handles entities with null Status as Aktywny' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Type 'Gracz' -Quiet
        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'Solmyr'
    }

    It 'Location filter with Nieaktywny entity excluded by default' {
        # Thant is at Steadwick but is Nieaktywny — excluded by default
        # Only active entity at Steadwick is... none (Steadwick has Location=Enroth)
        $Result = Resolve-Entity -Entities $script:MockEntities -Location 'Deyja' -Quiet
        $Result.Count | Should -Be 0
        # Stary NPC is at Deyja but is Usunięty, excluded by default
    }

    It 'Location filter with -IncludeInactive includes Nieaktywny' {
        $Result = Resolve-Entity -Entities $script:MockEntities -Location 'Steadwick' -IncludeInactive -Quiet
        $Result.Count | Should -Be 1
        $Result.Name | Should -Contain 'Thant'
    }
}

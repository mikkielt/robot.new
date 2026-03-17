<#
    .SYNOPSIS
    Pester tests for item @Transfer expansion and parser parity.

    .DESCRIPTION
    Tests that @Transfer supports both currency (amount + denomination) and
    item (amount-optional + item name) formats across all three parsers
    (PowerShell fallback, SessionTagParser.cs, SessionExtractor.cs).
    Validates symmetric @ilość deltas for item transfers in Get-EntityState.

    Item entities use @generyczne_nazwy as shared transfer identifiers
    (e.g., "Miecz Armagedonu" as generic name) while having unique primary
    names (e.g., "Miecz Armagedonu Xerona", "Miecz Armagedonu Brehona").
    The ByNameAndOwner lookup indexes ALL names including generic names,
    enabling transfer resolution by shared identifier + owner.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'public' 'get-entity.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'player' 'get-player.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-name.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-nameindex.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'resolve' 'resolve-narrator.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'session' 'get-session.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'get-entitystate.ps1')
}

Describe 'Parser: amount-optional @Transfer format' {
    BeforeAll {
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-item-transfer.md')
        $script:TransferSession = $script:Sessions | Where-Object { $_.Transfers -and $_.Transfers.Count -gt 0 }
    }

    It 'parses amount-less item transfer (Miecz Armagedonu) with Amount=1' {
        $Transfer = $script:TransferSession[0].Transfers | Where-Object { $_.Denomination -eq 'Miecz Armagedonu' }
        $Transfer | Should -Not -BeNullOrEmpty
        $Transfer.Amount | Should -Be 1
        $Transfer.Source | Should -Be 'Xeron Demonlord'
        $Transfer.Destination | Should -Be 'Brehon'
    }

    It 'parses amount + item name transfer (2 Mikstura Leczenia)' {
        $Transfer = $script:TransferSession[0].Transfers | Where-Object { $_.Denomination -eq 'Mikstura Leczenia' }
        $Transfer | Should -Not -BeNullOrEmpty
        $Transfer.Amount | Should -Be 2
        $Transfer.Source | Should -Be 'Xeron Demonlord'
        $Transfer.Destination | Should -Be 'Brehon'
    }

    It 'parses currency transfer (20 koron) with numeric amount' {
        $Transfer = $script:TransferSession[0].Transfers | Where-Object { $_.Denomination -eq 'koron' }
        $Transfer | Should -Not -BeNullOrEmpty
        $Transfer.Amount | Should -Be 20
        $Transfer.Source | Should -Be 'Xeron Demonlord'
        $Transfer.Destination | Should -Be 'Kupiec Orrin'
    }

    It 'extracts all three transfers from session' {
        $script:TransferSession[0].Transfers.Count | Should -Be 3
    }
}

Describe 'Get-EntityState - item @Transfer expansion' {
    BeforeAll {
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-item-transfer.md')
        $script:Sessions = Get-Session -File (Join-Path $script:FixturesRoot 'sessions-item-transfer.md')
        $script:Enriched = Get-EntityState -Entities $script:Entities -Sessions $script:Sessions -Quiet
    }

    It 'applies unique item transfer (Miecz Armagedonu) as symmetric @ilość deltas' {
        # Source: "Miecz Armagedonu Xerona" has generic name "Miecz Armagedonu", owned by Xeron
        # Base @ilość: 1, transfer -1 = 0
        $Source = $script:Enriched | Where-Object { $_.Name -eq 'Miecz Armagedonu Xerona' }
        $Source | Should -Not -BeNullOrEmpty
        $Source.Quantity | Should -Be '0'

        # Destination: "Miecz Armagedonu Brehona" has generic name "Miecz Armagedonu", owned by Brehon
        # Base @ilość: 0, transfer +1 = 1
        $Dest = $script:Enriched | Where-Object { $_.Name -eq 'Miecz Armagedonu Brehona' }
        $Dest | Should -Not -BeNullOrEmpty
        $Dest.Quantity | Should -Be '1'
    }

    It 'applies stackable item transfer (2 Mikstura Leczenia) as symmetric @ilość deltas' {
        # Source: "Mikstury Leczenia Xerona" has generic name "Mikstura Leczenia", owned by Xeron
        # Base @ilość: 5, transfer -2 = 3
        $Source = $script:Enriched | Where-Object { $_.Name -eq 'Mikstury Leczenia Xerona' }
        $Source | Should -Not -BeNullOrEmpty
        $Source.Quantity | Should -Be '3'

        # Destination: "Mikstury Leczenia Brehona" has generic name "Mikstura Leczenia", owned by Brehon
        # Base @ilość: 3, transfer +2 = 5
        $Dest = $script:Enriched | Where-Object { $_.Name -eq 'Mikstury Leczenia Brehona' }
        $Dest | Should -Not -BeNullOrEmpty
        $Dest.Quantity | Should -Be '5'
    }

    It 'applies currency transfer alongside item transfers (regression guard)' {
        # Currency: 20 koron, Xeron -> Kupiec Orrin
        # Source: Korony Xeron Demonlorda base 100, -20 = 80
        $Source = $script:Enriched | Where-Object { $_.Name -eq 'Korony Xeron Demonlorda' }
        $Source | Should -Not -BeNullOrEmpty
        $Source.Quantity | Should -Be '80'

        # Destination: Korony Kupca Orrina base 50, +20 = 70
        $Dest = $script:Enriched | Where-Object { $_.Name -eq 'Korony Kupca Orrina' }
        $Dest | Should -Not -BeNullOrEmpty
        $Dest.Quantity | Should -Be '70'
    }
}

Describe 'Get-EntityState - item @Transfer unresolved destination' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
        $EntPath = Join-Path $script:TempDir 'entities.md'
        $SessPath = Join-Path $script:TempDir 'sessions.md'

        # Only Xeron has the item; Brehon does NOT have a matching entity
        Write-TestFile -Path $EntPath -Content @"
## Gracz

* Solmyr
    - @margonemid: 12345

## Postać

* Xeron Demonlord
    - @należy_do: Solmyr

* Brehon
    - @należy_do: Solmyr

## Przedmiot

* Zaklęty Miecz
    - @należy_do: Xeron Demonlord (2024-06:)
    - @ilość: 1 (2024-06:)
    - @status: Aktywny (2024-06:)
"@

        Write-TestFile -Path $SessPath -Content @"
# Sesje

## Historia

### 2025-08-01, Nieudany transfer, Solmyr

- @Transfer: Zaklęty Miecz, Xeron Demonlord -> Brehon
"@

        $script:UnresolvedEntities = Get-Entity -Path $script:TempDir
        $script:UnresolvedSessions = Get-Session -File $SessPath
    }

    AfterAll {
        Remove-TestTempDir
    }

    It 'skips transfer when destination item entity is missing' {
        $Enriched = Get-EntityState -Entities $script:UnresolvedEntities -Sessions $script:UnresolvedSessions -Quiet
        # Source should remain unchanged (transfer was skipped)
        $Source = $Enriched | Where-Object { $_.Name -eq 'Zaklęty Miecz' }
        $Source | Should -Not -BeNullOrEmpty
        $Source.Quantity | Should -Be '1'
    }
}

Describe 'item-helpers: Build-ItemLookup' {
    BeforeAll {
        . (Join-Path $script:ModuleRoot 'private' 'item-helpers.ps1')
        . (Join-Path $script:ModuleRoot 'private' 'currency-helpers.ps1')

        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-item-transfer.md')
        $script:DenomNames = @($script:CurrencyDenominations | ForEach-Object { $_.Name })
        $script:Lookup = Build-ItemLookup -Entities $script:Entities -DenominationNames $script:DenomNames
    }

    It 'builds ByNameAndOwner index for Przedmiot entities' {
        $script:Lookup.ByNameAndOwner.Count | Should -BeGreaterThan 0
    }

    It 'builds ByDenomAndOwner index for currency entities' {
        $script:Lookup.ByDenomAndOwner.Count | Should -BeGreaterThan 0
    }

    It 'finds item by generic name and owner' {
        # "Miecz Armagedonu Xerona" has @generyczne_nazwy: Miecz Armagedonu
        $Found = Find-ItemByNameAndOwner -Lookup $script:Lookup -ItemName 'Miecz Armagedonu' -OwnerName 'Xeron Demonlord'
        $Found | Should -Not -BeNullOrEmpty
        $Found.Name | Should -Be 'Miecz Armagedonu Xerona'
    }

    It 'finds item by primary name and owner' {
        $Found = Find-ItemByNameAndOwner -Lookup $script:Lookup -ItemName 'Miecz Armagedonu Xerona' -OwnerName 'Xeron Demonlord'
        $Found | Should -Not -BeNullOrEmpty
        $Found.Name | Should -Be 'Miecz Armagedonu Xerona'
    }

    It 'finds currency entity by denomination and owner' {
        $Found = Find-ItemByDenomAndOwner -Lookup $script:Lookup -Denomination 'Korony Elanckie' -OwnerName 'Xeron Demonlord'
        $Found | Should -Not -BeNullOrEmpty
        $Found.Name | Should -Be 'Korony Xeron Demonlorda'
    }

    It 'returns null for missing item' {
        $Found = Find-ItemByNameAndOwner -Lookup $script:Lookup -ItemName 'Nieistniejący Przedmiot' -OwnerName 'Xeron Demonlord'
        $Found | Should -BeNullOrEmpty
    }

    It 'counts items and currency separately' {
        $script:Lookup.ItemCount | Should -BeGreaterThan 0
        $script:Lookup.CurrencyCount | Should -BeGreaterThan 0
        $script:Lookup.ItemCount | Should -BeGreaterOrEqual $script:Lookup.CurrencyCount
    }
}

Describe 'item-helpers: Resolve-ItemOwnerType' {
    BeforeAll {
        . (Join-Path $script:ModuleRoot 'private' 'item-helpers.ps1')
        $script:Entities = Get-Entity -Path (Join-Path $script:FixturesRoot 'entities-item-transfer.md')

        $script:EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Entity in $script:Entities) {
            foreach ($Name in $Entity.Names) {
                if (-not $script:EntityLookup.ContainsKey($Name)) {
                    $script:EntityLookup[$Name] = $Entity
                }
            }
        }
    }

    It 'classifies Postać owner as Physical' {
        $Type = Resolve-ItemOwnerType -OwnerName 'Xeron Demonlord' -EntityLookup $script:EntityLookup
        $Type | Should -Be 'Physical'
    }

    It 'classifies NPC owner as Virtual' {
        $Type = Resolve-ItemOwnerType -OwnerName 'Kupiec Orrin' -EntityLookup $script:EntityLookup
        $Type | Should -Be 'Virtual'
    }

    It 'classifies unknown owner as Unknown' {
        $Type = Resolve-ItemOwnerType -OwnerName 'Nieznany' -EntityLookup $script:EntityLookup
        $Type | Should -Be 'Unknown'
    }
}

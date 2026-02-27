BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/currency-helpers.ps1"
}

Describe 'ConvertTo-CurrencyBaseUnit' {
    It 'converts Korony to Kogi' {
        ConvertTo-CurrencyBaseUnit -Amount 3 -Denomination 'Korony Elanckie' | Should -Be 30000
    }

    It 'converts Talary to Kogi' {
        ConvertTo-CurrencyBaseUnit -Amount 50 -Denomination 'Talary Hirońskie' | Should -Be 5000
    }

    It 'converts Kogi to Kogi (identity)' {
        ConvertTo-CurrencyBaseUnit -Amount 250 -Denomination 'Kogi Skeltvorskie' | Should -Be 250
    }

    It 'accepts colloquial denomination names via stem matching' {
        ConvertTo-CurrencyBaseUnit -Amount 1 -Denomination 'koron' | Should -Be 10000
        ConvertTo-CurrencyBaseUnit -Amount 1 -Denomination 'talarów' | Should -Be 100
        ConvertTo-CurrencyBaseUnit -Amount 1 -Denomination 'kogi' | Should -Be 1
    }

    It 'throws on unknown denomination' {
        { ConvertTo-CurrencyBaseUnit -Amount 1 -Denomination 'złotówki' } | Should -Throw
    }
}

Describe 'ConvertFrom-CurrencyBaseUnit' {
    It 'converts Kogi to breakdown' {
        $Result = ConvertFrom-CurrencyBaseUnit -Amount 35250
        $Result.Korony | Should -Be 3
        $Result.Talary | Should -Be 52
        $Result.Kogi   | Should -Be 50
    }

    It 'handles zero' {
        $Result = ConvertFrom-CurrencyBaseUnit -Amount 0
        $Result.Korony | Should -Be 0
        $Result.Talary | Should -Be 0
        $Result.Kogi   | Should -Be 0
    }

    It 'handles exact denomination boundaries' {
        $Result = ConvertFrom-CurrencyBaseUnit -Amount 10000
        $Result.Korony | Should -Be 1
        $Result.Talary | Should -Be 0
        $Result.Kogi   | Should -Be 0
    }

    It 'handles negative amounts' {
        $Result = ConvertFrom-CurrencyBaseUnit -Amount -5050
        $Result.Korony | Should -Be 0
        $Result.Talary | Should -Be -50
        $Result.Kogi   | Should -Be -50
    }
}

Describe 'Resolve-CurrencyDenomination' {
    It 'resolves canonical name' {
        $Result = Resolve-CurrencyDenomination -Name 'Korony Elanckie'
        $Result.Name | Should -Be 'Korony Elanckie'
        $Result.Multiplier | Should -Be 10000
    }

    It 'resolves short name' {
        $Result = Resolve-CurrencyDenomination -Name 'Talary'
        $Result.Name | Should -Be 'Talary Hirońskie'
    }

    It 'resolves stem kor -> Korony' {
        $Result = Resolve-CurrencyDenomination -Name 'koron'
        $Result.Name | Should -Be 'Korony Elanckie'
    }

    It 'resolves stem tal -> Talary' {
        $Result = Resolve-CurrencyDenomination -Name 'talarów'
        $Result.Name | Should -Be 'Talary Hirońskie'
    }

    It 'resolves stem kog -> Kogi' {
        $Result = Resolve-CurrencyDenomination -Name 'kogów'
        $Result.Name | Should -Be 'Kogi Skeltvorskie'
    }

    It 'returns null for unknown denomination' {
        Resolve-CurrencyDenomination -Name 'złotówki' | Should -BeNullOrEmpty
    }

    It 'is case insensitive' {
        $Result = Resolve-CurrencyDenomination -Name 'KORONY ELANCKIE'
        $Result.Name | Should -Be 'Korony Elanckie'
    }
}

Describe 'Test-IsCurrencyEntity' {
    It 'returns true for entity with currency GenericNames' {
        $Entity = [PSCustomObject]@{
            GenericNames = [System.Collections.Generic.List[string]]@('Korony Elanckie')
        }
        Test-IsCurrencyEntity -Entity $Entity | Should -Be $true
    }

    It 'returns false for entity with non-currency GenericNames' {
        $Entity = [PSCustomObject]@{
            GenericNames = [System.Collections.Generic.List[string]]@('Strażnik Miasta')
        }
        Test-IsCurrencyEntity -Entity $Entity | Should -Be $false
    }

    It 'returns false for entity with no GenericNames' {
        $Entity = [PSCustomObject]@{
            GenericNames = [System.Collections.Generic.List[string]]::new()
        }
        Test-IsCurrencyEntity -Entity $Entity | Should -Be $false
    }
}

Describe 'Find-CurrencyEntity' {
    BeforeAll {
        $script:TestEntities = @(
            [PSCustomObject]@{
                Name         = 'Korony Xerona'
                Type         = 'Przedmiot'
                Owner        = 'Xeron Demonlord'
                GenericNames = [System.Collections.Generic.List[string]]@('Korony Elanckie')
            }
            [PSCustomObject]@{
                Name         = 'Talary Xerona'
                Type         = 'Przedmiot'
                Owner        = 'Xeron Demonlord'
                GenericNames = [System.Collections.Generic.List[string]]@('Talary Hirońskie')
            }
            [PSCustomObject]@{
                Name         = 'Korony Orrina'
                Type         = 'Przedmiot'
                Owner        = 'Kupiec Orrin'
                GenericNames = [System.Collections.Generic.List[string]]@('Korony Elanckie')
            }
        )
    }

    It 'finds entity by denomination and owner' {
        $Result = Find-CurrencyEntity -Entities $script:TestEntities -Denomination 'Korony Elanckie' -OwnerName 'Xeron Demonlord'
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Korony Xerona'
    }

    It 'finds entity with stem denomination name' {
        $Result = Find-CurrencyEntity -Entities $script:TestEntities -Denomination 'koron' -OwnerName 'Kupiec Orrin'
        $Result | Should -Not -BeNullOrEmpty
        $Result.Name | Should -Be 'Korony Orrina'
    }

    It 'returns null when owner does not match' {
        $Result = Find-CurrencyEntity -Entities $script:TestEntities -Denomination 'Korony Elanckie' -OwnerName 'Nobody'
        $Result | Should -BeNullOrEmpty
    }

    It 'returns null when denomination does not match' {
        $Result = Find-CurrencyEntity -Entities $script:TestEntities -Denomination 'Kogi Skeltvorskie' -OwnerName 'Xeron Demonlord'
        $Result | Should -BeNullOrEmpty
    }
}

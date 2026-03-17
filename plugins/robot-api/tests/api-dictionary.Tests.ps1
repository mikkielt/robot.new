BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiNameDictionary' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiNameDictionary').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiNameDictionary not compiled'
        }
    }

    Context 'ResolveCanonical — entity types' {
        It 'resolves English label to Polish canonical' {
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'item') |
                Should -Be 'Przedmiot'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'location') |
                Should -Be 'Lokacja'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'character') |
                Should -BeExactly 'Postać'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'group') |
                Should -Be 'Grupa'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'map') |
                Should -Be 'Mapa'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'player') |
                Should -Be 'Gracz'
        }

        It 'passes through already-canonical values' {
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'NPC') |
                Should -Be 'NPC'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'Lokacja') |
                Should -Be 'Lokacja'
        }

        It 'is case-insensitive' {
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'ITEM') |
                Should -Be 'Przedmiot'
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'lokacja') |
                Should -Be 'Lokacja'
        }

        It 'passes through unknown values unchanged' {
            [Robot.ApiNameDictionary]::ResolveCanonical('type', 'CustomType') |
                Should -Be 'CustomType'
        }
    }

    Context 'ResolveCanonical — statuses' {
        It 'resolves status labels' {
            [Robot.ApiNameDictionary]::ResolveCanonical('status', 'active') |
                Should -Be 'Aktywny'
            [Robot.ApiNameDictionary]::ResolveCanonical('status', 'inactive') |
                Should -Be 'Nieaktywny'
            [Robot.ApiNameDictionary]::ResolveCanonical('status', 'deleted') |
                Should -BeExactly 'Usunięty'
        }

        It 'passes through canonical status values' {
            [Robot.ApiNameDictionary]::ResolveCanonical('status', 'Aktywny') |
                Should -Be 'Aktywny'
        }
    }

    Context 'ResolveCanonical — seasons' {
        It 'resolves season labels' {
            [Robot.ApiNameDictionary]::ResolveCanonical('season', 'spring') |
                Should -Be 'wiosna'
            [Robot.ApiNameDictionary]::ResolveCanonical('season', 'summer') |
                Should -Be 'lato'
            [Robot.ApiNameDictionary]::ResolveCanonical('season', 'autumn') |
                Should -BeExactly 'jesień'
            [Robot.ApiNameDictionary]::ResolveCanonical('season', 'winter') |
                Should -Be 'zima'
        }
    }

    Context 'ResolveCanonical — denominations' {
        It 'resolves denomination labels to full canonical names' {
            [Robot.ApiNameDictionary]::ResolveCanonical('denomination', 'gold') |
                Should -Be 'Korony Elanckie'
            [Robot.ApiNameDictionary]::ResolveCanonical('denomination', 'silver') |
                Should -BeExactly 'Talary Hirońskie'
            [Robot.ApiNameDictionary]::ResolveCanonical('denomination', 'copper') |
                Should -BeExactly 'Kogi Skeltvorskie'
        }

        It 'passes through canonical denomination values' {
            [Robot.ApiNameDictionary]::ResolveCanonical('denomination', 'Korony') |
                Should -Be 'Korony'
        }
    }

    Context 'ResolveCanonical — session formats' {
        It 'resolves format labels' {
            [Robot.ApiNameDictionary]::ResolveCanonical('format', 'tagged') |
                Should -Be 'Gen4'
            [Robot.ApiNameDictionary]::ResolveCanonical('format', 'legacy') |
                Should -Be 'Gen1'
        }
    }

    Context 'ResolveCanonical — participation sources' {
        It 'resolves source labels' {
            [Robot.ApiNameDictionary]::ResolveCanonical('source', 'filesystem') |
                Should -Be 'FilePath'
            [Robot.ApiNameDictionary]::ResolveCanonical('source', 'skillPoints') |
                Should -Be 'PU'
        }
    }

    Context 'ResolveCanonical — edge cases' {
        It 'handles null input' {
            [Robot.ApiNameDictionary]::ResolveCanonical('type', $null) |
                Should -BeNullOrEmpty
            [Robot.ApiNameDictionary]::ResolveCanonical('type', '') |
                Should -Be ''
        }
    }

    Context 'GetLabel' {
        It 'returns English label for Polish canonical type' {
            [Robot.ApiNameDictionary]::GetLabel('type', 'Przedmiot') |
                Should -Be 'item'
            [Robot.ApiNameDictionary]::GetLabel('type', 'Lokacja') |
                Should -Be 'location'
            [Robot.ApiNameDictionary]::GetLabel('type', 'NPC') |
                Should -Be 'npc'
        }

        It 'returns English label for Polish canonical status' {
            [Robot.ApiNameDictionary]::GetLabel('status', 'Aktywny') |
                Should -Be 'active'
            [Robot.ApiNameDictionary]::GetLabel('status', 'Usunięty') |
                Should -Be 'deleted'
        }

        It 'returns null for unknown values' {
            [Robot.ApiNameDictionary]::GetLabel('type', 'UnknownType') |
                Should -BeNullOrEmpty
        }

        It 'returns null for null input' {
            [Robot.ApiNameDictionary]::GetLabel('type', $null) |
                Should -BeNullOrEmpty
        }

        It 'supports owner type category' {
            [Robot.ApiNameDictionary]::GetLabel('ownerType', 'Physical') |
                Should -Be 'physical'
            [Robot.ApiNameDictionary]::GetLabel('ownerType', 'Virtual') |
                Should -Be 'virtual'
        }
    }

    Context 'GetSchema' {
        BeforeAll {
            $Schema = [Robot.ApiNameDictionary]::GetSchema()
        }

        It 'returns all expected categories' {
            $Schema.Keys | Should -Contain 'entityTypes'
            $Schema.Keys | Should -Contain 'statuses'
            $Schema.Keys | Should -Contain 'tags'
            $Schema.Keys | Should -Contain 'seasons'
            $Schema.Keys | Should -Contain 'denominations'
            $Schema.Keys | Should -Contain 'formats'
            $Schema.Keys | Should -Contain 'sources'
            $Schema.Keys | Should -Contain 'directives'
            $Schema.Keys | Should -Contain 'ownerTypes'
        }

        It 'has 7 entity types' {
            $Schema['entityTypes'].Count | Should -Be 7
        }

        It 'has 3 statuses' {
            $Schema['statuses'].Count | Should -Be 3
        }

        It 'has 14 tags' {
            $Schema['tags'].Count | Should -Be 14
        }

        It 'has 4 seasons' {
            $Schema['seasons'].Count | Should -Be 4
        }

        It 'has 3 denominations with multiplier field' {
            $Schema['denominations'].Count | Should -Be 3
            $Gold = $Schema['denominations'] | Where-Object { $_['label'] -eq 'gold' }
            $Gold['multiplier'] | Should -Be '10000'
            $Gold['short'] | Should -Be 'Korony'
        }

        It 'has 4 session formats' {
            $Schema['formats'].Count | Should -Be 4
        }

        It 'has 5 participation sources' {
            $Schema['sources'].Count | Should -Be 5
        }

        It 'has 3 intel directives' {
            $Schema['directives'].Count | Should -Be 3
        }

        It 'has 3 owner types' {
            $Schema['ownerTypes'].Count | Should -Be 3
        }

        It 'each entry has canonical and label keys' {
            foreach ($Entry in $Schema['entityTypes']) {
                $Entry.Keys | Should -Contain 'canonical'
                $Entry.Keys | Should -Contain 'label'
            }
        }
    }
}

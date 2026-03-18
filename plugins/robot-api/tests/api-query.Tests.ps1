BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiQueryParser' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiQueryParser').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiQueryParser not compiled'
        }
    }

    Context 'ParseFilter' {
        It 'parses simple equality' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('type==NPC')
            $Groups.Count | Should -Be 1
            $Groups[0].Conditions[0].Field | Should -Be 'type'
            $Groups[0].Conditions[0].Operator | Should -Be 'eq'
            $Groups[0].Conditions[0].Value | Should -Be 'NPC'
        }

        It 'parses not-equal' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('status!=Usunięty')
            $Groups[0].Conditions[0].Operator | Should -Be 'neq'
            $Groups[0].Conditions[0].Value | Should -Be 'Usunięty'
        }

        It 'parses AND groups with semicolons' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('type==Lokacja;status!=Usunięty')
            $Groups.Count | Should -Be 2
            $Groups[0].Conditions[0].Field | Should -Be 'type'
            $Groups[1].Conditions[0].Field | Should -Be 'status'
        }

        It 'parses OR conditions with commas' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('status==Aktywny,status==Nieaktywny')
            $Groups.Count | Should -Be 1
            $Groups[0].Conditions.Count | Should -Be 2
        }

        It 'parses in-set operator' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('type=in=(NPC,Lokacja,Przedmiot)')
            $Groups[0].Conditions[0].Operator | Should -Be 'in'
            $Groups[0].Conditions[0].Values.Count | Should -Be 3
        }

        It 'parses out-set operator' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('type=out=(Mapa)')
            $Groups[0].Conditions[0].Operator | Should -Be 'out'
        }

        It 'parses like operator' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('name=like=Sol*')
            $Groups[0].Conditions[0].Operator | Should -Be 'like'
            $Groups[0].Conditions[0].Value | Should -Be 'Sol*'
        }

        It 'parses comparison operators' {
            $Groups = [Robot.ApiQueryParser]::ParseFilter('name=gt=A')
            $Groups[0].Conditions[0].Operator | Should -Be 'gt'

            $Groups = [Robot.ApiQueryParser]::ParseFilter('name=le=Z')
            $Groups[0].Conditions[0].Operator | Should -Be 'le'
        }

        It 'returns empty for null/whitespace' {
            [Robot.ApiQueryParser]::ParseFilter($null).Count | Should -Be 0
            [Robot.ApiQueryParser]::ParseFilter('').Count | Should -Be 0
            [Robot.ApiQueryParser]::ParseFilter('   ').Count | Should -Be 0
        }
    }

    Context 'EvaluateCondition' {
        It 'evaluates eq case-insensitively' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'type'; $Cond.Operator = 'eq'; $Cond.Value = 'npc'
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'NPC') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Lokacja') | Should -BeFalse
        }

        It 'evaluates neq' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'status'; $Cond.Operator = 'neq'; $Cond.Value = 'Usunięty'
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Aktywny') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Usunięty') | Should -BeFalse
        }

        It 'evaluates gt/ge/lt/le' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'name'; $Cond.Operator = 'gt'; $Cond.Value = 'M'
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Solmyr') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Alek') | Should -BeFalse
        }

        It 'evaluates in-set' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'type'; $Cond.Operator = 'in'
            $Cond.Values = @('NPC', 'Lokacja')
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Lokacja') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Przedmiot') | Should -BeFalse
        }

        It 'evaluates out-set' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'type'; $Cond.Operator = 'out'
            $Cond.Values = @('Mapa')
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'NPC') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Mapa') | Should -BeFalse
        }

        It 'evaluates like with wildcard' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'name'; $Cond.Operator = 'like'; $Cond.Value = 'Sol*'
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Solmyr') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Alek') | Should -BeFalse
        }

        It 'handles null property value as empty string' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'owner'; $Cond.Operator = 'eq'; $Cond.Value = ''
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, $null) | Should -BeTrue
        }

        It 'resolves English aliases for known fields' {
            # type==item should match Przedmiot (via dictionary alias resolution)
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'type'; $Cond.Operator = 'eq'; $Cond.Value = 'item'
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Przedmiot') | Should -BeTrue
        }

        It 'resolves English aliases for in-set operator' {
            $Cond = [Robot.FilterCondition]::new()
            $Cond.Field = 'type'; $Cond.Operator = 'in'
            $Cond.Values = @('item', 'location', 'npc')
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Przedmiot') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Lokacja') | Should -BeTrue
            [Robot.ApiQueryParser]::EvaluateCondition($Cond, 'Grupa') | Should -BeFalse
        }
    }

    Context 'ParseSort' {
        It 'parses ascending and descending fields' {
            $Fields = [Robot.ApiQueryParser]::ParseSort('-name,type,+status')
            $Fields.Count | Should -Be 3
            $Fields[0].Field | Should -Be 'name'
            $Fields[0].Descending | Should -BeTrue
            $Fields[1].Field | Should -Be 'type'
            $Fields[1].Descending | Should -BeFalse
            $Fields[2].Field | Should -Be 'status'
            $Fields[2].Descending | Should -BeFalse
        }

        It 'returns empty for null input' {
            [Robot.ApiQueryParser]::ParseSort($null).Count | Should -Be 0
        }
    }

    Context 'ParseFields' {
        It 'returns null for empty input (all fields)' {
            [Robot.ApiQueryParser]::ParseFields($null) | Should -BeNullOrEmpty
            [Robot.ApiQueryParser]::ParseFields('') | Should -BeNullOrEmpty
        }

        It 'returns field set' {
            $FS = [Robot.ApiQueryParser]::ParseFields('name,type,status')
            $FS.Count | Should -Be 3
            $FS.Contains('name') | Should -BeTrue
            $FS.Contains('type') | Should -BeTrue
        }

        It 'is case-insensitive' {
            $FS = [Robot.ApiQueryParser]::ParseFields('Name,TYPE')
            $FS.Contains('name') | Should -BeTrue
        }
    }

    Context 'Pagination' {
        It 'uses default page size of 50' {
            $QP = [System.Collections.Generic.Dictionary[string,string]]::new()
            $P = [Robot.ApiQueryParser]::ParsePage($QP)
            $P.Size | Should -Be 50
        }

        It 'clamps page size to max 500' {
            $QP = [System.Collections.Generic.Dictionary[string,string]]::new()
            $QP['page[size]'] = '9999'
            $P = [Robot.ApiQueryParser]::ParsePage($QP)
            $P.Size | Should -Be 500
        }

        It 'clamps page size to min 1' {
            $QP = [System.Collections.Generic.Dictionary[string,string]]::new()
            $QP['page[size]'] = '0'
            $P = [Robot.ApiQueryParser]::ParsePage($QP)
            $P.Size | Should -Be 1
        }

        It 'decodes base64 cursor' {
            $Cursor = [Robot.ApiQueryParser]::EncodeCursor('Solmyr')
            $QP = [System.Collections.Generic.Dictionary[string,string]]::new()
            $QP['page[after]'] = $Cursor
            $P = [Robot.ApiQueryParser]::ParsePage($QP)
            $P.AfterCursor | Should -Be 'Solmyr'
        }

        It 'ignores invalid base64 cursor' {
            $QP = [System.Collections.Generic.Dictionary[string,string]]::new()
            $QP['page[after]'] = '!!!invalid!!!'
            $P = [Robot.ApiQueryParser]::ParsePage($QP)
            $P.AfterCursor | Should -BeNullOrEmpty
        }
    }

    Context 'Entity field access' {
        BeforeAll {
            if (-not ([System.Management.Automation.PSTypeName]'Robot.Entity').Type) {
                Set-ItResult -Skipped -Because 'Robot.Entity not compiled'
            }
        }

        It 'returns entity property values by field name' {
            $E = [Robot.Entity]::new()
            $E.Name = 'Solmyr'
            $E.Type = 'NPC'
            $E.Status = 'Aktywny'

            [Robot.ApiQueryParser]::GetEntityField($E, 'name') | Should -Be 'Solmyr'
            [Robot.ApiQueryParser]::GetEntityField($E, 'type') | Should -Be 'NPC'
            [Robot.ApiQueryParser]::GetEntityField($E, 'status') | Should -Be 'Aktywny'
        }

        It 'is case-insensitive for field names' {
            $E = [Robot.Entity]::new()
            $E.Name = 'Test'
            [Robot.ApiQueryParser]::GetEntityField($E, 'NAME') | Should -Be 'Test'
        }

        It 'returns null for unknown fields' {
            $E = [Robot.Entity]::new()
            [Robot.ApiQueryParser]::GetEntityField($E, 'nonexistent') | Should -BeNullOrEmpty
        }
    }

    Context 'FilterEntities' {
        BeforeAll {
            if (-not ([System.Management.Automation.PSTypeName]'Robot.Entity').Type) {
                Set-ItResult -Skipped -Because 'Robot.Entity not compiled'
            }
        }

        It 'filters entities by type' {
            $E1 = [Robot.Entity]::new(); $E1.Name = 'NPC1'; $E1.Type = 'NPC'
            $E2 = [Robot.Entity]::new(); $E2.Name = 'Loc1'; $E2.Type = 'Lokacja'
            $E3 = [Robot.Entity]::new(); $E3.Name = 'NPC2'; $E3.Type = 'NPC'
            $List = [System.Collections.Generic.List[Robot.Entity]]::new()
            $List.Add($E1); $List.Add($E2); $List.Add($E3)

            $Groups = [Robot.ApiQueryParser]::ParseFilter('type==NPC')
            $Result = [Robot.ApiQueryParser]::FilterEntities($List, $Groups)
            $Result.Count | Should -Be 2
        }

        It 'returns all entities with empty filter' {
            $E1 = [Robot.Entity]::new(); $E1.Name = 'A'
            $List = [System.Collections.Generic.List[Robot.Entity]]::new()
            $List.Add($E1)

            $Groups = [Robot.ApiQueryParser]::ParseFilter('')
            $Result = [Robot.ApiQueryParser]::FilterEntities($List, $Groups)
            $Result.Count | Should -Be 1
        }
    }

    Context 'SortEntities' {
        BeforeAll {
            if (-not ([System.Management.Automation.PSTypeName]'Robot.Entity').Type) {
                Set-ItResult -Skipped -Because 'Robot.Entity not compiled'
            }
        }

        It 'sorts entities ascending by name' {
            $E1 = [Robot.Entity]::new(); $E1.Name = 'Zebra'
            $E2 = [Robot.Entity]::new(); $E2.Name = 'Alpha'
            $List = [System.Collections.Generic.List[Robot.Entity]]::new()
            $List.Add($E1); $List.Add($E2)

            $SortFields = [Robot.ApiQueryParser]::ParseSort('name')
            [Robot.ApiQueryParser]::SortEntities($List, $SortFields)
            $List[0].Name | Should -Be 'Alpha'
            $List[1].Name | Should -Be 'Zebra'
        }

        It 'sorts entities descending with - prefix' {
            $E1 = [Robot.Entity]::new(); $E1.Name = 'Alpha'
            $E2 = [Robot.Entity]::new(); $E2.Name = 'Zebra'
            $List = [System.Collections.Generic.List[Robot.Entity]]::new()
            $List.Add($E1); $List.Add($E2)

            $SortFields = [Robot.ApiQueryParser]::ParseSort('-name')
            [Robot.ApiQueryParser]::SortEntities($List, $SortFields)
            $List[0].Name | Should -Be 'Zebra'
            $List[1].Name | Should -Be 'Alpha'
        }
    }

    Context 'PaginateEntities' {
        BeforeAll {
            if (-not ([System.Management.Automation.PSTypeName]'Robot.Entity').Type) {
                Set-ItResult -Skipped -Because 'Robot.Entity not compiled'
            }
        }

        It 'returns first page with hasMore flag' {
            $List = [System.Collections.Generic.List[Robot.Entity]]::new()
            for ($i = 0; $i -lt 10; $i++) {
                $E = [Robot.Entity]::new(); $E.Name = "Entity$i"
                $List.Add($E)
            }

            $Page = [Robot.PageParams]::new()
            $Page.Size = 3
            $Result = [Robot.ApiQueryParser]::PaginateEntities($List, $Page)
            $Result.Items.Count | Should -Be 3
            $Result.TotalCount | Should -Be 10
            $Result.HasMore | Should -BeTrue
            $Result.NextCursor | Should -Not -BeNullOrEmpty
        }

        It 'returns last page without hasMore' {
            $List = [System.Collections.Generic.List[Robot.Entity]]::new()
            $E1 = [Robot.Entity]::new(); $E1.Name = 'Only'
            $List.Add($E1)

            $Page = [Robot.PageParams]::new()
            $Page.Size = 50
            $Result = [Robot.ApiQueryParser]::PaginateEntities($List, $Page)
            $Result.Items.Count | Should -Be 1
            $Result.HasMore | Should -BeFalse
            $Result.NextCursor | Should -BeNullOrEmpty
        }
    }
}

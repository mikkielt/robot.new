<#
    .SYNOPSIS
    Pester tests for session-parsehelpers.ps1 (session metadata parsing).

    .DESCRIPTION
    Unit tests for Get-SessionTitle, Get-SessionLocations, and
    Get-SessionListMetadata covering all 8 metadata branches:
    PU, Logi, Zmiany, Intel, Narrator, Data, Transfer, plus
    edge cases (European decimals, inline vs child @Data, nested
    Zmiany with 3-level depth, Transfer 4-way parsing).

    Uses loading pattern C (standalone helper - dot-source directly).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'session-parsehelpers.ps1')

    # PU regex used by Get-SessionListMetadata (matches "CharName: 0,3" or "CharName: 0.3")
    $script:PURegex = [regex]::new(
        '^(.+?):\s*(\d+[\.,]?\d*)$',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)

    # URL regex used by Get-SessionListMetadata
    $script:UrlRegex = [regex]::new(
        '(https?://[^\s\)\]]+)',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)

    # Helper: build ChildrenOf hashtable from flat list items using ParentIndex
    function Build-ChildrenOf {
        param([object[]]$ListItems)
        $ChildrenOf = @{}
        foreach ($LI in $ListItems) {
            if ($LI.ParentIndex -lt 0) { continue }
            $ParentId = $LI.ParentIndex
            if (-not $ChildrenOf.ContainsKey($ParentId)) {
                $ChildrenOf[$ParentId] = [System.Collections.Generic.List[object]]::new()
            }
            $ChildrenOf[$ParentId].Add($LI)
        }
        return $ChildrenOf
    }

    # Helper: create list item objects with parent/local index
    function New-ListItem {
        param(
            [string]$Text,
            [int]$Indent = 0,
            [int]$ParentIndex = -1,
            [int]$LocalIndex = 0
        )
        return [PSCustomObject]@{
            Type          = 'Bullet'
            Text          = $Text
            Indent        = $Indent
            ParentIndex   = $ParentIndex
            LocalIndex    = $LocalIndex
            SectionHeader = $null
        }
    }
}


# -- Get-SessionTitle ----------------------------------------------------------

Describe 'Get-SessionTitle' {
    It 'strips date and narrator from header' {
        $DateInfo = @{ DateStr = '2025-03-01'; EndDayStr = $null; Date = [datetime]'2025-03-01' }
        $Title = Get-SessionTitle -Header '2025-03-01, Wielka Bitwa, Solmyr' -DateInfo $DateInfo
        $Title | Should -Be 'Wielka Bitwa'
    }

    It 'handles multi-day date range' {
        $DateInfo = @{ DateStr = '2025-03-01'; EndDayStr = '03'; Date = [datetime]'2025-03-01' }
        $Title = Get-SessionTitle -Header '2025-03-01-03, Trzy Dni Oblężenia, Solmyr' -DateInfo $DateInfo
        $Title | Should -Be 'Trzy Dni Oblężenia'
    }

    It 'returns header as-is when DateInfo is null' {
        $Title = Get-SessionTitle -Header 'Some Header' -DateInfo $null
        $Title | Should -Be 'Some Header'
    }

    It 'strips leading/trailing commas and spaces' {
        $DateInfo = @{ DateStr = '2025-01-01'; EndDayStr = $null; Date = [datetime]'2025-01-01' }
        $Title = Get-SessionTitle -Header '2025-01-01, , Tytuł z przecinkami, , Narrator' -DateInfo $DateInfo
        # After stripping date and narrator, title should be cleaned
        $Title | Should -Not -Match '^\s*,|,\s*$'
    }

    It 'handles title with no commas after date' {
        $DateInfo = @{ DateStr = '2025-05-15'; EndDayStr = $null; Date = [datetime]'2025-05-15' }
        $Title = Get-SessionTitle -Header '2025-05-15 Samotny Tytuł' -DateInfo $DateInfo
        $Title.Length | Should -BeGreaterThan 0
    }
}


# -- Get-SessionListMetadata --------------------------------------------------

Describe 'Get-SessionListMetadata' {

    Context 'PU branch' {
        It 'extracts PU with European decimal (comma)' {
            $PUParent = New-ListItem -Text '@PU:' -LocalIndex 0
            $PUChild1 = New-ListItem -Text 'Xeron Demonlord: 0,5' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $PUChild2 = New-ListItem -Text 'Kyrre: 0,3' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $AllItems = @($PUParent, $PUChild1, $PUChild2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 2
            $Result.PU[0].Character | Should -Be 'Xeron Demonlord'
            $Result.PU[0].Value | Should -Be 0.5
            $Result.PU[1].Character | Should -Be 'Kyrre'
            $Result.PU[1].Value | Should -Be 0.3
        }

        It 'extracts PU with dot decimal' {
            $PUParent = New-ListItem -Text 'PU:' -LocalIndex 0
            $PUChild = New-ListItem -Text 'Dracon: 0.8' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($PUParent, $PUChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 1
            $Result.PU[0].Character | Should -Be 'Dracon'
            $Result.PU[0].Value | Should -Be 0.8
        }

        It 'handles invalid PU value (returns null Value)' {
            $PUParent = New-ListItem -Text '@PU:' -LocalIndex 0
            $PUChild = New-ListItem -Text 'BadChar: abc' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($PUParent, $PUChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            # PU regex won't match "abc" so PU list stays empty
            $Result.PU.Count | Should -Be 0
        }

        It 'ignores PU parent with no children' {
            $PUParent = New-ListItem -Text '@PU:' -LocalIndex 0
            $AllItems = @($PUParent)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 0
        }

        It 'handles PU with space separator (PU :)' {
            $PUParent = New-ListItem -Text '@PU :' -LocalIndex 0
            $PUChild = New-ListItem -Text 'Gelu: 1' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($PUParent, $PUChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 1
        }
    }

    Context 'Logi branch' {
        It 'extracts log URLs from children' {
            $LogParent = New-ListItem -Text '@Logi:' -LocalIndex 0
            $LogChild1 = New-ListItem -Text 'https://example.com/log1' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $LogChild2 = New-ListItem -Text 'https://example.com/log2' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $AllItems = @($LogParent, $LogChild1, $LogChild2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Logs.Count | Should -Be 2
            $Result.Logs[0] | Should -Be 'https://example.com/log1'
            $Result.Logs[1] | Should -Be 'https://example.com/log2'
        }

        It 'extracts inline log URL' {
            $LogItem = New-ListItem -Text 'Logi: https://example.com/inline-log' -LocalIndex 0
            $AllItems = @($LogItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Logs.Count | Should -Be 1
            $Result.Logs[0] | Should -Be 'https://example.com/inline-log'
        }

        It 'deduplicates inline URL already in children' {
            $LogParent = New-ListItem -Text '@Logi: https://example.com/dupe' -LocalIndex 0
            $LogChild = New-ListItem -Text 'https://example.com/dupe' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($LogParent, $LogChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Logs.Count | Should -Be 1
        }

        It 'extracts local file paths (res/logs/)' {
            $LogParent = New-ListItem -Text '@Logi:' -LocalIndex 0
            $LogChild = New-ListItem -Text 'res/logs/2025-03-01-sesja.html' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($LogParent, $LogChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Logs.Count | Should -Be 1
            $Result.Logs[0] | Should -Be 'res/logs/2025-03-01-sesja.html'
        }
    }

    Context 'Zmiany branch' {
        It 'extracts entity changes with nested tags' {
            $ZmianyParent = New-ListItem -Text '@Zmiany:' -LocalIndex 0
            $Entity1 = New-ListItem -Text 'Kupiec Orrin' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Tag1 = New-ListItem -Text '@lokacja: Erathia (2025-03:)' -Indent 4 -ParentIndex 1 -LocalIndex 2
            $Tag2 = New-ListItem -Text '@status: Aktywny (2025-03:)' -Indent 4 -ParentIndex 1 -LocalIndex 3
            $AllItems = @($ZmianyParent, $Entity1, $Tag1, $Tag2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Changes.Count | Should -Be 1
            $Result.Changes[0].EntityName | Should -Be 'Kupiec Orrin'
            $Result.Changes[0].Tags.Count | Should -Be 2
            $Result.Changes[0].Tags[0].Tag | Should -Be '@lokacja'
            $Result.Changes[0].Tags[0].Value | Should -Be 'Erathia (2025-03:)'
        }

        It 'handles multiple entities in Zmiany' {
            $ZmianyParent = New-ListItem -Text 'Zmiany:' -LocalIndex 0
            $Entity1 = New-ListItem -Text 'Entity A' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Tag1 = New-ListItem -Text '@lokacja: Place (2025-01:)' -Indent 4 -ParentIndex 1 -LocalIndex 2
            $Entity2 = New-ListItem -Text 'Entity B' -Indent 2 -ParentIndex 0 -LocalIndex 3
            $Tag2 = New-ListItem -Text '@status: Nieaktywny (2025-01:)' -Indent 4 -ParentIndex 3 -LocalIndex 4
            $AllItems = @($ZmianyParent, $Entity1, $Tag1, $Entity2, $Tag2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Changes.Count | Should -Be 2
            $Result.Changes[0].EntityName | Should -Be 'Entity A'
            $Result.Changes[1].EntityName | Should -Be 'Entity B'
        }

        It 'skips tags without @ prefix' {
            $ZmianyParent = New-ListItem -Text '@Zmiany:' -LocalIndex 0
            $Entity = New-ListItem -Text 'SomeEntity' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Tag1 = New-ListItem -Text '@lokacja: Place' -Indent 4 -ParentIndex 1 -LocalIndex 2
            $Tag2 = New-ListItem -Text 'not a tag: value' -Indent 4 -ParentIndex 1 -LocalIndex 3
            $AllItems = @($ZmianyParent, $Entity, $Tag1, $Tag2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Changes[0].Tags.Count | Should -Be 1
        }

        It 'skips tags without colon' {
            $ZmianyParent = New-ListItem -Text '@Zmiany:' -LocalIndex 0
            $Entity = New-ListItem -Text 'SomeEntity' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Tag = New-ListItem -Text '@justATag' -Indent 4 -ParentIndex 1 -LocalIndex 2
            $AllItems = @($ZmianyParent, $Entity, $Tag)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Changes.Count | Should -Be 0
        }

        It 'matches Zmiany without colon (bare keyword)' {
            $ZmianyParent = New-ListItem -Text 'Zmiany' -LocalIndex 0
            $Entity = New-ListItem -Text 'TestEntity' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Tag = New-ListItem -Text '@lokacja: TestPlace' -Indent 4 -ParentIndex 1 -LocalIndex 2
            $AllItems = @($ZmianyParent, $Entity, $Tag)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Changes.Count | Should -Be 1
        }
    }

    Context 'Intel branch' {
        It 'extracts Intel entries with target and message' {
            $IntelParent = New-ListItem -Text '@Intel:' -LocalIndex 0
            $Intel1 = New-ListItem -Text 'Grupa/Kupcy: Orrin wrócił z towarem' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Intel2 = New-ListItem -Text 'Xeron Demonlord: Znalazł artefakt' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $AllItems = @($IntelParent, $Intel1, $Intel2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Intel.Count | Should -Be 2
            $Result.Intel[0].RawTarget | Should -Be 'Grupa/Kupcy'
            $Result.Intel[0].Message | Should -Be 'Orrin wrócił z towarem'
            $Result.Intel[1].RawTarget | Should -Be 'Xeron Demonlord'
        }

        It 'skips Intel entries with empty target or message' {
            $IntelParent = New-ListItem -Text '@Intel:' -LocalIndex 0
            $Intel1 = New-ListItem -Text ': Empty target' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Intel2 = New-ListItem -Text 'Target: ' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $Intel3 = New-ListItem -Text 'NoColonHere' -Indent 2 -ParentIndex 0 -LocalIndex 3
            $AllItems = @($IntelParent, $Intel1, $Intel2, $Intel3)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Intel.Count | Should -Be 0
        }

        It 'matches Intel with space separator' {
            $IntelParent = New-ListItem -Text 'Intel :' -LocalIndex 0
            $Intel = New-ListItem -Text 'Target: Message here' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($IntelParent, $Intel)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Intel.Count | Should -Be 1
        }
    }

    Context 'Narrator branch' {
        It 'extracts narrator override names' {
            $NarrParent = New-ListItem -Text '@Narrator:' -LocalIndex 0
            $Narr1 = New-ListItem -Text 'Solmyr' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Narr2 = New-ListItem -Text 'Dracon' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $AllItems = @($NarrParent, $Narr1, $Narr2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Narrators.Count | Should -Be 2
            $Result.Narrators[0] | Should -Be 'Solmyr'
            $Result.Narrators[1] | Should -Be 'Dracon'
        }

        It 'skips empty narrator names' {
            $NarrParent = New-ListItem -Text '@Narrator:' -LocalIndex 0
            $Narr1 = New-ListItem -Text '   ' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $Narr2 = New-ListItem -Text 'Solmyr' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $AllItems = @($NarrParent, $Narr1, $Narr2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Narrators.Count | Should -Be 1
            $Result.Narrators[0] | Should -Be 'Solmyr'
        }
    }

    Context 'Data branch' {
        It 'extracts inline date override' {
            $DataItem = New-ListItem -Text '@Data: 2024-07-14' -LocalIndex 0
            $AllItems = @($DataItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.DateOverride | Should -Be '2024-07-14'
        }

        It 'extracts child date override when inline is empty' {
            $DataParent = New-ListItem -Text '@Data:' -LocalIndex 0
            $DataChild = New-ListItem -Text '2024-08-20' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($DataParent, $DataChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.DateOverride | Should -Be '2024-08-20'
        }

        It 'prefers inline over children' {
            $DataParent = New-ListItem -Text '@Data: 2024-07-14' -LocalIndex 0
            $DataChild = New-ListItem -Text '2024-08-20' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($DataParent, $DataChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.DateOverride | Should -Be '2024-07-14'
        }

        It 'skips empty child lines in date override' {
            $DataParent = New-ListItem -Text '@Data:' -LocalIndex 0
            $DataChild1 = New-ListItem -Text '   ' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $DataChild2 = New-ListItem -Text '2024-09-01' -Indent 2 -ParentIndex 0 -LocalIndex 2
            $AllItems = @($DataParent, $DataChild1, $DataChild2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.DateOverride | Should -Be '2024-09-01'
        }

        It 'returns null DateOverride when not present' {
            $OtherItem = New-ListItem -Text 'Some unrelated item' -LocalIndex 0
            $AllItems = @($OtherItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.DateOverride | Should -BeNullOrEmpty
        }
    }

    Context 'Transfer branch' {
        It 'extracts transfer with amount, denomination, source and destination' {
            $TransferItem = New-ListItem -Text '@Transfer: 20 koron, Dawca -> Odbiorca' -LocalIndex 0
            $AllItems = @($TransferItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Transfers.Count | Should -Be 1
            $Result.Transfers[0].Amount | Should -Be 20
            $Result.Transfers[0].Denomination | Should -Be 'koron'
            $Result.Transfers[0].Source | Should -Be 'Dawca'
            $Result.Transfers[0].Destination | Should -Be 'Odbiorca'
        }

        It 'extracts multiple transfers' {
            $T1 = New-ListItem -Text '@Transfer: 20 koron, Dawca -> Odbiorca' -LocalIndex 0
            $T2 = New-ListItem -Text '@Transfer: 15 koron, Dawca -> Trzeci' -LocalIndex 1
            $T3 = New-ListItem -Text '@Transfer: 5 koron, Odbiorca -> Trzeci' -LocalIndex 2
            $AllItems = @($T1, $T2, $T3)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Transfers.Count | Should -Be 3
        }

        It 'rejects transfer with invalid amount' {
            $TransferItem = New-ListItem -Text '@Transfer: abc koron, Dawca -> Odbiorca' -LocalIndex 0
            $AllItems = @($TransferItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Transfers.Count | Should -Be 0
        }

        It 'rejects transfer with zero amount' {
            $TransferItem = New-ListItem -Text '@Transfer: 0 koron, Dawca -> Odbiorca' -LocalIndex 0
            $AllItems = @($TransferItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Transfers.Count | Should -Be 0
        }

        It 'rejects transfer without arrow' {
            $TransferItem = New-ListItem -Text '@Transfer: 20 koron, Dawca do Odbiorca' -LocalIndex 0
            $AllItems = @($TransferItem)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Transfers.Count | Should -Be 0
        }

        It 'rejects transfer with empty source or destination' {
            $T1 = New-ListItem -Text '@Transfer: 20 koron,  -> Odbiorca' -LocalIndex 0
            $T2 = New-ListItem -Text '@Transfer: 20 koron, Dawca ->  ' -LocalIndex 1
            $AllItems = @($T1, $T2)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.Transfers.Count | Should -Be 0
        }
    }

    Context 'combined metadata' {
        It 'extracts all metadata types from a single section' {
            $PUParent = New-ListItem -Text '@PU:' -LocalIndex 0
            $PUChild = New-ListItem -Text 'Xeron: 0,5' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $LogParent = New-ListItem -Text '@Logi:' -LocalIndex 2
            $LogChild = New-ListItem -Text 'https://example.com/log1' -Indent 2 -ParentIndex 2 -LocalIndex 3
            $ZmianyParent = New-ListItem -Text '@Zmiany:' -LocalIndex 4
            $Entity = New-ListItem -Text 'Kupiec' -Indent 2 -ParentIndex 4 -LocalIndex 5
            $Tag = New-ListItem -Text '@lokacja: Erathia' -Indent 4 -ParentIndex 5 -LocalIndex 6
            $IntelParent = New-ListItem -Text '@Intel:' -LocalIndex 7
            $Intel = New-ListItem -Text 'Target: Message' -Indent 2 -ParentIndex 7 -LocalIndex 8
            $NarrParent = New-ListItem -Text '@Narrator:' -LocalIndex 9
            $Narr = New-ListItem -Text 'Solmyr' -Indent 2 -ParentIndex 9 -LocalIndex 10
            $Data = New-ListItem -Text '@Data: 2025-01-01' -LocalIndex 11
            $Transfer = New-ListItem -Text '@Transfer: 10 koron, A -> B' -LocalIndex 12

            $AllItems = @($PUParent, $PUChild, $LogParent, $LogChild, $ZmianyParent, $Entity, $Tag,
                          $IntelParent, $Intel, $NarrParent, $Narr, $Data, $Transfer)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 1
            $Result.Logs.Count | Should -Be 1
            $Result.Changes.Count | Should -Be 1
            $Result.Intel.Count | Should -Be 1
            $Result.Narrators.Count | Should -Be 1
            $Result.DateOverride | Should -Be '2025-01-01'
            $Result.Transfers.Count | Should -Be 1
        }

        It 'returns empty collections when no metadata tags present' {
            $Item = New-ListItem -Text 'Some unrelated list item' -LocalIndex 0
            $AllItems = @($Item)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 0
            $Result.Logs.Count | Should -Be 0
            $Result.Changes.Count | Should -Be 0
            $Result.Intel.Count | Should -Be 0
            $Result.Transfers.Count | Should -Be 0
            $Result.Narrators.Count | Should -Be 0
            $Result.DateOverride | Should -BeNullOrEmpty
        }
    }

    Context 'Gen3 vs Gen4 tag prefix' {
        It 'handles Gen3 tags without @ prefix' {
            $PUParent = New-ListItem -Text 'PU:' -LocalIndex 0
            $PUChild = New-ListItem -Text 'Hero: 1' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($PUParent, $PUChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 1
        }

        It 'handles Gen4 tags with @ prefix' {
            $PUParent = New-ListItem -Text '@PU:' -LocalIndex 0
            $PUChild = New-ListItem -Text 'Hero: 1' -Indent 2 -ParentIndex 0 -LocalIndex 1
            $AllItems = @($PUParent, $PUChild)
            $ChildrenOf = Build-ChildrenOf -ListItems $AllItems

            $Result = Get-SessionListMetadata -SectionLists $AllItems -PURegex $script:PURegex -UrlRegex $script:UrlRegex -ChildrenOf $ChildrenOf

            $Result.PU.Count | Should -Be 1
        }
    }
}

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/charfile-helpers.ps1"
    . "$script:ModuleRoot/entity-writehelpers.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-set-pc-cf-" + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    $script:CharFileTemplate = @'
**Karta Postaci:** https://example.com/sheet

**Tematy zastrzeżone:**
Brak.

**Stan:**
Zdrowy.

**Przedmioty specjalne:**
Brak.

**Reputacja:**
- Pozytywna:
- Neutralna: Deyja, Erathia
- Negatywna:

**Dodatkowe informacje:**
- Brak.

**Opisane sesje:**

[[_TOC_]]

### 2025-01-15, Test session, Narrator
Content...
'@
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe 'Write-CharacterFileSection' {
    Context 'Condition update' {
        It 'replaces Stan section content' {
            $CharFile = Join-Path $script:TempRoot 'cond.md'
            Write-TestFile -Path $CharFile -Content $script:CharFileTemplate

            $Data = Read-CharacterFile -Path $CharFile
            $Lines = [System.Collections.Generic.List[string]]::new($Data.Lines)
            Write-CharacterFileSection -Lines $Lines -SectionName 'Stan' -NewContent @('Ranny, złamana ręka.')

            $Content = [string]::Join("`n", $Lines)
            $Content | Should -Match 'Ranny, złamana ręka\.'
            $Content | Should -Not -Match 'Zdrowy\.'
        }
    }

    Context 'SpecialItems update' {
        It 'replaces Przedmioty specjalne section' {
            $CharFile = Join-Path $script:TempRoot 'items.md'
            Write-TestFile -Path $CharFile -Content $script:CharFileTemplate

            $Data = Read-CharacterFile -Path $CharFile
            $Lines = [System.Collections.Generic.List[string]]::new($Data.Lines)
            Write-CharacterFileSection -Lines $Lines -SectionName 'Przedmioty specjalne' -NewContent @('- Magiczny miecz', '- Tarcza ognia')

            $Content = [string]::Join("`n", $Lines)
            $Content | Should -Match 'Magiczny miecz'
            $Content | Should -Match 'Tarcza ognia'
            $Content | Should -Not -Match 'Brak\.'
        }
    }

    Context 'Reputation partial update' {
        It 'updates only Positive tier while preserving others' {
            $CharFile = Join-Path $script:TempRoot 'rep.md'
            Write-TestFile -Path $CharFile -Content $script:CharFileTemplate

            $ExistingRep = (Read-CharacterFile -Path $CharFile).Reputation
            $NewPos = @([PSCustomObject]@{ Location = 'Erathia'; Detail = 'walczył w obronie' })
            $RepLines = Format-ReputationSection -Positive $NewPos -Neutral $ExistingRep.Neutral -Negative $ExistingRep.Negative

            $Data = Read-CharacterFile -Path $CharFile
            $Lines = [System.Collections.Generic.List[string]]::new($Data.Lines)
            Write-CharacterFileSection -Lines $Lines -SectionName 'Reputacja' -NewContent $RepLines

            $Content = [string]::Join("`n", $Lines)
            $Content | Should -Match 'Erathia: walczył w obronie'
            $Content | Should -Match 'Neutralna: Deyja, Erathia'
        }
    }

    Context 'Opisane sesje boundary' {
        It 'does not modify content after Opisane sesje section' {
            $CharFile = Join-Path $script:TempRoot 'boundary.md'
            Write-TestFile -Path $CharFile -Content $script:CharFileTemplate

            $Data = Read-CharacterFile -Path $CharFile
            $Lines = [System.Collections.Generic.List[string]]::new($Data.Lines)
            Write-CharacterFileSection -Lines $Lines -SectionName 'Dodatkowe informacje' -NewContent @('- New info entry.')

            $Content = [string]::Join("`n", $Lines)
            $Content | Should -Match '### 2025-01-15, Test session, Narrator'
            $Content | Should -Match 'Content\.\.\.'
        }
    }

    Context 'CharacterSheet inline update' {
        It 'updates inline URL' {
            $CharFile = Join-Path $script:TempRoot 'sheet.md'
            Write-TestFile -Path $CharFile -Content $script:CharFileTemplate

            $Data = Read-CharacterFile -Path $CharFile
            $Lines = [System.Collections.Generic.List[string]]::new($Data.Lines)
            Write-CharacterFileSection -Lines $Lines -SectionName 'Karta Postaci' -InlineValue 'https://new.example.com/sheet'

            $Lines[0] | Should -Be '**Karta Postaci:** https://new.example.com/sheet'
        }
    }
}

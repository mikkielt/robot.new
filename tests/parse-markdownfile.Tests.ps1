<#
    .SYNOPSIS
    Pester tests for parse-markdownfile.ps1.

    .DESCRIPTION
    Tests for parse-markdownfile.ps1 script covering header parsing,
    section extraction, list item processing, link detection, and
    multi-level document structure handling.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ParserPath = Join-Path $script:ModuleRoot 'parse-markdownfile.ps1'
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-parse-markdownfile-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)
}

Describe 'parse-markdownfile.ps1' {
    Context 'Script invocation' {
        It 'returns expected properties and parses headers, sections, lists, and links' {
            $FilePath = Join-Path $script:TempRoot 'rich.md'
            $Content = @'
# Root
Intro [One](https://example.com/md) and https://example.com/plain
## Child
- Top item
   - Child item
### Grandchild
```
## NotAHeader
  - NotAList https://example.com/hidden
[Hidden](https://example.com/hidden-md)
```
After block https://example.com/visible2
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath

            $PropertyNames = $Result.PSObject.Properties.Name
            foreach ($Name in @('FilePath', 'Headers', 'Sections', 'Lists', 'Links')) {
                $PropertyNames | Should -Contain $Name
            }
            $Result.FilePath | Should -Be $FilePath

            $Result.Headers.Count | Should -Be 3
            $Result.Headers[0].Level | Should -Be 1
            $Result.Headers[0].Text | Should -Be 'Root'
            $Result.Headers[0].LineNumber | Should -Be 1
            $Result.Headers[0].ParentHeader | Should -BeNullOrEmpty

            $Result.Headers[1].Level | Should -Be 2
            $Result.Headers[1].Text | Should -Be 'Child'
            $Result.Headers[1].LineNumber | Should -Be 3
            $Result.Headers[1].ParentHeader.Text | Should -Be 'Root'

            $Result.Headers[2].Level | Should -Be 3
            $Result.Headers[2].Text | Should -Be 'Grandchild'
            $Result.Headers[2].LineNumber | Should -Be 6
            $Result.Headers[2].ParentHeader.Text | Should -Be 'Child'

            $Result.Sections.Count | Should -Be 3
            $Result.Sections[0].Header.Text | Should -Be 'Root'
            $Result.Sections[1].Header.Text | Should -Be 'Child'
            $Result.Sections[2].Header.Text | Should -Be 'Grandchild'
            $Result.Sections[1].Lists.Count | Should -Be 2

            $Result.Lists.Count | Should -Be 2
            $Result.Lists[0].Text | Should -Be 'Top item'
            $Result.Lists[0].Indent | Should -Be 0
            $Result.Lists[0].ParentListItem | Should -BeNullOrEmpty
            $Result.Lists[1].Text | Should -Be 'Child item'
            $Result.Lists[1].Indent | Should -Be 2
            $Result.Lists[1].ParentListItem.Text | Should -Be 'Top item'

            $LinkUrls = @($Result.Links | ForEach-Object { $_.Url })
            $LinkUrls | Should -Contain 'https://example.com/md'
            $LinkUrls | Should -Contain 'https://example.com/plain'
            $LinkUrls | Should -Contain 'https://example.com/visible2'
            $LinkUrls | Should -Not -Contain 'https://example.com/hidden'
            $LinkUrls | Should -Not -Contain 'https://example.com/hidden-md'
        }

        It 'returns empty collections for an empty file' {
            $FilePath = Join-Path $script:TempRoot 'empty.md'
            [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath

            $Result.Headers.Count | Should -Be 0
            $Result.Sections.Count | Should -Be 0
            $Result.Lists.Count | Should -Be 0
            $Result.Links.Count | Should -Be 0
        }

        It 'stores all content in a single root section when no headers exist' {
            $FilePath = Join-Path $script:TempRoot 'no-headers.md'
            $Content = @'
First line.
- One bullet
Plain URL: https://example.com/no-header
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath

            $Result.Headers.Count | Should -Be 0
            $Result.Sections.Count | Should -Be 1
            $Result.Sections[0].Header | Should -BeNullOrEmpty
            $Result.Sections[0].Content | Should -Match 'First line\.'
            $Result.Sections[0].Content | Should -Match 'One bullet'
        }

        It 'handles deeply nested headers (h1 through h5)' {
            $FilePath = Join-Path $script:TempRoot 'deep-headers.md'
            $Content = @'
# Level 1
## Level 2
### Level 3
#### Level 4
##### Level 5
Some content.
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $Result.Headers.Count | Should -Be 5
            $Result.Headers[4].Level | Should -Be 5
            $Result.Headers[4].Text | Should -Be 'Level 5'
            $Result.Headers[4].ParentHeader.Text | Should -Be 'Level 4'
        }

        It 'handles header with Polish diacritics' {
            $FilePath = Join-Path $script:TempRoot 'unicode-headers.md'
            $Content = @'
# Główna Sekcja
## Żółwie Ćwiartki
Treść z ąęćłńóśźż.
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $Result.Headers.Count | Should -Be 2
            $Result.Headers[0].Text | Should -Be 'Główna Sekcja'
            $Result.Headers[1].Text | Should -Be 'Żółwie Ćwiartki'
        }

        It 'handles multiple code fences without picking up false headers' {
            $FilePath = Join-Path $script:TempRoot 'multi-fence.md'
            $Content = @'
# Real Header
```
## Fake Header 1
```
Some text.
```markdown
## Fake Header 2
```
## Real Header 2
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $RealHeaders = $Result.Headers | ForEach-Object { $_.Text }
            $RealHeaders | Should -Contain 'Real Header'
            $RealHeaders | Should -Contain 'Real Header 2'
            $RealHeaders | Should -Not -Contain 'Fake Header 1'
            $RealHeaders | Should -Not -Contain 'Fake Header 2'
        }

        It 'handles file with only headers and no content' {
            $FilePath = Join-Path $script:TempRoot 'only-headers.md'
            $Content = @'
# First
## Second
### Third
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $Result.Headers.Count | Should -Be 3
            $Result.Lists.Count | Should -Be 0
            $Result.Links.Count | Should -Be 0
        }

        It 'handles deeply nested list items (4 levels)' {
            $FilePath = Join-Path $script:TempRoot 'deep-lists.md'
            $Content = @'
# Tasks
- Level 0
   - Level 1
      - Level 2
         - Level 3
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $Result.Lists.Count | Should -Be 4
            $Result.Lists[3].Indent | Should -BeGreaterThan $Result.Lists[2].Indent
        }

        It 'handles multiple links on the same line' {
            $FilePath = Join-Path $script:TempRoot 'multi-link.md'
            $Content = @'
# Links
[A](https://example.com/a) text [B](https://example.com/b) and https://example.com/c
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $LinkUrls = $Result.Links | ForEach-Object { $_.Url }
            $LinkUrls | Should -Contain 'https://example.com/a'
            $LinkUrls | Should -Contain 'https://example.com/b'
            $LinkUrls | Should -Contain 'https://example.com/c'
        }

        It 'handles sibling headers at same level (no nesting)' {
            $FilePath = Join-Path $script:TempRoot 'siblings.md'
            $Content = @'
## Sekcja A
Content A
## Sekcja B
Content B
## Sekcja C
Content C
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $Result.Headers.Count | Should -Be 3
            $Result.Sections.Count | Should -Be 3
            foreach ($hdr in $Result.Headers) {
                $hdr.ParentHeader | Should -BeNullOrEmpty
            }
        }

        It 'content before first header goes into root section' {
            $FilePath = Join-Path $script:TempRoot 'pre-header.md'
            $Content = @'
Intro text before any header.
# First Header
Content after.
'@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $RootSection = $Result.Sections | Where-Object { $null -eq $_.Header }
            $RootSection | Should -Not -BeNullOrEmpty
            $RootSection.Content | Should -Match 'Intro text'
        }

        It 'handles blank lines between sections' {
            $FilePath = Join-Path $script:TempRoot 'blank-lines.md'
            $Content = @"
# Header One


Some content after blank lines.


## Header Two


More content.

"@
            [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))

            $Result = & $script:ParserPath $FilePath
            $Result.Headers.Count | Should -Be 2
            $Result.Sections.Count | Should -Be 2
        }
    }
}

AfterAll {
    if ([System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

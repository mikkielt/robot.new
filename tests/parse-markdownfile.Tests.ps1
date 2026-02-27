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
    }
}

AfterAll {
    if ([System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

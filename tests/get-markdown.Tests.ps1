BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path $script:ModuleRoot 'robot.psd1'
    $script:ParserPath = Join-Path $script:ModuleRoot 'parse-markdownfile.ps1'
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-get-markdown-" + [System.Guid]::NewGuid().ToString('N'))

    $script:FileInputRoot = Join-Path $script:TempRoot 'file-input'
    $script:DirScanRoot = Join-Path $script:TempRoot 'dir-scan'
    $script:ParallelRoot = Join-Path $script:TempRoot 'parallel'

    foreach ($Path in @($script:FileInputRoot, $script:DirScanRoot, $script:ParallelRoot)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }

    function script:Write-TestFile {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Content
        )

        $Parent = Split-Path $Path -Parent
        if ($Parent -and -not [System.IO.Directory]::Exists($Parent)) {
            [System.IO.Directory]::CreateDirectory($Parent) | Out-Null
        }
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    $script:SingleFile = Join-Path $script:FileInputRoot 'single.md'
    $script:SecondFile = Join-Path $script:FileInputRoot 'second.markdown'
    Write-TestFile -Path $script:SingleFile -Content @'
# Single Header
Single body [Ref](https://example.com/single-md) and https://example.com/single-plain
- Single item
'@
    Write-TestFile -Path $script:SecondFile -Content @'
# Second Header
Second body.
'@

    Write-TestFile -Path (Join-Path $script:DirScanRoot 'top.md') -Content @'
# Top
Top content
'@
    Write-TestFile -Path (Join-Path $script:DirScanRoot 'nested/child.markdown') -Content @'
# Child
Child content
'@
    Write-TestFile -Path (Join-Path $script:DirScanRoot 'nested/deep.md') -Content @'
# Deep
Deep content
'@
    Write-TestFile -Path (Join-Path $script:DirScanRoot 'nested/ignore.txt') -Content 'ignore me'

    $script:ParallelFiles = @(1..5 | ForEach-Object {
            $Path = Join-Path $script:ParallelRoot ("parallel-$_.md")
            Write-TestFile -Path $Path -Content @"
# Parallel $_
Line $_ [L$_](https://example.com/p$_) and https://example.com/plain$_
- Item $_
"@
            $Path
        }) | Sort-Object

    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
}

Describe 'Get-Markdown' {
    Context '-File parameter' {
        It 'returns unwrapped single object for a single file input' {
            $Result = Get-Markdown -File $script:SingleFile

            ($Result -is [System.Collections.IList]) | Should -BeFalse
            $Result.PSObject.Properties.Name | Should -Contain 'FilePath'
            $Result.FilePath | Should -Be $script:SingleFile
        }

        It 'returns a list with one element per file for array input' {
            $Result = Get-Markdown -File @($script:SingleFile, $script:SecondFile)

            ($Result -is [System.Collections.IList]) | Should -BeTrue
            $Result.Count | Should -Be 2
            @($Result | ForEach-Object { $_.FilePath }) | Should -Be @($script:SingleFile, $script:SecondFile)
        }

        It 'throws for non-existent file path' {
            $MissingFile = Join-Path $script:TempRoot 'missing-file.md'
            { Get-Markdown -File $MissingFile } | Should -Throw '*File not found:*'
        }

        It 'returns structure matching parse-markdownfile output shape' {
            $Expected = & $script:ParserPath $script:SingleFile
            $Actual = Get-Markdown -File $script:SingleFile

            @($Actual.PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected.PSObject.Properties.Name | Sort-Object)
            @($Actual.Headers[0].PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected.Headers[0].PSObject.Properties.Name | Sort-Object)
            @($Actual.Sections[0].PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected.Sections[0].PSObject.Properties.Name | Sort-Object)
            @($Actual.Lists[0].PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected.Lists[0].PSObject.Properties.Name | Sort-Object)
            @($Actual.Links[0].PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected.Links[0].PSObject.Properties.Name | Sort-Object)
        }
    }

    Context '-Directory parameter' {
        It 'scans .md and .markdown files recursively under the provided directory' {
            $Result = Get-Markdown -Directory $script:DirScanRoot
            $Basenames = @($Result | ForEach-Object { [System.IO.Path]::GetFileName($_.FilePath) })

            $Result.Count | Should -Be 3
            $Basenames | Should -Contain 'top.md'
            $Basenames | Should -Contain 'child.markdown'
            $Basenames | Should -Contain 'deep.md'
            $Basenames | Should -Not -Contain 'ignore.txt'
        }

        It 'uses Get-RepoRoot by default when -Directory is omitted' {
            $RepoRoot = $script:DirScanRoot
            Mock -CommandName Get-RepoRoot -ModuleName robot -MockWith { return $RepoRoot }

            $Result = Get-Markdown
            $Basenames = @($Result | ForEach-Object { [System.IO.Path]::GetFileName($_.FilePath) })

            Should -Invoke -CommandName Get-RepoRoot -ModuleName robot -Times 1 -Exactly
            $Result.Count | Should -Be 3
            $Basenames | Should -Contain 'top.md'
            $Basenames | Should -Contain 'child.markdown'
            $Basenames | Should -Contain 'deep.md'
        }

        It 'throws for non-existent directory path' {
            $MissingDir = Join-Path $script:TempRoot 'missing-dir'
            { Get-Markdown -Directory $MissingDir } | Should -Throw '*Directory not found:*'
        }
    }

    Context 'determinism across execution paths' {
        It 'returns equivalent results for parallel multi-file and sequential single-file execution' {
            $ParallelResults = Get-Markdown -File $script:ParallelFiles
            $SequentialResults = @($script:ParallelFiles | ForEach-Object { Get-Markdown -File $_ })
            $GetSignature = {
                param($Result)
                [PSCustomObject]@{
                    FilePath     = [System.IO.Path]::GetFileName($Result.FilePath)
                    HeaderTexts  = @($Result.Headers | ForEach-Object { $_.Text })
                    SectionCount = $Result.Sections.Count
                    ListTexts    = @($Result.Lists | ForEach-Object { $_.Text })
                    LinkUrls     = @($Result.Links | ForEach-Object { $_.Url })
                }
            }

            $ParallelSignature = $ParallelResults |
                ForEach-Object { & $GetSignature $_ } |
                Sort-Object FilePath |
                ConvertTo-Json -Depth 6 -Compress

            $SequentialSignature = $SequentialResults |
                ForEach-Object { & $GetSignature $_ } |
                Sort-Object FilePath |
                ConvertTo-Json -Depth 6 -Compress

            $ParallelResults.Count | Should -Be 5
            $ParallelSignature | Should -Be $SequentialSignature
        }
    }
}

AfterAll {
    Remove-Module -Name robot -Force -ErrorAction SilentlyContinue
    if ([System.IO.Directory]::Exists($script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
    }
}

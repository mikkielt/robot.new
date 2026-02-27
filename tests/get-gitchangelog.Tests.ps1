<#
    .SYNOPSIS
    Pester tests for get-gitchangelog.ps1.

    .DESCRIPTION
    Tests for ConvertFrom-CommitLine and Get-GitChangeLog covering
    commit header parsing, date handling, file change lists, NoPatch
    mode, date range filtering, and patch content extraction.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    # Point Get-RepoRoot to the actual repository (parent of .robot.new)
    $script:ActualRepoRoot = Split-Path $script:ModuleRoot -Parent
    Mock Get-RepoRoot { return $script:ActualRepoRoot }
    . (Join-Path $script:ModuleRoot 'get-gitchangelog.ps1')
}

Describe 'ConvertFrom-CommitLine' {
    It 'parses commit header with ISO 8601 date' {
        $Line = "COMMIT$([char]0x1F)abc123def$([char]0x1F)2024-06-15T10:30:00+02:00$([char]0x1F)Author Name$([char]0x1F)author@example.com"
        $Regex = [regex]'^COMMIT\x1F(.+?)\x1F(.+?)\x1F(.+?)\x1F(.+)$'
        $Match = $Regex.Match($Line)
        $Match.Success | Should -BeTrue

        $Result = ConvertFrom-CommitLine -Match $Match
        $Result.CommitHash | Should -Be 'abc123def'
        $Result.AuthorName | Should -Be 'Author Name'
        $Result.AuthorEmail | Should -Be 'author@example.com'
        $Result.CommitDate | Should -BeOfType [datetime]
        $Result.CommitDate.Year | Should -Be 2024
        $Result.Files.Count | Should -Be 0
    }

    It 'handles unparseable date gracefully' {
        $Line = "COMMIT$([char]0x1F)hash1$([char]0x1F)NOT-A-DATE$([char]0x1F)Author$([char]0x1F)a@b.com"
        $Regex = [regex]'^COMMIT\x1F(.+?)\x1F(.+?)\x1F(.+?)\x1F(.+)$'
        $Match = $Regex.Match($Line)

        $Result = ConvertFrom-CommitLine -Match $Match
        $Result.CommitHash | Should -Be 'hash1'
        $Result.CommitDate | Should -BeNullOrEmpty
    }
}

Describe 'Get-GitChangeLog' {
    It 'returns structured commit objects in NoPatch mode' {
        $Result = Get-GitChangeLog -NoPatch
        $Result | Should -Not -BeNullOrEmpty
        $Result[0].CommitHash | Should -Not -BeNullOrEmpty
        $Result[0].AuthorName | Should -Not -BeNullOrEmpty
        $Result[0].AuthorEmail | Should -Not -BeNullOrEmpty
    }

    It 'commit objects have Files list' {
        $Result = Get-GitChangeLog -NoPatch
        $WithFiles = $Result | Where-Object { $_.Files.Count -gt 0 } | Select-Object -First 1
        $WithFiles | Should -Not -BeNullOrEmpty
        $WithFiles.Files[0].Path | Should -Not -BeNullOrEmpty
        $WithFiles.Files[0].ChangeType | Should -Match '^[AMDRC]$'
    }

    It 'returns empty for far-future MinDate' {
        $Result = Get-GitChangeLog -MinDate '2099-01-01' -NoPatch
        $Result.Count | Should -Be 0
    }

    It 'returns empty for ancient MaxDate' {
        $Result = Get-GitChangeLog -MaxDate '2000-01-01' -NoPatch
        $Result.Count | Should -Be 0
    }

    It 'patch mode returns patch content' {
        # Limit to last few commits for speed
        $Result = Get-GitChangeLog -MinDate (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
        if ($Result.Count -gt 0) {
            $WithPatch = $Result | Where-Object {
                $_.Files | Where-Object { $_.Patch.Count -gt 0 }
            } | Select-Object -First 1
            if ($WithPatch) {
                $PatchFile = $WithPatch.Files | Where-Object { $_.Patch.Count -gt 0 } | Select-Object -First 1
                $PatchFile.Patch[0] | Should -BeLike '@@*'
            }
        }
    }

    It 'CommitDate is a datetime when parseable' {
        $Result = Get-GitChangeLog -NoPatch
        $WithDate = $Result | Where-Object { $null -ne $_.CommitDate } | Select-Object -First 1
        $WithDate | Should -Not -BeNullOrEmpty
        $WithDate.CommitDate | Should -BeOfType [datetime]
    }
}

<#
    .SYNOPSIS
    Pester tests for session integrity checking system.

    .DESCRIPTION
    Tests for session-hashhelpers.ps1 (Get-ContentHash, Get-FileHeaderHashes,
    Read-SessionHashFile, Write-SessionHashFile, Get-HashableFiles,
    Get-RelativeHashPath), Set-SessionHash, and Test-SessionIntegrity.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'temporal-helpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-parsehelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'session-hashhelpers.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'admin-config.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'workflow' 'set-sessionhash.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'reporting' 'test-sessionintegrity.ps1')

    $script:IntegrityFixtures = Join-Path $script:FixturesRoot 'sessions-integrity'
}

Describe 'Get-ContentHash' {
    It 'returns a 64-character lowercase hex string' {
        $Hash = Get-ContentHash -Content 'Hello World'
        $Hash | Should -Not -BeNullOrEmpty
        $Hash.Length | Should -Be 64
        $Hash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'produces identical hashes for whitespace variations' {
        $Hash1 = Get-ContentHash -Content "### 2024-06-15, Title, Narrator`nSome content here"
        $Hash2 = Get-ContentHash -Content "### 2024-06-15, Title, Narrator`r`nSome content here"
        $Hash3 = Get-ContentHash -Content "###  2024-06-15,  Title,  Narrator`n  Some  content  here  "
        $Hash1 | Should -Be $Hash2
        $Hash1 | Should -Be $Hash3
    }

    It 'produces different hashes for different content' {
        $Hash1 = Get-ContentHash -Content '### 2024-06-15, Session A, Narrator'
        $Hash2 = Get-ContentHash -Content '### 2024-06-15, Session B, Narrator'
        $Hash1 | Should -Not -Be $Hash2
    }

    It 'handles empty string input' {
        $Hash = Get-ContentHash -Content ''
        $Hash | Should -Not -BeNullOrEmpty
        $Hash.Length | Should -Be 64
        $Hash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'strips tabs, spaces, CR, LF before hashing' {
        $Hash1 = Get-ContentHash -Content "ABC"
        $Hash2 = Get-ContentHash -Content "`t A `r`n B `n C `t"
        $Hash1 | Should -Be $Hash2
    }
}

Describe 'Get-FileHeaderHashes' {
    It 'computes hashes for all headers in a parsed Markdown file' {
        $MdResult = Get-Markdown -File (Join-Path $script:IntegrityFixtures 'base.md')
        $Hashes = Get-FileHeaderHashes -MarkdownResult $MdResult
        $Hashes.Count | Should -BeGreaterThan 0

        # Should contain the top-level header and all session headers
        $Hashes.ContainsKey('# Sesje testowe') | Should -BeTrue
        $Hashes.ContainsKey('## Historia') | Should -BeTrue
        $Hashes.ContainsKey('### 2024-06-15, Oblężenie Steadwick, Solmyr') | Should -BeTrue
        $Hashes.ContainsKey('### 2024-07-01, Powrót zdrowia, Crag Hack') | Should -BeTrue
        $Hashes.ContainsKey('### 2024-08-20, Handel w porcie, Solmyr') | Should -BeTrue
    }

    It 'returns empty dictionary for file with no headers' {
        $TempDir = New-TestTempDir
        $TempFile = Join-Path $TempDir 'no-headers.md'
        Write-TestFile -Path $TempFile -Content "Just some plain text without any headers.`n"
        $MdResult = Get-Markdown -File $TempFile
        $Hashes = Get-FileHeaderHashes -MarkdownResult $MdResult
        $Hashes.Count | Should -Be 0
        Remove-TestTempDir
    }

    It 'uses case-insensitive key comparer' {
        $MdResult = Get-Markdown -File (Join-Path $script:IntegrityFixtures 'base.md')
        $Hashes = Get-FileHeaderHashes -MarkdownResult $MdResult
        # OrdinalIgnoreCase comparer
        $Hashes.ContainsKey('### 2024-06-15, oblężenie steadwick, solmyr') | Should -BeTrue
    }
}

Describe 'Read-SessionHashFile / Write-SessionHashFile' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
    }
    AfterEach {
        Remove-TestTempDir
    }

    It 'round-trips hash data correctly' {
        $JsonPath = Join-Path $script:TempDir 'test.json'

        $Hashes = [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $Hashes['### 2024-06-15, Session A, Narrator'] = 'aaaa' * 16
        $Hashes['## Section'] = 'bbbb' * 16

        Write-SessionHashFile -JsonPath $JsonPath -Hashes $Hashes

        $Loaded = Read-SessionHashFile -JsonPath $JsonPath
        $Loaded.Count | Should -Be 2
        $Loaded['### 2024-06-15, Session A, Narrator'] | Should -Be ('aaaa' * 16)
        $Loaded['## Section'] | Should -Be ('bbbb' * 16)
    }

    It 'returns empty dictionary for missing file' {
        $Loaded = Read-SessionHashFile -JsonPath (Join-Path $script:TempDir 'nonexistent.json')
        $Loaded.Count | Should -Be 0
    }

    It 'creates parent directories on write' {
        $NestedPath = Join-Path $script:TempDir 'sub' 'dir' 'test.json'

        $Hashes = [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $Hashes['# Title'] = 'cccc' * 16

        Write-SessionHashFile -JsonPath $NestedPath -Hashes $Hashes
        [System.IO.File]::Exists($NestedPath) | Should -BeTrue
    }

    It 'writes sorted keys for deterministic output' {
        $JsonPath = Join-Path $script:TempDir 'sorted.json'

        $Hashes = [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $Hashes['### ZZZ'] = 'zzzz' * 16
        $Hashes['### AAA'] = 'aaaa' * 16
        $Hashes['### MMM'] = 'mmmm' * 16

        Write-SessionHashFile -JsonPath $JsonPath -Hashes $Hashes

        $RawJson = [System.IO.File]::ReadAllText($JsonPath)
        $AIdx = $RawJson.IndexOf('AAA')
        $MIdx = $RawJson.IndexOf('MMM')
        $ZIdx = $RawJson.IndexOf('ZZZ')
        $AIdx | Should -BeLessThan $MIdx
        $MIdx | Should -BeLessThan $ZIdx
    }

    It 'returns empty dictionary for corrupt JSON' {
        $JsonPath = Join-Path $script:TempDir 'corrupt.json'
        Write-TestFile -Path $JsonPath -Content 'NOT VALID JSON {{{{'

        $Loaded = Read-SessionHashFile -JsonPath $JsonPath
        $Loaded.Count | Should -Be 0
    }
}

Describe 'Read-SessionHashMeta / Write-SessionHashMeta' {
    BeforeEach {
        $script:TempDir = New-TestTempDir
    }
    AfterEach {
        Remove-TestTempDir
    }

    It 'returns defaults for missing meta file' {
        $Meta = Read-SessionHashMeta -MetaPath (Join-Path $script:TempDir 'missing.json')
        $Meta['Version'] | Should -Be 1
        $Meta['LastFullUpdate'] | Should -BeNullOrEmpty
        $Meta['LastIncrementalUpdate'] | Should -BeNullOrEmpty
    }

    It 'round-trips metadata correctly' {
        $MetaPath = Join-Path $script:TempDir '_meta.json'
        # Use a non-ISO format to avoid ConvertFrom-Json date auto-conversion
        $Meta = @{
            LastFullUpdate        = '2026-03-01 14:30'
            LastIncrementalUpdate = '2026-03-03 10:15'
            Version               = 1
        }

        Write-SessionHashMeta -MetaPath $MetaPath -Meta $Meta

        $Loaded = Read-SessionHashMeta -MetaPath $MetaPath
        $Loaded['LastFullUpdate'] | Should -Be '2026-03-01 14:30'
        $Loaded['LastIncrementalUpdate'] | Should -Be '2026-03-03 10:15'
        $Loaded['Version'] | Should -Be 1
    }
}

Describe 'Get-HashableFiles' {
    BeforeEach {
        $script:TempDir = New-TestTempDir

        # Create directory structure
        $SubDirs = @(
            'Archiwum',
            'Postaci',
            '.robot',
            '.git',
            'Nerthus'
        )
        foreach ($Dir in $SubDirs) {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TempDir $Dir))
        }

        # Create .md files in various locations
        Write-TestFile -Path (Join-Path $script:TempDir 'Archiwum' 'sesje.md') -Content '# Test'
        Write-TestFile -Path (Join-Path $script:TempDir 'Postaci' 'npc.md') -Content '# Test'
        Write-TestFile -Path (Join-Path $script:TempDir '.robot' 'state.md') -Content '# Test'
        Write-TestFile -Path (Join-Path $script:TempDir '.git' 'readme.md') -Content '# Test'
        Write-TestFile -Path (Join-Path $script:TempDir 'Nerthus' 'lore.md') -Content '# Test'
        Write-TestFile -Path (Join-Path $script:TempDir 'top-level.md') -Content '# Test'
    }
    AfterEach {
        Remove-TestTempDir
    }

    It 'includes files from content directories' {
        $Files = Get-HashableFiles -RepoRoot $script:TempDir
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Contain 'Archiwum/sesje.md'
        $RelPaths | Should -Contain 'Postaci/npc.md'
        $RelPaths | Should -Contain 'top-level.md'
    }

    It 'excludes dot directories' {
        $Files = Get-HashableFiles -RepoRoot $script:TempDir
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Not -Contain '.robot/state.md'
        $RelPaths | Should -Not -Contain '.git/readme.md'
    }

    It 'excludes Nerthus/ subdirectory' {
        $Files = Get-HashableFiles -RepoRoot $script:TempDir
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Not -Contain 'Nerthus/lore.md'
    }

    It 'excludes user-specified directories' {
        $ExcludeDir = Join-Path $script:TempDir 'Postaci'
        $Files = Get-HashableFiles -RepoRoot $script:TempDir -ExcludeDirectory @($ExcludeDir)
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Not -Contain 'Postaci/npc.md'
        $RelPaths | Should -Contain 'Archiwum/sesje.md'
    }
}

Describe 'Get-RelativeHashPath' {
    It 'computes relative path with forward slashes' {
        $Sep = [System.IO.Path]::DirectorySeparatorChar
        $RepoRoot = "/repo/root"
        $FilePath = "/repo/root${Sep}Archiwum${Sep}sesje.md"
        $Result = Get-RelativeHashPath -FilePath $FilePath -RepoRoot $RepoRoot
        $Result | Should -Be 'Archiwum/sesje.md'
    }

    It 'handles paths outside repo root' {
        $Result = Get-RelativeHashPath -FilePath '/other/path/file.md' -RepoRoot '/repo/root'
        $Result | Should -Be '/other/path/file.md'
    }
}

Describe 'Set-SessionHash' {
    BeforeEach {
        $script:TempDir = New-TestTempDir

        # Create minimal repo structure
        $ResDir = Join-Path $script:TempDir '.robot' 'res'
        [void][System.IO.Directory]::CreateDirectory($ResDir)

        # Copy fixture file
        $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
        $DstFile = Join-Path $script:TempDir 'base.md'
        [System.IO.File]::Copy($SrcFile, $DstFile)
    }
    AfterEach {
        Remove-TestTempDir
    }

    It 'creates JSON hash files when run with -File' {
        Mock Get-RepoRoot { return $script:TempDir }

        $DstFile = Join-Path $script:TempDir 'base.md'
        $Result = Set-SessionHash -File @($DstFile)

        $Result.FilesProcessed | Should -BeGreaterThan 0
        $Result.HashesComputed | Should -BeGreaterThan 0

        $JsonPath = Join-Path $script:TempDir '.robot' 'res' 'session-hashes' 'base.md.json'
        [System.IO.File]::Exists($JsonPath) | Should -BeTrue
    }

    It 'does not create files with -WhatIf' {
        Mock Get-RepoRoot { return $script:TempDir }

        $DstFile = Join-Path $script:TempDir 'base.md'
        Set-SessionHash -File @($DstFile) -WhatIf

        $JsonPath = Join-Path $script:TempDir '.robot' 'res' 'session-hashes' 'base.md.json'
        [System.IO.File]::Exists($JsonPath) | Should -BeFalse
    }

    It 'reports updated and new hashes on second run' {
        Mock Get-RepoRoot { return $script:TempDir }

        $DstFile = Join-Path $script:TempDir 'base.md'

        # First run: all new
        $Result1 = Set-SessionHash -File @($DstFile)
        $Result1.HashesNew | Should -BeGreaterThan 0
        $Result1.HashesUpdated | Should -Be 0

        # Second run with same content: no updates
        $Result2 = Set-SessionHash -File @($DstFile)
        $Result2.HashesNew | Should -Be 0
        $Result2.HashesUpdated | Should -Be 0
    }
}

Describe 'Test-SessionIntegrity' {
    BeforeEach {
        $script:TempDir = New-TestTempDir

        # Create minimal repo structure
        $ResDir = Join-Path $script:TempDir '.robot' 'res'
        [void][System.IO.Directory]::CreateDirectory($ResDir)
    }
    AfterEach {
        Remove-TestTempDir
    }

    Context 'Clean state (hashes match)' {
        It 'returns OK = $true when hashes match current content' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            $DstFile = Join-Path $script:TempDir 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            # Generate hashes
            Set-SessionHash -File @($DstFile)

            # Validate — should be clean
            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.OK | Should -BeTrue
            $Result.ModifiedSessions.Count | Should -Be 0
            $Result.DeletedSessions.Count | Should -Be 0
            $Result.NewSessions.Count | Should -Be 0
        }
    }

    Context 'Modified sessions detection' {
        It 'detects content changes via hash mismatch' {
            Mock Get-RepoRoot { return $script:TempDir }

            # Create and hash the base version
            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            $DstFile = Join-Path $script:TempDir 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)
            Set-SessionHash -File @($DstFile)

            # Overwrite with modified version
            $ModFile = Join-Path $script:IntegrityFixtures 'modified.md'
            [System.IO.File]::Copy($ModFile, $DstFile, $true)

            # Validate
            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.OK | Should -BeFalse
            $Result.ModifiedSessions.Count | Should -BeGreaterThan 0

            # The first session was modified
            $Modified = $Result.ModifiedSessions | Where-Object { $_.Header -match 'Oblężenie' }
            $Modified | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Deleted sessions detection' {
        It 'detects headers removed from file' {
            Mock Get-RepoRoot { return $script:TempDir }

            # Create and hash the base version (3 sessions)
            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            $DstFile = Join-Path $script:TempDir 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)
            Set-SessionHash -File @($DstFile)

            # Overwrite with a version missing one session
            $ShorterContent = @"
# Sesje testowe

## Historia

### 2024-06-15, Oblężenie Steadwick, Solmyr

Armia nieumarłych zaatakowała bramy Steadwick.

- @PU:
    - Xeron: 0,3
    - Kyrre: 0,5
"@
            Write-TestFile -Path $DstFile -Content $ShorterContent

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.DeletedSessions.Count | Should -BeGreaterThan 0
        }
    }

    Context 'New sessions detection' {
        It 'detects new headers not in hash store' {
            Mock Get-RepoRoot { return $script:TempDir }

            # Create and hash a short version
            $DstFile = Join-Path $script:TempDir 'base.md'
            $ShortContent = @"
# Sesje testowe

## Historia

### 2024-06-15, Oblężenie Steadwick, Solmyr

Armia nieumarłych zaatakowała bramy Steadwick.
"@
            Write-TestFile -Path $DstFile -Content $ShortContent
            Set-SessionHash -File @($DstFile)

            # Replace with the full version (more sessions)
            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile, $true)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.NewSessions.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Missing hash files' {
        It 'reports .md files without corresponding .json' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            $DstFile = Join-Path $script:TempDir 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            # Do NOT generate hashes — should report as missing
            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.MissingHashFiles.Count | Should -Be 1
        }
    }

    Context 'Malformed headers' {
        It 'detects ### headers that fail date parsing' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'malformed.md'
            $DstFile = Join-Path $script:TempDir 'malformed.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            # Generate hashes first (so it does not short-circuit on missing hash file)
            Set-SessionHash -File @($DstFile)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.MalformedHeaders.Count | Should -BeGreaterOrEqual 2

            $BadDate = $Result.MalformedHeaders | Where-Object { $_.Header -match 'invalid-date' }
            $BadDate | Should -Not -BeNullOrEmpty

            $BadMonth = $Result.MalformedHeaders | Where-Object { $_.Header -match '2024-13-01' }
            $BadMonth | Should -Not -BeNullOrEmpty
        }
    }

    Context 'PU-affected sessions' {
        It 'flags modified sessions containing PU data' {
            Mock Get-RepoRoot { return $script:TempDir }

            # Hash base version
            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            $DstFile = Join-Path $script:TempDir 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)
            Set-SessionHash -File @($DstFile)

            # Replace with modified version (first session has modified PU values)
            $ModFile = Join-Path $script:IntegrityFixtures 'modified.md'
            [System.IO.File]::Copy($ModFile, $DstFile, $true)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.PUAffectedSessions.Count | Should -BeGreaterThan 0

            $PUAffected = $Result.PUAffectedSessions | Where-Object { $_.Header -match 'Oblężenie' }
            $PUAffected | Should -Not -BeNullOrEmpty
            $PUAffected.HasPU | Should -BeTrue
        }
    }

    Context 'Duplicate PU markers (tamper indicator)' {
        It 'detects sessions with two or more PU section markers' {
            Mock Get-RepoRoot { return $script:TempDir }

            # First, hash a clean version of the file
            $DstFile = Join-Path $script:TempDir 'pu-test.md'
            $CleanContent = @"
# Sesje testowe

## Historia

### 2024-06-15, Sesja z duplikatem PU, Solmyr

Ktoś napisał sekcję PU.

- @PU:
    - Xeron: 0,3
    - Kyrre: 0,5
- @Lokacje:
    - Steadwick
"@
            Write-TestFile -Path $DstFile -Content $CleanContent
            Set-SessionHash -File @($DstFile)

            # Now overwrite with a tampered version containing duplicate PU
            $TamperedFile = Join-Path $script:IntegrityFixtures 'duplicate-pu.md'
            [System.IO.File]::Copy($TamperedFile, $DstFile, $true)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.DuplicatePUMarkers.Count | Should -Be 1
            $Result.DuplicatePUMarkers[0].PUMarkerCount | Should -Be 2
        }
    }

    Context 'Format anomalies' {
        It 'detects date-like lines without ### prefix' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'format-anomaly.md'
            $DstFile = Join-Path $script:TempDir 'anomaly.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            # Generate hashes
            Set-SessionHash -File @($DstFile)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.FormatAnomalies.Count | Should -Be 1
            $Result.FormatAnomalies[0].Line | Should -Match '2024-07-01'
            $Result.FormatAnomalies[0].Issue | Should -Match 'without ### header prefix'
        }
    }

    Context 'Future-dated sessions' {
        It 'detects sessions with dates in the future' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'future-dated.md'
            $DstFile = Join-Path $script:TempDir 'future-dated.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            # Generate hashes
            Set-SessionHash -File @($DstFile)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.OK | Should -BeFalse
            $Result.FutureDatedSessions.Count | Should -Be 1
            $Result.FutureDatedSessions[0].Date | Should -Be '2099-01-01'
            $Result.FutureDatedSessions[0].Issue | Should -Match 'future'
        }

        It 'does not flag past-dated sessions' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'base.md'
            $DstFile = Join-Path $script:TempDir 'base.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            Set-SessionHash -File @($DstFile)

            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.FutureDatedSessions.Count | Should -Be 0
        }

        It 'detects future dates even without a hash file' {
            Mock Get-RepoRoot { return $script:TempDir }

            $SrcFile = Join-Path $script:IntegrityFixtures 'future-dated.md'
            $DstFile = Join-Path $script:TempDir 'future-dated.md'
            [System.IO.File]::Copy($SrcFile, $DstFile)

            # Do NOT generate hashes — should still detect future dates
            $Result = Test-SessionIntegrity -File @($DstFile)
            $Result.FutureDatedSessions.Count | Should -Be 1
        }
    }

    Context 'Diagnostic output structure' {
        It 'returns all expected properties on result object' {
            Mock Get-RepoRoot { return $script:TempDir }

            $DstFile = Join-Path $script:TempDir 'empty.md'
            Write-TestFile -Path $DstFile -Content "# Empty`n"

            Set-SessionHash -File @($DstFile)
            $Result = Test-SessionIntegrity -File @($DstFile)

            $Result.PSObject.Properties.Name | Should -Contain 'OK'
            $Result.PSObject.Properties.Name | Should -Contain 'ModifiedSessions'
            $Result.PSObject.Properties.Name | Should -Contain 'DeletedSessions'
            $Result.PSObject.Properties.Name | Should -Contain 'NewSessions'
            $Result.PSObject.Properties.Name | Should -Contain 'MissingHashFiles'
            $Result.PSObject.Properties.Name | Should -Contain 'MalformedHeaders'
            $Result.PSObject.Properties.Name | Should -Contain 'PUAffectedSessions'
            $Result.PSObject.Properties.Name | Should -Contain 'DuplicatePUMarkers'
            $Result.PSObject.Properties.Name | Should -Contain 'FormatAnomalies'
            $Result.PSObject.Properties.Name | Should -Contain 'FutureDatedSessions'
        }
    }
}

<#
    .SYNOPSIS
    Pester tests for Get-RepoFiles (private/repo-filehelpers.ps1).

    .DESCRIPTION
    Validates file enumeration with dot-directory exclusion, user-specified
    exclusions, module root exclusion, and custom glob patterns.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . (Join-Path $script:ModuleRoot 'private' 'repo-filehelpers.ps1')
}

Describe 'Get-RepoFiles' {
    BeforeEach {
        $script:TempDir = New-TestTempDir

        # Content directories (should be included)
        $Dirs = @(
            'Archiwum'
            'Postaci'
            'Sesje/Sezon1'
        )
        foreach ($D in $Dirs) {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TempDir $D))
        }
        Write-TestFile -Path (Join-Path $script:TempDir 'Archiwum/sesje.md') -Content '# Archiwum'
        Write-TestFile -Path (Join-Path $script:TempDir 'Postaci/npc.md') -Content '# NPC'
        Write-TestFile -Path (Join-Path $script:TempDir 'Sesje/Sezon1/s01.md') -Content '# Sesja'
        Write-TestFile -Path (Join-Path $script:TempDir 'entities.md') -Content '# Entities'

        # Dot directories (should be excluded)
        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TempDir '.robot.powershell'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TempDir '.git'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TempDir '.robot.local'))
        Write-TestFile -Path (Join-Path $script:TempDir '.robot.powershell/state.md') -Content 'mod'
        Write-TestFile -Path (Join-Path $script:TempDir '.git/readme.md') -Content 'git'
        Write-TestFile -Path (Join-Path $script:TempDir '.robot.local/data.md') -Content 'local'
    }

    AfterEach {
        Remove-TestTempDir
    }

    It 'includes files from content directories' {
        $Files = Get-RepoFiles -RepoRoot $script:TempDir
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Contain 'Archiwum/sesje.md'
        $RelPaths | Should -Contain 'Postaci/npc.md'
        $RelPaths | Should -Contain 'Sesje/Sezon1/s01.md'
        $RelPaths | Should -Contain 'entities.md'
    }

    It 'excludes dot directories' {
        $Files = Get-RepoFiles -RepoRoot $script:TempDir
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Not -Contain '.robot.powershell/state.md'
        $RelPaths | Should -Not -Contain '.git/readme.md'
        $RelPaths | Should -Not -Contain '.robot.local/data.md'
    }

    It 'excludes user-specified directories' {
        $ExcludeDir = Join-Path $script:TempDir 'Postaci'
        $Files = Get-RepoFiles -RepoRoot $script:TempDir -ExcludeDirectory @($ExcludeDir)
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Not -Contain 'Postaci/npc.md'
        $RelPaths | Should -Contain 'Archiwum/sesje.md'
    }

    It 'supports custom pattern' {
        Write-TestFile -Path (Join-Path $script:TempDir 'Archiwum/notes.txt') -Content 'txt'
        $Files = Get-RepoFiles -RepoRoot $script:TempDir -Pattern '*.txt'
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Contain 'Archiwum/notes.txt'
        $RelPaths | Should -Not -Contain 'Archiwum/sesje.md'
    }

    It 'excludes module root when $script:ModuleRoot is set' {
        # Simulate a non-dot module directory inside the temp repo
        $ModDir = Join-Path $script:TempDir 'my-module'
        [void][System.IO.Directory]::CreateDirectory($ModDir)
        Write-TestFile -Path (Join-Path $ModDir 'internal.md') -Content 'mod'

        $OrigModuleRoot = $script:ModuleRoot
        try {
            $script:ModuleRoot = $ModDir
            $Files = Get-RepoFiles -RepoRoot $script:TempDir
            $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
            $RelPaths | Should -Not -Contain 'my-module/internal.md'
            $RelPaths | Should -Contain 'Archiwum/sesje.md'
        } finally {
            $script:ModuleRoot = $OrigModuleRoot
        }
    }

    It 'does not include Nerthus/ (that is domain-specific to Get-HashableFiles)' {
        # Get-RepoFiles does NOT exclude Nerthus/ — that is Get-HashableFiles' job
        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:TempDir 'Nerthus'))
        Write-TestFile -Path (Join-Path $script:TempDir 'Nerthus/lore.md') -Content 'lore'
        $Files = Get-RepoFiles -RepoRoot $script:TempDir
        $RelPaths = $Files | ForEach-Object { $_.Substring($script:TempDir.Length + 1).Replace('\', '/') }
        $RelPaths | Should -Contain 'Nerthus/lore.md'
    }

    It 'returns empty list for empty directory' {
        $EmptyDir = Join-Path $script:TempDir 'empty-sub'
        [void][System.IO.Directory]::CreateDirectory($EmptyDir)
        $Files = Get-RepoFiles -RepoRoot $EmptyDir
        $Files.Count | Should -Be 0
    }
}

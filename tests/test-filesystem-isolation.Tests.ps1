<#
    .SYNOPSIS
    Sentinel test that fails if any test in the suite leaks files into the
    module directory.

    .DESCRIPTION
    Snapshots a known allowlist of expected top-level entries in $script:ModuleRoot
    and fails if anything else is present. Catches future regressions where a new
    test forgets Mock Get-RepoRoot or bypasses the filesystem firewall in
    TestHelpers.ps1 / PluginTestHelpers.ps1.

    Lexicographical ordering of the tests/ directory places this file near the
    end of the run, so it sees the state left by every preceding test.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    $script:ExpectedTopLevel = @(
        '.git', '.github', '.gitignore', '.robot.local',
        'devdocs', 'docs', 'lib', 'migration', 'plugins',
        'private', 'public', 'templates', 'tests', 'tools',
        'LICENSE', 'README.md', 'Robot.PowerShell.psd1',
        'Robot.PowerShell.psm1', 'VERSION'
    )
}

Describe 'Filesystem isolation' {
    It 'leaves no unexpected files or directories in the module root' {
        $Actual = [System.IO.Directory]::EnumerateFileSystemEntries($script:ModuleRoot) |
            ForEach-Object { [System.IO.Path]::GetFileName($_) }
        $Unexpected = @($Actual | Where-Object { $_ -notin $script:ExpectedTopLevel })
        $Unexpected | Should -BeNullOrEmpty -Because "Tests must not write into the module directory; check that every test file mocks Get-RepoRoot or relies on the filesystem firewall. Leaked entries: $($Unexpected -join ', ')"
    }
}

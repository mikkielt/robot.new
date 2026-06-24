<#
    .SYNOPSIS
    Shared test bootstrap for all Pester test files.

    .DESCRIPTION
    Provides common variables, utility functions, and module import helpers.
    Every test file should dot-source this in its BeforeAll block:

        . "$PSScriptRoot/TestHelpers.ps1"
#>

# Root paths
$script:ModuleRoot   = Split-Path $PSScriptRoot -Parent
$script:FixturesRoot = Join-Path $PSScriptRoot 'fixtures'

# Warning suppression support - mirrors Robot.PowerShell.psm1 definitions so that
# dot-sourced files (pattern B/C/D) can call Write-RobotWarning/Write-RobotInfo
# in the test scope.
$script:SuppressWarnings = $false

function Write-RobotWarning {
    param([Parameter(Mandatory)] [string]$Message)
    if (-not $script:SuppressWarnings) {
        [System.Console]::Error.WriteLine($Message)
    }
}

function Write-RobotInfo {
    param([Parameter(Mandatory)] [string]$Message)
    if (-not $script:SuppressWarnings) {
        [System.Console]::Error.WriteLine($Message)
    }
}

# Temp directory (unique per test run)
$script:TempRoot = $null

function New-TestTempDir {
    <#
        .SYNOPSIS
        Creates a disposable temp directory for write tests.
    #>
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-test-" + [System.Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)
    return $script:TempRoot
}

function Remove-TestTempDir {
    <#
        .SYNOPSIS
        Cleans up the temp directory created by New-TestTempDir.
    #>
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
    $script:TempRoot = $null
}

# Filesystem firewall — default Get-RepoRoot override
$script:FilesystemFirewallRoot = $null
$script:OriginalRepoRoot       = $null

function Initialize-TestFilesystemFirewall {
    <#
        .SYNOPSIS
        Installs a default Get-RepoRoot override pointing at a disposable
        per-process directory. Any test that forgets to Mock Get-RepoRoot
        will write here instead of the module directory.

        Explicit Mock Get-RepoRoot calls in test files override this — Pester
        intercepts the cmdlet before its body runs, so $RepoRootOverride is
        never consulted when a mock is in scope.

        Captures the pre-firewall Get-RepoRoot result into $script:OriginalRepoRoot
        for tests that genuinely need access to the real repository (e.g. git
        history tests in get-gitchangelog.Tests.ps1).
    #>
    if ($script:FilesystemFirewallRoot -and [System.IO.Directory]::Exists($script:FilesystemFirewallRoot)) {
        Set-RepoRoot -Path $script:FilesystemFirewallRoot
        return
    }
    if (-not $script:OriginalRepoRoot) {
        $script:OriginalRepoRoot = Get-RepoRoot -Optional
    }
    $script:FilesystemFirewallRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-test-firewall-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
    [void][System.IO.Directory]::CreateDirectory($script:FilesystemFirewallRoot)
    Set-RepoRoot -Path $script:FilesystemFirewallRoot
}

function Remove-TestFilesystemFirewall {
    <#
        .SYNOPSIS
        Removes the firewall directory and clears the Get-RepoRoot override.
    #>
    if ($script:FilesystemFirewallRoot -and [System.IO.Directory]::Exists($script:FilesystemFirewallRoot)) {
        [System.IO.Directory]::Delete($script:FilesystemFirewallRoot, $true)
    }
    $script:FilesystemFirewallRoot = $null
    Set-RepoRoot -Reset
}

function Copy-FixtureToTemp {
    <#
        .SYNOPSIS
        Copies a fixture file into the temp directory.
        Returns the destination path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureName,

        [string]$DestName
    )

    if (-not $DestName) { $DestName = $FixtureName }

    $Src = Join-Path $script:FixturesRoot $FixtureName
    $Dst = Join-Path $script:TempRoot $DestName

    # Ensure parent directory exists
    $DstDir = [System.IO.Path]::GetDirectoryName($Dst)
    if (-not [System.IO.Directory]::Exists($DstDir)) {
        [void][System.IO.Directory]::CreateDirectory($DstDir)
    }

    [System.IO.File]::Copy($Src, $Dst, $true)
    return $Dst
}

function Import-RobotModule {
    <#
        .SYNOPSIS
        Imports the robot module with -Force and installs the filesystem firewall.

        The firewall sets a default Get-RepoRoot override pointing at a disposable
        temp directory, so tests that forget Mock Get-RepoRoot write there instead
        of the module directory.
    #>
    Import-Module (Join-Path $script:ModuleRoot 'Robot.PowerShell.psd1') -Force
    Initialize-TestFilesystemFirewall
}

function Import-RobotHelpers {
    <#
        .SYNOPSIS
        Dot-sources a helper file by name from the module root.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )
    . (Join-Path $script:ModuleRoot 'private' $FileName)
}

function Invoke-FixtureMigrations {
    <#
        .SYNOPSIS
        Runs the migration chain against a fixture directory (WP-14).

        .DESCRIPTION
        Swaps Get-RepoRoot to point at $FixturePath, runs Invoke-MigrationChain
        to advance the fixture to TargetVersion (default 'latest'), then
        restores the original repo root. Migrations under $FixturePath must
        use $Config.RepoRoot (not hardcoded paths) to work in fixture mode.
    #>
    param(
        [Parameter(Mandatory)] [string]$FixturePath,
        [string]$TargetVersion = 'latest'
    )
    $OriginalRoot = Get-RepoRoot -Optional
    try {
        Set-RepoRoot -Path $FixturePath
        Invoke-MigrationChain -To $TargetVersion -BranchMode InPlace -AllowUnsigned -Confirm:$false
    } finally {
        if ($OriginalRoot) { Set-RepoRoot -Path $OriginalRoot } else { Set-RepoRoot -Reset }
    }
}

function Write-TestFile {
    <#
        .SYNOPSIS
        Writes UTF-8 no-BOM content to a file path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

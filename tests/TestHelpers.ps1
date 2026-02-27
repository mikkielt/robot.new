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
    [System.IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null
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
        [System.IO.Directory]::CreateDirectory($DstDir) | Out-Null
    }

    [System.IO.File]::Copy($Src, $Dst, $true)
    return $Dst
}

function Import-RobotModule {
    <#
        .SYNOPSIS
        Imports the robot module with -Force.
    #>
    Import-Module (Join-Path $script:ModuleRoot 'robot.psd1') -Force
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
    . (Join-Path $script:ModuleRoot $FileName)
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

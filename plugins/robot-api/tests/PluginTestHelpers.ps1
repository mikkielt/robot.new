<#
    .SYNOPSIS
    Shared test bootstrap for robot-api plugin tests.

    .DESCRIPTION
    Imports Robot.PowerShell.psm1 and installs the filesystem firewall
    (Set-RepoRoot override pointing at a per-process disposable temp dir).
    Every plugin test that exercises write handlers MUST dot-source this in
    BeforeAll and call Import-RobotModuleForPlugin instead of Import-Module
    directly. Without it, Get-RepoRoot's standalone-checkout fallback returns
    the module directory and writes leak into the working tree.

    Mirrors the firewall in tests/TestHelpers.ps1 and reuses the same
    per-process directory so the entire Pester run shares one disposable root.
#>

$script:PluginModuleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

function Import-RobotModuleForPlugin {
    <#
        .SYNOPSIS
        Imports Robot.PowerShell.psm1 and installs the filesystem firewall.
    #>
    Import-Module (Join-Path $script:PluginModuleRoot 'Robot.PowerShell.psd1') -Force -WarningAction SilentlyContinue
    Initialize-PluginFilesystemFirewall
}

function Initialize-PluginFilesystemFirewall {
    <#
        .SYNOPSIS
        Sets Get-RepoRoot to a disposable per-process temp directory.

        Explicit Mock Get-RepoRoot calls in test files still override this
        because Pester intercepts the cmdlet before its body runs.
    #>
    $FirewallRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-test-firewall-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
    if (-not [System.IO.Directory]::Exists($FirewallRoot)) {
        [void][System.IO.Directory]::CreateDirectory($FirewallRoot)
    }
    Set-RepoRoot -Path $FirewallRoot
}

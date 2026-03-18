<#
    .SYNOPSIS
    Standalone dashboard launcher via iwr | iex.

    .DESCRIPTION
    Quick launcher that imports the Robot module (downloading if needed),
    starts the API server on an ephemeral port, opens the dashboard in
    the browser, and waits for Ctrl+C to shut down.

    Usage:
      iwr https://raw.githubusercontent.com/mikkielt/robot.new/main/tools/dashboard.ps1 | iex

    Works on Windows (PowerShell 7+), macOS, and Linux (PowerShell Core).
#>

param(
    [string]$ModulePath,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'

# ── Find or download module ──────────────────────────────────────
$Candidates = @(
    $ModulePath,
    [System.IO.Path]::Combine($PSScriptRoot, '..'),
    [System.IO.Path]::Combine($HOME, 'robot.new'),
    [System.IO.Path]::Combine($PWD, '.robot.new')
).Where({ $_ -and [System.IO.File]::Exists([System.IO.Path]::Combine($_, 'robot.psm1')) })

if ($Candidates.Count -eq 0) {
    Write-Host 'Robot module not found. Run install.ps1 first or pass -ModulePath.' -ForegroundColor Red
    Write-Host '  iwr https://raw.githubusercontent.com/mikkielt/robot.new/main/tools/install.ps1 | iex'
    return
}

$ModRoot = $Candidates[0]
Write-Host "Using module at: $ModRoot" -ForegroundColor Cyan

# ── Import module ─────────────────────────────────────────────────
Import-Module "$ModRoot/robot.psm1" -Force -WarningAction SilentlyContinue

# ── Start API if not running ─────────────────────────────────────
$Status = Get-RobotApiStatus
if (-not $Status.IsRunning) {
    $StartParams = @{ Quiet = $true }
    if ($Port -gt 0) { $StartParams.Port = $Port }
    Write-Host 'Starting API server...' -ForegroundColor Cyan
    Start-RobotApi @StartParams
}

# Determine actual port
$Config = Get-PluginConfig -PluginName 'robot-api'
$ActualPort = if ($Port -gt 0) { $Port }
              elseif ($Config.ListenPort) { $Config.ListenPort }
              else { 8642 }

$Url = "http://localhost:$ActualPort/api/dashboard"
Write-Host "Dashboard: $Url" -ForegroundColor Green

# ── Open browser ──────────────────────────────────────────────────
if ($IsMacOS -or ($PSVersionTable.OS -and $PSVersionTable.OS.Contains('Darwin'))) {
    Start-Process 'open' -ArgumentList $Url
}
elseif ($IsLinux -or ($PSVersionTable.OS -and $PSVersionTable.OS.Contains('Linux'))) {
    Start-Process 'xdg-open' -ArgumentList $Url
}
else {
    Start-Process $Url
}

# ── Wait for Ctrl+C ──────────────────────────────────────────────
Write-Host ''
Write-Host 'Press Ctrl+C to stop the server...' -ForegroundColor DarkGray

try {
    while ($true) {
        Start-Sleep -Seconds 1
    }
} finally {
    Write-Host 'Stopping server...' -ForegroundColor Yellow
    Stop-RobotApi
    Write-Host 'Done.' -ForegroundColor Green
}

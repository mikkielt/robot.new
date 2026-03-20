<#
    .SYNOPSIS
    Bootstrap script for Robot module installation via iwr | iex.

    .DESCRIPTION
    Downloads and sets up the Robot PowerShell module for Nerthus campaign
    management. Checks prerequisites, clones the repository, creates a
    minimal .robot directory structure, imports the module, and optionally
    starts the API server with a dashboard.

    Usage:
      iwr https://raw.githubusercontent.com/mikkielt/robot.new/main/tools/install.ps1 | iex

    Works on Windows (PowerShell 5+), macOS, and Linux (PowerShell Core).
#>

param(
    [string]$InstallPath = ([System.IO.Path]::Combine($HOME, 'robot.new')),
    [string]$RepoUrl = 'https://github.com/mikkielt/robot.new.git',
    [switch]$StartApi,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

# ── Prerequisites ─────────────────────────────────────────────────
Write-Host '[1/5] Checking prerequisites...' -ForegroundColor Cyan

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.0+ required. Current: $($PSVersionTable.PSVersion). Install from https://aka.ms/powershell"
}

$GitPath = Get-Command 'git' -ErrorAction SilentlyContinue
if (-not $GitPath) {
    throw 'Git not found. Install from https://git-scm.com'
}

Write-Host "  PowerShell $($PSVersionTable.PSVersion) - OK" -ForegroundColor Green
Write-Host "  Git $(& git --version) - OK" -ForegroundColor Green

# ── Clone / Update ────────────────────────────────────────────────
Write-Host '[2/5] Setting up module...' -ForegroundColor Cyan

if ([System.IO.Directory]::Exists($InstallPath)) {
    Write-Host "  Directory exists at $InstallPath — pulling latest..." -ForegroundColor Yellow
    Push-Location $InstallPath
    try {
        & git pull --ff-only 2>&1 | ForEach-Object { Write-Host "  $_" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  Cloning to $InstallPath..."
    & git clone $RepoUrl $InstallPath 2>&1 | ForEach-Object { Write-Host "  $_" }
}

if (-not [System.IO.File]::Exists([System.IO.Path]::Combine($InstallPath, 'Robot.PowerShell.psm1'))) {
    throw "Robot.PowerShell.psm1 not found at $InstallPath — installation failed"
}

# ── Minimal .robot structure ──────────────────────────────────────
Write-Host '[3/5] Creating minimal config...' -ForegroundColor Cyan

$RobotDir = [System.IO.Path]::Combine($InstallPath, '.robot.local')
if (-not [System.IO.Directory]::Exists($RobotDir)) {
    [void][System.IO.Directory]::CreateDirectory($RobotDir)
    Write-Host "  Created $RobotDir"
}

$ResDir = [System.IO.Path]::Combine($RobotDir, 'res')
if (-not [System.IO.Directory]::Exists($ResDir)) {
    [void][System.IO.Directory]::CreateDirectory($ResDir)
}

# ── Import & Verify ──────────────────────────────────────────────
Write-Host '[4/5] Importing module...' -ForegroundColor Cyan

Import-Module "$InstallPath/Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue

if (-not $SkipVerify) {
    try {
        $Status = Get-RobotApiStatus
        Write-Host "  Module loaded. API status: $($Status.IsRunning)" -ForegroundColor Green
    } catch {
        Write-Host '  Module loaded (API plugin may require lore repository context)' -ForegroundColor Yellow
    }
}

# ── Optional: Start API ──────────────────────────────────────────
if ($StartApi) {
    Write-Host '[5/5] Starting API server...' -ForegroundColor Cyan
    try {
        Start-RobotApi -Quiet
        $Status = Get-RobotApiStatus
        Write-Host "  API running on port 8642 (requests: $($Status.RequestCount))" -ForegroundColor Green

        $HasDashboard = Get-Command 'Invoke-RobotDashboard' -ErrorAction SilentlyContinue
        if ($HasDashboard) {
            Write-Host '  Opening dashboard...' -ForegroundColor Cyan
            [void](Invoke-RobotDashboard)
        }
    } catch {
        Write-Host "  Could not start API: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host '[5/5] Skipping API start (use -StartApi to auto-start)' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Installation complete!' -ForegroundColor Green
Write-Host "  Module path:  $InstallPath" -ForegroundColor DarkGray
Write-Host '  Import:       Import-Module ./Robot.PowerShell.psm1' -ForegroundColor DarkGray
Write-Host '  Start API:    Start-RobotApi' -ForegroundColor DarkGray
Write-Host '  Dashboard:    Invoke-RobotDashboard' -ForegroundColor DarkGray

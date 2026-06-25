<#
    .SYNOPSIS
    0.1.0-verify-environment: Inspect-only environment audit.

    .DESCRIPTION
    Read-only checks performed at the start of bootstrap.
    Produces .robot.local/migration-artifacts/0.1.0-verify-environment/env-report.json
    which downstream migrations (0.1.1-bootstrap-entities) consume as advisory
    input. No writes outside the artifact directory.

    Checks:
    - Repository tracked by git, working tree state
    - pre-migration safety tag presence
    - .robot.local/res/pu-sessions.json + discord-delivery.json presence
    - .gitmodules contains .robot.powershell submodule
    - Robot.PowerShell module loaded with reasonable command count
    - .robot.local/robot-data.psd1 manifest present and valid
    - entities.md existence + section coverage (NPC, Grupa, Lokacja, Przedmiot)

    Per CC-N1 this is an Inspect-archetype migration. It advances the schema
    pointer to 0.1.0 to record that inspection ran (idempotent: re-running
    refreshes the artifact).
#>

function Read-EnvReport {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $Report = [ordered]@{
        GitRepository       = $false
        GitWorkingTreeClean = $false
        PreMigrationTag     = $false
        ResDirExists        = $false
        PUSessionsMd        = $false
        PUSessionsJson      = $false
        DiscordMd           = $false
        DiscordJson         = $false
        SubmoduleDeclared   = $false
        ModuleLoaded        = $false
        ModuleCommandCount  = 0
        ManifestExists      = $false
        ManifestValid       = $false
        EntitiesExists      = $false
        EntitiesLineCount   = 0
        EntitiesSections    = @{
            NPC       = $false
            Grupa     = $false
            Lokacja   = $false
            Przedmiot = $false
        }
        SourceGracze        = $false
    }

    # ── Git checks ────────────────────────────────────────────────────────
    $GitDir = [System.IO.Path]::Combine($RepoRoot, '.git')
    if ([System.IO.Directory]::Exists($GitDir) -or [System.IO.File]::Exists($GitDir)) {
        $Report.GitRepository = $true
        $GitStatus = & git -C $RepoRoot status --porcelain 2>&1
        if ($LASTEXITCODE -eq 0) {
            $Report.GitWorkingTreeClean = [string]::IsNullOrWhiteSpace([string]$GitStatus)
        }
        $TagOutput = & git -C $RepoRoot tag -l 'pre-migration' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $Report.PreMigrationTag = -not [string]::IsNullOrWhiteSpace([string]$TagOutput)
        }
    }

    # ── State files ───────────────────────────────────────────────────────
    $ResDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res')
    $Report.ResDirExists = [System.IO.Directory]::Exists($ResDir)
    if ($Report.ResDirExists) {
        $Report.PUSessionsMd   = [System.IO.File]::Exists([System.IO.Path]::Combine($ResDir, 'pu-sessions.md'))
        $Report.PUSessionsJson = [System.IO.File]::Exists([System.IO.Path]::Combine($ResDir, 'pu-sessions.json'))
        $Report.DiscordMd      = [System.IO.File]::Exists([System.IO.Path]::Combine($ResDir, 'discord-delivery.md'))
        $Report.DiscordJson    = [System.IO.File]::Exists([System.IO.Path]::Combine($ResDir, 'discord-delivery.json'))
    }

    # ── Submodule registration ────────────────────────────────────────────
    $GitmodulesPath = [System.IO.Path]::Combine($RepoRoot, '.gitmodules')
    if ([System.IO.File]::Exists($GitmodulesPath)) {
        $GitmodulesContent = [System.IO.File]::ReadAllText($GitmodulesPath)
        $Report.SubmoduleDeclared = $GitmodulesContent.Contains('.robot.powershell')
    }

    # ── Module load ───────────────────────────────────────────────────────
    $Commands = Get-Command -Module Robot.PowerShell -ErrorAction SilentlyContinue
    $Report.ModuleCommandCount = @($Commands).Count
    $Report.ModuleLoaded = ($Report.ModuleCommandCount -ge 30)

    # ── Manifest ──────────────────────────────────────────────────────────
    $ManifestPath = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'robot-data.psd1')
    if ([System.IO.File]::Exists($ManifestPath)) {
        $Report.ManifestExists = $true
        try {
            $ManifestData = Import-PowerShellDataFile -Path $ManifestPath
            $Report.ManifestValid = $ManifestData.ContainsKey('EntitiesFile')
        } catch {
            $Report.ManifestValid = $false
        }
    }

    # ── entities.md + sections ────────────────────────────────────────────
    $EntitiesPath = [System.IO.Path]::Combine($RepoRoot, 'entities.md')
    if ([System.IO.File]::Exists($EntitiesPath)) {
        $Report.EntitiesExists = $true
        $Lines = [System.IO.File]::ReadAllLines($EntitiesPath)
        $Report.EntitiesLineCount = $Lines.Count
        $Text = [string]::Join("`n", $Lines)
        $Report.EntitiesSections.NPC       = $Text.Contains('## NPC')
        $Report.EntitiesSections.Grupa     = $Text.Contains('## Grupa')
        $Report.EntitiesSections.Lokacja   = $Text.Contains('## Lokacja')
        $Report.EntitiesSections.Przedmiot = $Text.Contains('## Przedmiot')
    }

    # ── Source Gracze.md presence (informational for downstream bootstrap) ──
    $Report.SourceGracze = [System.IO.File]::Exists(
        [System.IO.Path]::Combine($RepoRoot, 'Gracze.md'))

    return $Report
}

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    $ArtifactDir = [System.IO.Path]::Combine(
        $Config.RepoRoot, '.robot.local', 'migration-artifacts', '0.1.0-verify-environment')
    return [PSCustomObject]@{
        Migration            = '0.1.0-verify-environment'
        EstimatedDurationSec = 5
        FilesToModify        = @()
        FilesToCreate        = @([System.IO.Path]::Combine($ArtifactDir, 'env-report.json'))
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Inspect-only: writes only to migration-artifacts directory.')
        NetworkRequired      = $false
        SourceUnchanged      = $false
        ChangeRecords        = @()
    }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [hashtable]$Checklist
    )

    $Report = Read-EnvReport -RepoRoot $Config.RepoRoot
    $ArtifactPath = Write-MigrationArtifactFile `
        -MigrationId '0.1.0-verify-environment' `
        -Name 'env-report' `
        -Value $Report `
        -RepoRoot $Config.RepoRoot

    return [PSCustomObject]@{
        OK           = $true
        FilesWritten = @($ArtifactPath)
    }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    # Inspect migrations are intentionally not idempotent on the artifact —
    # operators may rerun to refresh the report. Schema-pointer idempotency
    # is handled by the framework's Set-SchemaVersion which is itself
    # idempotent (no-op if already at this version).
    return $false
}

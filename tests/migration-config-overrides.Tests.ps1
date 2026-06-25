<#
    .SYNOPSIS
    Pester tests for Invoke-MigrationInternal Config + Overrides extension (WP-A3).

    .DESCRIPTION
    Stages a synthetic migration with declared ConfigSchema; exercises:
    - default fill on absent Config
    - rejection of unknown Config field
    - rejection of missing Required Config field
    - Overrides accepted when preview-cache is absent
    - Overrides accepted when key is present in preview-cache
    - Overrides rejected when key is absent from preview-cache
    - chain partitioning: per-migration Config / Overrides delivered correctly
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'plugin-hooks.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-config.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-artifact.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-log.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-runtime.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migration.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'invoke-migrationchain.ps1')

    function New-CfgRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-cfg-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-CfgRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }

    function New-SyntheticMigration {
        param(
            [Parameter(Mandatory)] [string]$RepoRoot,
            [Parameter(Mandatory)] [string]$Version,
            [Parameter(Mandatory)] [string]$Slug,
            [hashtable]$ConfigSchema = @{},
            [string]$BodyExtra = ''
        )
        $Dir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'migrations', "$Version-$Slug")
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $SchemaStr = ($ConfigSchema | ConvertTo-Json -Depth 5 -Compress)
        if ([string]::IsNullOrWhiteSpace($SchemaStr) -or $SchemaStr -eq '{}') {
            $SchemaLiteral = '@{}'
        } else {
            $Builder = [System.Text.StringBuilder]::new()
            [void]$Builder.Append('@{')
            foreach ($Key in $ConfigSchema.Keys) {
                $Field = $ConfigSchema[$Key]
                [void]$Builder.Append("$Key = @{ ")
                foreach ($SubKey in $Field.Keys) {
                    $Val = $Field[$SubKey]
                    if ($Val -is [bool])   { $V = if ($Val) { '$true' } else { '$false' } }
                    elseif ($Val -is [int]) { $V = "$Val" }
                    else                    { $V = "'" + ([string]$Val).Replace("'", "''") + "'" }
                    [void]$Builder.Append("$SubKey = $V; ")
                }
                [void]$Builder.Append('}; ')
            }
            [void]$Builder.Append('}')
            $SchemaLiteral = $Builder.ToString()
        }
        $Manifest = @"
@{
    Version              = '$Version'
    MajorName            = ''
    Slug                 = '$Slug'
    Description          = 'synthetic test migration'
    Author               = 'Test'
    AffectsCategories    = @('StateFile')
    EstimatedDurationSec = 1
    RequiresNetwork      = `$false
    Archetype            = 'Transform'
    ConfigSchema         = $SchemaLiteral
}
"@
        $UTF8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Dir, 'migration.psd1'), $Manifest, $UTF8)
        $MigrateBody = @"
function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]`$Config)
    return [PSCustomObject]@{
        Migration = '$Version-$Slug'
        FilesToCreate = @(); FilesToModify = @(); FilesToDelete = @()
        EntityCountsBefore = @{}; EntityCountsAfter = @{}
        SampleDiffs = @(); Warnings = @()
        NetworkRequired = `$false; SourceUnchanged = `$false
        ChangeRecords = @()
    }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]`$Config,
          [scriptblock]`$ProgressCallback, [hashtable]`$Checklist)
    `$RepoRoot = `$Config.RepoRoot
    `$ProbePath = [System.IO.Path]::Combine(`$RepoRoot, '$Version-$Slug.probe.json')
    `$Probe = [PSCustomObject]@{
        MigrationConfig = `$Config.Migration
        Overrides       = `$Config.Overrides
    }
    `$Json = `$Probe | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText(`$ProbePath, `$Json,
        [System.Text.UTF8Encoding]::new(`$false))
    $BodyExtra
    return [PSCustomObject]@{ OK = `$true; FilesWritten = @(`$ProbePath) }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]`$Checklist)
    return `$false
}
"@
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Dir, 'migrate.ps1'), $MigrateBody, $UTF8)
    }
}

Describe 'Invoke-Migration — Config defaults merge' {
    It 'fills defaults when no Config supplied' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'cfg-defaults' -ConfigSchema @{
                Name = @{ Type='String'; Default='alice' }
                Count = @{ Type='Int'; Default=7 }
            }
            Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Confirm:$false | Out-Null
            $Probe = Get-Content -Raw (Join-Path $R '0.1.0-cfg-defaults.probe.json') | ConvertFrom-Json
            $Probe.MigrationConfig.Name | Should -Be 'alice'
            $Probe.MigrationConfig.Count | Should -Be 7
        } finally { Remove-CfgRepoRoot -Path $R }
    }

    It 'supplied Config overrides defaults' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'cfg-supplied' -ConfigSchema @{
                Name = @{ Type='String'; Default='alice' }
            }
            Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Config @{ Name='bob' } -Confirm:$false | Out-Null
            $Probe = Get-Content -Raw (Join-Path $R '0.1.0-cfg-supplied.probe.json') | ConvertFrom-Json
            $Probe.MigrationConfig.Name | Should -Be 'bob'
        } finally { Remove-CfgRepoRoot -Path $R }
    }
}

Describe 'Invoke-Migration — Config validation' {
    It 'rejects unknown Config field' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'cfg-unknown' -ConfigSchema @{
                Name = @{ Type='String'; Default='x' }
            }
            { Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Config @{ Unknown=1 } -Confirm:$false } | Should -Throw
        } finally { Remove-CfgRepoRoot -Path $R }
    }

    It 'rejects missing Required field' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'cfg-required' -ConfigSchema @{
                Name = @{ Type='String'; Required=$true }
            }
            { Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Confirm:$false } | Should -Throw
        } finally { Remove-CfgRepoRoot -Path $R }
    }
}

Describe 'Invoke-Migration — Overrides validation' {
    It 'accepts Overrides when no preview-cache is present' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'ovr-nocache' -ConfigSchema @{}
            Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Overrides @{ 'k:a'='v' } -Confirm:$false | Out-Null
            $Probe = Get-Content -Raw (Join-Path $R '0.1.0-ovr-nocache.probe.json') | ConvertFrom-Json
            $Probe.Overrides.'k:a' | Should -Be 'v'
        } finally { Remove-CfgRepoRoot -Path $R }
    }

    It 'accepts Overrides when key is in preview-cache' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'ovr-cached' -ConfigSchema @{}
            $MigId = '0.1.0-ovr-cached'
            $Cache = [PSCustomObject]@{
                MigrationId = $MigId; Generated = 'now'; ChangeRecordCount = 1
                OverrideKeys = @('k:a')
            }
            Set-MigrationArtifact -SourceMigration $MigId -Name '.preview-cache' -Value $Cache -RepoRoot $R -Confirm:$false | Out-Null
            Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Overrides @{ 'k:a'='v' } -Confirm:$false | Out-Null
            $Probe = Get-Content -Raw (Join-Path $R '0.1.0-ovr-cached.probe.json') | ConvertFrom-Json
            $Probe.Overrides.'k:a' | Should -Be 'v'
        } finally { Remove-CfgRepoRoot -Path $R }
    }

    It 'rejects Overrides when key is absent from preview-cache' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'ovr-rejected' -ConfigSchema @{}
            $MigId = '0.1.0-ovr-rejected'
            $Cache = [PSCustomObject]@{
                MigrationId = $MigId; Generated = 'now'; ChangeRecordCount = 1
                OverrideKeys = @('k:a')
            }
            Set-MigrationArtifact -SourceMigration $MigId -Name '.preview-cache' -Value $Cache -RepoRoot $R -Confirm:$false | Out-Null
            { Invoke-Migration -Version '0.1.0' -RepoRoot $R -AllowUnsigned -Overrides @{ 'k:foreign'='v' } -Confirm:$false } | Should -Throw
        } finally { Remove-CfgRepoRoot -Path $R }
    }
}

Describe 'Invoke-MigrationChain — per-migration partitioning' {
    It 'delivers the right Config + Overrides slice to each migration' {
        $R = New-CfgRepoRoot
        try {
            New-SyntheticMigration -RepoRoot $R -Version '0.1.0' -Slug 'one' -ConfigSchema @{
                Tag = @{ Type='String'; Default='default-a' }
            }
            New-SyntheticMigration -RepoRoot $R -Version '0.2.0' -Slug 'two' -ConfigSchema @{
                Tag = @{ Type='String'; Default='default-b' }
            }
            $PerMigConfig = @{
                '0.1.0' = @{ Tag = 'override-a' }
                '0.2.0' = @{ Tag = 'override-b' }
            }
            $PerMigOverrides = @{
                '0.1.0' = @{ 'k:a' = '1' }
                '0.2.0' = @{ 'k:b' = '2' }
            }
            Invoke-MigrationChain -To '0.2.0' -RepoRoot $R -AllowUnsigned `
                -Config $PerMigConfig -Overrides $PerMigOverrides -Confirm:$false | Out-Null
            $A = Get-Content -Raw (Join-Path $R '0.1.0-one.probe.json') | ConvertFrom-Json
            $B = Get-Content -Raw (Join-Path $R '0.2.0-two.probe.json') | ConvertFrom-Json
            $A.MigrationConfig.Tag | Should -Be 'override-a'
            $B.MigrationConfig.Tag | Should -Be 'override-b'
            $A.Overrides.'k:a' | Should -Be '1'
            $B.Overrides.'k:b' | Should -Be '2'
        } finally { Remove-CfgRepoRoot -Path $R }
    }
}

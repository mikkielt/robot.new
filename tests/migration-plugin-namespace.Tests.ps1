<#
    .SYNOPSIS
    Pester tests for WP-11 plugin migration composite versioning + tiebreaks.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')

    function New-Migration {
        param(
            [string]$Version, [string]$Slug, [string]$Origin = 'Module',
            [int]$PluginLoadIndex = -1, [int]$PluginSequence = 0,
            [string]$Requires
        )
        return [PSCustomObject]@{
            Id              = "$Version-$Slug"
            Version         = $Version
            Slug            = $Slug
            Origin          = $Origin
            PluginLoadIndex = $PluginLoadIndex
            PluginSequence  = $PluginSequence
            Requires        = $Requires
            Validation      = [PSCustomObject]@{ OK = $true; Errors = @(); Warnings = @() }
            AffectsCategories = @('DataRewrite')
            MajorName       = ''
            OnlyIfSourceChanged = $false
            SourceHashScript    = $null
            RequiresNetwork     = $false
            Path                = '/tmp/x'
            ScriptPath          = '/tmp/x/migrate.ps1'
        }
    }
}

Describe 'Composite version ordering' {
    It 'plugin composite sorts AFTER bare version at same core' {
        $A = '21.3.7'
        $B = '21.3.7+plugin-foo.1'
        Compare-SchemaVersion $B $A | Should -Be 1
        Compare-SchemaVersion $A $B | Should -Be -1
    }

    It 'plugin composite at version X < module migration at version X+1' {
        Compare-SchemaVersion '21.3.7+foo.99' '21.3.8' | Should -Be -1
    }
}

Describe 'Resolve-MigrationChain plugin tiebreaks' {
    It 'emits Module before Plugin at the same effective version' {
        # Two migrations: module 0.1.0, plugin foo 0.1.0 (composite 0.1.0+foo.1)
        # The plugin requires the module — so plugin lands after.
        $Catalog = @(
            (New-Migration -Version '0.1.0' -Slug 'mod' -Origin 'Module'),
            (New-Migration -Version '0.1.0+foo.1' -Slug 'fooext' -Origin 'Plugin:foo' -PluginLoadIndex 0 -PluginSequence 1 -Requires '0.1.0')
        )
        $Chain = Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion '0.1.0+foo.1' -Catalog $Catalog
        @($Chain).Count | Should -Be 2
        $Chain[0].Slug | Should -Be 'mod'
        $Chain[1].Slug | Should -Be 'fooext'
    }

    It 'orders two plugins by PluginLoadIndex when both ready in same layer' {
        # No interdependencies — both plugin migrations target 0.1.0+ space and
        # require nothing in the chain. Tiebreak by PluginLoadIndex.
        $Catalog = @(
            (New-Migration -Version '0.2.0+bar.1' -Slug 'barext' -Origin 'Plugin:bar' -PluginLoadIndex 1 -PluginSequence 1),
            (New-Migration -Version '0.1.0+foo.1' -Slug 'fooext' -Origin 'Plugin:foo' -PluginLoadIndex 0 -PluginSequence 1)
        )
        $Chain = Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion '0.2.0+bar.1' -Catalog $Catalog
        @($Chain).Count | Should -Be 2
        # foo (index 0) before bar (index 1)
        $Chain[0].Slug | Should -Be 'fooext'
        $Chain[1].Slug | Should -Be 'barext'
    }

    It 'within a single plugin, orders by PluginSequence then Slug' {
        $Catalog = @(
            (New-Migration -Version '0.1.0+foo.2' -Slug 'zzz' -Origin 'Plugin:foo' -PluginLoadIndex 0 -PluginSequence 2),
            (New-Migration -Version '0.1.0+foo.1' -Slug 'aaa' -Origin 'Plugin:foo' -PluginLoadIndex 0 -PluginSequence 1)
        )
        $Chain = Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion '0.1.0+foo.2' -Catalog $Catalog
        $Chain[0].Slug | Should -Be 'aaa'
        $Chain[1].Slug | Should -Be 'zzz'
    }
}

Describe 'Get-EffectiveVersion rewriting' {
    It 'rewrites a bare version for a plugin origin to composite form' {
        $Manifest = @{ Version = '21.3.7'; Slug = 'foo'; PluginSequence = 1 }
        $V = Get-EffectiveVersion -Manifest $Manifest -Origin 'Plugin:foo'
        $V | Should -Be '21.3.7+foo.1'
    }
    It 'leaves an already-composite version untouched' {
        $Manifest = @{ Version = '21.3.7+foo.2'; Slug = 'foo'; PluginSequence = 1 }
        $V = Get-EffectiveVersion -Manifest $Manifest -Origin 'Plugin:foo'
        $V | Should -Be '21.3.7+foo.2'
    }
    It 'leaves Module-origin versions untouched' {
        $Manifest = @{ Version = '0.1.0'; Slug = 'mod' }
        $V = Get-EffectiveVersion -Manifest $Manifest -Origin 'Module'
        $V | Should -Be '0.1.0'
    }
}

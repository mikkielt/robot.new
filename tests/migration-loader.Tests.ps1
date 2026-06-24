<#
    .SYNOPSIS
    Pester tests for the migration loader (WP-2).

    .DESCRIPTION
    Covers Get-MigrationCatalog (discovery + caching), Test-MigrationManifest
    (CC-3 AST-only validation), Resolve-MigrationChain (DAG ordering + plugin
    tiebreaks), and Get-Migration (public projection).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-version.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-loader.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-schemaversion.ps1')
    . (Join-Path $script:ModuleRoot 'public' 'migration' 'get-migration.ps1')

    $script:FixtureMigRoot = Join-Path $script:FixturesRoot 'migrations'

    function New-IsolatedRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-loader-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-IsolatedRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
}

Describe 'Test-MigrationManifest (CC-3 AST-only)' {
    It 'accepts a well-formed migration' {
        $Manifest = Import-PowerShellDataFile (Join-Path $script:FixtureMigRoot '0.1.0-foo' 'migration.psd1')
        $R = Test-MigrationManifest -Manifest $Manifest -Path (Join-Path $script:FixtureMigRoot '0.1.0-foo')
        $R.OK | Should -BeTrue
        $R.Errors.Count | Should -Be 0
    }

    It 'rejects a migration missing Invoke-Migration' {
        $Manifest = Import-PowerShellDataFile (Join-Path $script:FixtureMigRoot '0.4.0-broken' 'migration.psd1')
        $R = Test-MigrationManifest -Manifest $Manifest -Path (Join-Path $script:FixtureMigRoot '0.4.0-broken')
        $R.OK | Should -BeFalse
        ($R.Errors -join "`n") | Should -Match 'Invoke-Migration'
    }

    It 'rejects a migration with top-level side effects' {
        $Manifest = Import-PowerShellDataFile (Join-Path $script:FixtureMigRoot '0.5.0-sideeffect' 'migration.psd1')
        $R = Test-MigrationManifest -Manifest $Manifest -Path (Join-Path $script:FixtureMigRoot '0.5.0-sideeffect')
        $R.OK | Should -BeFalse
        ($R.Errors -join "`n") | Should -Match 'non-function statement'
    }

    It 'rejects malformed version' {
        $R = Test-MigrationManifest -Manifest @{ Version = 'banana'; Slug = 'foo' } -Path (Join-Path $script:FixtureMigRoot '0.1.0-foo')
        $R.OK | Should -BeFalse
        ($R.Errors -join "`n") | Should -Match 'parseable SemVer'
    }

    It 'rejects non-kebab-case slug' {
        $R = Test-MigrationManifest -Manifest @{ Version = '0.1.0'; Slug = 'FooBar' } -Path (Join-Path $script:FixtureMigRoot '0.1.0-foo')
        $R.OK | Should -BeFalse
        ($R.Errors -join "`n") | Should -Match 'kebab-case'
    }

    It 'rejects invalid AffectsCategories' {
        $Manifest = @{ Version = '0.1.0'; Slug = 'foo'; AffectsCategories = @('EntitySchema', 'WidgetFrobnication') }
        $R = Test-MigrationManifest -Manifest $Manifest -Path (Join-Path $script:FixtureMigRoot '0.1.0-foo')
        $R.OK | Should -BeFalse
        ($R.Errors -join "`n") | Should -Match 'WidgetFrobnication'
    }

    It 'accepts composite plugin version' {
        $R = Test-MigrationManifest -Manifest @{ Version = '0.1.0+foo.1'; Slug = 'plug' } -Path (Join-Path $script:FixtureMigRoot '0.1.0-foo')
        # parse OK on version; may have other errors (e.g. file missing) but version OK
        ($R.Errors -join "`n") | Should -Not -Match 'parseable SemVer'
    }

    It 'warns on operator-local origin' {
        $Manifest = Import-PowerShellDataFile (Join-Path $script:FixtureMigRoot '0.1.0-foo' 'migration.psd1')
        $R = Test-MigrationManifest -Manifest $Manifest -Path (Join-Path $script:FixtureMigRoot '0.1.0-foo') -Origin 'OperatorLocal'
        $R.Warnings.Count | Should -BeGreaterThan 0
        ($R.Warnings -join "`n") | Should -Match 'Unsigned operator-local'
    }
}

Describe 'Get-MigrationCatalog discovery' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        # Wire fixtures as the operator-local root for this scope
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        foreach ($D in 'foo','bar','baz') {
            $Src = Join-Path $script:FixtureMigRoot "0.$([array]::IndexOf(@('foo','bar','baz'),$D)+1).0-$D"
            $Dst = Join-Path $LocalDir "0.$([array]::IndexOf(@('foo','bar','baz'),$D)+1).0-$D"
            [void][System.IO.Directory]::CreateDirectory($Dst)
            Copy-Item (Join-Path $Src 'migration.psd1') $Dst
            Copy-Item (Join-Path $Src 'migrate.ps1') $Dst
        }
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'finds operator-local migrations under .robot.local/migrations/' {
        $C = Get-MigrationCatalog -RepoRoot $script:Repo
        $Found = @($C | Where-Object { $_.Slug -in 'foo','bar','baz' })
        $Found.Count | Should -BeGreaterOrEqual 3
        ($Found | Where-Object { $_.Slug -eq 'foo' }).Origin | Should -Be 'OperatorLocal'
    }

    It 'caches the catalog across consecutive calls' {
        $C1 = Get-MigrationCatalog -RepoRoot $script:Repo
        $C2 = Get-MigrationCatalog -RepoRoot $script:Repo
        [object]::ReferenceEquals($C1, $C2) | Should -BeTrue
    }

    It '-Force invalidates the cache' {
        $C1 = Get-MigrationCatalog -RepoRoot $script:Repo
        $C2 = Get-MigrationCatalog -RepoRoot $script:Repo -Force
        [object]::ReferenceEquals($C1, $C2) | Should -BeFalse
    }
}

Describe 'Get-Migration public projection' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
        Copy-Item (Join-Path $script:FixtureMigRoot '0.2.0-bar') $LocalDir -Recurse
        Copy-Item (Join-Path $script:FixtureMigRoot '0.4.0-broken') $LocalDir -Recurse
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'hides invalid migrations by default' {
        $Ms = @(Get-Migration -RepoRoot $script:Repo | Where-Object { $_.Slug -in 'foo','bar','broken' })
        ($Ms | Where-Object { $_.Slug -eq 'broken' }).Count | Should -Be 0
    }

    It '-IncludeInvalid surfaces validation failures' {
        $Ms = @(Get-Migration -RepoRoot $script:Repo -IncludeInvalid | Where-Object { $_.Slug -eq 'broken' })
        $Ms.Count | Should -BeGreaterOrEqual 1
        $Ms[0].ValidationOK | Should -BeFalse
    }

    It '-Pending returns migrations above current schema (0.0.0 on fresh repo)' {
        $Ms = @(Get-Migration -RepoRoot $script:Repo -Pending | Where-Object { $_.Slug -in 'foo','bar' })
        $Ms.Count | Should -Be 2
    }

    It '-Version filters to a specific entry' {
        $Ms = @(Get-Migration -RepoRoot $script:Repo -Version '0.1.0')
        ($Ms | Where-Object { $_.Slug -eq 'foo' }).Count | Should -Be 1
    }
}

Describe 'Resolve-MigrationChain' {
    BeforeEach {
        Clear-MigrationCatalogCache
        $script:Repo = New-IsolatedRepoRoot
        $LocalDir = Join-Path $script:Repo '.robot.local' 'migrations'
        [void][System.IO.Directory]::CreateDirectory($LocalDir)
        Copy-Item (Join-Path $script:FixtureMigRoot '0.1.0-foo') $LocalDir -Recurse
        Copy-Item (Join-Path $script:FixtureMigRoot '0.2.0-bar') $LocalDir -Recurse
        Copy-Item (Join-Path $script:FixtureMigRoot '0.3.0-baz') $LocalDir -Recurse
    }
    AfterEach {
        Remove-IsolatedRepoRoot -Path $script:Repo
        Clear-MigrationCatalogCache
    }

    It 'orders foo -> bar -> baz by Requires DAG' {
        $Chain = Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion '0.3.0' -RepoRoot $script:Repo
        @($Chain).Count | Should -Be 3
        $Chain[0].Slug | Should -Be 'foo'
        $Chain[1].Slug | Should -Be 'bar'
        $Chain[2].Slug | Should -Be 'baz'
    }

    It 'excludes migrations <= FromVersion' {
        $Chain = Resolve-MigrationChain -FromVersion '0.1.0' -ToVersion '0.3.0' -RepoRoot $script:Repo
        @($Chain).Count | Should -Be 2
        $Chain[0].Slug | Should -Be 'bar'
    }

    It 'excludes migrations > ToVersion' {
        $Chain = Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion '0.2.0' -RepoRoot $script:Repo
        @($Chain).Count | Should -Be 2
        $Chain[-1].Slug | Should -Be 'bar'
    }

    It 'throws on broken Requires chain' {
        # Synthetic catalog: foo (0.1.0) and baz (0.3.0 requires bar). bar is missing.
        $Synth = @(
            [PSCustomObject]@{
                Id = '0.1.0-foo'; Version = '0.1.0'; Slug = 'foo'; Origin = 'OperatorLocal'
                PluginLoadIndex = -1; PluginSequence = 0; Requires = $null
                Validation = [PSCustomObject]@{ OK = $true }; AffectsCategories = @(); MajorName = ''
                OnlyIfSourceChanged = $false; SourceHashScript = $null; RequiresNetwork = $false
                Path = '/tmp/x'; ScriptPath = '/tmp/x/migrate.ps1'
            }
            [PSCustomObject]@{
                Id = '0.3.0-baz'; Version = '0.3.0'; Slug = 'baz'; Origin = 'OperatorLocal'
                PluginLoadIndex = -1; PluginSequence = 0; Requires = '0.2.0'
                Validation = [PSCustomObject]@{ OK = $true }; AffectsCategories = @(); MajorName = ''
                OnlyIfSourceChanged = $false; SourceHashScript = $null; RequiresNetwork = $false
                Path = '/tmp/x'; ScriptPath = '/tmp/x/migrate.ps1'
            }
        )
        { Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion '0.3.0' -Catalog $Synth -RepoRoot $script:Repo } |
            Should -Throw -ExpectedMessage '*requires version*'
    }

    It 'resolves "latest" to highest Module version in a synthetic catalog' {
        # Synthetic catalog with two Module migrations; "latest" picks the top one.
        $Synth = @(
            [PSCustomObject]@{
                Id = '0.1.0-a'; Version = '0.1.0'; Slug = 'a'; Origin = 'Module'
                PluginLoadIndex = -1; PluginSequence = 0; Requires = $null
                Validation = [PSCustomObject]@{ OK = $true }; AffectsCategories = @(); MajorName = ''
                OnlyIfSourceChanged = $false; SourceHashScript = $null; RequiresNetwork = $false
                Path = '/tmp/x'; ScriptPath = '/tmp/x/migrate.ps1'
            }
            [PSCustomObject]@{
                Id = '0.2.0-b'; Version = '0.2.0'; Slug = 'b'; Origin = 'Module'
                PluginLoadIndex = -1; PluginSequence = 0; Requires = '0.1.0'
                Validation = [PSCustomObject]@{ OK = $true }; AffectsCategories = @(); MajorName = ''
                OnlyIfSourceChanged = $false; SourceHashScript = $null; RequiresNetwork = $false
                Path = '/tmp/x'; ScriptPath = '/tmp/x/migrate.ps1'
            }
        )
        $Chain = Resolve-MigrationChain -FromVersion '0.0.0' -ToVersion 'latest' -Catalog $Synth -RepoRoot $script:Repo
        @($Chain).Count | Should -Be 2
        $Chain[-1].Version | Should -Be '0.2.0'
    }
}

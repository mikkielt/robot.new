<#
    .SYNOPSIS
    Migration discovery, manifest validation, and chain resolution.

    .DESCRIPTION
    Non-exported helper functions consumed by public/migration/get-migration.ps1
    and the migration runtime. Loaded once at module-init via the CC-1
    dot-source block in Robot.PowerShell.psm1.

    Helpers:
    - Get-MigrationCatalog:        scan three discovery roots, cache the catalog
    - Test-MigrationManifest:      AST-only validation (CC-3) — never dot-sources
                                   migrate.ps1 during validation
    - Resolve-MigrationChain:      topological sort by Requires; plugin tiebreak
                                   via Origin / PluginLoadIndex / PluginSequence

    Module-level data:
    - $script:CachedMigrationCatalog:    cached scan results
    - $script:CachedCatalogStamps:       per-root mod-time fingerprints for cache
                                         invalidation

    Discovery order (later roots can override earlier roots with a warning):
      1. <module>/migrations/                          → Origin 'Module'
      2. <lore-repo>/.robot.local/migrations/          → Origin 'OperatorLocal'
      3. <plugin>/migrations/ for each loaded plugin   → Origin 'Plugin:<name>'

    Per-migration manifest schema (migration.psd1):
      Version              SemVer; plugin migrations stay at module version,
                           loader rewrites to composite "21.3.7+plugin-foo.1"
      MajorName            informational, must match registry for that MAJOR
      Slug                 kebab-case ≤64 chars, used in branch + ID
      Description          one-line
      Requires             predecessor version (optional for first migration)
      Author               free-text
      AffectsCategories    array; values from the category enum below
      EstimatedDurationSec hint for sync/async dispatch
      OnlyIfSourceChanged  WP-10 external-import idempotency flag
      SourceHashScript     path relative to migration dir (default: 'source-hash.ps1')
      RequiresNetwork      WP-4 preview degradation flag
      PluginSequence       WP-11 per-plugin ordering (plugin origin only)

    Category enum:
      EntitySchema | DataRewrite | SessionFormat | StateFile | RepoLayout
      | Cache | ExternalImport | Fixture
#>

$script:CachedMigrationCatalog = $null
$script:CachedCatalogStamps    = $null

$script:MigrationCategoryEnum = @(
    'EntitySchema', 'DataRewrite', 'SessionFormat', 'StateFile',
    'RepoLayout', 'Cache', 'ExternalImport', 'Fixture'
)

# Kebab-case: lowercase letters, digits, dot, single hyphens between segments.
# Allows numeric segments so "21.3.7-to-21.4.0" style slugs are accepted.
$script:SlugPattern = [regex]::new(
    '^[a-z0-9]+(-[a-z0-9]+)*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Plain SemVer (no build tag); accepts 0.0.0 through arbitrary major.minor.patch.
$script:SemVerPattern = [regex]::new(
    '^\d+\.\d+\.\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Composite plugin version: SemVer + '+' + plugin-tag.sequence
$script:CompositeVersionPattern = [regex]::new(
    '^\d+\.\d+\.\d+\+[a-z0-9][a-z0-9-]*\.\d+$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# ── Catalog Discovery ───────────────────────────────────────────────────────

function Get-MigrationCatalog {
    <#
        .SYNOPSIS
        Returns the full discoverable migration catalog. Cached per-process.

        .PARAMETER AdditionalRoots
        Test hook: additional directories to scan as if they were operator-local.

        .PARAMETER Force
        Bypass the cache and rescan.

        .PARAMETER RepoRoot
        Override the repo root used to locate .robot.local/migrations/.
    #>
    [CmdletBinding()]
    param(
        [string[]]$AdditionalRoots,
        [switch]$Force,
        [string]$RepoRoot
    )

    $Roots = Resolve-MigrationRoots -RepoRoot $RepoRoot -AdditionalRoots $AdditionalRoots
    $Stamps = Get-CatalogStamps -Roots $Roots

    if (-not $Force -and $script:CachedMigrationCatalog -and
        $script:CachedCatalogStamps -and
        (Compare-CatalogStamps $script:CachedCatalogStamps $Stamps)) {
        # Comma-wrap suppresses pipeline enumeration so callers see the same array reference.
        return , $script:CachedMigrationCatalog
    }

    $List = [System.Collections.Generic.List[object]]::new()
    $SeenVersions = @{}      # effectiveVersion -> first-seen migration object

    foreach ($Root in $Roots) {
        if (-not [System.IO.Directory]::Exists($Root.Path)) { continue }

        $Subdirs = [System.IO.Directory]::GetDirectories($Root.Path)
        foreach ($Dir in $Subdirs) {
            $ManifestPath = [System.IO.Path]::Combine($Dir, 'migration.psd1')
            $ScriptPath   = [System.IO.Path]::Combine($Dir, 'migrate.ps1')
            if (-not [System.IO.File]::Exists($ManifestPath)) { continue }

            $Manifest = $null
            $LoadError = $null
            try {
                $Manifest = Import-PowerShellDataFile -Path $ManifestPath
            } catch {
                $LoadError = $_.Exception.Message
            }

            $Validation = if ($Manifest) {
                Test-MigrationManifest -Manifest $Manifest -Path $Dir -Origin $Root.Origin
            } else {
                [PSCustomObject]@{
                    OK       = $false
                    Errors   = @("Failed to parse migration.psd1: $LoadError")
                    Warnings = @()
                }
            }

            $EffectiveVersion = if ($Manifest -and $Manifest.Version) {
                Get-EffectiveVersion -Manifest $Manifest -Origin $Root.Origin
            } else { $null }

            $Slug = if ($Manifest -and $Manifest.Slug) { $Manifest.Slug } else {
                [System.IO.Path]::GetFileName($Dir)
            }
            $MigrationId = if ($EffectiveVersion) { "$EffectiveVersion-$Slug" } else {
                [System.IO.Path]::GetFileName($Dir)
            }

            $Entry = [PSCustomObject]@{
                Id                = $MigrationId
                Version           = $EffectiveVersion
                DeclaredVersion   = if ($Manifest) { $Manifest.Version } else { $null }
                MajorName         = if ($Manifest -and $Manifest.MajorName) { $Manifest.MajorName } else { '' }
                Slug              = $Slug
                Description       = if ($Manifest -and $Manifest.Description) { $Manifest.Description } else { '' }
                Requires          = if ($Manifest -and $Manifest.Requires) { $Manifest.Requires } else { $null }
                Author            = if ($Manifest -and $Manifest.Author) { $Manifest.Author } else { '' }
                AffectsCategories = if ($Manifest -and $Manifest.AffectsCategories) {
                    @($Manifest.AffectsCategories)
                } else { @() }
                EstimatedDurationSec = if ($Manifest -and $Manifest.EstimatedDurationSec) {
                    [int]$Manifest.EstimatedDurationSec
                } else { 0 }
                OnlyIfSourceChanged = [bool]($Manifest -and $Manifest.OnlyIfSourceChanged)
                SourceHashScript    = if ($Manifest -and $Manifest.SourceHashScript) {
                    $Manifest.SourceHashScript
                } else { $null }
                RequiresNetwork     = [bool]($Manifest -and $Manifest.RequiresNetwork)
                PluginSequence      = if ($Manifest -and $Manifest.PluginSequence) {
                    [int]$Manifest.PluginSequence
                } else { 0 }
                Origin            = $Root.Origin
                PluginName        = $Root.PluginName
                PluginLoadIndex   = $Root.PluginLoadIndex
                Path              = $Dir
                ScriptPath        = $ScriptPath
                ManifestPath      = $ManifestPath
                Manifest          = $Manifest
                Validation        = $Validation
            }

            # Detect cross-root version collisions (later roots override earlier ones
            # with a warning, so the operator can drop a local override on top of
            # a module migration intentionally).
            if ($EffectiveVersion -and $SeenVersions.ContainsKey($EffectiveVersion)) {
                $Prior = $SeenVersions[$EffectiveVersion]
                Write-RobotWarning ("Migration version '$EffectiveVersion' overridden: " +
                    "'$($Prior.Origin)' at '$($Prior.Path)' shadowed by " +
                    "'$($Entry.Origin)' at '$($Entry.Path)'.")
                # Remove the earlier entry from the list so consumers see the override.
                for ($I = 0; $I -lt $List.Count; $I++) {
                    if ([object]::ReferenceEquals($List[$I], $Prior)) {
                        $List.RemoveAt($I); break
                    }
                }
            }
            if ($EffectiveVersion) {
                $SeenVersions[$EffectiveVersion] = $Entry
            }
            [void]$List.Add($Entry)
        }
    }

    # Cache the array form so subsequent cache-hit returns share the same
    # reference. Returning a List[object] from a PS function causes pipeline
    # unrolling, breaking caller reference equality and obscuring cache reuse.
    $script:CachedMigrationCatalog = @($List.ToArray())
    $script:CachedCatalogStamps    = $Stamps
    return , $script:CachedMigrationCatalog
}

function Clear-MigrationCatalogCache {
    $script:CachedMigrationCatalog = $null
    $script:CachedCatalogStamps    = $null
}

# ── Discovery Roots ─────────────────────────────────────────────────────────

function Resolve-MigrationRoots {
    [CmdletBinding()]
    param([string]$RepoRoot, [string[]]$AdditionalRoots)

    $Roots = [System.Collections.Generic.List[object]]::new()

    $ModuleMigDir = [System.IO.Path]::Combine($script:ModuleRoot, 'migrations')
    [void]$Roots.Add([PSCustomObject]@{
        Path = $ModuleMigDir; Origin = 'Module'
        PluginName = $null; PluginLoadIndex = -1
    })

    $ResolvedRoot = $RepoRoot
    if (-not $ResolvedRoot) {
        try { $ResolvedRoot = Get-RepoRoot -Optional } catch { $ResolvedRoot = $null }
    }
    if ($ResolvedRoot) {
        $LocalDir = [System.IO.Path]::Combine($ResolvedRoot, '.robot.local', 'migrations')
        [void]$Roots.Add([PSCustomObject]@{
            Path = $LocalDir; Origin = 'OperatorLocal'
            PluginName = $null; PluginLoadIndex = -1
        })
    }

    if ($AdditionalRoots) {
        foreach ($R in $AdditionalRoots) {
            [void]$Roots.Add([PSCustomObject]@{
                Path = $R; Origin = 'OperatorLocal'
                PluginName = $null; PluginLoadIndex = -1
            })
        }
    }

    # Plugin roots in plugin-load order. $script:LoadedPlugins is keyed by name;
    # the actual load order is captured by enumeration order when populated by
    # Resolve-PluginLoadOrder (preserves topological order).
    if ($script:LoadedPlugins) {
        $Index = 0
        foreach ($PluginName in $script:LoadedPlugins.Keys) {
            $PluginDir = [System.IO.Path]::Combine($script:ModuleRoot, 'plugins', $PluginName)
            $PluginMigDir = [System.IO.Path]::Combine($PluginDir, 'migrations')
            [void]$Roots.Add([PSCustomObject]@{
                Path = $PluginMigDir; Origin = "Plugin:$PluginName"
                PluginName = $PluginName; PluginLoadIndex = $Index
            })
            $Index++
        }
    }

    return $Roots
}

function Get-CatalogStamps {
    param([Parameter(Mandatory)][object[]]$Roots)
    $Stamps = @{}
    foreach ($Root in $Roots) {
        if ([System.IO.Directory]::Exists($Root.Path)) {
            $Info = [System.IO.DirectoryInfo]::new($Root.Path)
            $Stamps[$Root.Path] = $Info.LastWriteTimeUtc.Ticks
        } else {
            $Stamps[$Root.Path] = 0
        }
    }
    return $Stamps
}

function Compare-CatalogStamps {
    param([hashtable]$A, [hashtable]$B)
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($Key in $A.Keys) {
        if (-not $B.ContainsKey($Key)) { return $false }
        if ($A[$Key] -ne $B[$Key]) { return $false }
    }
    return $true
}

# ── Effective Version (Plugin Composite Rewriting) ──────────────────────────

function Get-EffectiveVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Manifest,
        [Parameter(Mandatory)] [string]$Origin
    )

    $Raw = [string]$Manifest.Version

    # Composite versions are explicit — accept as-is for any origin (allows
    # tests to declare composite versions directly).
    if ($Raw.Contains('+')) { return $Raw }

    # Plugin migrations targeting a module version inherit composite naming
    # to avoid collisions with the module migration at that version.
    if ($Origin -like 'Plugin:*') {
        $PluginName = $Origin.Substring('Plugin:'.Length)
        $Seq = if ($Manifest.PluginSequence) { [int]$Manifest.PluginSequence } else { 1 }
        # PluginName may contain dashes already; lowercased for stable ordinal compare.
        return ("{0}+{1}.{2}" -f $Raw, $PluginName.ToLowerInvariant(), $Seq)
    }

    return $Raw
}

# ── Manifest Validation (CC-3: AST-only) ────────────────────────────────────

function Test-MigrationManifest {
    <#
        .SYNOPSIS
        Validates a migration manifest + migrate.ps1 without executing the script.

        .DESCRIPTION
        Per CC-3, validation NEVER dot-sources migrate.ps1. It parses the file's
        AST and walks for the required function definitions; it also rejects any
        top-level statement that is not a FunctionDefinitionAst, UsingStatementAst,
        or comment trivia. Top-level commands, assignments, or Set-Location calls
        would let a malformed migration execute writes before validation could
        reject the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Manifest,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Origin = 'Module'
    )

    $Errors   = [System.Collections.Generic.List[string]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()

    # ── Manifest field validation ─────────────────────────────────────────
    if (-not $Manifest.Version) {
        [void]$Errors.Add("Manifest missing required field 'Version'.")
    } else {
        $V = [string]$Manifest.Version
        $ValidSemVer  = $script:SemVerPattern.IsMatch($V)
        $ValidComp    = $script:CompositeVersionPattern.IsMatch($V)
        if (-not $ValidSemVer -and -not $ValidComp) {
            [void]$Errors.Add("Version '$V' is not parseable SemVer or composite (e.g. '1.2.3' or '1.2.3+plugin-foo.1').")
        }
    }

    if (-not $Manifest.Slug) {
        [void]$Errors.Add("Manifest missing required field 'Slug'.")
    } else {
        $S = [string]$Manifest.Slug
        if ($S.Length -gt 64) {
            [void]$Errors.Add("Slug '$S' exceeds 64 chars.")
        }
        if (-not $script:SlugPattern.IsMatch($S)) {
            [void]$Errors.Add("Slug '$S' is not kebab-case (lowercase letters, digits, hyphens).")
        }
    }

    if ($Manifest.AffectsCategories) {
        foreach ($Cat in @($Manifest.AffectsCategories)) {
            if ($Cat -notin $script:MigrationCategoryEnum) {
                [void]$Errors.Add("AffectsCategories includes invalid category '$Cat'. " +
                    "Valid: $($script:MigrationCategoryEnum -join ', ')")
            }
        }
    }

    # CC-N1: Archetype is optional during the framework rollout
    # (WP-A6 backfills existing manifests). When present, must be one of
    # the three archetype enum values.
    if ($Manifest.ContainsKey('Archetype')) {
        $Archetype = [string]$Manifest['Archetype']
        if ($Archetype -notin @('Transform', 'Inspect', 'Commit')) {
            [void]$Errors.Add("Archetype '$Archetype' is not one of: Transform, Inspect, Commit.")
        }
    }

    # CC-N2: ConfigSchema is optional during the transition; when present,
    # Resolve-MigrationConfigSchema validates field shapes (throws on
    # malformed Type / non-hashtable field bodies). Failure becomes a
    # validation error rather than an unhandled throw so the catalog stays
    # loadable with bad migrations marked invalid.
    if ($Manifest.ContainsKey('ConfigSchema')) {
        try {
            [void](Resolve-MigrationConfigSchema -Manifest $Manifest)
        }
        catch {
            [void]$Errors.Add("ConfigSchema validation failed: $($_.Exception.Message)")
        }
    }

    # ── migrate.ps1 existence + AST validation ────────────────────────────
    $ScriptPath = [System.IO.Path]::Combine($Path, 'migrate.ps1')
    if (-not [System.IO.File]::Exists($ScriptPath)) {
        [void]$Errors.Add("migrate.ps1 not found at '$ScriptPath'.")
    } else {
        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $ScriptPath, [ref]$Tokens, [ref]$ParseErrors)

        if ($ParseErrors -and $ParseErrors.Count -gt 0) {
            foreach ($P in $ParseErrors) {
                [void]$Errors.Add("migrate.ps1 parse error: $($P.Message)")
            }
        } else {
            # Walk top-level statements: must be functions, using statements, or
            # comments (comments don't appear as AST nodes). Anything else is
            # rejected per CC-3 to keep validation side-effect free.
            $TopLevel = $Ast.EndBlock.Statements
            $FunctionNames = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Stmt in $TopLevel) {
                if ($Stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    [void]$FunctionNames.Add($Stmt.Name)
                } elseif ($Stmt -is [System.Management.Automation.Language.UsingStatementAst]) {
                    # allowed
                } else {
                    [void]$Errors.Add(("migrate.ps1 top-level scope contains non-function statement: " +
                        "'$($Stmt.Extent.Text.Substring(0, [Math]::Min(60, $Stmt.Extent.Text.Length)))...'. " +
                        "Migrations must define only Get-MigrationPreview and Invoke-Migration."))
                }
            }
            if (-not $FunctionNames.Contains('Get-MigrationPreview')) {
                [void]$Errors.Add("migrate.ps1 must export 'Get-MigrationPreview' function.")
            }
            if (-not $FunctionNames.Contains('Invoke-Migration')) {
                [void]$Errors.Add("migrate.ps1 must export 'Invoke-Migration' function.")
            }
        }
    }

    if ($Origin -eq 'OperatorLocal') {
        [void]$Warnings.Add("Unsigned operator-local migration; review migrate.ps1 before applying.")
    }

    return [PSCustomObject]@{
        OK       = ($Errors.Count -eq 0)
        Errors   = @($Errors)
        Warnings = @($Warnings)
    }
}

# ── Chain Resolution ────────────────────────────────────────────────────────

function Resolve-MigrationChain {
    <#
        .SYNOPSIS
        Returns the ordered migration chain from FromVersion to ToVersion.

        .DESCRIPTION
        Topological sort over Requires edges. When multiple migrations are ready
        in the same layer (no inter-edge), emits them in this priority order:
          1. Origin: Module (1) < Plugin:* (2) < OperatorLocal (3)
          2. Within Plugin:*: PluginLoadIndex from $script:LoadedPlugins
          3. Within a single plugin: ascending PluginSequence, then Slug ordinal

        Throws if the chain is broken (a Requires points at a non-existent
        version) or if a cycle is detected.
    #>
    [CmdletBinding()]
    param(
        [string]$FromVersion,
        [Parameter(Mandatory)] [string]$ToVersion,
        [object[]]$Catalog,
        [string]$RepoRoot
    )

    if (-not $Catalog) {
        $Catalog = Get-MigrationCatalog -RepoRoot $RepoRoot
    }
    # Exclude validation-failed migrations from chain resolution — they cannot
    # be applied safely. Operators see them via Get-Migration -IncludeInvalid.
    $Valid = @($Catalog | Where-Object { $_.Validation.OK -and $_.Version })

    if (-not $FromVersion) {
        $Schema = Get-SchemaVersion -RepoRoot $RepoRoot
        $FromVersion = $Schema.Current
    }

    if ($ToVersion -eq 'latest') {
        # Sort by SemVer and pick the highest; ignore plugin builds for "latest"
        # so operators don't get pulled into plugin migrations by default.
        $ModuleOnly = @($Valid | Where-Object { $_.Origin -eq 'Module' })
        if ($ModuleOnly.Count -eq 0) { return @() }
        $Sorted = $ModuleOnly | Sort-Object @{ Expression = { $_.Version } } -Descending:$false
        $Highest = $ModuleOnly[0].Version
        foreach ($M in $ModuleOnly) {
            if ((Compare-SchemaVersion $M.Version $Highest) -gt 0) { $Highest = $M.Version }
        }
        $ToVersion = $Highest
    }

    # Pending = versions strictly above From and at-or-below To.
    $Pending = [System.Collections.Generic.List[object]]::new()
    foreach ($M in $Valid) {
        $AboveFrom = (Compare-SchemaVersion $M.Version $FromVersion) -gt 0
        $AtOrBelowTo = (Compare-SchemaVersion $M.Version $ToVersion) -le 0
        if ($AboveFrom -and $AtOrBelowTo) { [void]$Pending.Add($M) }
    }

    if ($Pending.Count -eq 0) { return @() }

    # Build adjacency: edges from prerequisite (Requires) to the dependent.
    $ById = @{}
    foreach ($M in $Pending) { $ById[$M.Version] = $M }

    $Indegree = @{}
    $Successors = @{}
    foreach ($M in $Pending) {
        $Indegree[$M.Version] = 0
        $Successors[$M.Version] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($M in $Pending) {
        if (-not $M.Requires) { continue }
        $Req = [string]$M.Requires
        # If Requires points to the current schema version, no edge needed (the
        # repo already satisfies it). If it points to another pending migration,
        # add an edge so that prerequisite emits first.
        if ($ById.ContainsKey($Req)) {
            [void]$Successors[$Req].Add($M.Version)
            $Indegree[$M.Version] = $Indegree[$M.Version] + 1
        } elseif ((Compare-SchemaVersion $Req $FromVersion) -gt 0) {
            # Requires a version that is neither current schema nor in the
            # pending chain — broken chain.
            $Ex = [System.InvalidOperationException]::new(
                "Migration '$($M.Id)' requires version '$Req' which is neither " +
                "the current schema ('$FromVersion') nor in the pending chain.")
            throw $Ex
        }
    }

    # Kahn's algorithm with the tiebreak comparator for the ready set.
    $Ready = [System.Collections.Generic.List[object]]::new()
    foreach ($M in $Pending) {
        if ($Indegree[$M.Version] -eq 0) { [void]$Ready.Add($M) }
    }

    $Out = [System.Collections.Generic.List[object]]::new()
    while ($Ready.Count -gt 0) {
        # Sort Ready in-place by tiebreak priority each iteration so newly
        # ready migrations get the right ordering.
        $Sorted = $Ready | Sort-Object -Property `
            @{ Expression = { Get-OriginPriority $_.Origin } },
            @{ Expression = { Get-VersionSortKey $_.Version } },
            @{ Expression = { $_.PluginLoadIndex } },
            @{ Expression = { $_.PluginSequence } },
            @{ Expression = { $_.Slug } }

        $Next = $Sorted[0]
        $Ready.Remove($Next) | Out-Null
        [void]$Out.Add($Next)

        foreach ($SuccVer in $Successors[$Next.Version]) {
            $Indegree[$SuccVer] = $Indegree[$SuccVer] - 1
            if ($Indegree[$SuccVer] -eq 0) {
                [void]$Ready.Add($ById[$SuccVer])
            }
        }
    }

    if ($Out.Count -ne $Pending.Count) {
        throw "Cycle detected in migration Requires graph."
    }

    return @($Out)
}

function Get-OriginPriority {
    param([string]$Origin)
    if ($Origin -eq 'Module')        { return 1 }
    if ($Origin -like 'Plugin:*')    { return 2 }
    if ($Origin -eq 'OperatorLocal') { return 3 }
    return 99
}

function Get-VersionSortKey {
    # Sortable key: pad each core component to 6 digits so string sort matches
    # numeric SemVer. Build tag (post-'+') is appended verbatim and sorts after
    # untagged via the lex bias inserted between core and tag.
    param([string]$Version)
    $Parts = $Version.Split('+', 2)
    $Core = $Parts[0].Split('.')
    $Padded = ($Core | ForEach-Object { ([int]$_).ToString().PadLeft(6, '0') }) -join '.'
    if ($Parts.Count -eq 1) {
        # Use '0' so untagged < any tagged at same core (lex: '0' < '~' < anything)
        return "$Padded|0"
    }
    return "$Padded|1$($Parts[1])"
}

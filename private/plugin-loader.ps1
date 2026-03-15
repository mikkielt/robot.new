<#
    .SYNOPSIS
    Plugin discovery, dependency resolution, and configuration loading.

    .DESCRIPTION
    Non-exported helper functions consumed by robot.psm1 during the plugin
    loading phase. Not auto-loaded (non-Verb-Noun filename).

    Helpers:
    - Resolve-PluginLoadOrder:  topological sort of plugins by DependsOn using Kahn's algorithm
    - Resolve-PluginConfig:     per-plugin config resolution from environment, local config, and manifest defaults

    Plugin config resolution priority (per key):
    1. Environment variable (declared in manifest Config.<Key>.EnvVar)
    2. Plugin's own local.config.psd1 (in plugin directory, git-ignored)
    3. Core local.config.psd1 with namespaced key (pluginname.KeyName)
    4. Manifest default (declared in manifest Config.<Key>.Default)
    5. Warning if Required = $true and nothing resolved

    Resolve-PluginLoadOrder uses Kahn's algorithm for topological sorting.
    Plugins with missing dependencies are excluded via an InDegree = -1 sentinel
    and warned. Circular dependencies are detected as remaining nodes with
    InDegree > 0 after the BFS completes.
#>

function Resolve-PluginLoadOrder {
    param(
        [System.Collections.Generic.List[object]]$Candidates
    )

    $ByName   = @{}
    $InDegree = @{}
    $Adj      = @{}

    foreach ($C in $Candidates) {
        $Name = $C.Manifest.Name
        $ByName[$Name]   = $C
        $InDegree[$Name] = 0
        $Adj[$Name]      = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($C in $Candidates) {
        $Name = $C.Manifest.Name
        $Deps = $C.Manifest.DependsOn

        if (-not $Deps) { continue }

        foreach ($Dep in $Deps) {
            if (-not $ByName.ContainsKey($Dep)) {
                [System.Console]::Error.WriteLine(
                    "[WARN Resolve-PluginLoadOrder] Plugin '$Name' depends on missing plugin '$Dep' - skipped")
                $InDegree[$Name] = -1  # sentinel: -1 excludes from topological sort
                continue
            }

            if (-not $Adj.ContainsKey($Dep)) {
                $Adj[$Dep] = [System.Collections.Generic.List[string]]::new()
            }
            $Adj[$Dep].Add($Name)
            $InDegree[$Name]++
        }
    }

    # BFS from zero-dependency nodes — produces dependency-safe load order
    $Queue  = [System.Collections.Generic.Queue[string]]::new()
    $Result = [System.Collections.Generic.List[object]]::new()

    foreach ($Name in $InDegree.Keys) {
        if ($InDegree[$Name] -eq 0) {
            $Queue.Enqueue($Name)
        }
    }

    while ($Queue.Count -gt 0) {
        $Current = $Queue.Dequeue()
        if ($ByName.ContainsKey($Current)) {
            $Result.Add($ByName[$Current])
        }

        if ($Adj.ContainsKey($Current)) {
            foreach ($Neighbor in $Adj[$Current]) {
                if ($InDegree[$Neighbor] -lt 0) { continue }
                $InDegree[$Neighbor]--
                if ($InDegree[$Neighbor] -eq 0) {
                    $Queue.Enqueue($Neighbor)
                }
            }
        }
    }

    # Warn about circular dependencies (remaining nodes with InDegree > 0)
    foreach ($Name in $InDegree.Keys) {
        if ($InDegree[$Name] -gt 0) {
            [System.Console]::Error.WriteLine(
                "[WARN Resolve-PluginLoadOrder] Plugin '$Name' has unresolved dependencies (possible cycle) - skipped")
        }
    }

    return $Result
}

function Resolve-PluginConfig {
    param(
        [hashtable]$Manifest,
        [string]$PluginDir,
        [string]$ModuleRoot
    )

    $ConfigDefs = $Manifest.Config
    if (-not $ConfigDefs) { return @{} }

    # Pre-load both config files once, then iterate keys (avoids repeated I/O per key)
    $PluginLocalPath = [System.IO.Path]::Combine($PluginDir, 'local.config.psd1')
    $PluginLocal = if ([System.IO.File]::Exists($PluginLocalPath)) {
        try { Import-PowerShellDataFile -Path $PluginLocalPath } catch { @{} }
    } else { @{} }

    $CoreLocalPath = [System.IO.Path]::Combine($ModuleRoot, 'local.config.psd1')
    $CoreLocal = if ([System.IO.File]::Exists($CoreLocalPath)) {
        try { Import-PowerShellDataFile -Path $CoreLocalPath } catch { @{} }
    } else { @{} }

    $PluginName = $Manifest.Name
    $Resolved = @{}

    foreach ($Key in $ConfigDefs.Keys) {
        $Def = $ConfigDefs[$Key]
        $Value = $null

        # Priority 1: env var — highest precedence for CI/CD overrides
        if ($Def.EnvVar) {
            $EnvVal = [System.Environment]::GetEnvironmentVariable($Def.EnvVar)
            if (-not [string]::IsNullOrWhiteSpace($EnvVal)) {
                $Value = $EnvVal
            }
        }

        # Priority 2: plugin-local config (git-ignored, per-developer settings)
        if (-not $Value -and $PluginLocal.ContainsKey($Key)) {
            $Val = $PluginLocal[$Key]
            if (-not [string]::IsNullOrWhiteSpace($Val)) {
                $Value = $Val
            }
        }

        # Priority 3: core config with namespaced key (shared across plugins)
        $NamespacedKey = "$PluginName.$Key"
        if (-not $Value -and $CoreLocal.ContainsKey($NamespacedKey)) {
            $Val = $CoreLocal[$NamespacedKey]
            if (-not [string]::IsNullOrWhiteSpace($Val)) {
                $Value = $Val
            }
        }

        # Priority 4: manifest default — last resort before warning
        if (-not $Value -and $null -ne $Def.Default) {
            $Value = $Def.Default
        }

        # Priority 5: warn if required key unresolved after full chain
        if (-not $Value -and $Def.Required) {
            [System.Console]::Error.WriteLine(
                "[WARN Resolve-PluginConfig] Plugin '$PluginName' config key '$Key' is required but not set." +
                " Set env var '$($Def.EnvVar)' or add '$Key' to $PluginLocalPath")
        }

        $Resolved[$Key] = $Value
    }

    return $Resolved
}

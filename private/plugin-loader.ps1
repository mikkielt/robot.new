<#
    .SYNOPSIS
    Plugin discovery, dependency resolution, and configuration loading.

    .DESCRIPTION
    Non-exported helper functions consumed by robot.psm1 during the plugin
    loading phase. Not auto-loaded (non-Verb-Noun filename).

    Contains:
    - Resolve-PluginLoadOrder:  topological sort of plugins by DependsOn
    - Resolve-PluginConfig:     per-plugin config resolution chain

    Plugin config resolution priority (per key):
    1. Environment variable (declared in manifest Config.<Key>.EnvVar)
    2. Plugin's own local.config.psd1 (in plugin directory, git-ignored)
    3. Core local.config.psd1 with namespaced key (pluginname.KeyName)
    4. Manifest default (declared in manifest Config.<Key>.Default)
    5. Warning if Required = $true and nothing resolved
#>

# Topological sort of plugin candidates by DependsOn using Kahn's algorithm.
# Returns a List[object] of plugin candidates in dependency-safe load order.
# Plugins with missing dependencies are warned and skipped.
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

# Resolves plugin configuration values from the priority chain.
# Returns a hashtable of resolved key -> value pairs.
function Resolve-PluginConfig {
    param(
        [hashtable]$Manifest,
        [string]$PluginDir,
        [string]$ModuleRoot
    )

    $ConfigDefs = $Manifest.Config
    if (-not $ConfigDefs) { return @{} }

    # Load plugin-level local.config.psd1
    $PluginLocalPath = [System.IO.Path]::Combine($PluginDir, 'local.config.psd1')
    $PluginLocal = if ([System.IO.File]::Exists($PluginLocalPath)) {
        try { Import-PowerShellDataFile -Path $PluginLocalPath } catch { @{} }
    } else { @{} }

    # Load core local.config.psd1 for namespaced fallback
    $CoreLocalPath = [System.IO.Path]::Combine($ModuleRoot, 'local.config.psd1')
    $CoreLocal = if ([System.IO.File]::Exists($CoreLocalPath)) {
        try { Import-PowerShellDataFile -Path $CoreLocalPath } catch { @{} }
    } else { @{} }

    $PluginName = $Manifest.Name
    $Resolved = @{}

    foreach ($Key in $ConfigDefs.Keys) {
        $Def = $ConfigDefs[$Key]
        $Value = $null

        # 1. Environment variable
        if ($Def.EnvVar) {
            $EnvVal = [System.Environment]::GetEnvironmentVariable($Def.EnvVar)
            if (-not [string]::IsNullOrWhiteSpace($EnvVal)) {
                $Value = $EnvVal
            }
        }

        # 2. Plugin's own local.config.psd1
        if (-not $Value -and $PluginLocal.ContainsKey($Key)) {
            $Val = $PluginLocal[$Key]
            if (-not [string]::IsNullOrWhiteSpace($Val)) {
                $Value = $Val
            }
        }

        # 3. Core local.config.psd1 with namespaced key
        $NamespacedKey = "$PluginName.$Key"
        if (-not $Value -and $CoreLocal.ContainsKey($NamespacedKey)) {
            $Val = $CoreLocal[$NamespacedKey]
            if (-not [string]::IsNullOrWhiteSpace($Val)) {
                $Value = $Val
            }
        }

        # 4. Manifest default
        if (-not $Value -and $null -ne $Def.Default) {
            $Value = $Def.Default
        }

        # 5. Required check
        if (-not $Value -and $Def.Required) {
            [System.Console]::Error.WriteLine(
                "[WARN Resolve-PluginConfig] Plugin '$PluginName' config key '$Key' is required but not set." +
                " Set env var '$($Def.EnvVar)' or add '$Key' to $PluginLocalPath")
        }

        $Resolved[$Key] = $Value
    }

    return $Resolved
}

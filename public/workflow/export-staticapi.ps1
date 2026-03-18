<#
    .SYNOPSIS
    Generates static JSON files mirroring the live API response shapes.

    .DESCRIPTION
    This file contains Export-StaticApi.

    Export-StaticApi produces a directory of JSON files suitable for serving
    as a static API (e.g. on nerthus.pl). Uses Robot.JsonHelper.WriteSortedJson
    for deterministic output with clean git diffs.

    Default exports: schema, entities, sessions, players, manifest.
    Optional: economy snapshot, location graph, session leaderboard.

    Helpers:
    - Write-ExportJson: nested helper that writes an object as sorted JSON
      via the C# helper or ConvertTo-Json fallback.
#>

function Export-StaticApi {
    <#
        .SYNOPSIS
        Generates static JSON files mirroring the live API response shapes
        for offline/CDN hosting.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')] param(
        [Parameter(Mandatory, HelpMessage = "Target directory for exported JSON files")]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter(HelpMessage = "Include economy/snapshot.json export")]
        [switch]$IncludeEconomy,

        [Parameter(HelpMessage = "Include location-graph.json and session-graph exports")]
        [switch]$IncludeGraph
    )

    $UTF8NoBOM  = [System.Text.UTF8Encoding]::new($false)
    $HasJsonHelper = ([System.Management.Automation.PSTypeName]'Robot.JsonHelper').Type
    $HasNameDict   = ([System.Management.Automation.PSTypeName]'Robot.ApiNameDictionary').Type

    $FullPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath }
                else { [System.IO.Path]::GetFullPath($OutputPath) }

    if (-not [System.IO.Directory]::Exists($FullPath)) {
        if ($PSCmdlet.ShouldProcess($FullPath, 'Create directory')) {
            [void][System.IO.Directory]::CreateDirectory($FullPath)
        }
    }

    $Exported  = [System.Collections.Generic.List[string]]::new()
    $ExportedAt = [datetime]::UtcNow.ToString('o')

    # Helper: write object as sorted JSON via C# helper or ConvertTo-Json fallback
    function Write-ExportJson {
        param([string]$RelPath, [object]$Data)
        $FilePath = [System.IO.Path]::Combine($FullPath, $RelPath)
        $Dir = [System.IO.Path]::GetDirectoryName($FilePath)
        if (-not [System.IO.Directory]::Exists($Dir)) {
            [void][System.IO.Directory]::CreateDirectory($Dir)
        }

        if ($HasJsonHelper -and $Data -is [System.Collections.IDictionary]) {
            [Robot.JsonHelper]::WriteSortedJson($FilePath, $Data, 8)
        }
        else {
            $Json = $Data | ConvertTo-Json -Depth 8 -Compress:$false
            [System.IO.File]::WriteAllText($FilePath, $Json, $UTF8NoBOM)
        }
        $Exported.Add($RelPath)
    }

    if (-not $PSCmdlet.ShouldProcess($FullPath, 'Export static API')) { return }

    # schema.json
    if ($HasNameDict) {
        $Schema = [Robot.ApiNameDictionary]::GetSchema()
        Write-ExportJson -RelPath 'schema.json' -Data $Schema
    }

    # entities.json
    $Entities = @(Get-Entity -Quiet)
    Write-ExportJson -RelPath 'entities.json' -Data @{
        count = $Entities.Count
        items = $Entities
    }

    # sessions.json (metadata only — no body content)
    $Sessions = @(Get-Session)
    Write-ExportJson -RelPath 'sessions.json' -Data @{
        count = $Sessions.Count
        items = $Sessions
    }

    # players.json
    $Players = @(Get-Player)
    Write-ExportJson -RelPath 'players.json' -Data @{
        count = $Players.Count
        items = $Players
    }

    # Optional: economy
    if ($IncludeEconomy) {
        try {
            $Snapshot = Get-EconomicSnapshot -Quiet
            $EcoDir = [System.IO.Path]::Combine($FullPath, 'economy')
            if (-not [System.IO.Directory]::Exists($EcoDir)) {
                [void][System.IO.Directory]::CreateDirectory($EcoDir)
            }
            Write-ExportJson -RelPath 'economy/snapshot.json' -Data $Snapshot
        } catch {
            Write-RobotWarning "[WARN Export-StaticApi] Economy snapshot failed: $_"
        }
    }

    # Optional: graphs
    if ($IncludeGraph) {
        try {
            $LocGraph = Get-LocationGraph -Quiet
            Write-ExportJson -RelPath 'location-graph.json' -Data $LocGraph
        } catch {
            Write-RobotWarning "[WARN Export-StaticApi] Location graph failed: $_"
        }

        try {
            $Leaderboard = @(Get-SessionGraphLeaderboard -Quiet)
            $LbDir = [System.IO.Path]::Combine($FullPath, 'session-graph')
            if (-not [System.IO.Directory]::Exists($LbDir)) {
                [void][System.IO.Directory]::CreateDirectory($LbDir)
            }
            Write-ExportJson -RelPath 'session-graph/leaderboard.json' -Data @{
                count = $Leaderboard.Count
                items = $Leaderboard
            }
        } catch {
            Write-RobotWarning "[WARN Export-StaticApi] Leaderboard failed: $_"
        }
    }

    # manifest.json — always last (contains list of exported files)
    $VersionPath = [System.IO.Path]::Combine($script:ModuleRoot, 'VERSION')
    $Version = if ([System.IO.File]::Exists($VersionPath)) {
        [System.IO.File]::ReadAllText($VersionPath).Trim()
    } else { 'unknown' }

    $Manifest = @{
        version    = $Version
        exportedAt = $ExportedAt
        endpoints  = @($Exported)
    }
    Write-ExportJson -RelPath 'manifest.json' -Data $Manifest

    return [PSCustomObject]@{
        OutputPath = $FullPath
        Files      = @($Exported)
        FileCount  = $Exported.Count
        ExportedAt = $ExportedAt
    }
}

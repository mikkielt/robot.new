<#
    .SYNOPSIS
    Scrapes MargoWorld.pl for canonical map data, diffs against local registry.

    .DESCRIPTION
    Modernized replacement for invoke-mapcheckup-legacy.ps1.

    Scrapes /world/list for all maps (ID, Name, URL slug), visits each detail
    page to extract CDN image URL. Supports:
    - -DiffOnly:                 compare against maps.json, return only new/changed
    - -UpdateRegistry:           merge results into maps.json with timestamp
    - -SendDiscordNotification:  send via Send-DiscordMessage (core function)
    - -ShowProgress:             write progress to stdout
    - -Id:                       filter to specific map IDs
    - SupportsShouldProcess:     full -WhatIf / -Confirm support

    Cross-references with nerthusaddon if nerthusaddon-integration plugin is loaded
    (flags IsModifiedByNerthusAddon).

    Dot-sources margoworld-helpers.ps1 for helper functions.
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"

function Invoke-MargoWorldMapCheckup {
    <#
        .SYNOPSIS
        Scrapes MargoWorld.pl for map data, diffs against local registry.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(HelpMessage = "Filter to specific map IDs")]
        [int[]]$Id,

        [Parameter(HelpMessage = "Return only new/changed entries vs maps.json")]
        [switch]$DiffOnly,

        [Parameter(HelpMessage = "Merge results into maps.json")]
        [switch]$UpdateRegistry,

        [Parameter(HelpMessage = "Send Discord notification with results")]
        [switch]$SendDiscordNotification,

        [Parameter(HelpMessage = "Show scraping progress")]
        [switch]$ShowProgress,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-PluginConfig -PluginName 'margoworld-datasource'
    $MargoWorldDomain = if ($Config.MargoWorldDomain) { $Config.MargoWorldDomain } else { 'https://margoworld.pl' }
    $GarmoryDomain    = if ($Config.GarmoryDomain) { $Config.GarmoryDomain } else { 'https://micc.garmory-cdn.cloud' }

    # Check for nerthusaddon-integration plugin (optional cross-ref)
    $NerthusAddonMapIds = $null
    $NerthusAddonLoaded = ($script:LoadedPlugins -and $script:LoadedPlugins.ContainsKey('nerthusaddon-integration'))
    if ($NerthusAddonLoaded) {
        try {
            $AddonMaps = Import-NerthusAddonMaps -Quiet
            if ($AddonMaps) {
                $NerthusAddonMapIds = [System.Collections.Generic.HashSet[int]]::new()
                foreach ($AM in $AddonMaps) {
                    [void]$NerthusAddonMapIds.Add($AM.Id)
                }
            }
        } catch {
            Write-RobotWarning "[WARN Invoke-MargoWorldMapCheckup] Failed to load nerthusaddon maps: $_"
        }
    }

    # Scrape /world/list
    Write-Verbose "Fetching $MargoWorldDomain/world/list"
    $ListHtml = Invoke-RestMethod -Method GET -Uri "$MargoWorldDomain/world/list" -UseBasicParsing

    $AllMaps = ConvertFrom-MargoWorldList -Html $ListHtml

    if ($AllMaps.Count -eq 0) {
        Write-RobotWarning "[WARN Invoke-MargoWorldMapCheckup] No maps found on MargoWorld.pl"
        return @()
    }

    # Filter by ID if specified
    if ($Id -and $Id.Count -gt 0) {
        $IdSet = [System.Collections.Generic.HashSet[int]]::new([int[]]$Id)
        $AllMaps = $AllMaps | Where-Object { $IdSet.Contains($_.Id) }
    }

    # Visit each detail page to get CDN URL
    $Results = [System.Collections.Generic.List[object]]::new()
    $Counter = 0

    foreach ($Map in $AllMaps) {
        $Counter++
        if ($ShowProgress) {
            Write-Host "[$Counter/$($AllMaps.Count)] $($Map.Name)" -ForegroundColor Yellow
        }

        $MapUrl = $null
        try {
            $DetailHtml = Invoke-RestMethod -Method GET -Uri "$MargoWorldDomain/world/view/$($Map.Id)/$($Map.Slug)" -UseBasicParsing
            $MapUrl = ConvertFrom-MargoWorldDetail -Html $DetailHtml
        } catch {
            Write-RobotWarning "[WARN Invoke-MargoWorldMapCheckup] Failed to fetch detail for map $($Map.Id) '$($Map.Name)': $_"
        }

        $IsModified = if ($NerthusAddonMapIds) { $NerthusAddonMapIds.Contains($Map.Id) } else { $null }

        [void]$Results.Add([PSCustomObject]@{
            Id                      = $Map.Id
            Name                    = $Map.Name
            Slug                    = $Map.Slug
            Url                     = $MapUrl
            BaseName                = Get-MapBaseName -Name $Map.Name
            LastChecked             = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            IsModifiedByNerthusAddon = $IsModified
        })
    }

    # Diff against existing registry
    if ($DiffOnly -or $UpdateRegistry) {
        $MapsJsonPath = Get-MargoWorldMapsJsonPath -Config $Config
        $ExistingData = if ($MapsJsonPath) { Read-MargoWorldMapsJson -Path $MapsJsonPath } else { $null }

        if ($DiffOnly -and $ExistingData -and $ExistingData.maps) {
            $ExistingUrls = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Existing in $ExistingData.maps) {
                [void]$ExistingUrls.Add("$($Existing.id):$($Existing.url)")
            }

            $Results = [System.Collections.Generic.List[object]]::new(
                [object[]]@($Results | Where-Object { -not $ExistingUrls.Contains("$($_.Id):$($_.Url)") }))
        }

        if ($UpdateRegistry -and $MapsJsonPath) {
            if ($PSCmdlet.ShouldProcess($MapsJsonPath, "Update maps.json registry with $($Results.Count) entries")) {
                $NewMaps = [System.Collections.Generic.List[object]]::new()

                # Keep existing entries
                if ($ExistingData -and $ExistingData.maps) {
                    $UpdatedIds = [System.Collections.Generic.HashSet[int]]::new()
                    foreach ($R in $Results) { [void]$UpdatedIds.Add($R.Id) }

                    foreach ($Existing in $ExistingData.maps) {
                        if (-not $UpdatedIds.Contains($Existing.id)) {
                            [void]$NewMaps.Add($Existing)
                        }
                    }
                }

                # Add new/updated entries
                foreach ($R in $Results) {
                    [void]$NewMaps.Add([PSCustomObject]@{
                        id          = $R.Id
                        name        = $R.Name
                        url         = $R.Url
                        lastChecked = $R.LastChecked
                    })
                }

                $RegistryData = [PSCustomObject]@{
                    lastUpdated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
                    maps        = $NewMaps.ToArray()
                }

                # Ensure directory exists
                $ParentDir = [System.IO.Path]::GetDirectoryName($MapsJsonPath)
                if (-not [System.IO.Directory]::Exists($ParentDir)) {
                    [void][System.IO.Directory]::CreateDirectory($ParentDir)
                }

                Write-MargoWorldMapsJson -Data $RegistryData -Path $MapsJsonPath
                Write-Verbose "Updated maps.json with $($Results.Count) entries"
            }
        }
    }

    # Send Discord notification if requested
    if ($SendDiscordNotification -and $Results.Count -gt 0) {
        $AdminConfig = Get-AdminConfig
        $Webhook = $AdminConfig.RepoWebhook
        if ($Webhook) {
            $Message = "Sprawdzono mapy na MargoWorld.pl."
            foreach ($R in $Results) {
                $Line = "Id: $($R.Id); Nazwa: $($R.Name), Url: $($R.Url)"
                if ($R.IsModifiedByNerthusAddon) {
                    $Line += " (UWAGA! Mapa zmodyfikowana przez NerthusAddon)"
                }
                $Message += [System.Environment]::NewLine + $Line
            }

            if ($PSCmdlet.ShouldProcess('Discord', "Send notification ($($Results.Count) maps)")) {
                Send-DiscordMessage -Webhook $Webhook -Message $Message -Username $AdminConfig.BotUsername
            }
        } else {
            Write-RobotWarning "[WARN Invoke-MargoWorldMapCheckup] RepoWebhook not configured - skipping Discord notification"
        }
    }

    return $Results

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

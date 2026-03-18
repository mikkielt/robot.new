<#
    .SYNOPSIS
    Scrapes MargoWorld.pl /world page for minimap coordinates, matches to Lokacja entities.

    .DESCRIPTION
    Fetches the /world page which contains CSS-positioned <a> elements with pixel
    coordinates for every exterior location on the world minimap. Converts pixel
    positions to tile coordinates and cross-references with Lokacja entities by
    @margonemid.

    For each matched entity, classifies as New (no existing @koordynaty), Changed
    (different coordinates), or Unchanged. Writes @koordynaty tags with temporal
    validity when not in -ReportOnly mode.

    Dot-sources margoworld-helpers.ps1 for helper functions and
    entity-findhelpers.ps1 for shared entity file scanning patterns
    ($script:EntityBulletPattern, $script:TagPattern).
#>

# Load helpers
. "$PSScriptRoot/../private/margoworld-helpers.ps1"
. "$script:ModuleRoot/private/entity-findhelpers.ps1"

function Invoke-MargoWorldMapCoordinates {
    <#
        .SYNOPSIS
        Scrapes MargoWorld.pl /world for tile coordinates, matches to Lokacja entities.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(HelpMessage = "Pre-fetched entity data from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Path to entities.md file (overrides AdminConfig)")]
        [string]$EntitiesFile,

        [Parameter(HelpMessage = "Temporal validity start date (YYYY-MM format)")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Filter to specific MargoWorld map IDs")]
        [int[]]$Id,

        [Parameter(HelpMessage = "Only report matches without writing changes")]
        [switch]$ReportOnly,

        [Parameter(HelpMessage = "Suppress warnings")]
        [switch]$Quiet
    )

    $OldSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-PluginConfig -PluginName 'margoworld-datasource'
    $MargoWorldDomain = if ($Config.MargoWorldDomain) { $Config.MargoWorldDomain } else { 'https://margoworld.pl' }
    $CoordPadding = if ($Config.CoordPadding) { [int]$Config.CoordPadding } else { 7 }

    # ── Step 1: Scrape /world ──
    $Html = $null
    try {
        Write-Verbose "Fetching $MargoWorldDomain/world"
        $Html = Invoke-RestMethod -Method GET -Uri "$MargoWorldDomain/world" -UseBasicParsing
    } catch {
        Write-RobotWarning "[WARN Invoke-MargoWorldMapCoordinates] Failed to fetch /world: $_"
        return @{
            ScrapedCount   = 0
            MatchedCount   = 0
            UnmatchedCount = 0
            NewCount       = 0
            ChangedCount   = 0
            UnchangedCount = 0
            Results        = @()
            Unmatched      = @()
        }
    }

    # ── Step 2: Parse HTML ──
    $ScrapedMaps = ConvertFrom-MargoWorldMap -Html $Html -Padding $CoordPadding

    if ($ScrapedMaps.Count -eq 0) {
        Write-RobotWarning "[WARN Invoke-MargoWorldMapCoordinates] No map coordinates found on /world page"
        return @{
            ScrapedCount   = 0
            MatchedCount   = 0
            UnmatchedCount = 0
            NewCount       = 0
            ChangedCount   = 0
            UnchangedCount = 0
            Results        = @()
            Unmatched      = @()
        }
    }

    # ── Step 3: Filter by ID (optional) ──
    if ($Id -and $Id.Count -gt 0) {
        $IdSet = [System.Collections.Generic.HashSet[int]]::new([int[]]$Id)
        $ScrapedMaps = [System.Collections.Generic.List[object]]::new(
            [object[]]@($ScrapedMaps | Where-Object { $IdSet.Contains($_.Id) }))
    }

    # ── Step 4: Load entities ──
    if (-not $Entities) {
        $Entities = Get-Entity -Quiet
    }

    $Locations = @($Entities | Where-Object { $_.Type -eq 'Lokacja' })

    # ── Step 5: Build margonemid → entity lookup ──
    $MargoIdToEntity = [System.Collections.Generic.Dictionary[int, object]]::new()

    foreach ($Loc in $Locations) {
        if (-not $Loc.Overrides -or -not $Loc.Overrides.ContainsKey('margonemid')) { continue }

        foreach ($MidValue in $Loc.Overrides['margonemid']) {
            $MidText = if ($MidValue -is [string]) { $MidValue } else { $MidValue.ToString() }
            if ($MidText -match '^\d+$') {
                $MidInt = [int]$MidText
                if (-not $MargoIdToEntity.ContainsKey($MidInt)) {
                    $MargoIdToEntity[$MidInt] = $Loc
                }
            }
        }
    }

    # ── Step 6: Cross-reference ──
    # Group scraped maps by entity (multiple margonemids may map to same entity)
    $EntityResults = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $Unmatched = [System.Collections.Generic.List[object]]::new()

    foreach ($Map in $ScrapedMaps) {
        if (-not $MargoIdToEntity.ContainsKey($Map.Id)) {
            [void]$Unmatched.Add([PSCustomObject]@{
                Id    = $Map.Id
                Name  = $Map.Name
                TileX = $Map.TileX
                TileY = $Map.TileY
            })
            continue
        }

        $Entity = $MargoIdToEntity[$Map.Id]

        # Use first matching map's coordinates as canonical (lowest ID)
        if ($EntityResults.ContainsKey($Entity.Name)) {
            $Existing = $EntityResults[$Entity.Name]
            if ($Map.TileX -ne $Existing.ScrapedX -or $Map.TileY -ne $Existing.ScrapedY) {
                Write-RobotWarning "[WARN Invoke-MargoWorldMapCoordinates] Entity '$($Entity.Name)' has different coordinates from map ID $($Map.Id) ($($Map.TileX), $($Map.TileY)) vs ID $($Existing.MargonemId) ($($Existing.ScrapedX), $($Existing.ScrapedY))"
            }
            continue
        }

        # Determine status
        $ExistingX = $null
        $ExistingY = $null
        $Status = 'New'

        if ($Entity.Coordinates) {
            $ExistingX = $Entity.Coordinates.X
            $ExistingY = $Entity.Coordinates.Y

            if ($ExistingX -eq $Map.TileX -and $ExistingY -eq $Map.TileY) {
                $Status = 'Unchanged'
            } else {
                $Status = 'Changed'
            }
        }

        $EntityResults[$Entity.Name] = [PSCustomObject]@{
            EntityName = $Entity.Name
            CN         = $Entity.CN
            MargonemId = $Map.Id
            MapName    = $Map.Name
            ScrapedX   = $Map.TileX
            ScrapedY   = $Map.TileY
            ExistingX  = $ExistingX
            ExistingY  = $ExistingY
            Status     = $Status
        }
    }

    $AllResults = @($EntityResults.Values)
    $NewEntries     = @($AllResults | Where-Object { $_.Status -eq 'New' })
    $ChangedEntries = @($AllResults | Where-Object { $_.Status -eq 'Changed' })
    $UnchangedEntries = @($AllResults | Where-Object { $_.Status -eq 'Unchanged' })

    # ── Step 7: Report-only mode ──
    if ($ReportOnly) {
        return @{
            ScrapedCount   = $ScrapedMaps.Count
            MatchedCount   = $EntityResults.Count
            UnmatchedCount = $Unmatched.Count
            NewCount       = $NewEntries.Count
            ChangedCount   = $ChangedEntries.Count
            UnchangedCount = $UnchangedEntries.Count
            Results        = $AllResults
            Unmatched      = @($Unmatched)
        }
    }

    # ── Step 8: Write updates ──

    # 8a. "New" entities — use Set-Entity (no existing @koordynaty)
    foreach ($Entry in $NewEntries) {
        $CoordValue = "$($Entry.ScrapedX), $($Entry.ScrapedY)"
        $SetParams = @{
            Name = $Entry.EntityName
            Type = 'Lokacja'
            Tags = @{ 'koordynaty' = $CoordValue }
        }
        if (-not [string]::IsNullOrWhiteSpace($ValidFrom)) {
            $SetParams['ValidFrom'] = $ValidFrom
        }
        if ($EntitiesFile) {
            $SetParams['EntitiesFile'] = $EntitiesFile
        }

        if ($PSCmdlet.ShouldProcess($Entry.EntityName, "Set @koordynaty: $CoordValue")) {
            Set-Entity @SetParams
        }
    }

    # 8b. "Changed" entities — direct file manipulation to close old + add new
    if ($ChangedEntries.Count -gt 0) {
        # Resolve the entities file path
        $AdminConfig = Get-AdminConfig
        $TargetEntitiesFile = if ($EntitiesFile) { $EntitiesFile } else { $AdminConfig.EntitiesFile }

        # Discover all entity files in the same directory
        $EntDir = [System.IO.Path]::GetDirectoryName($TargetEntitiesFile)
        $AllEntityFiles = [System.Collections.Generic.List[string]]::new()
        if ([System.IO.File]::Exists($TargetEntitiesFile)) {
            [void]$AllEntityFiles.Add($TargetEntitiesFile)
        }
        $OverflowFiles = [System.IO.Directory]::GetFiles($EntDir, '*-*-ent.md', [System.IO.SearchOption]::AllDirectories)
        foreach ($OF in $OverflowFiles) {
            [void]$AllEntityFiles.Add($OF)
        }

        # Process each changed entity
        foreach ($Entry in $ChangedEntries) {
            $ValidToDate = if (-not [string]::IsNullOrWhiteSpace($ValidFrom)) { $ValidFrom } else { (Get-Date -Format 'yyyy-MM') }
            $Written = $false

            foreach ($FilePath in $AllEntityFiles) {
                if ($Written) { break }

                $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $RawContent = [System.IO.File]::ReadAllText($FilePath, $Utf8NoBom)
                $NL = if ($RawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
                $LineArray = $RawContent.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)
                $Lines = [System.Collections.Generic.List[string]]::new($LineArray)

                # Find the entity bullet
                $BulletIdx = -1
                for ($i = 0; $i -lt $Lines.Count; $i++) {
                    $BMatch = $script:EntityBulletPattern.Match($Lines[$i])
                    if ($BMatch.Success) {
                        $BulletName = $BMatch.Groups[1].Value.Trim()
                        if ([string]::Equals($BulletName, $Entry.EntityName, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $BulletIdx = $i
                            break
                        }
                    }
                }

                if ($BulletIdx -lt 0) { continue }

                # Find children range
                $ChildEnd = $BulletIdx + 1
                for ($j = $BulletIdx + 1; $j -lt $Lines.Count; $j++) {
                    if ($script:EntityBulletPattern.IsMatch($Lines[$j])) {
                        $ChildEnd = $j
                        break
                    }
                    if ($Lines[$j].Length -gt 0 -and $Lines[$j][0] -ne ' ' -and $Lines[$j][0] -ne "`t" -and -not [string]::IsNullOrWhiteSpace($Lines[$j])) {
                        $ChildEnd = $j
                        break
                    }
                    $ChildEnd = $j + 1
                }

                # Trim trailing blanks
                while ($ChildEnd -gt $BulletIdx + 1 -and [string]::IsNullOrWhiteSpace($Lines[$ChildEnd - 1])) {
                    $ChildEnd--
                }

                # Find the last @koordynaty tag line in children (bottom-to-top)
                $KoordIdx = -1
                for ($k = $ChildEnd - 1; $k -ge $BulletIdx + 1; $k--) {
                    $TMatch = $script:TagPattern.Match($Lines[$k])
                    if ($TMatch.Success -and [string]::Equals($TMatch.Groups[1].Value, 'koordynaty', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $KoordIdx = $k
                        break
                    }
                }

                if ($KoordIdx -lt 0) { continue }

                # Close the existing tag and insert new one
                $NewCoordValue = "$($Entry.ScrapedX), $($Entry.ScrapedY)"
                $TemporalSuffix = if (-not [string]::IsNullOrWhiteSpace($ValidFrom)) { " ($ValidFrom`:)" } else { '' }
                $NewTagLine = "    - @koordynaty: $NewCoordValue$TemporalSuffix"

                if ($PSCmdlet.ShouldProcess($Entry.EntityName, "Update @koordynaty: $($Entry.ExistingX), $($Entry.ExistingY) -> $NewCoordValue")) {
                    $Lines[$KoordIdx] = Close-TemporalTag -Line $Lines[$KoordIdx] -ValidTo $ValidToDate
                    $Lines.Insert($KoordIdx + 1, $NewTagLine)

                    $Content = [string]::Join($NL, $Lines)
                    [System.IO.File]::WriteAllText($FilePath, $Content, $Utf8NoBom)
                    $Written = $true
                }
            }

            if (-not $Written -and -not $WhatIfPreference) {
                Write-RobotWarning "[WARN Invoke-MargoWorldMapCoordinates] Could not find entity '$($Entry.EntityName)' in any entity file for coordinate update"
            }
        }
    }

    return @{
        ScrapedCount   = $ScrapedMaps.Count
        MatchedCount   = $EntityResults.Count
        UnmatchedCount = $Unmatched.Count
        NewCount       = $NewEntries.Count
        ChangedCount   = $ChangedEntries.Count
        UnchangedCount = $UnchangedEntries.Count
        Results        = $AllResults
        Unmatched      = @($Unmatched)
    }

    } finally { if ($Quiet) { $script:SuppressWarnings = $OldSuppress } }
}

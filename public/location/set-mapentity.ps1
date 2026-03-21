<#
    .SYNOPSIS
    Updates a Mapa entity with domain-specific validation.

    .DESCRIPTION
    This file contains Set-MapEntity which wraps Set-Entity with validation
    of slug uniqueness, dimensions format, parent existence, and door target
    existence. Supports adding and removing individual door entries (multi-valued
    @drzwi tags) and updating Mapa-specific properties (@slug, @url, @url_nerthus,
    @wymiary, @info).

    Processing pipeline:
    1. Validates -Dimensions format (two comma-separated positive integers)
    2. Reads raw entity file for slug/parent/door validations
    3. Validates -Slug uniqueness within ## Mapa section (excludes own bullet)
    4. Validates -Parent resolves to existing Lokacja or Mapa entity
    5. Warns on unresolved -AddDoors targets (non-fatal)
    6. Delegates simple tag updates to Set-Entity -Type Mapa
    7. For -AddDoors: appends new @drzwi entries via direct entity file insertion
    8. For -RemoveDoors: removes matching @drzwi lines from entity bullet

    Dot-sources entity-writehelpers.ps1 and admin-config.ps1.
    Uses ThrowTerminatingError for validation errors.
    Supports -WhatIf via SupportsShouldProcess.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Set-MapEntity {
    <#
        .SYNOPSIS
        Updates a Mapa entity with domain-specific validation.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "New URL-safe slug (@slug). Uniqueness enforced.")]
        [string]$Slug,

        [Parameter(HelpMessage = "Parent location name (@lokacja)")]
        [string]$Parent,

        [Parameter(HelpMessage = "CDN map image URL (@url)")]
        [string]$Url,

        [Parameter(HelpMessage = "Nerthus map image URL (@url_nerthus)")]
        [string]$UrlNerthus,

        [Parameter(HelpMessage = "Map dimensions as 'W, H' (@wymiary)")]
        [string]$Dimensions,

        [Parameter(HelpMessage = "Description (@info)")]
        [string]$Info,

        [Parameter(HelpMessage = "Door connections to add (@drzwi)")]
        [string[]]$AddDoors,

        [Parameter(HelpMessage = "Door connections to remove (@drzwi)")]
        [string[]]$RemoveDoors,

        [Parameter(HelpMessage = "Additional tags")]
        [hashtable]$Tags = @{},

        [Parameter(HelpMessage = "Temporal validity (YYYY-MM)")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    # Validate dimensions format
    if ($Dimensions) {
        $Parts = $Dimensions -split ','
        if ($Parts.Count -ne 2) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Invalid dimensions format '$Dimensions'. Expected 'W, H' (two comma-separated positive integers)."),
                'InvalidDimensionsFormat', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Dimensions)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
        [int]$W = 0; [int]$H = 0
        if (-not [int]::TryParse($Parts[0].Trim(), [ref]$W) -or -not [int]::TryParse($Parts[1].Trim(), [ref]$H) -or $W -le 0 -or $H -le 0) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Invalid dimensions '$Dimensions'. Width and height must be positive integers."),
                'InvalidDimensionsValue', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Dimensions)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
    }

    # Read raw entity file for slug/parent/door validations
    if ($Slug -or $Parent -or $AddDoors) {
        $Config0 = Get-AdminConfig
        $ValidationFilePath = if ($EntitiesFile) { $EntitiesFile } else { $Config0.EntitiesFile }
        $ValidationFilePath = Invoke-EnsureEntityFile -Path $ValidationFilePath
        $ValFile = Read-EntityFile -Path $ValidationFilePath
        $ValLines = $ValFile.Lines.ToArray()
    }

    # Validate slug uniqueness, excluding own entity's current slug
    if ($Slug) {
        $Section = Find-EntitySection -Lines $ValLines -EntityType 'Mapa'
        if ($Section) {
            $OwnBullet = Find-EntityBullet -Lines $ValLines -SectionStart $Section.StartIdx `
                -SectionEnd $Section.EndIdx -EntityName $Name
            for ($i = $Section.StartIdx; $i -lt $Section.EndIdx; $i++) {
                # Skip lines belonging to the target entity's own bullet
                if ($OwnBullet -and $i -ge $OwnBullet.BulletIdx -and $i -lt $OwnBullet.ChildrenEndIdx) {
                    continue
                }
                if ($ValLines[$i] -match '^\s+-\s+@slug:\s*(.+)$') {
                    $ExistingSlug = $Matches[1].Trim()
                    # Strip temporal suffix for comparison
                    $ParenIdx = $ExistingSlug.IndexOf('(')
                    if ($ParenIdx -gt 0) { $ExistingSlug = $ExistingSlug.Substring(0, $ParenIdx).Trim() }
                    if ([string]::Equals($ExistingSlug, $Slug, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $Err = [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new(
                                "Slug '$Slug' already exists under ## Mapa. Use a unique slug."),
                            'DuplicateSlug',
                            [System.Management.Automation.ErrorCategory]::ResourceExists, $Slug)
                        $PSCmdlet.ThrowTerminatingError($Err)
                    }
                }
            }
        }
    }

    # Validate parent exists as Lokacja or Mapa bullet
    if ($Parent) {
        $ParentFound = $false
        foreach ($SectionType in @('Lokacja', 'Mapa')) {
            $ParentSection = Find-EntitySection -Lines $ValLines -EntityType $SectionType
            if ($ParentSection) {
                $ParentBullet = Find-EntityBullet -Lines $ValLines -SectionStart $ParentSection.StartIdx -SectionEnd $ParentSection.EndIdx -EntityName $Parent
                if ($ParentBullet) { $ParentFound = $true; break }
            }
        }
        if (-not $ParentFound) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Parent location '$Parent' not found. Create it first or check the name."),
                'ParentNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Parent)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
    }

    # Warn about unresolved AddDoors targets (non-fatal)
    if ($AddDoors) {
        $AllSectionTypes = @('NPC', 'Grupa', 'Lokacja', 'Mapa', 'Przedmiot')
        foreach ($DoorTarget in $AddDoors) {
            $DoorFound = $false
            foreach ($SectionType in $AllSectionTypes) {
                $DoorSection = Find-EntitySection -Lines $ValLines -EntityType $SectionType
                if ($DoorSection) {
                    $DoorBullet = Find-EntityBullet -Lines $ValLines -SectionStart $DoorSection.StartIdx -SectionEnd $DoorSection.EndIdx -EntityName $DoorTarget
                    if ($DoorBullet) { $DoorFound = $true; break }
                }
            }
            if (-not $DoorFound) {
                Write-RobotWarning "Door target '$DoorTarget' not found as entity. It can be created later."
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Set-MapEntity: update map")) {
        return
    }

    # Build simple tags for Set-Entity delegation
    $SimpleTags = @{}
    foreach ($Key in $Tags.Keys) { $SimpleTags[$Key] = $Tags[$Key] }
    if ($Slug)       { $SimpleTags['slug'] = $Slug }
    if ($Parent)     { $SimpleTags['lokacja'] = $Parent }
    if ($Url)        { $SimpleTags['url'] = $Url }
    if ($UrlNerthus) { $SimpleTags['url_nerthus'] = $UrlNerthus }
    if ($Dimensions) { $SimpleTags['wymiary'] = $Dimensions }
    if ($Info)       { $SimpleTags['info'] = $Info }

    if ($SimpleTags.Count -gt 0) {
        $SetParams = @{ Name = $Name; Type = 'Mapa'; Tags = $SimpleTags; Confirm = $false }
        if ($ValidFrom)    { $SetParams.ValidFrom = $ValidFrom }
        if ($EntitiesFile) { $SetParams.EntitiesFile = $EntitiesFile }
        Set-Entity @SetParams
    }

    # Multi-valued door operations via direct entity file manipulation
    if ($AddDoors -or $RemoveDoors) {
        $Config = Get-AdminConfig
        $FilePath = if ($EntitiesFile) { $EntitiesFile } else { $Config.EntitiesFile }
        $FilePath = Invoke-EnsureEntityFile -Path $FilePath
        $File = Read-EntityFile -Path $FilePath
        $LinesArray = $File.Lines.ToArray()
        $Section = Find-EntitySection -Lines $LinesArray -EntityType 'Mapa'
        if (-not $Section) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Entity '$Name' not found - no ## Mapa section in entities.md"),
                'SectionNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
        $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
        if (-not $Bullet) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Entity '$Name' not found under ## Mapa in entities.md"),
                'EntityNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
            $PSCmdlet.ThrowTerminatingError($Err)
        }

        $Lines = $File.Lines

        # Remove matching @drzwi lines (iterate backwards to preserve indices)
        if ($RemoveDoors) {
            $RemoveSet = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($D in $RemoveDoors) { [void]$RemoveSet.Add($D) }

            for ($i = $Bullet.ChildrenEndIdx - 1; $i -ge $Bullet.ChildrenStartIdx; $i--) {
                $Line = $Lines[$i]
                if ($Line -match '^\s+-\s+@drzwi:\s*(.+)$') {
                    $DoorVal = $Matches[1].Trim()
                    # Strip temporal suffix for comparison: "Steadwick (2020-01:)" -> "Steadwick"
                    $ParenIdx = $DoorVal.IndexOf('(')
                    if ($ParenIdx -gt 0) { $DoorVal = $DoorVal.Substring(0, $ParenIdx).Trim() }
                    if ($RemoveSet.Contains($DoorVal)) {
                        $Lines.RemoveAt($i)
                    }
                }
            }
        }

        # Add new @drzwi lines
        if ($AddDoors) {
            # Re-find bullet after potential removals
            $LinesArray = $Lines.ToArray()
            $Section = Find-EntitySection -Lines $LinesArray -EntityType 'Mapa'
            $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
            $ChildEnd = $Bullet.ChildrenEndIdx
            foreach ($DoorTarget in $AddDoors) {
                $DoorValue = if ($ValidFrom) { "$DoorTarget ($ValidFrom`:)" } else { $DoorTarget }
                $Lines.Insert($ChildEnd, "    - @drzwi: $DoorValue")
                $ChildEnd++
            }
        }

        Write-EntityFile -Path $FilePath -Lines $Lines -NL $File.NL
    }
}

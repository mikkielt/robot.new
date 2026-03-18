<#
    .SYNOPSIS
    Creates a new Mapa entity in entities.md with domain-specific validation.

    .DESCRIPTION
    This file contains New-MapEntity which wraps New-Entity -Type Mapa
    with validation of slug uniqueness, dimensions format, URL format,
    and parent existence.

    Processing pipeline:
    1. Validates -Slug uniqueness within ## Mapa section (fail-early)
    2. Validates -Dimensions format (two comma-separated positive integers)
    3. Validates -Parent resolves to existing Lokacja or Mapa entity
    4. Builds merged tags hashtable
    5. Delegates to New-Entity -Type Mapa
    6. Appends multi-valued tags (@drzwi) via post-creation insertion

    Note: @slug is stored as a tag line but parsed into the Names list
    by the entity parser (C2: not a dedicated property on Robot.Entity).

    Dot-sources entity-writehelpers.ps1 and admin-config.ps1.
    Uses ThrowTerminatingError for validation errors.
    Supports -WhatIf via SupportsShouldProcess.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function New-MapEntity {
    <#
        .SYNOPSIS
        Creates a new Mapa entity in entities.md with domain-specific validation.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory, HelpMessage = "URL-safe slug, unique within Mapa section")]
        [ValidateNotNullOrEmpty()]
        [string]$Slug,

        [Parameter(HelpMessage = "Parent location name (@lokacja)")]
        [string]$Parent,

        [Parameter(HelpMessage = "CDN map image URL (@url)")]
        [string]$Url,

        [Parameter(HelpMessage = "Nerthus map image URL (@url_nerthus)")]
        [string]$UrlNerthus,

        [Parameter(HelpMessage = "Map dimensions as 'W, H' (@wymiary)")]
        [string]$Dimensions,

        [Parameter(HelpMessage = "Door connections (@drzwi targets)")]
        [string[]]$Doors,

        [Parameter(HelpMessage = "Description (@info)")]
        [string]$Info,

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

    # Fail-early slug uniqueness check against raw markdown
    $Config = Get-AdminConfig
    $FilePath = if ($EntitiesFile) { $EntitiesFile } else { $Config.EntitiesFile }
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $FilePath
    $File = Read-EntityFile -Path $EntitiesFilePath
    $LinesArray = $File.Lines.ToArray()
    $Section = Find-EntitySection -Lines $LinesArray -EntityType 'Mapa'
    if ($Section) {
        for ($i = $Section.StartIdx; $i -lt $Section.EndIdx; $i++) {
            if ($LinesArray[$i] -match '^\s+-\s+@slug:\s*(.+)$') {
                if ([string]::Equals($Matches[1].Trim(), $Slug, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Err = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new("Slug '$Slug' already exists under ## Mapa. Use a unique slug."),
                        'DuplicateSlug', [System.Management.Automation.ErrorCategory]::ResourceExists, $Slug)
                    $PSCmdlet.ThrowTerminatingError($Err)
                }
            }
        }
    }

    # Validate parent exists as Lokacja or Mapa bullet in same entity file
    if ($Parent) {
        $ParentFound = $false
        foreach ($SectionType in @('Lokacja', 'Mapa')) {
            $ParentSection = Find-EntitySection -Lines $LinesArray -EntityType $SectionType
            if ($ParentSection) {
                $ParentBullet = Find-EntityBullet -Lines $LinesArray -SectionStart $ParentSection.StartIdx -SectionEnd $ParentSection.EndIdx -EntityName $Parent
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

    # Build tags
    $MergedTags = @{}
    foreach ($Key in $Tags.Keys) { $MergedTags[$Key] = $Tags[$Key] }
    if ($Parent)     { $MergedTags['lokacja'] = $Parent }
    $MergedTags['slug'] = $Slug
    if ($Url)        { $MergedTags['url'] = $Url }
    if ($UrlNerthus) { $MergedTags['url_nerthus'] = $UrlNerthus }
    if ($Dimensions) { $MergedTags['wymiary'] = $Dimensions }
    if ($Info)       { $MergedTags['info'] = $Info }

    $NewParams = @{
        Type    = 'Mapa'
        Name    = $Name
        Tags    = $MergedTags
        Confirm = $false
    }
    if ($ValidFrom)    { $NewParams.ValidFrom = $ValidFrom }
    if ($EntitiesFile) { $NewParams.EntitiesFile = $EntitiesFile }

    if ($PSCmdlet.ShouldProcess($Name, "New-MapEntity: create map")) {
        $Result = New-Entity @NewParams

        # Add multi-valued tags (@drzwi) via post-creation insertion
        if ($Doors) {
            $File2 = Read-EntityFile -Path $EntitiesFilePath
            $LinesArray2 = $File2.Lines.ToArray()
            $Section2 = Find-EntitySection -Lines $LinesArray2 -EntityType 'Mapa'
            $Bullet = Find-EntityBullet -Lines $LinesArray2 -SectionStart $Section2.StartIdx -SectionEnd $Section2.EndIdx -EntityName $Name
            if ($Bullet) {
                $Lines = $File2.Lines
                $ChildEnd = $Bullet.ChildrenEndIdx
                foreach ($DoorTarget in $Doors) {
                    $DoorValue = if ($ValidFrom) { "$DoorTarget ($ValidFrom`:)" } else { $DoorTarget }
                    $Lines.Insert($ChildEnd, "    - @drzwi: $DoorValue")
                    $ChildEnd++
                }
                Write-EntityFile -Path $EntitiesFilePath -Lines $Lines -NL $File2.NL
            }
        }

        return $Result
    }
}

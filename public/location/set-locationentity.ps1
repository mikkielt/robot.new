<#
    .SYNOPSIS
    Updates a Lokacja or Mapa entity with domain-specific validation.

    .DESCRIPTION
    This file contains Set-LocationEntity which wraps Set-Entity with validation
    of parent existence, coordinate format, and door target existence. Supports
    adding and removing individual door entries (multi-valued @drzwi tags).

    Processing pipeline:
    1. Validates -Coordinates format (two comma-separated integers) if provided
    2. Validates -Parent resolves to existing Lokacja or Mapa entity if provided
    3. Warns on unresolved -AddDoors targets (non-fatal)
    4. Delegates simple tag updates to Set-Entity (parent, coordinates, NerthusName, custom tags)
    5. For -AddDoors: appends new @drzwi entries via direct entity file insertion
    6. For -RemoveDoors: removes matching @drzwi lines from entity bullet

    Supports both Lokacja and Mapa entities via -Type parameter (M3 fix).

    Dot-sources entity-writehelpers.ps1 and admin-config.ps1.
    Uses ThrowTerminatingError for validation errors.
    Supports -WhatIf via SupportsShouldProcess.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Set-LocationEntity {
    <#
        .SYNOPSIS
        Updates a Lokacja or Mapa entity with domain-specific validation.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "Entity type (Lokacja or Mapa)")]
        [ValidateSet('Lokacja', 'Mapa')]
        [string]$Type = 'Lokacja',

        [Parameter(HelpMessage = "New parent location name (@lokacja)")]
        [string]$Parent,

        [Parameter(HelpMessage = "Door connections to add (@drzwi)")]
        [string[]]$AddDoors,

        [Parameter(HelpMessage = "Door connections to remove (@drzwi)")]
        [string[]]$RemoveDoors,

        [Parameter(HelpMessage = "Map coordinates as 'X, Y'")]
        [string]$Coordinates,

        [Parameter(HelpMessage = "RP display name (@nazwa_nerthus)")]
        [string]$NerthusName,

        [Parameter(HelpMessage = "Additional tags")]
        [hashtable]$Tags = @{},

        [Parameter(HelpMessage = "Temporal validity (YYYY-MM)")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    # Validate coordinates format
    if ($Coordinates) {
        $Parts = $Coordinates -split ','
        if ($Parts.Count -ne 2) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Invalid coordinates format '$Coordinates'. Expected 'X, Y' (two comma-separated integers)."),
                'InvalidCoordinateFormat', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Coordinates)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
        [int]$X = 0; [int]$Y = 0
        if (-not [int]::TryParse($Parts[0].Trim(), [ref]$X) -or -not [int]::TryParse($Parts[1].Trim(), [ref]$Y)) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Invalid coordinates '$Coordinates'. X and Y must be integers."),
                'InvalidCoordinateValue', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Coordinates)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
    }

    # Validate parent and doors against raw entity file (same file as write target)
    if ($Parent -or $AddDoors) {
        $Config0 = Get-AdminConfig
        $ValidationFilePath = if ($EntitiesFile) { $EntitiesFile } else { $Config0.EntitiesFile }
        $ValidationFilePath = Invoke-EnsureEntityFile -Path $ValidationFilePath
        $ValFile = Read-EntityFile -Path $ValidationFilePath
        $ValLines = $ValFile.Lines.ToArray()
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

    if (-not $PSCmdlet.ShouldProcess($Name, "Set-LocationEntity: update location")) {
        return
    }

    # Build simple tags for Set-Entity delegation
    $SimpleTags = @{}
    foreach ($Key in $Tags.Keys) { $SimpleTags[$Key] = $Tags[$Key] }
    if ($Parent)      { $SimpleTags['lokacja'] = $Parent }
    if ($Coordinates) { $SimpleTags['koordynaty'] = $Coordinates }
    if ($NerthusName) { $SimpleTags['nazwa_nerthus'] = $NerthusName }

    if ($SimpleTags.Count -gt 0) {
        $SetParams = @{ Name = $Name; Type = $Type; Tags = $SimpleTags; Confirm = $false }
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
        $Section = Find-EntitySection -Lines $LinesArray -EntityType $Type
        if (-not $Section) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Entity '$Name' not found - no ## $Type section in entities.md"),
                'SectionNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
            $PSCmdlet.ThrowTerminatingError($Err)
        }
        $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
        if (-not $Bullet) {
            $Err = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Entity '$Name' not found under ## $Type in entities.md"),
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
            $Section = Find-EntitySection -Lines $LinesArray -EntityType $Type
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

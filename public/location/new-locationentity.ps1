<#
    .SYNOPSIS
    Creates a new Lokacja entity in entities.md with domain-specific validation.

    .DESCRIPTION
    This file contains New-LocationEntity which wraps New-Entity -Type Lokacja
    with validation of parent existence, coordinate format, and door target
    existence (non-fatal warning).

    Processing pipeline:
    1. Validates -Coordinates format (two comma-separated integers)
    2. Reads raw entity file for parent and door validation (same file as write target)
    3. Validates -Parent resolves to existing Lokacja or Mapa bullet
    4. Warns on unresolved -Doors targets (non-fatal)
    5. Builds merged tags hashtable from explicit parameters + -Tags override
    6. Delegates to New-Entity -Type Lokacja
    7. Appends multi-valued tags (@drzwi, @margonemid) via post-creation insertion

    Dot-sources entity-writehelpers.ps1 (Read-EntityFile, Find-EntitySection,
    Find-EntityBullet, Write-EntityFile) and admin-config.ps1 (Get-AdminConfig).

    Uses ThrowTerminatingError for validation errors (H2 fix).
    Supports -WhatIf via SupportsShouldProcess.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function New-LocationEntity {
    <#
        .SYNOPSIS
        Creates a new Lokacja entity in entities.md with domain-specific validation.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "Parent location name (@lokacja)")]
        [string]$Parent,

        [Parameter(HelpMessage = "Door connections (@drzwi targets)")]
        [string[]]$Doors,

        [Parameter(HelpMessage = "Map coordinates as 'X, Y'")]
        [string]$Coordinates,

        [Parameter(HelpMessage = "RP display name (@nazwa_nerthus)")]
        [string]$NerthusName,

        [Parameter(HelpMessage = "Margonem map IDs")]
        [int[]]$MargonemIds,

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

    # Validate parent and doors against the raw entity file (uses same file path
    # as the write operation, not Get-Entity which reads from Get-RepoRoot)
    if ($Parent -or $Doors) {
        $Config = Get-AdminConfig
        $ValidationFilePath = if ($EntitiesFile) { $EntitiesFile } else { $Config.EntitiesFile }
        $ValidationFilePath = Invoke-EnsureEntityFile -Path $ValidationFilePath
        $ValFile = Read-EntityFile -Path $ValidationFilePath
        $ValLines = $ValFile.Lines.ToArray()
    }

    # Validate parent exists as Lokacja or Mapa bullet in entity file
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

    # Warn about unresolved door targets (non-fatal) — scan all sections for each target
    if ($Doors) {
        $AllSectionTypes = @('NPC', 'Grupa', 'Lokacja', 'Mapa', 'Przedmiot')
        foreach ($DoorTarget in $Doors) {
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

    # Build tags for New-Entity (single-valued tags)
    $MergedTags = @{}
    foreach ($Key in $Tags.Keys) { $MergedTags[$Key] = $Tags[$Key] }
    if ($Parent)      { $MergedTags['lokacja'] = $Parent }
    if ($Coordinates) { $MergedTags['koordynaty'] = $Coordinates }
    if ($NerthusName) { $MergedTags['nazwa_nerthus'] = $NerthusName }

    $NewParams = @{
        Type    = 'Lokacja'
        Name    = $Name
        Tags    = $MergedTags
        Confirm = $false
    }
    if ($ValidFrom)    { $NewParams.ValidFrom = $ValidFrom }
    if ($EntitiesFile) { $NewParams.EntitiesFile = $EntitiesFile }

    if ($PSCmdlet.ShouldProcess($Name, "New-LocationEntity: create location")) {
        $Result = New-Entity @NewParams

        # Add multi-valued tags via direct entity file insertion
        if ($Doors -or $MargonemIds) {
            $Config = Get-AdminConfig
            $FilePath = if ($EntitiesFile) { $EntitiesFile } else { $Config.EntitiesFile }
            $FilePath = Invoke-EnsureEntityFile -Path $FilePath
            $File = Read-EntityFile -Path $FilePath
            $LinesArray = $File.Lines.ToArray()
            $Section = Find-EntitySection -Lines $LinesArray -EntityType 'Lokacja'
            $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
            if ($Bullet) {
                $Lines = $File.Lines
                $ChildEnd = $Bullet.ChildrenEndIdx
                foreach ($DoorTarget in $Doors) {
                    $DoorValue = if ($ValidFrom) { "$DoorTarget ($ValidFrom`:)" } else { $DoorTarget }
                    $Lines.Insert($ChildEnd, "    - @drzwi: $DoorValue")
                    $ChildEnd++
                }
                foreach ($Mid in $MargonemIds) {
                    $Lines.Insert($ChildEnd, "    - @margonemid: $Mid")
                    $ChildEnd++
                }
                Write-EntityFile -Path $FilePath -Lines $Lines -NL $File.NL
            }
        }

        return $Result
    }
}

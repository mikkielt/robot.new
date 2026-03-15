<#
    .SYNOPSIS
    Upserts @tag values on an existing entity in entities.md.

    .DESCRIPTION
    This file contains Set-Entity which updates or inserts @tag values
    on a named entity. Searches all entity type sections for the name,
    or scopes to -Type if provided for disambiguation.

    If the entity is not found and -Type is provided, creates it via
    Resolve-EntityTarget (auto-create). Throws if not found and no -Type
    is given, because the target section cannot be determined without an
    explicit type.

    Tags receive a (YYYY-MM:) temporal suffix when -ValidFrom is provided,
    enabling downstream temporal resolution (e.g. Get-EntityState filters
    by date to determine which tag value was active at a given point).

    Dot-sources entity-writehelpers.ps1 (file I/O and tag manipulation)
    and admin-config.ps1 (entities file path resolution).
    Supports -WhatIf via SupportsShouldProcess.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Set-Entity {
    <#
        .SYNOPSIS
        Upserts @tag values on an entity in entities.md.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Entity name")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "Entity type (for disambiguation or auto-creation)")]
        [ValidateSet("NPC", "Grupa", "Lokacja", "Mapa", "Przedmiot")]
        [string]$Type,

        [Parameter(Mandatory, HelpMessage = "@tag values to upsert (hashtable of tag name -> value)")]
        [hashtable]$Tags,

        [Parameter(HelpMessage = "Temporal validity suffix (YYYY-MM). Applied to all tag values.")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    $Config = Get-AdminConfig
    if ($script:HasOpCtx) { Clear-OperationContext }

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $LinesArray = $File.Lines.ToArray()

    # Search scoped to -Type when given, otherwise scan all sections sequentially
    $FoundSection = $null
    $FoundBullet = $null

    if ($Type) {
        $Section = Find-EntitySection -Lines $LinesArray -EntityType $Type
        if ($Section) {
            $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
            if ($Bullet) {
                $FoundSection = $Section
                $FoundBullet = $Bullet
            }
        }
    } else {
        $AllTypes = @('NPC', 'Grupa', 'Lokacja', 'Mapa', 'Przedmiot', 'Gracz', 'Postać')
        foreach ($SearchType in $AllTypes) {
            $Section = Find-EntitySection -Lines $LinesArray -EntityType $SearchType
            if (-not $Section) { continue }
            $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
            if ($Bullet) {
                $FoundSection = $Section
                $FoundBullet = $Bullet
                break
            }
        }
    }

    if (-not $FoundBullet) {
        if (-not $Type) {
            throw "Entity '$Name' not found in entities.md. Provide -Type to auto-create."
        }

        # Auto-create via Resolve-EntityTarget
        $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType $Type -EntityName $Name
        $Lines = $Target.Lines
        $ChildEnd = $Target.ChildrenEnd
        $ChildStart = $Target.ChildrenStart
    } else {
        $Lines = $File.Lines
        $ChildEnd = $FoundBullet.ChildrenEndIdx
        $ChildStart = $FoundBullet.ChildrenStartIdx
    }

    # Temporal suffix ensures tag value is scoped to a date range for
    # downstream consumers that resolve history (e.g. Get-EntityState)
    foreach ($Key in $Tags.Keys) {
        $Value = $Tags[$Key]
        if (-not [string]::IsNullOrWhiteSpace($ValidFrom)) {
            $Value = "$Value ($ValidFrom`:)"
        }
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $ChildStart -ChildrenEnd $ChildEnd -TagName $Key -Value $Value
    }

    $FilePath = if ($FoundBullet) { $EntitiesFilePath } else { $Target.FilePath }
    $NL = if ($FoundBullet) { $File.NL } else { $Target.NL }

    if ($PSCmdlet.ShouldProcess($FilePath, "Set-Entity: update '$Name' tags")) {
        Write-EntityFile -Path $FilePath -Lines $Lines -NL $NL

        Set-SessionGraphStale -Reason "Encja '$Name' została zmodyfikowana" -ResDir $Config.ResDir

        if ($script:HasOpCtx) {
            return (New-OperationResult -Success $true -Action 'Update' `
                -TargetType $(if ($Type) { $Type } else { 'Entity' }) -TargetName $Name -UndoHint $null)
        }
    }
}

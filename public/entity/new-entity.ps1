<#
    .SYNOPSIS
    Creates a new entity entry in entities.md.

    .DESCRIPTION
    This file contains New-Entity which creates an entity bullet under the
    appropriate ## Type section in entities.md.

    Supported types: NPC, Organizacja, Lokacja, Przedmiot.
    Gracz and Postać are excluded — use New-Player and New-PlayerCharacter
    for those (they carry domain-specific logic).

    Throws if an entity with the same name already exists under the given type.
    Tags receive a (YYYY-MM:) temporal suffix when -ValidFrom is provided.

    Dot-sources entity-writehelpers.ps1 and admin-config.ps1.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function New-Entity {
    <#
        .SYNOPSIS
        Creates a new entity entry in entities.md under the specified type section.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Entity type section")]
        [ValidateSet("NPC", "Organizacja", "Lokacja", "Przedmiot")]
        [string]$Type,

        [Parameter(Mandatory, HelpMessage = "Entity name")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "Initial @tag values (hashtable of tag name -> value)")]
        [hashtable]$Tags = @{},

        [Parameter(HelpMessage = "Temporal validity suffix (YYYY-MM). Applied to all tags.")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    $Config = Get-AdminConfig

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    # Duplicate detection
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType $Type
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
        if ($ExistingBullet) {
            throw "Entity '$Name' already exists under ## $Type in entities.md"
        }
    }

    # Apply temporal suffix to tag values
    $EffectiveTags = @{}
    foreach ($Key in $Tags.Keys) {
        $Value = $Tags[$Key]
        if (-not [string]::IsNullOrWhiteSpace($ValidFrom)) {
            $EffectiveTags[$Key] = "$Value ($ValidFrom`:)"
        } else {
            $EffectiveTags[$Key] = $Value
        }
    }

    # Create entity
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType $Type -EntityName $Name -InitialTags $EffectiveTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-Entity: create '$Name' under ## $Type")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL
    }

    return [PSCustomObject]@{
        Name         = $Name
        Type         = $Type
        EntitiesFile = $EntitiesFile
        Tags         = $EffectiveTags
        Created      = $true
    }
}

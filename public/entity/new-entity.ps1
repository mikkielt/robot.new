<#
    .SYNOPSIS
    Creates a new entity entry in entities.md.

    .DESCRIPTION
    This file contains New-Entity which creates an entity bullet under the
    appropriate ## Type section in entities.md.

    Supported types: NPC, Grupa, Lokacja, Mapa, Przedmiot.
    Gracz and Postać are excluded — use New-Player and New-PlayerCharacter
    for those (they carry domain-specific validation and charfile logic).

    Processing pipeline:
    1. Fail-early duplicate detection against raw entity file under ## Type
    2. Applies temporal suffix (YYYY-MM:) to all tag values when -ValidFrom is set
    3. Resolves insertion point via Resolve-EntityTarget
    4. Writes entity file via Write-EntityFile (guarded by ShouldProcess)
    5. Marks session graph as stale (Set-SessionGraphStale) after write

    Dot-sources entity-writehelpers.ps1 (Invoke-EnsureEntityFile, Read-EntityFile,
    Find-EntitySection, Find-EntityBullet, Resolve-EntityTarget, Write-EntityFile)
    and admin-config.ps1 (Get-AdminConfig).

    Supports -WhatIf via SupportsShouldProcess. When $script:HasOpCtx is true,
    returns an OperationResult for auditing with undo hint.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function New-Entity {
    <#
        .SYNOPSIS
        Creates a new entity entry in entities.md under the specified type section.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Entity type section")]
        [ValidateSet("NPC", "Grupa", "Lokacja", "Mapa", "Przedmiot")]
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
    if ($script:HasOpCtx) { Clear-OperationContext }

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    # Fail-early duplicate detection against raw entity file
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType $Type
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
        if ($ExistingBullet) {
            throw "Entity '$Name' already exists under ## $Type in entities.md"
        }
    }

    # Append (YYYY-MM:) temporal suffix to all tag values for date-scoped creation
    $EffectiveTags = @{}
    foreach ($Key in $Tags.Keys) {
        $Value = $Tags[$Key]
        if (-not [string]::IsNullOrWhiteSpace($ValidFrom)) {
            $EffectiveTags[$Key] = "$Value ($ValidFrom`:)"
        } else {
            $EffectiveTags[$Key] = $Value
        }
    }

    # Resolve insertion point under ## Type section
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType $Type -EntityName $Name -InitialTags $EffectiveTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-Entity: create '$Name' under ## $Type")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL

        if (Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue) {
            Invoke-PluginHook -Operation 'New-Entity' -Phase 'AfterCreate' -Context @{
                Operation    = 'New-Entity'
                Name         = $Name
                Type         = $Type
                EntitiesFile = $EntitiesFile
                Tags         = $EffectiveTags
            }
        }

        Set-SessionGraphStale -Reason "Nowa encja '$Name' została utworzona" -ResDir $Config.ResDir
    }

    $ReturnObj = [PSCustomObject]@{
        Name         = $Name
        Type         = $Type
        EntitiesFile = $EntitiesFile
        Tags         = $EffectiveTags
        Created      = $true
    }

    if ($script:HasOpCtx) {
        $OpResult = New-OperationResult -Success $true -Action 'Create' `
            -TargetType $Type -TargetName $Name -UndoHint "Remove-Entity -Name '$Name' -Type '$Type'"
        $ReturnObj | Add-Member -NotePropertyName 'OperationResult' -NotePropertyValue $OpResult
    }

    return $ReturnObj
}

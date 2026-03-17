<#
    .SYNOPSIS
    Soft-deletes an entity by setting @status: Usunięty in entities.md.

    .DESCRIPTION
    This file contains Remove-Entity which marks an entity as soft-deleted
    by writing @status: Usunięty (YYYY-MM:) to its entry in entities.md.

    Processing pipeline:
    1. Resolve config, locate entities file via Invoke-EnsureEntityFile.
    2. Search for entity bullet — scoped to -Type when given, otherwise
       scans all 7 entity type sections sequentially (first match wins).
    3. Write @status: Usunięty tag with (YYYY-MM:) temporal suffix.
    4. Persist via Write-EntityFile, fire AfterWrite plugin hook.
    5. Invalidate session graph cache (entity removal affects graph edges).
    6. Return OperationResult with undo hint pointing to Set-Entity.

    Soft-delete preserves referential integrity: session @Zmiany and @PU
    entries that reference the entity remain valid, and historical queries
    still find it. Entities with status Usunięty are filtered out by
    Get-Entity unless -IncludeDeleted is set.

    ConfirmImpact is High because the operation changes entity visibility
    across all downstream consumers (reports, CLI, PU assignment).

    Helpers (dot-sourced):
    - entity-writehelpers.ps1: Read-EntityFile, Find-EntitySection,
      Find-EntityBullet, Set-EntityTag, Write-EntityFile
    - admin-config.ps1: Get-AdminConfig (entities file path resolution)

    Integration points:
    - Invoke-PluginHook 'AfterWrite': notifies plugins after successful file write
    - Set-SessionGraphStale: invalidates cached session graph
    - New-OperationResult: returns structured result when operation context is active
    - SupportsShouldProcess: -WhatIf/-Confirm support (ConfirmImpact = High)
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Remove-Entity {
    <#
        .SYNOPSIS
        Soft-deletes an entity by setting @status: Usunięty in entities.md.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param(
        [Parameter(Mandatory, HelpMessage = "Entity name to soft-delete")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "Entity type (for disambiguation)")]
        [ValidateSet("NPC", "Grupa", "Lokacja", "Mapa", "Przedmiot")]
        [string]$Type,

        [Parameter(HelpMessage = "Effective date for removal (YYYY-MM). Defaults to current month.")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    # Resolve config and reset operation context for fresh warning collection
    $Config = Get-AdminConfig
    if ($script:HasOpCtx) { Clear-OperationContext }

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    if (-not $ValidFrom) {
        $ValidFrom = (Get-Date).ToString('yyyy-MM')
    }

    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $LinesArray = $File.Lines.ToArray()

    # Search scoped to -Type when given, otherwise scan all 7 sections sequentially
    $FoundBullet = $null
    $FoundType = $null

    if ($Type) {
        $Section = Find-EntitySection -Lines $LinesArray -EntityType $Type
        if ($Section) {
            $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
            if ($Bullet) {
                $FoundBullet = $Bullet
                $FoundType = $Type
            }
        }
    } else {
        $AllTypes = @('NPC', 'Grupa', 'Lokacja', 'Mapa', 'Przedmiot', 'Gracz', 'Postać')
        foreach ($SearchType in $AllTypes) {
            $Section = Find-EntitySection -Lines $LinesArray -EntityType $SearchType
            if (-not $Section) { continue }
            $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
            if ($Bullet) {
                $FoundBullet = $Bullet
                $FoundType = $SearchType
                break
            }
        }
    }

    if (-not $FoundBullet) {
        throw "Entity '$Name' not found in entities.md"
    }

    # Mark entity as deleted — temporal suffix preserves the removal date for auditing
    $Lines = $File.Lines
    $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $FoundBullet.ChildrenStartIdx -ChildrenEnd $FoundBullet.ChildrenEndIdx -TagName 'status' -Value "Usunięty ($ValidFrom`:)"

    if ($PSCmdlet.ShouldProcess($EntitiesFilePath, "Remove-Entity: soft-delete '$Name' (## $FoundType, @status: Usunięty ($ValidFrom`:))")) {
        Write-EntityFile -Path $EntitiesFilePath -Lines $Lines -NL $File.NL

        # Notify plugins after successful write (e.g. API cache invalidation)
        if (Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue) {
            Invoke-PluginHook -Operation 'Remove-Entity' -Phase 'AfterWrite' -Context @{
                Operation  = 'Remove-Entity'
                Name       = $Name
                EntityType = $FoundType
                Path       = $EntitiesFilePath
            }
        }

        # Entity removal changes graph topology — force rebuild on next access
        Set-SessionGraphStale -Reason "Encja '$Name' została usunięta" -ResDir $Config.ResDir

        if ($script:HasOpCtx) {
            return (New-OperationResult -Success $true -Action 'SoftDelete' `
                -TargetType $(if ($FoundType) { $FoundType } else { 'Entity' }) -TargetName $Name `
                -UndoHint "Set-Entity -Name '$Name' -Tags @{status='Aktywny'}")  # reversible via status reset
        }
    }
}

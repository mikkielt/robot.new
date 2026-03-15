<#
    .SYNOPSIS
    Soft-deletes an entity by setting @status: Usunięty in entities.md.

    .DESCRIPTION
    This file contains Remove-Entity which marks an entity as soft-deleted
    by writing @status: Usunięty (YYYY-MM:) to its entry in entities.md.

    Searches all entity type sections for the named entity, or scopes to
    -Type if provided for disambiguation. Does not delete the bullet or
    any files — only sets the status tag. This preserves referential
    integrity: session @Zmiany and @PU entries that reference the entity
    remain valid, and historical queries still find it.

    Entities with status Usunięty are filtered out by Get-Entity unless
    -IncludeDeleted is set.

    ConfirmImpact is High because the operation changes entity visibility
    across all downstream consumers (reports, CLI, PU assignment).

    Dot-sources entity-writehelpers.ps1 (file I/O and tag manipulation)
    and admin-config.ps1 (entities file path resolution).
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

    # Search scoped to -Type when given, otherwise scan all sections sequentially
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

    $Lines = $File.Lines
    $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $FoundBullet.ChildrenStartIdx -ChildrenEnd $FoundBullet.ChildrenEndIdx -TagName 'status' -Value "Usunięty ($ValidFrom`:)"

    if ($PSCmdlet.ShouldProcess($EntitiesFilePath, "Remove-Entity: soft-delete '$Name' (## $FoundType, @status: Usunięty ($ValidFrom`:))")) {
        Write-EntityFile -Path $EntitiesFilePath -Lines $Lines -NL $File.NL

        Set-SessionGraphStale -Reason "Encja '$Name' została usunięta" -ResDir $Config.ResDir

        if ($script:HasOpCtx) {
            return (New-OperationResult -Success $true -Action 'SoftDelete' `
                -TargetType $(if ($FoundType) { $FoundType } else { 'Entity' }) -TargetName $Name `
                -UndoHint "Set-Entity -Name '$Name' -Tags @{status='Aktywny'}")
        }
    }
}

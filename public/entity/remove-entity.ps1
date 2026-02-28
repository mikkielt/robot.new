<#
    .SYNOPSIS
    Soft-deletes an entity by setting @status: Usunięty in entities.md.

    .DESCRIPTION
    This file contains Remove-Entity which marks an entity as soft-deleted
    by writing @status: Usunięty (YYYY-MM:) to its entry in entities.md.

    Searches all entity type sections for the named entity, or scopes to
    -Type if provided for disambiguation. Does not delete the bullet or
    any files — only sets the status tag.

    Entities with status Usunięty are filtered out by Get-Entity unless
    -IncludeDeleted is set.

    ConfirmImpact is High for safety.
    Dot-sources entity-writehelpers.ps1 and admin-config.ps1.
#>

# Dot-source helpers
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
        [ValidateSet("NPC", "Organizacja", "Lokacja", "Przedmiot")]
        [string]$Type,

        [Parameter(HelpMessage = "Effective date for removal (YYYY-MM). Defaults to current month.")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    $Config = Get-AdminConfig

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    if (-not $ValidFrom) {
        $ValidFrom = (Get-Date).ToString('yyyy-MM')
    }

    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $LinesArray = $File.Lines.ToArray()

    # Find the entity
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
        $AllTypes = @('NPC', 'Organizacja', 'Lokacja', 'Przedmiot', 'Gracz', 'Postać')
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
    }
}

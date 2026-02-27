<#
    .SYNOPSIS
    Soft-deletes a character by setting @status: Usunięty in entities.md.

    .DESCRIPTION
    This file contains Remove-PlayerCharacter which marks a character as
    soft-deleted by writing @status: Usunięty (YYYY-MM:) to the character's
    entity entry in entities.md under ## Postać (Gracz).

    Does not delete the character file or remove the entity entry.
    Characters with status Usunięty are filtered out by
    Get-PlayerCharacter -IncludeState unless -IncludeDeleted is set.

    ConfirmImpact is High for safety.
    Dot-sources entity-writehelpers.ps1.
#>

# Dot-source helpers
. "$PSScriptRoot/entity-writehelpers.ps1"

function Remove-PlayerCharacter {
    <#
        .SYNOPSIS
        Soft-deletes a character by setting @status: Usunięty in entities.md.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param(
        [Parameter(Mandatory, HelpMessage = "Player name who owns the character")]
        [string]$PlayerName,

        [Parameter(Mandatory, HelpMessage = "Character name to soft-delete")]
        [string]$CharacterName,

        [Parameter(HelpMessage = "Validity start (YYYY-MM). Defaults to current month.")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    if (-not $EntitiesFile) {
        $EntitiesFile = [System.IO.Path]::Combine($PSScriptRoot, 'entities.md')
    }

    if (-not $ValidFrom) {
        $ValidFrom = (Get-Date).ToString('yyyy-MM')
    }

    # Resolve entity target (creates entry if missing, with @należy_do)
    $InitialTags = [ordered]@{
        'należy_do' = $PlayerName
    }

    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Postać (Gracz)' -EntityName $CharacterName -InitialTags $InitialTags
    $Lines = $Target.Lines

    $ChildEnd = $Target.ChildrenEnd
    $ChildEnd = Set-EntityTag -Lines $Lines -BulletIdx $Target.BulletIdx -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'status' -Value "Usunięty ($ValidFrom`:)"

    if ($PSCmdlet.ShouldProcess($Target.FilePath, "Remove-PlayerCharacter: soft-delete '$CharacterName' (owner: $PlayerName, @status: Usunięty ($ValidFrom`:))")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Lines -NL $Target.NL
    }
}

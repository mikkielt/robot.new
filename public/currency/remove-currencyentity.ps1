<#
    .SYNOPSIS
    Soft-deletes a currency entity by setting @status: Usunięty.

    .DESCRIPTION
    This file contains Remove-CurrencyEntity which marks a currency
    Przedmiot entity as soft-deleted by writing @status: Usunięty (YYYY-MM:).

    Warns if the entity has a non-zero balance (potential data loss).
    Does not delete the bullet or any files.

    ConfirmImpact is High for safety.
    Dot-sources entity-writehelpers.ps1 and admin-config.ps1.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Remove-CurrencyEntity {
    <#
        .SYNOPSIS
        Soft-deletes a currency entity by setting @status: Usunięty.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param(
        [Parameter(Mandatory, HelpMessage = "Currency entity name (e.g. 'Korony Erdamon')")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "Effective date (YYYY-MM). Defaults to current month.")]
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

    # Find the entity
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $LinesArray = $File.Lines.ToArray()

    $Section = Find-EntitySection -Lines $LinesArray -EntityType 'Przedmiot'
    if (-not $Section) {
        throw "Currency entity '$Name' not found — no ## Przedmiot section in entities.md"
    }

    $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
    if (-not $Bullet) {
        throw "Currency entity '$Name' not found under ## Przedmiot in entities.md"
    }

    # Check for non-zero balance and warn
    $BalanceTag = Find-EntityTag -Lines $LinesArray -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'ilość'
    if ($BalanceTag) {
        $QtyText = $BalanceTag.Value
        $ParenIdx = $QtyText.IndexOf('(')
        if ($ParenIdx -gt 0) { $QtyText = $QtyText.Substring(0, $ParenIdx).Trim() }
        [int]$Qty = 0
        if ([int]::TryParse($QtyText, [ref]$Qty) -and $Qty -ne 0) {
            [System.Console]::Error.WriteLine("[WARN Remove-CurrencyEntity] Entity '$Name' has non-zero balance ($Qty). Soft-deleting anyway.")
        }
    }

    $Lines = $File.Lines
    $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'status' -Value "Usunięty ($ValidFrom`:)"

    if ($PSCmdlet.ShouldProcess($EntitiesFilePath, "Remove-CurrencyEntity: soft-delete '$Name' (@status: Usunięty ($ValidFrom`:))")) {
        Write-EntityFile -Path $EntitiesFilePath -Lines $Lines -NL $File.NL
    }
}

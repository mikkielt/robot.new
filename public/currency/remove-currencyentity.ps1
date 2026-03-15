<#
    .SYNOPSIS
    Soft-deletes a currency entity by setting @status: Usunięty.

    .DESCRIPTION
    This file contains Remove-CurrencyEntity which marks a currency
    Przedmiot entity as soft-deleted by writing @status: Usunięty (YYYY-MM:).

    The entity bullet is never physically removed — soft-delete preserves
    transaction history for audit and currency reconciliation. Warns if the
    entity has a non-zero balance (potential data loss from orphaned funds).

    ConfirmImpact is High because deletion affects currency reconciliation
    reports. Supports -Quiet to suppress the non-zero balance warning.

    Dot-sources entity-writehelpers.ps1 (Read-EntityFile, Find-EntitySection,
    Find-EntityBullet, Find-EntityTag, Set-EntityTag, Write-EntityFile)
    and admin-config.ps1 (Get-AdminConfig).
#>

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
        [string]$EntitiesFile,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-AdminConfig
    if ($script:HasOpCtx) { Clear-OperationContext }

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    if (-not $ValidFrom) {
        $ValidFrom = (Get-Date).ToString('yyyy-MM')
    }

    # Locate entity bullet under ## Przedmiot
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $LinesArray = $File.Lines.ToArray()

    $Section = Find-EntitySection -Lines $LinesArray -EntityType 'Przedmiot'
    if (-not $Section) {
        throw "Currency entity '$Name' not found - no ## Przedmiot section in entities.md"
    }

    $Bullet = Find-EntityBullet -Lines $LinesArray -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
    if (-not $Bullet) {
        throw "Currency entity '$Name' not found under ## Przedmiot in entities.md"
    }

    # Non-zero balance warning — soft-deleting orphans funds from reconciliation
    $BalanceTag = Find-EntityTag -Lines $LinesArray -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'ilość'
    if ($BalanceTag) {
        $QtyText = $BalanceTag.Value
        $ParenIdx = $QtyText.IndexOf('(')
        if ($ParenIdx -gt 0) { $QtyText = $QtyText.Substring(0, $ParenIdx).Trim() }
        [int]$Qty = 0
        if ([int]::TryParse($QtyText, [ref]$Qty) -and $Qty -ne 0) {
            Write-RobotWarning "[WARN Remove-CurrencyEntity] Entity '$Name' has non-zero balance ($Qty). Soft-deleting anyway."
        }
    }

    $Lines = $File.Lines
    $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'status' -Value "Usunięty ($ValidFrom`:)"

    if ($PSCmdlet.ShouldProcess($EntitiesFilePath, "Remove-CurrencyEntity: soft-delete '$Name' (@status: Usunięty ($ValidFrom`:))")) {
        Write-EntityFile -Path $EntitiesFilePath -Lines $Lines -NL $File.NL

        if ($script:HasOpCtx) {
            return (New-OperationResult -Success $true -Action 'SoftDelete' `
                -TargetType 'Przedmiot' -TargetName $Name `
                -UndoHint "Set-Entity -Name '$Name' -Tags @{status='Aktywny'}")
        }
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

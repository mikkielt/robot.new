<#
    .SYNOPSIS
    Updates a currency entity's quantity, owner, or location.

    .DESCRIPTION
    This file contains Set-CurrencyEntity which modifies tags on a currency
    Przedmiot entity. Supports absolute quantity, delta quantity (+N/-N),
    owner transfer, and location assignment.

    Owner and Location are mutually exclusive (per CURRENCY.md §4.2).
    Delta arithmetic reads current @ilość, computes new value, writes absolute.

    Dot-sources entity-writehelpers.ps1, admin-config.ps1, and currency-helpers.ps1.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"
. "$script:ModuleRoot/private/currency-helpers.ps1"

function Set-CurrencyEntity {
    <#
        .SYNOPSIS
        Updates a currency entity's quantity, owner, or location.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Currency entity name (e.g. 'Korony Erdamon')")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(HelpMessage = "New quantity (absolute)")]
        [Nullable[int]]$Amount,

        [Parameter(HelpMessage = "Quantity delta (positive or negative integer)")]
        [Nullable[int]]$AmountDelta,

        [Parameter(HelpMessage = "New owner entity name")]
        [string]$Owner,

        [Parameter(HelpMessage = "New location (for dropped/stored currency)")]
        [string]$Location,

        [Parameter(HelpMessage = "Effective date (YYYY-MM). Defaults to current month.")]
        [string]$ValidFrom,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    # Validate mutual exclusions
    if ($null -ne $Amount -and $null -ne $AmountDelta) {
        throw "Cannot specify both -Amount and -AmountDelta. Use one or the other."
    }

    if (-not [string]::IsNullOrWhiteSpace($Owner) -and -not [string]::IsNullOrWhiteSpace($Location)) {
        throw "Cannot specify both -Owner and -Location. Currency is either owned or placed at a location."
    }

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

    $Lines = $File.Lines
    $ChildEnd = $Bullet.ChildrenEndIdx
    $ChildStart = $Bullet.ChildrenStartIdx

    # Handle delta arithmetic
    if ($null -ne $AmountDelta) {
        # Read current @ilość
        $CurrentTag = Find-EntityTag -Lines $LinesArray -ChildrenStart $ChildStart -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'ilość'
        [int]$CurrentQty = 0
        if ($CurrentTag) {
            $QtyText = $CurrentTag.Value
            # Strip temporal suffix: "50 (2025-01:)" -> "50"
            $ParenIdx = $QtyText.IndexOf('(')
            if ($ParenIdx -gt 0) { $QtyText = $QtyText.Substring(0, $ParenIdx).Trim() }
            [void][int]::TryParse($QtyText, [ref]$CurrentQty)
        }
        $Amount = $CurrentQty + $AmountDelta
    }

    # Apply tags
    if ($null -ne $Amount) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $ChildStart -ChildrenEnd $ChildEnd -TagName 'ilość' -Value "$Amount ($ValidFrom`:)"
    }

    if (-not [string]::IsNullOrWhiteSpace($Owner)) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $ChildStart -ChildrenEnd $ChildEnd -TagName 'należy_do' -Value "$Owner ($ValidFrom`:)"
    }

    if (-not [string]::IsNullOrWhiteSpace($Location)) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $ChildStart -ChildrenEnd $ChildEnd -TagName 'lokacja' -Value "$Location ($ValidFrom`:)"
    }

    if ($PSCmdlet.ShouldProcess($EntitiesFilePath, "Set-CurrencyEntity: update '$Name'")) {
        Write-EntityFile -Path $EntitiesFilePath -Lines $Lines -NL $File.NL
    }
}

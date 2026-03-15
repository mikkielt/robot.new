<#
    .SYNOPSIS
    Creates a new currency Przedmiot entity in entities.md.

    .DESCRIPTION
    This file contains New-CurrencyEntity which creates a currency entity
    under ## Przedmiot with validated denomination, auto-generated entity name,
    and standard currency tags (@generyczne_nazwy, @ilość, @należy_do, @status).

    Processing pipeline:
    1. Resolves denomination stem via Resolve-CurrencyDenomination (throws on unknown)
    2. Auto-generates entity name: "{DenomShort} {Owner}" (e.g. "Korony Erdamon")
    3. Checks for duplicate entity bullet under ## Przedmiot (throws if exists)
    4. Renders currency-entity.md.template with denomination/owner/amount/date variables
    5. Resolves target file and insertion point via Resolve-EntityTarget
    6. Writes entity file via Write-EntityFile (guarded by ShouldProcess)

    Dot-sources entity-writehelpers.ps1 (Read-EntityFile, Find-EntitySection,
    Find-EntityBullet, Resolve-EntityTarget, Write-EntityFile),
    admin-config.ps1 (Get-AdminConfig, Get-AdminTemplate), and
    currency-helpers.ps1 (Resolve-CurrencyDenomination).

    Supports -WhatIf via SupportsShouldProcess. When $script:HasOpCtx is true,
    returns an OperationResult for auditing.
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"
. "$script:ModuleRoot/private/currency-helpers.ps1"

function New-CurrencyEntity {
    <#
        .SYNOPSIS
        Creates a new currency Przedmiot entity in entities.md.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Denomination name or stem (e.g. 'Korony', 'tal', 'Kogi Skeltvorskie')")]
        [string]$Denomination,

        [Parameter(Mandatory, HelpMessage = "Owner entity name")]
        [string]$Owner,

        [Parameter(HelpMessage = "Initial quantity")]
        [int]$Amount = 0,

        [Parameter(HelpMessage = "Effective date (YYYY-MM). Defaults to current month.")]
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

    # Resolve stem to canonical denomination (e.g. "tal" -> Talary)
    $ResolvedDenom = Resolve-CurrencyDenomination -Name $Denomination
    if (-not $ResolvedDenom) {
        throw "Unknown currency denomination: '$Denomination'. Use Korony/Talary/Kogi or a recognized stem."
    }

    # Convention: currency entity name = "{DenomShort} {Owner}"
    $EntityName = "$($ResolvedDenom.Short) $Owner"

    # Fail-early duplicate detection against raw entity file
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType 'Przedmiot'
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $EntityName
        if ($ExistingBullet) {
            throw "Currency entity '$EntityName' already exists under ## Przedmiot in entities.md"
        }
    }

    # Render template with denomination/owner/amount variables
    $TemplateVars = @{
        EntityName            = $EntityName
        CanonicalDenomination = $ResolvedDenom.Name
        Owner                 = $Owner
        Amount                = $Amount.ToString()
        ValidFrom             = $ValidFrom
    }
    $RenderedEntry = Get-AdminTemplate -Name 'currency-entity.md.template' -Variables $TemplateVars
    $Parsed = ConvertFrom-EntityTemplate -Content $RenderedEntry
    $InitialTags = $Parsed.Tags

    # Resolve insertion point under ## Przedmiot section
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Przedmiot' -EntityName $EntityName -InitialTags $InitialTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-CurrencyEntity: create '$EntityName' ($($ResolvedDenom.Name), owner: $Owner, amount: $Amount)")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL
    }

    $ReturnObj = [PSCustomObject]@{
        EntityName   = $EntityName
        Denomination = $ResolvedDenom.Name
        DenomShort   = $ResolvedDenom.Short
        Owner        = $Owner
        Amount       = $Amount
        EntitiesFile = $EntitiesFile
    }

    if ($script:HasOpCtx) {
        $OpResult = New-OperationResult -Success $true -Action 'Create' `
            -TargetType 'Przedmiot' -TargetName $EntityName `
            -UndoHint "Remove-CurrencyEntity -Name '$EntityName'"
        $ReturnObj | Add-Member -NotePropertyName 'OperationResult' -NotePropertyValue $OpResult
    }

    return $ReturnObj
}

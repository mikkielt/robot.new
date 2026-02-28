<#
    .SYNOPSIS
    Creates a new currency Przedmiot entity in entities.md.

    .DESCRIPTION
    This file contains New-CurrencyEntity which creates a currency entity
    under ## Przedmiot with validated denomination, auto-generated entity name,
    and standard currency tags (@generyczne_nazwy, @ilość, @należy_do, @status).

    Uses the currency-entity.md.template for initial structure.
    Validates denomination via Resolve-CurrencyDenomination.
    Auto-generates entity name: "{DenomShort} {Owner}" (e.g. "Korony Erdamon").

    Dot-sources entity-writehelpers.ps1, admin-config.ps1, and currency-helpers.ps1.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
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

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    if (-not $ValidFrom) {
        $ValidFrom = (Get-Date).ToString('yyyy-MM')
    }

    # Validate denomination
    $ResolvedDenom = Resolve-CurrencyDenomination -Name $Denomination
    if (-not $ResolvedDenom) {
        throw "Unknown currency denomination: '$Denomination'. Use Korony/Talary/Kogi or a recognized stem."
    }

    # Auto-generate entity name
    $EntityName = "$($ResolvedDenom.Short) $Owner"

    # Duplicate detection via raw entity file search
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType 'Przedmiot'
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $EntityName
        if ($ExistingBullet) {
            throw "Currency entity '$EntityName' already exists under ## Przedmiot in entities.md"
        }
    }

    # Build tags from template
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

    # Create entity under ## Przedmiot
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Przedmiot' -EntityName $EntityName -InitialTags $InitialTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-CurrencyEntity: create '$EntityName' ($($ResolvedDenom.Name), owner: $Owner, amount: $Amount)")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Target.Lines -NL $Target.NL
    }

    return [PSCustomObject]@{
        EntityName   = $EntityName
        Denomination = $ResolvedDenom.Name
        DenomShort   = $ResolvedDenom.Short
        Owner        = $Owner
        Amount       = $Amount
        EntitiesFile = $EntitiesFile
    }
}

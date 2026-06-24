<#
    .SYNOPSIS
    Lists discoverable migrations and their applied status.

    .DESCRIPTION
    Surfaces Get-MigrationCatalog output as a clean PSCustomObject projection
    with optional filtering. Migrations whose manifest fails validation are
    hidden unless -IncludeInvalid is passed.
#>

function Get-Migration {
    <#
        .SYNOPSIS
        Returns metadata for discoverable migrations.

        .PARAMETER Version
        Filter to a specific effective version (e.g. '21.3.7' or '21.3.7+foo.1').

        .PARAMETER Pending
        Return only migrations strictly above the current schema version.

        .PARAMETER IncludeInvalid
        Include migrations whose manifest failed validation.

        .PARAMETER RepoRoot
        Override repo root for catalog discovery.
    #>
    [CmdletBinding()]
    param(
        [string]$Version,
        [switch]$Pending,
        [switch]$IncludeInvalid,
        [string]$RepoRoot
    )

    $Catalog = Get-MigrationCatalog -RepoRoot $RepoRoot

    if (-not $IncludeInvalid) {
        $Catalog = @($Catalog | Where-Object { $_.Validation.OK })
    }

    if ($Pending) {
        $Schema = Get-SchemaVersion -RepoRoot $RepoRoot
        $Current = $Schema.Current
        $Catalog = @($Catalog | Where-Object {
            $_.Version -and (Compare-SchemaVersion $_.Version $Current) -gt 0
        })
    }

    if ($Version) {
        $Catalog = @($Catalog | Where-Object { $_.Version -eq $Version })
    }

    return $Catalog | ForEach-Object {
        [PSCustomObject]@{
            Id                   = $_.Id
            Version              = $_.Version
            MajorName            = $_.MajorName
            Slug                 = $_.Slug
            Description          = $_.Description
            Requires             = $_.Requires
            Author               = $_.Author
            AffectsCategories    = $_.AffectsCategories
            EstimatedDurationSec = $_.EstimatedDurationSec
            OnlyIfSourceChanged  = $_.OnlyIfSourceChanged
            RequiresNetwork      = $_.RequiresNetwork
            Origin               = $_.Origin
            PluginName           = $_.PluginName
            Path                 = $_.Path
            ValidationOK         = $_.Validation.OK
            ValidationErrors     = $_.Validation.Errors
            ValidationWarnings   = $_.Validation.Warnings
        }
    }
}

<#
    .SYNOPSIS
    ChangeRecord factory and shape validator for migration previews (CC-N9).

    .DESCRIPTION
    Non-exported helpers consumed by migration migrate.ps1 files (each emits
    ChangeRecord[] from Get-MigrationPreview) and by the REST preview handler
    (which caches OverrideKeys for Apply-time validation).

    Helpers:
    - New-MigrationChangeRecord:  factory that fills defaults and validates
                                  ChangeKind / ObjectType enum values.
    - Test-MigrationChangeRecord: shape validator returning OK + Errors[].
    - Test-MigrationChangeRecordSet: collection validator — flags duplicate
                                     OverrideKeys.

    Module-level data:
    - $script:ChangeRecordKinds   = Create | Modify | Delete | Rename
    - $script:ChangeRecordTypes   = EntityBullet | EntityFile | Session |
                                    Charfile | StateFile | FilePath
    - $script:ChangeRecordSchema  = property-name → required-flag map; the
                                    full shape declared in CC-N9.

    Design:
    - The factory normalises absent fields to $null rather than throwing,
      so simple Transform migrations can call New-MigrationChangeRecord with
      only the mandatory params.
    - Validation is structural only (types + enum values + filepath shape) —
      it does NOT verify that Before/After differ; a no-op ChangeRecord is
      legitimate (it documents that the operator's earlier override is being
      applied unchanged).
    - OverrideKey uniqueness is enforced at the SET level, not the single-
      record level, because the same record can legitimately be re-emitted
      across preview calls (idempotency).

    Dependencies: none (pure data structures).
#>

$script:ChangeRecordKinds = @('Create', 'Modify', 'Delete', 'Rename')
$script:ChangeRecordTypes = @(
    'EntityBullet', 'EntityFile', 'Session', 'Charfile', 'StateFile', 'FilePath'
)

function New-MigrationChangeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$ObjectType,
        [Parameter(Mandatory)] [string]$ChangeKind,
        [Parameter(Mandatory)] [string]$FilePath,
        [string]$NewFilePath,
        [object]$Before,
        [object]$After,
        [string]$OverrideKey,
        [string[]]$Notes
    )

    if ($ObjectType -notin $script:ChangeRecordTypes) {
        $Ex = [System.InvalidOperationException]::new(
            "ChangeRecord ObjectType '$ObjectType' is not one of: $($script:ChangeRecordTypes -join ', ').")
        throw $Ex
    }
    if ($ChangeKind -notin $script:ChangeRecordKinds) {
        $Ex = [System.InvalidOperationException]::new(
            "ChangeRecord ChangeKind '$ChangeKind' is not one of: $($script:ChangeRecordKinds -join ', ').")
        throw $Ex
    }
    if ([string]::Equals($ChangeKind, 'Rename', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::IsNullOrWhiteSpace($NewFilePath)) {
        $Ex = [System.InvalidOperationException]::new(
            "ChangeRecord with ChangeKind 'Rename' requires NewFilePath.")
        throw $Ex
    }

    return [PSCustomObject]@{
        PSTypeName  = 'Robot.MigrationChangeRecord'
        Id          = $Id
        ObjectType  = $ObjectType
        FilePath    = $FilePath
        NewFilePath = if ([string]::IsNullOrWhiteSpace($NewFilePath)) { $null } else { $NewFilePath }
        ChangeKind  = $ChangeKind
        Before      = $Before
        After       = $After
        OverrideKey = if ([string]::IsNullOrWhiteSpace($OverrideKey)) { $null } else { $OverrideKey }
        Notes       = if ($Notes) { @($Notes) } else { @() }
    }
}

function Test-MigrationChangeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Record
    )

    $Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($Required in @('Id', 'ObjectType', 'FilePath', 'ChangeKind')) {
        $Value = $null
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains($Required)) { $Value = $Record[$Required] }
        } else {
            $Property = $Record.PSObject.Properties[$Required]
            if ($Property) { $Value = $Property.Value }
        }
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            [void]$Errors.Add("ChangeRecord missing required field '$Required'.")
        }
    }

    $Kind = if ($Record -is [System.Collections.IDictionary]) { $Record['ChangeKind'] } else { $Record.ChangeKind }
    if ($Kind -and $Kind -notin $script:ChangeRecordKinds) {
        [void]$Errors.Add("ChangeKind '$Kind' is not one of: $($script:ChangeRecordKinds -join ', ').")
    }
    $Type = if ($Record -is [System.Collections.IDictionary]) { $Record['ObjectType'] } else { $Record.ObjectType }
    if ($Type -and $Type -notin $script:ChangeRecordTypes) {
        [void]$Errors.Add("ObjectType '$Type' is not one of: $($script:ChangeRecordTypes -join ', ').")
    }
    if ([string]::Equals([string]$Kind, 'Rename', [System.StringComparison]::OrdinalIgnoreCase)) {
        $NewPath = if ($Record -is [System.Collections.IDictionary]) { $Record['NewFilePath'] } else { $Record.NewFilePath }
        if ([string]::IsNullOrWhiteSpace([string]$NewPath)) {
            [void]$Errors.Add("Rename ChangeRecord requires NewFilePath.")
        }
    }

    return [PSCustomObject]@{
        OK     = ($Errors.Count -eq 0)
        Errors = @($Errors)
    }
}

function Test-MigrationChangeRecordSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Records
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $OverrideKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Record in $Records) {
        $Single = Test-MigrationChangeRecord -Record $Record
        if (-not $Single.OK) {
            foreach ($E in $Single.Errors) { [void]$Errors.Add($E) }
            continue
        }
        $Id = if ($Record -is [System.Collections.IDictionary]) { $Record['Id'] } else { $Record.Id }
        if (-not $Ids.Add([string]$Id)) {
            [void]$Errors.Add("Duplicate ChangeRecord Id '$Id'.")
        }
        $Key = if ($Record -is [System.Collections.IDictionary]) { $Record['OverrideKey'] } else { $Record.OverrideKey }
        if (-not [string]::IsNullOrWhiteSpace([string]$Key)) {
            if (-not $OverrideKeys.Add([string]$Key)) {
                [void]$Errors.Add("Duplicate OverrideKey '$Key'.")
            }
        }
    }

    return [PSCustomObject]@{
        OK     = ($Errors.Count -eq 0)
        Errors = @($Errors)
    }
}

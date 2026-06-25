<#
    .SYNOPSIS
    ConfigSchema parser, defaults merger, and validator for migration manifests.

    .DESCRIPTION
    Non-exported helpers consumed by public/migration/get-migrationconfigschema.ps1
    and the migration runtime (private/migration/migration-runtime.ps1). Loaded
    once at module-init via the CC-1 dot-source block in Robot.PowerShell.psm1.

    Helpers:
    - Resolve-MigrationConfigSchema: returns the ConfigSchema hashtable for a
      catalog entry, normalising omitted fields (Type defaults to 'String',
      Required defaults to $false, Description defaults to '').
    - Merge-MigrationConfigDefaults: returns a new hashtable that merges
      operator-supplied Config over the schema's declared defaults.
    - Test-MigrationConfig: validates a (already-merged) Config hashtable
      against the schema. Returns @{ OK; Errors[]; Warnings[] }.
    - ConvertFromMigrationConfigValue: coerces a string/JSON-decoded value to
      the schema-declared Type. Used by the REST layer when a query string
      delivers strings for Switch/Int/Decimal fields.

    Module-level data:
    - $script:MigrationConfigTypes: the closed type enum.

    Design:
    - Schema-driven validation lets the framework reject malformed apply payloads
      before the migration body runs, replacing the prior "Polish-prompt at runtime"
      flow. The REST surface in WP-A4 calls Test-MigrationConfig after merging
      defaults; failures become 400 responses with a structured error list.
    - Unknown fields are an error (not a warning) — the form is the contract;
      operators cannot smuggle extra fields the migration body would silently
      ignore.

    Dependencies: none (pure value-validation; no I/O).
#>

$script:MigrationConfigTypes = @(
    'Switch', 'String', 'Int', 'Decimal', 'Hashtable', 'Array'
)

function Resolve-MigrationConfigSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Manifest
    )

    $Raw = $Manifest['ConfigSchema']
    if ($null -eq $Raw) { return @{} }
    if ($Raw -isnot [hashtable]) {
        $Ex = [System.InvalidOperationException]::new(
            "Manifest field 'ConfigSchema' must be a hashtable; got [$($Raw.GetType().FullName)].")
        $ErrRec = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'MigrationConfigSchemaInvalid',
            [System.Management.Automation.ErrorCategory]::InvalidData, $Raw)
        throw $ErrRec
    }

    $Normalized = [ordered]@{}
    foreach ($Key in $Raw.Keys) {
        $Field = $Raw[$Key]
        if ($Field -isnot [hashtable]) {
            $Ex = [System.InvalidOperationException]::new(
                "ConfigSchema field '$Key' must be a hashtable with Type / Default / Description / Required.")
            $ErrRec = [System.Management.Automation.ErrorRecord]::new(
                $Ex, 'MigrationConfigSchemaFieldInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidData, $Field)
            throw $ErrRec
        }
        $Type = if ($Field.ContainsKey('Type')) { [string]$Field['Type'] } else { 'String' }
        if ($Type -notin $script:MigrationConfigTypes) {
            $Ex = [System.InvalidOperationException]::new(
                "ConfigSchema field '$Key' declares unsupported Type '$Type'. " +
                "Valid: $($script:MigrationConfigTypes -join ', ').")
            $ErrRec = [System.Management.Automation.ErrorRecord]::new(
                $Ex, 'MigrationConfigSchemaTypeInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidData, $Type)
            throw $ErrRec
        }
        $Default = if ($Field.ContainsKey('Default')) { $Field['Default'] } else { $null }
        $Required = if ($Field.ContainsKey('Required')) { [bool]$Field['Required'] } else { $false }
        $Description = if ($Field.ContainsKey('Description')) { [string]$Field['Description'] } else { '' }
        $Normalized[$Key] = @{
            Type        = $Type
            Default     = $Default
            Required    = $Required
            Description = $Description
        }
    }
    return $Normalized
}

function Merge-MigrationConfigDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Schema,
        [hashtable]$Supplied
    )

    # $Schema is an [ordered] hashtable returned by Resolve-MigrationConfigSchema.
    # The merge fills missing keys with declared defaults; supplied wins over default.
    $Merged = @{}
    foreach ($Key in $Schema.Keys) {
        if ($Supplied -and $Supplied.ContainsKey($Key)) {
            $Merged[$Key] = $Supplied[$Key]
        } else {
            $Merged[$Key] = $Schema[$Key]['Default']
        }
    }
    return $Merged
}

function ConvertFromMigrationConfigValue {
    <#
        Coerces a raw value (typically from query-string or JSON-decoded body)
        into the schema-declared type. Used by the REST layer; PowerShell callers
        usually pass typed values already.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Type,
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    switch ($Type) {
        'Switch' {
            if ($Value -is [bool]) { return $Value }
            $S = [string]$Value
            if ([string]::Equals($S, 'true',  [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ([string]::Equals($S, 'false', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            if ([string]::Equals($S, '1',     [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ([string]::Equals($S, '0',     [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            $Ex = [System.InvalidOperationException]::new(
                "Cannot coerce '$Value' to Switch (expected: true/false/1/0).")
            throw $Ex
        }
        'String' { return [string]$Value }
        'Int' {
            $Parsed = 0
            if ([int]::TryParse([string]$Value, [ref]$Parsed)) { return $Parsed }
            $Ex = [System.InvalidOperationException]::new(
                "Cannot coerce '$Value' to Int.")
            throw $Ex
        }
        'Decimal' {
            $Parsed = [decimal]0
            $Style  = [System.Globalization.NumberStyles]::Float
            $Culture = [System.Globalization.CultureInfo]::InvariantCulture
            if ([decimal]::TryParse([string]$Value, $Style, $Culture, [ref]$Parsed)) { return $Parsed }
            $Ex = [System.InvalidOperationException]::new(
                "Cannot coerce '$Value' to Decimal.")
            throw $Ex
        }
        'Hashtable' {
            if ($Value -is [hashtable]) { return $Value }
            if ($Value -is [System.Collections.IDictionary]) {
                $H = @{}
                foreach ($K in $Value.Keys) { $H[$K] = $Value[$K] }
                return $H
            }
            $Ex = [System.InvalidOperationException]::new(
                "Cannot coerce value of type [$($Value.GetType().FullName)] to Hashtable.")
            throw $Ex
        }
        'Array' {
            if ($Value -is [System.Array]) { return $Value }
            if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
                $List = [System.Collections.Generic.List[object]]::new()
                foreach ($Item in $Value) { [void]$List.Add($Item) }
                return $List.ToArray()
            }
            return @($Value)
        }
    }
    return $Value
}

function Test-MigrationConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Schema,
        [hashtable]$Config
    )

    $Errors   = [System.Collections.Generic.List[string]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()

    $Effective = if ($Config) { $Config } else { @{} }

    # Required-field enforcement.
    foreach ($Key in $Schema.Keys) {
        $Field = $Schema[$Key]
        if ($Field['Required'] -and (-not $Effective.ContainsKey($Key) -or $null -eq $Effective[$Key])) {
            [void]$Errors.Add("ConfigSchema field '$Key' is Required but missing from supplied Config.")
        }
    }

    # Type-shape checks on supplied values. Strict on unknown keys per the
    # "form is the contract" rule.
    foreach ($Key in $Effective.Keys) {
        if (-not $Schema.Contains($Key)) {
            [void]$Errors.Add("ConfigSchema does not declare field '$Key'.")
            continue
        }
        $Type = $Schema[$Key]['Type']
        $Val  = $Effective[$Key]
        if ($null -eq $Val) { continue }
        $Ok = switch ($Type) {
            'Switch'    { $Val -is [bool] }
            'String'    { $Val -is [string] }
            'Int'       { $Val -is [int] -or $Val -is [long] }
            'Decimal'   { $Val -is [decimal] -or $Val -is [double] -or $Val -is [int] -or $Val -is [long] }
            'Hashtable' { $Val -is [hashtable] -or $Val -is [System.Collections.IDictionary] }
            'Array'     { $Val -is [System.Array] -or ($Val -is [System.Collections.IEnumerable] -and $Val -isnot [string]) }
            default     { $true }
        }
        if (-not $Ok) {
            [void]$Errors.Add("ConfigSchema field '$Key' declares Type '$Type' but supplied value is [$($Val.GetType().FullName)].")
        }
    }

    return [PSCustomObject]@{
        OK       = ($Errors.Count -eq 0)
        Errors   = @($Errors)
        Warnings = @($Warnings)
    }
}

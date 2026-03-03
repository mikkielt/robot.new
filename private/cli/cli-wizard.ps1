<#
    .SYNOPSIS
    Wizard auto-generation system for the Robot CLI - step type resolution
    and wizard orchestration.

    .DESCRIPTION
    This file contains the wizard pipeline that auto-generates interactive
    step-through wizards from function [Parameter] metadata. Dot-sourced
    on demand (not at module import).

    Functions in this file:
    - Resolve-StepType:    parameter metadata → wizard step type resolution
    - Invoke-Wizard:       full wizard orchestration from registry entry

    Chain-loaded companion files (dot-sourced below):
    - cli-wizard-steps.ps1:   Invoke-WizardStep (individual step executor)
    - cli-wizard-preview.ps1: Show-Preview (-WhatIf display + confirmation + execution)

    Module-level data:
    - $script:CommonParams: framework parameter names to skip in wizard auto-gen

    Design:
    - No wizard has custom rendering - all go through the same auto-gen pipeline.
    - 10 step types: text, number, decimal, date, selection, yesno, multitext,
      fuzzy, multi-entry, multi-entry-nested.
    - Override format allows registry entries to customize step behavior.
    - Back-navigation preserves previously entered values.
#>

# Framework parameters to skip in wizard auto-generation
$script:CommonParams = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction',
        'ErrorVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable',
        'WarningAction', 'WarningVariable', 'InformationAction',
        'InformationVariable', 'ProgressAction'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

# Chain-load companion files
. "$PSScriptRoot/cli-wizard-steps.ps1"
. "$PSScriptRoot/cli-wizard-preview.ps1"

# ── Resolve-StepType ─────────────────────────────────────────────────────────

function Resolve-StepType {
    param(
        [Parameter(Mandatory)] [object]$ParamInfo,
        [hashtable]$Override
    )

    $Name = $ParamInfo.Name
    $Type = $ParamInfo.ParameterType
    $IsMandatory = $false
    $HelpMsg = $Name
    $ValidateSetValues = $null

    # Extract from parameter attributes
    foreach ($Attr in $ParamInfo.Attributes) {
        if ($Attr -is [System.Management.Automation.ParameterAttribute]) {
            if ($Attr.Mandatory) { $IsMandatory = $true }
            if ($Attr.HelpMessage) { $HelpMsg = $Attr.HelpMessage }
        }
        if ($Attr -is [System.Management.Automation.ValidateSetAttribute]) {
            $ValidateSetValues = $Attr.ValidValues
        }
    }

    # If override specifies type, use that
    if ($Override -and $Override.Type) {
        return [PSCustomObject]@{
            Name       = $Name
            Label      = if ($Override.Label) { $Override.Label } else { $HelpMsg }
            StepType   = $Override.Type
            Required   = $IsMandatory
            Source     = if ($Override.Source) { $Override.Source } else { $null }
            Options    = if ($Override.Options) { $Override.Options } else { $ValidateSetValues }
            SubSteps   = if ($Override.SubSteps) { $Override.SubSteps } else { $null }
            EntrySource = if ($Override.EntrySource) { $Override.EntrySource } else { $null }
            Condition  = if ($Override.Condition) { $Override.Condition } else { $null }
            Transform  = if ($Override.Transform) { $Override.Transform } else { $null }
            Default    = if ($Override.Default) { $Override.Default } else { $null }
        }
    }

    # Auto-detect from type
    $StepType = 'text'

    if ($ValidateSetValues) {
        $StepType = 'selection'
    }
    elseif ($Type -eq [switch] -or $Type -eq [System.Management.Automation.SwitchParameter]) {
        $StepType = 'yesno'
        $IsMandatory = $false  # switches are never mandatory in wizard context
    }
    elseif ($Type -eq [int] -or $Type -eq [System.Nullable[int]]) {
        $StepType = 'number'
        if ($Type -eq [System.Nullable[int]]) { $IsMandatory = $false }
    }
    elseif ($Type -eq [decimal] -or $Type -eq [System.Nullable[decimal]]) {
        $StepType = 'decimal'
        if ($Type -eq [System.Nullable[decimal]]) { $IsMandatory = $false }
    }
    elseif ($Type -eq [datetime]) {
        $StepType = 'date'
    }
    elseif ($Type -eq [string[]]) {
        $StepType = 'multitext'
    }

    return [PSCustomObject]@{
        Name       = $Name
        Label      = $HelpMsg
        StepType   = $StepType
        Required   = $IsMandatory
        Source     = $null
        Options    = $ValidateSetValues
        SubSteps   = $null
        EntrySource = $null
        Condition  = $null
        Transform  = $null
        Default    = $null
    }
}

# ── Invoke-Wizard ────────────────────────────────────────────────────────────

function Invoke-Wizard {
    param(
        [Parameter(Mandatory)] [hashtable]$RegistryEntry,
        [Parameter(Mandatory)] [object]$State
    )

    $FunctionName = $RegistryEntry.Function
    $Overrides    = if ($RegistryEntry.Overrides) { $RegistryEntry.Overrides } else { @{} }
    $PreChecks    = $RegistryEntry.PreChecks

    # Show pre-checks info box
    if ($PreChecks) {
        Show-InfoBox -Checks $PreChecks
    }

    # Auto-generate steps from function parameter metadata
    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        Write-CLILine -Text "Funkcja '$FunctionName' nie jest dostępna." -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
        return $null
    }

    $Steps = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($ParamEntry in $Cmd.Parameters.GetEnumerator()) {
        $ParamName = $ParamEntry.Key
        $ParamInfo = $ParamEntry.Value

        # Skip common framework params
        if ($script:CommonParams.Contains($ParamName)) { continue }

        # Check if override says to hide this param
        if ($Overrides.ContainsKey($ParamName) -and $Overrides[$ParamName].Hidden) { continue }

        # Determine step type
        $Override = if ($Overrides.ContainsKey($ParamName)) { $Overrides[$ParamName] } else { $null }
        $StepDef = Resolve-StepType -ParamInfo $ParamInfo -Override $Override
        [void]$Steps.Add($StepDef)
    }

    if ($Steps.Count -eq 0) {
        Write-CLILine -Text "Brak parametrów do skonfigurowania." -Color (Get-CLIColor -Role 'Disabled')
        return $null
    }

    # Walk steps sequentially with back-navigation
    $CollectedParams = [ordered]@{}
    $StepIndex = 0

    while ($StepIndex -lt $Steps.Count) {
        $CurrentStep = $Steps[$StepIndex]

        # Check condition
        if ($CurrentStep.Condition) {
            $CondResult = & $CurrentStep.Condition $CollectedParams
            if (-not $CondResult) {
                $StepIndex++
                continue
            }
        }

        # Get current value (for back-navigation pre-fill)
        $PrevValue = if ($CollectedParams.Contains($CurrentStep.Name)) {
            $CollectedParams[$CurrentStep.Name]
        } else { $null }

        $Result = Invoke-WizardStep -Step $CurrentStep -State $State -CurrentValue $PrevValue

        if ($Result -eq '__quit__') { return $null }
        if ($Result -eq '__back__') {
            if ($StepIndex -gt 0) {
                $StepIndex--
            } else {
                return $null  # Back from first step = cancel
            }
            continue
        }

        # null result on required field = retry same step
        if ($null -eq $Result -and $CurrentStep.Required) {
            continue
        }

        # Apply transform if defined
        if ($CurrentStep.Transform -and $null -ne $Result) {
            $Result = & $CurrentStep.Transform $Result
        }

        # Store result
        if ($null -ne $Result) {
            $CollectedParams[$CurrentStep.Name] = $Result
        }

        $StepIndex++
    }

    # Show preview and execute
    return (Show-Preview -FunctionName $FunctionName -Parameters $CollectedParams -State $State)
}

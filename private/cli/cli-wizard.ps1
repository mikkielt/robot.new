<#
    .SYNOPSIS
    Wizard auto-generation system for the Robot CLI - step type resolution
    and wizard orchestration.

    .DESCRIPTION
    This file contains the wizard pipeline that auto-generates interactive
    step-through wizards from function [Parameter] metadata. Dot-sourced
    on demand (not at module import).

    Helpers:
    - Resolve-StepType:    inspects a ParameterInfo object's type, attributes,
      and ValidateSet to determine the wizard step type. Supports override
      hashtables that let registry entries force a specific step type, label,
      source, options, substeps, condition, or transform.
    - Invoke-Wizard:       full wizard orchestration from a registry entry.
      Auto-generates steps from the target function's parameter metadata,
      walks them sequentially with back-navigation, then delegates to
      Show-Preview for parameter review, confirmation, and execution.

    Chain-loaded companion files (dot-sourced below):
    - cli-wizard-steps.ps1:   Invoke-WizardStep (individual step executor)
    - cli-wizard-preview.ps1: Show-Preview (preview + confirmation + execution)

    Module-level data:
    - $script:CommonParams: HashSet of framework parameter names (WhatIf,
      Confirm, Verbose, Debug, etc.) skipped during wizard auto-generation.
      Uses OrdinalIgnoreCase comparer for case-insensitive matching.

    Design:
    - No wizard has custom rendering — all go through the same auto-gen
      pipeline. This eliminates per-operation UI code and ensures consistent
      UX across all 74+ exported functions.
    - 10 step types: text, number, decimal, date, selection, yesno, multitext,
      fuzzy, multi-entry, multi-entry-nested.
    - Override format allows registry entries to customize step behavior
      (Type, Label, Source, Options, SubSteps, EntrySource, Condition,
      Transform, Default, Hidden).
    - Back-navigation preserves previously entered values in $CollectedParams.
      Going back from the first step cancels the wizard entirely.
    - Conditional steps (Step.Condition scriptblock) are evaluated against
      $CollectedParams and silently skipped if the condition returns $false.
    - Transform scriptblocks are applied after collection, before storage,
      allowing value normalization (e.g., trimming, case conversion).

    Dependencies: cli-wizard-steps.ps1 (Invoke-WizardStep, Invoke-EngineLifecycle),
                  cli-wizard-preview.ps1 (Show-Preview),
                  cli-primitives.ps1 (Write-CLILine, Get-CLIColor, Show-InfoBox)
#>

# Framework parameters excluded from wizard step generation
$script:CommonParams = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction',
        'ErrorVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable',
        'WarningAction', 'WarningVariable', 'InformationAction',
        'InformationVariable', 'ProgressAction',
        'Quiet'
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

    # Extract Mandatory, HelpMessage, and ValidateSet from parameter attributes
    foreach ($Attr in $ParamInfo.Attributes) {
        if ($Attr -is [System.Management.Automation.ParameterAttribute]) {
            if ($Attr.Mandatory) { $IsMandatory = $true }
            if ($Attr.HelpMessage) { $HelpMsg = $Attr.HelpMessage }
        }
        if ($Attr -is [System.Management.Automation.ValidateSetAttribute]) {
            $ValidateSetValues = $Attr.ValidValues
        }
    }

    # Registry override takes precedence over auto-detection
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

    # Auto-detect step type from .NET parameter type
    $StepType = 'text'

    if ($ValidateSetValues) {
        $StepType = 'selection'
    }
    elseif ($Type -eq [switch] -or $Type -eq [System.Management.Automation.SwitchParameter]) {
        $StepType = 'yesno'
        $IsMandatory = $false  # switches always have a default (false) in wizard context
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

    # Pre-checks info box — shows what the wizard will validate
    if ($PreChecks) {
        Show-InfoBox -Checks $PreChecks
    }

    # Auto-generate steps from target function's parameter metadata
    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        Write-CLILine -Text "Funkcja '$FunctionName' nie jest dostępna." -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
        return $null
    }

    $Steps = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($ParamEntry in $Cmd.Parameters.GetEnumerator()) {
        $ParamName = $ParamEntry.Key
        $ParamInfo = $ParamEntry.Value

        # Skip framework params (WhatIf, Verbose, etc.)
        if ($script:CommonParams.Contains($ParamName)) { continue }

        # Skip params marked as hidden in registry overrides
        if ($Overrides.ContainsKey($ParamName) -and $Overrides[$ParamName].Hidden) { continue }

        # Resolve step type (override or auto-detect)
        $Override = if ($Overrides.ContainsKey($ParamName)) { $Overrides[$ParamName] } else { $null }
        $StepDef = Resolve-StepType -ParamInfo $ParamInfo -Override $Override
        [void]$Steps.Add($StepDef)
    }

    if ($Steps.Count -eq 0) {
        Write-CLILine -Text "Brak parametrów do skonfigurowania." -Color (Get-CLIColor -Role 'Disabled')
        return $null
    }

    # Walk steps with back-navigation (previously entered values preserved)
    $CollectedParams = [ordered]@{}
    $StepIndex = 0

    while ($StepIndex -lt $Steps.Count) {
        $CurrentStep = $Steps[$StepIndex]

        # Evaluate conditional step — skip if condition returns $false
        if ($CurrentStep.Condition) {
            $CondResult = & $CurrentStep.Condition $CollectedParams
            if (-not $CondResult) {
                $StepIndex++
                continue
            }
        }

        # Retrieve previously entered value for back-navigation pre-fill
        $PrevValue = if ($CollectedParams.Contains($CurrentStep.Name)) {
            $CollectedParams[$CurrentStep.Name]
        } else { $null }

        $Result = Invoke-WizardStep -Step $CurrentStep -State $State -CurrentValue $PrevValue `
            -StepNumber ($StepIndex + 1) -TotalSteps $Steps.Count

        if ($Result -eq '__back__') {
            if ($StepIndex -gt 0) {
                $StepIndex--
            } else {
                return $null  # back from first step cancels the wizard
            }
            continue
        }

        # null on required field — force retry (don't advance)
        if ($null -eq $Result -and $CurrentStep.Required) {
            continue
        }

        # Apply value transform if defined by registry override
        if ($CurrentStep.Transform -and $null -ne $Result) {
            $Result = & $CurrentStep.Transform $Result
        }

        # Store for splatting and back-navigation pre-fill
        if ($null -ne $Result) {
            $CollectedParams[$CurrentStep.Name] = $Result
        }

        $StepIndex++
    }

    # Delegate to Show-Preview for parameter review, confirmation, and execution
    $PreviewResult = Show-Preview -FunctionName $FunctionName -Parameters $CollectedParams -State $State
    if ($PreviewResult -eq '__quit__') { return '__quit__' }
    return $PreviewResult
}

<#
    .SYNOPSIS
    Wizard auto-generation system for the Robot CLI - step type resolution,
    step execution, wizard orchestration, and WhatIf preview.

    .DESCRIPTION
    This file contains the wizard pipeline that auto-generates interactive
    step-through wizards from function [Parameter] metadata. Dot-sourced
    on demand (not at module import).

    Helpers:
    - Resolve-StepType:    parameter metadata → wizard step type resolution
    - Invoke-WizardStep:   individual step executor (text, number, date, selection, etc.)
    - Invoke-Wizard:       full wizard orchestration from registry entry
    - Show-Preview:        -WhatIf display + Tak/Nie confirmation + execution

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

# ── Invoke-WizardStep ────────────────────────────────────────────────────────

function Invoke-WizardStep {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Step,
        [object]$State,
        [object]$CurrentValue
    )

    $Label = $Step.Label
    $Required = $Step.Required
    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $ErrorColor = Get-CLIColor -Role 'Error'

    $OptionalHint = if (-not $Required) { " (opcjonalne, Enter = pomiń)" } else { '' }

    switch ($Step.StepType) {
        'text' {
            $DefaultHint = ''
            if ($CurrentValue) { $DefaultHint = " [$CurrentValue]" }
            elseif ($Step.Default) { $DefaultHint = " [$($Step.Default)]" }

            Write-Host "  $Label$DefaultHint$OptionalHint`: " -NoNewline -ForegroundColor $AccentColor

            # Character-by-character input via ReadKey
            $Buffer = [System.Text.StringBuilder]::new()
            if ($CurrentValue) { [void]$Buffer.Append($CurrentValue) }

            $InputStartCol = [System.Console]::CursorLeft
            $InputRow = [System.Console]::CursorTop

            # Show pre-filled value
            if ($Buffer.Length -gt 0) {
                [System.Console]::Write($Buffer.ToString())
            }

            while ($true) {
                $K = [System.Console]::ReadKey($true)

                if ($K.Key -eq 'Enter') {
                    Write-Host ''
                    $Result = $Buffer.ToString()
                    if ([string]::IsNullOrWhiteSpace($Result)) {
                        if ($CurrentValue) { return $CurrentValue }
                        if ($Step.Default) { return $Step.Default }
                        if ($Required) {
                            Write-CLILine -Text "To pole jest wymagane." -Color $ErrorColor
                            return $null  # Signal: retry
                        }
                        return $null
                    }
                    return $Result
                }
                elseif ($K.Key -eq 'Escape') {
                    Write-Host ''
                    return '__back__'
                }
                elseif ($K.Key -eq 'Backspace') {
                    if ($Buffer.Length -gt 0) {
                        [void]$Buffer.Remove($Buffer.Length - 1, 1)
                        [System.Console]::SetCursorPosition($InputStartCol, $InputRow)
                        [System.Console]::Write($Buffer.ToString() + ' ')
                        [System.Console]::SetCursorPosition($InputStartCol + $Buffer.Length, $InputRow)
                    }
                }
                else {
                    $Ch = $K.KeyChar
                    if ($Ch -ge ' ') {
                        [void]$Buffer.Append($Ch)
                        [System.Console]::Write($Ch)
                    }
                }
            }
        }

        'number' {
            $DefaultHint = ''
            if ($null -ne $CurrentValue) { $DefaultHint = " [$CurrentValue]" }

            Write-Host "  $Label$DefaultHint$OptionalHint`: " -NoNewline -ForegroundColor $AccentColor

            $Buffer = [System.Text.StringBuilder]::new()
            if ($null -ne $CurrentValue) { [void]$Buffer.Append($CurrentValue) }

            $InputStartCol = [System.Console]::CursorLeft
            $InputRow = [System.Console]::CursorTop

            if ($Buffer.Length -gt 0) {
                [System.Console]::Write($Buffer.ToString())
            }

            while ($true) {
                $K = [System.Console]::ReadKey($true)

                if ($K.Key -eq 'Enter') {
                    Write-Host ''
                    $Str = $Buffer.ToString()
                    if ([string]::IsNullOrWhiteSpace($Str)) {
                        if ($null -ne $CurrentValue) { return $CurrentValue }
                        if (-not $Required) { return $null }
                        Write-CLILine -Text "To pole jest wymagane." -Color $ErrorColor
                        return $null
                    }
                    $NumVal = 0
                    if ([int]::TryParse($Str, [ref]$NumVal)) {
                        return $NumVal
                    }
                    Write-CLILine -Text "Nieprawidłowa liczba: '$Str'" -Color $ErrorColor
                    return $null
                }
                elseif ($K.Key -eq 'Escape') {
                    Write-Host ''
                    return '__back__'
                }
                elseif ($K.Key -eq 'Backspace') {
                    if ($Buffer.Length -gt 0) {
                        [void]$Buffer.Remove($Buffer.Length - 1, 1)
                        [System.Console]::SetCursorPosition($InputStartCol, $InputRow)
                        [System.Console]::Write($Buffer.ToString() + ' ')
                        [System.Console]::SetCursorPosition($InputStartCol + $Buffer.Length, $InputRow)
                    }
                }
                else {
                    $Ch = $K.KeyChar
                    if (($Ch -ge '0' -and $Ch -le '9') -or $Ch -eq '-') {
                        [void]$Buffer.Append($Ch)
                        [System.Console]::Write($Ch)
                    }
                }
            }
        }

        'decimal' {
            $DefaultHint = ''
            if ($null -ne $CurrentValue) { $DefaultHint = " [$CurrentValue]" }

            Write-Host "  $Label$DefaultHint$OptionalHint`: " -NoNewline -ForegroundColor $AccentColor

            $Buffer = [System.Text.StringBuilder]::new()
            if ($null -ne $CurrentValue) { [void]$Buffer.Append($CurrentValue) }

            $InputStartCol = [System.Console]::CursorLeft
            $InputRow = [System.Console]::CursorTop

            if ($Buffer.Length -gt 0) {
                [System.Console]::Write($Buffer.ToString())
            }

            while ($true) {
                $K = [System.Console]::ReadKey($true)

                if ($K.Key -eq 'Enter') {
                    Write-Host ''
                    $Str = $Buffer.ToString()
                    if ([string]::IsNullOrWhiteSpace($Str)) {
                        if ($null -ne $CurrentValue) { return $CurrentValue }
                        if (-not $Required) { return $null }
                        Write-CLILine -Text "To pole jest wymagane." -Color $ErrorColor
                        return $null
                    }
                    $DecVal = [decimal]0
                    if ([decimal]::TryParse($Str, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$DecVal)) {
                        return $DecVal
                    }
                    Write-CLILine -Text "Nieprawidłowa wartość: '$Str'" -Color $ErrorColor
                    return $null
                }
                elseif ($K.Key -eq 'Escape') {
                    Write-Host ''
                    return '__back__'
                }
                elseif ($K.Key -eq 'Backspace') {
                    if ($Buffer.Length -gt 0) {
                        [void]$Buffer.Remove($Buffer.Length - 1, 1)
                        [System.Console]::SetCursorPosition($InputStartCol, $InputRow)
                        [System.Console]::Write($Buffer.ToString() + ' ')
                        [System.Console]::SetCursorPosition($InputStartCol + $Buffer.Length, $InputRow)
                    }
                }
                else {
                    $Ch = $K.KeyChar
                    if (($Ch -ge '0' -and $Ch -le '9') -or $Ch -eq '.' -or $Ch -eq ',' -or $Ch -eq '-') {
                        [void]$Buffer.Append($Ch)
                        [System.Console]::Write($Ch)
                    }
                }
            }
        }

        'date' {
            $DefaultHint = ''
            if ($CurrentValue) { $DefaultHint = " [$CurrentValue]" }

            Write-Host "  $Label (RRRR-MM-DD)$DefaultHint$OptionalHint`: " -NoNewline -ForegroundColor $AccentColor

            $Buffer = [System.Text.StringBuilder]::new()
            if ($CurrentValue) { [void]$Buffer.Append($CurrentValue) }

            $InputStartCol = [System.Console]::CursorLeft
            $InputRow = [System.Console]::CursorTop

            if ($Buffer.Length -gt 0) {
                [System.Console]::Write($Buffer.ToString())
            }

            while ($true) {
                $K = [System.Console]::ReadKey($true)

                if ($K.Key -eq 'Enter') {
                    Write-Host ''
                    $Str = $Buffer.ToString()
                    if ([string]::IsNullOrWhiteSpace($Str)) {
                        if ($CurrentValue) { return $CurrentValue }
                        if (-not $Required) { return $null }
                        Write-CLILine -Text "To pole jest wymagane." -Color $ErrorColor
                        return $null
                    }
                    # Validate date format
                    $DateVal = [datetime]::MinValue
                    if ([datetime]::TryParseExact($Str, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$DateVal)) {
                        return $DateVal
                    }
                    # Try partial formats
                    if ([datetime]::TryParseExact($Str, 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$DateVal)) {
                        return $DateVal
                    }
                    Write-CLILine -Text "Nieprawidłowy format daty: '$Str' (oczekiwany: RRRR-MM-DD lub RRRR-MM)" -Color $ErrorColor
                    return $null
                }
                elseif ($K.Key -eq 'Escape') {
                    Write-Host ''
                    return '__back__'
                }
                elseif ($K.Key -eq 'Backspace') {
                    if ($Buffer.Length -gt 0) {
                        [void]$Buffer.Remove($Buffer.Length - 1, 1)
                        [System.Console]::SetCursorPosition($InputStartCol, $InputRow)
                        [System.Console]::Write($Buffer.ToString() + ' ')
                        [System.Console]::SetCursorPosition($InputStartCol + $Buffer.Length, $InputRow)
                    }
                }
                else {
                    $Ch = $K.KeyChar
                    if (($Ch -ge '0' -and $Ch -le '9') -or $Ch -eq '-') {
                        [void]$Buffer.Append($Ch)
                        [System.Console]::Write($Ch)
                    }
                }
            }
        }

        'selection' {
            $Options = if ($Step.Options) { $Step.Options } else { @('Tak', 'Nie') }
            Write-CLILine -Text "$Label`:" -Color $AccentColor

            $MenuItems = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($Opt in $Options) {
                [void]$MenuItems.Add([PSCustomObject]@{
                    ID          = $Opt
                    Label       = $Opt
                    Description = ''
                    RoleTag     = $null
                    InfoText    = $null
                    Disabled    = $false
                })
            }

            $Choice = Show-ArrowMenu -Items $MenuItems -ShowBack
            if ($Choice -eq '__back__') { return '__back__' }
            if ($Choice -eq '__quit__') { return '__quit__' }
            return $Choice
        }

        'yesno' {
            Write-CLILine -Text "$Label`:" -Color $AccentColor

            $YesNoItems = @(
                [PSCustomObject]@{ ID = 'yes'; Label = 'Tak'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                [PSCustomObject]@{ ID = 'no';  Label = 'Nie'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
            )

            $Choice = Show-ArrowMenu -Items $YesNoItems -ShowBack
            if ($Choice -eq '__back__') { return '__back__' }
            if ($Choice -eq '__quit__') { return '__quit__' }
            return ($Choice -eq 'yes')
        }

        'multitext' {
            Write-CLILine -Text "$Label (Enter po każdym wpisie, pusty Enter = zakończ)$OptionalHint`:" -Color $AccentColor

            $Items = [System.Collections.Generic.List[string]]::new()
            if ($CurrentValue -and $CurrentValue -is [array]) {
                foreach ($V in $CurrentValue) { [void]$Items.Add($V) }
            }

            $EntryNum = $Items.Count + 1
            while ($true) {
                Write-Host "    [$EntryNum] " -NoNewline -ForegroundColor $DisabledColor

                $Buffer = [System.Text.StringBuilder]::new()
                $InputStartCol = [System.Console]::CursorLeft
                $InputRow = [System.Console]::CursorTop

                while ($true) {
                    $K = [System.Console]::ReadKey($true)
                    if ($K.Key -eq 'Enter') { break }
                    elseif ($K.Key -eq 'Escape') {
                        Write-Host ''
                        if ($Items.Count -gt 0) { return [string[]]$Items.ToArray() }
                        return '__back__'
                    }
                    elseif ($K.Key -eq 'Backspace') {
                        if ($Buffer.Length -gt 0) {
                            [void]$Buffer.Remove($Buffer.Length - 1, 1)
                            [System.Console]::SetCursorPosition($InputStartCol, $InputRow)
                            [System.Console]::Write($Buffer.ToString() + ' ')
                            [System.Console]::SetCursorPosition($InputStartCol + $Buffer.Length, $InputRow)
                        }
                    }
                    else {
                        $Ch = $K.KeyChar
                        if ($Ch -ge ' ') {
                            [void]$Buffer.Append($Ch)
                            [System.Console]::Write($Ch)
                        }
                    }
                }

                Write-Host ''
                $Entry = $Buffer.ToString()
                if ([string]::IsNullOrWhiteSpace($Entry)) { break }

                [void]$Items.Add($Entry)
                $EntryNum++
            }

            if ($Items.Count -eq 0 -and $Required) {
                Write-CLILine -Text "Wymagany co najmniej jeden wpis." -Color $ErrorColor
                return $null
            }

            if ($Items.Count -eq 0) { return $null }
            return [string[]]$Items.ToArray()
        }

        'fuzzy' {
            $FuzzyResult = Show-FuzzySearch -Prompt $Label -Source $Step.Source -State $State
            if (-not $FuzzyResult) { return '__back__' }
            return $FuzzyResult.Name
        }

        'multi-entry' {
            Write-CLILine -Text "$Label`:" -Color $AccentColor
            $Items = [System.Collections.Generic.List[string]]::new()
            $EntryNum = 1

            while ($true) {
                Write-CLILine -Text "  Wpis $EntryNum`:" -Color $DisabledColor
                $FuzzyResult = Show-FuzzySearch -Prompt "Wybierz" -Source $Step.EntrySource -State $State
                if (-not $FuzzyResult) {
                    if ($Items.Count -gt 0) { break }
                    return '__back__'
                }
                [void]$Items.Add($FuzzyResult.Name)
                $EntryNum++

                # Ask "add another?"
                Write-Host ''
                $AddMore = Show-ArrowMenu -Items @(
                    [PSCustomObject]@{ ID = 'yes'; Label = 'Dodaj kolejny'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                    [PSCustomObject]@{ ID = 'no';  Label = 'Zakończ';       Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                ) -ShowBack

                if ($AddMore -ne 'yes') { break }
            }

            if ($Items.Count -eq 0) { return $null }
            return [string[]]$Items.ToArray()
        }

        'multi-entry-nested' {
            Write-CLILine -Text "$Label`:" -Color $AccentColor
            $Items = [System.Collections.Generic.List[PSCustomObject]]::new()
            $EntryNum = 1

            while ($true) {
                Write-CLILine -Text "  Wpis $EntryNum`:" -Color $DisabledColor
                $EntryData = [ordered]@{}
                $Cancelled = $false

                foreach ($SubStep in $Step.SubSteps) {
                    $SubStepObj = [PSCustomObject]@{
                        Name     = $SubStep.Param
                        Label    = if ($SubStep.Label) { $SubStep.Label } else { $SubStep.Param }
                        StepType = $SubStep.Type
                        Required = $true
                        Source   = if ($SubStep.Source) { $SubStep.Source } else { $null }
                        Options  = if ($SubStep.Options) { $SubStep.Options } else { $null }
                        SubSteps = $null
                        EntrySource = $null
                        Condition = $null
                        Transform = $null
                        Default   = $null
                    }

                    $SubResult = Invoke-WizardStep -Step $SubStepObj -State $State
                    if ($SubResult -eq '__back__' -or $SubResult -eq '__quit__') {
                        $Cancelled = $true
                        break
                    }
                    $EntryData[$SubStep.Param] = $SubResult
                }

                if ($Cancelled) {
                    if ($Items.Count -gt 0) { break }
                    return '__back__'
                }

                [void]$Items.Add([PSCustomObject]$EntryData)
                $EntryNum++

                Write-Host ''
                $AddMore = Show-ArrowMenu -Items @(
                    [PSCustomObject]@{ ID = 'yes'; Label = 'Dodaj kolejny'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                    [PSCustomObject]@{ ID = 'no';  Label = 'Zakończ';       Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
                ) -ShowBack

                if ($AddMore -ne 'yes') { break }
            }

            if ($Items.Count -eq 0) { return $null }
            return @(,$Items.ToArray())
        }

        default {
            # Fallback to text
            $TextStep = $Step.PSObject.Copy()
            $TextStep.StepType = 'text'
            return (Invoke-WizardStep -Step $TextStep -State $State -CurrentValue $CurrentValue)
        }
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

# ── Show-Preview ─────────────────────────────────────────────────────────────

function Show-Preview {
    param(
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Parameters,
        [Parameter(Mandatory)] [object]$State
    )

    $AccentColor  = Get-CLIColor -Role 'Accent'
    $WarningColor = Get-CLIColor -Role 'Warning'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor   = Get-CLIColor -Role 'Error'

    # Check if function supports -WhatIf
    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    $SupportsWhatIf = $false
    if ($Cmd) {
        $SupportsWhatIf = $Cmd.Parameters.ContainsKey('WhatIf')
    }

    [System.Console]::Clear()
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text "Podgląd: $FunctionName" -Color $AccentColor
    Write-Host ''

    # Show parameters
    foreach ($Key in $Parameters.Keys) {
        $Val = $Parameters[$Key]

        if ($Val -is [System.Collections.IDictionary]) {
            # Expand hashtable entries
            Write-Host "    $Key`:" -ForegroundColor $AccentColor
            foreach ($HKey in $Val.Keys) {
                $HVal = $Val[$HKey]
                $HDisplay = if ($HVal -is [array]) { $HVal -join ', ' } else { [string]$HVal }
                Write-Host "      @$HKey`: $HDisplay"
            }
        }
        else {
            $DisplayVal = if ($null -eq $Val) { '(brak)' }
                          elseif ($Val -is [array]) { $Val -join ', ' }
                          elseif ($Val -is [bool]) { if ($Val) { 'Tak' } else { 'Nie' } }
                          elseif ($Val -is [datetime]) { $Val.ToString('yyyy-MM-dd') }
                          else { [string]$Val }

            Write-Host "    $Key`: " -NoNewline -ForegroundColor $AccentColor
            Write-Host $DisplayVal
        }
    }

    # Run -WhatIf if supported
    if ($SupportsWhatIf) {
        Write-Host ''
        Write-CLILine -Text 'Operacja wykona:' -Color $WarningColor

        try {
            # Build splat hashtable (remove nulls)
            $SplatParams = @{}
            foreach ($Key in $Parameters.Keys) {
                if ($null -ne $Parameters[$Key]) {
                    $SplatParams[$Key] = $Parameters[$Key]
                }
            }
            $SplatParams['WhatIf'] = $true

            $WhatIfOutput = & $FunctionName @SplatParams *>&1 | Out-String
            if ($WhatIfOutput) {
                foreach ($Line in $WhatIfOutput.Split("`n")) {
                    if (-not [string]::IsNullOrWhiteSpace($Line)) {
                        Write-Host "    $($Line.Trim())" -ForegroundColor $WarningColor
                    }
                }
            }
        }
        catch {
            Write-CLILine -Text "Błąd podglądu: $_" -Color $ErrorColor
        }
    }

    Write-Host ''
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor (Get-CLIColor -Role 'Disabled')

    # Confirmation
    Write-CLILine -Text 'Wykonać operację?' -Color $AccentColor
    $ConfirmItems = @(
        [PSCustomObject]@{ ID = 'yes'; Label = 'Tak, wykonaj'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'no';  Label = 'Anuluj';       Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
    )

    $Confirm = Show-ArrowMenu -Items $ConfirmItems -ShowBack
    if ($Confirm -ne 'yes') {
        Write-CLILine -Text 'Anulowano.' -Color (Get-CLIColor -Role 'Disabled')
        return $null
    }

    # Execute
    try {
        $SplatParams = @{}
        foreach ($Key in $Parameters.Keys) {
            if ($null -ne $Parameters[$Key]) {
                $SplatParams[$Key] = $Parameters[$Key]
            }
        }

        $ExecResult = & $FunctionName @SplatParams

        Write-Host ''
        Write-CLILine -Text "$([char]0x2713) Operacja zakończona pomyślnie." -Color $SuccessColor

        # Refresh NavState
        try {
            Refresh-NavState -State $State
        }
        catch {
            # Non-fatal: state refresh failure shouldn't block the user
        }

        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)

        return $ExecResult
    }
    catch {
        Write-Host ''
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color $ErrorColor
        Write-Host ''
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
        return $null
    }
}

<#
    .SYNOPSIS
    Individual wizard step executor for the Robot CLI wizard system.

    .DESCRIPTION
    Contains the Invoke-WizardStep function, which handles execution of a single
    wizard step based on its StepType. Supports 10 step types: text, number,
    decimal, date, selection, yesno, multitext, fuzzy, multi-entry, and
    multi-entry-nested.

    Split out from cli-wizard.ps1 for maintainability. Dot-sourced by
    cli-wizard.ps1 at load time.

    Back-navigation is signalled by returning the sentinel string '__back__'.
    Uses the TUI engine (WizardStepComponent + Start-InputLoop) for rendering
    of all step types except multitext (which uses inline ReadKey collection).

    Helpers:
    - Invoke-EngineLifecycle:  runs a component through engine lifecycle
    - Invoke-WizardStep:       dispatches by StepType using engine components

    Factory functions (reduce boilerplate in workflow files):
    - New-WizardTextStep:      creates a text-input step definition
    - New-WizardNumberStep:    creates an integer-input step definition
    - New-WizardDateStep:      creates a date-input step definition (YYYY-MM-DD)
    - New-WizardChoiceStep:    creates a selection step from option list
    - New-WizardFuzzyStep:     creates a fuzzy-search step bound to a source
#>

# ── Engine lifecycle helper ──────────────────────────────────────────────────

# Runs a component through the standard engine lifecycle: Initialize-Screen →
# Initialize-Buffers → render → Start-InputLoop → Restore-Cursor.
# Returns the value from Start-InputLoop ('__back__', '__quit__', or step value).
function Invoke-EngineLifecycle {
    param(
        [Parameter(Mandatory)] [object]$Component,
        [Parameter(Mandatory)] [object]$State
    )

    $ScreenOK = Initialize-Screen -State $State
    if (-not $ScreenOK) {
        [void][System.Console]::ReadKey($true)
        return '__back__'
    }

    Initialize-Buffers
    $RenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
    $CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }

    & $RenderCB $State $Component
    Render-FullBuffer

    try {
        return (Start-InputLoop -State $State -Component $Component `
            -RenderCallback $RenderCB -CommandHandler $CmdHandler)
    } finally {
        Restore-Cursor
    }
}

# ── Invoke-WizardStep ────────────────────────────────────────────────────────

function Invoke-WizardStep {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Step,
        [object]$State,
        [object]$CurrentValue,
        [int]$StepNumber = 0,
        [int]$TotalSteps = 0
    )

    $Label = $Step.Label
    $Required = $Step.Required

    switch ($Step.StepType) {
        'text' {
            $DefaultVal = if ($CurrentValue) { [string]$CurrentValue }
                          elseif ($Step.Default) { [string]$Step.Default }
                          else { $null }

            $StepComponent = New-WizardStepComponent -Label $Label `
                -StepNumber $StepNumber -TotalSteps $TotalSteps `
                -StepType 'text' -DefaultValue $DefaultVal -Required:$Required

            $Result = Invoke-EngineLifecycle -Component $StepComponent -State $State
            if ($Result -eq '__back__' -or $Result -eq '__quit__') { return '__back__' }

            if ([string]::IsNullOrWhiteSpace($Result)) {
                if ($CurrentValue) { return $CurrentValue }
                if ($Step.Default) { return $Step.Default }
                return $null
            }
            return $Result
        }

        'number' {
            $DefaultVal = if ($null -ne $CurrentValue) { [string]$CurrentValue } else { $null }
            $ErrorMsg = $null

            while ($true) {
                $StepComponent = New-WizardStepComponent -Label $Label `
                    -StepNumber $StepNumber -TotalSteps $TotalSteps `
                    -StepType 'number' -DefaultValue $DefaultVal -Required:$Required
                if ($ErrorMsg) { $StepComponent.ErrorMessage = $ErrorMsg }

                $Result = Invoke-EngineLifecycle -Component $StepComponent -State $State
                if ($Result -eq '__back__' -or $Result -eq '__quit__') { return '__back__' }

                if ([string]::IsNullOrWhiteSpace($Result)) {
                    if ($null -ne $CurrentValue) { return $CurrentValue }
                    if (-not $Required) { return $null }
                    continue
                }

                $NumVal = 0
                if ([int]::TryParse($Result, [ref]$NumVal)) {
                    return $NumVal
                }

                # Invalid number — retry with error and previous input
                $DefaultVal = $Result
                $ErrorMsg = "Nieprawidłowa liczba: '$Result'"
            }
        }

        'decimal' {
            $DefaultVal = if ($null -ne $CurrentValue) { [string]$CurrentValue } else { $null }
            $ErrorMsg = $null

            while ($true) {
                $StepComponent = New-WizardStepComponent -Label $Label `
                    -StepNumber $StepNumber -TotalSteps $TotalSteps `
                    -StepType 'decimal' -DefaultValue $DefaultVal -Required:$Required
                if ($ErrorMsg) { $StepComponent.ErrorMessage = $ErrorMsg }

                $Result = Invoke-EngineLifecycle -Component $StepComponent -State $State
                if ($Result -eq '__back__' -or $Result -eq '__quit__') { return '__back__' }

                if ([string]::IsNullOrWhiteSpace($Result)) {
                    if ($null -ne $CurrentValue) { return $CurrentValue }
                    if (-not $Required) { return $null }
                    continue
                }

                $DecVal = [decimal]0
                if ([decimal]::TryParse($Result, [System.Globalization.NumberStyles]::Any,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$DecVal)) {
                    return $DecVal
                }

                $DefaultVal = $Result
                $ErrorMsg = "Nieprawidłowa wartość: '$Result'"
            }
        }

        'date' {
            $DefaultVal = if ($CurrentValue) { [string]$CurrentValue } else { $null }
            $ErrorMsg = $null

            while ($true) {
                $DateLabel = "$Label (RRRR-MM-DD)"
                $StepComponent = New-WizardStepComponent -Label $DateLabel `
                    -StepNumber $StepNumber -TotalSteps $TotalSteps `
                    -StepType 'date' -DefaultValue $DefaultVal -Required:$Required
                if ($ErrorMsg) { $StepComponent.ErrorMessage = $ErrorMsg }

                $Result = Invoke-EngineLifecycle -Component $StepComponent -State $State
                if ($Result -eq '__back__' -or $Result -eq '__quit__') { return '__back__' }

                if ([string]::IsNullOrWhiteSpace($Result)) {
                    if ($CurrentValue) { return $CurrentValue }
                    if (-not $Required) { return $null }
                    continue
                }

                $DateVal = [datetime]::MinValue
                if ([datetime]::TryParseExact($Result, 'yyyy-MM-dd',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$DateVal)) {
                    return $DateVal
                }
                if ([datetime]::TryParseExact($Result, 'yyyy-MM',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$DateVal)) {
                    return $DateVal
                }

                $DefaultVal = $Result
                $ErrorMsg = "Nieprawidłowy format daty: '$Result' (oczekiwany: RRRR-MM-DD lub RRRR-MM)"
            }
        }

        'selection' {
            $Options = if ($Step.Options) { $Step.Options } else { @('Tak', 'Nie') }

            $StepComponent = New-WizardStepComponent -Label $Label `
                -StepNumber $StepNumber -TotalSteps $TotalSteps `
                -StepType 'selection' -Options $Options

            $Result = Invoke-EngineLifecycle -Component $StepComponent -State $State
            if ($Result -eq '__back__' -or $Result -eq '__quit__') { return '__back__' }
            return $Result
        }

        'yesno' {
            $StepComponent = New-WizardStepComponent -Label $Label `
                -StepNumber $StepNumber -TotalSteps $TotalSteps `
                -StepType 'yesno'

            $Result = Invoke-EngineLifecycle -Component $StepComponent -State $State
            if ($Result -eq '__back__' -or $Result -eq '__quit__') { return '__back__' }
            return $Result
        }

        'multitext' {
            # Inline ReadKey loop instead of engine component because multi-line
            # collection with per-line echo doesn't fit WizardStepComponent's
            # single-value-return model. Used by SpecialItems, Triggers, etc.
            $AccentColor = Get-CLIColor -Role 'Accent'
            $DisabledColor = Get-CLIColor -Role 'Disabled'
            $ErrorColor = Get-CLIColor -Role 'Error'
            $OptionalHint = if (-not $Required) { " (opcjonalne, Enter = pomiń)" } else { '' }

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
            $FuzzyResult = Invoke-EngineFuzzySearch -Prompt $Label -Source $Step.Source -State $State
            if (-not $FuzzyResult) { return '__back__' }
            return $FuzzyResult.Name
        }

        'multi-entry' {
            $Items = [System.Collections.Generic.List[string]]::new()
            $EntryNum = 1

            while ($true) {
                $FuzzyResult = Invoke-EngineFuzzySearch -Prompt "$Label ($EntryNum)" -Source $Step.EntrySource -State $State
                if (-not $FuzzyResult) {
                    if ($Items.Count -gt 0) { break }
                    return '__back__'
                }
                [void]$Items.Add($FuzzyResult.Name)
                $EntryNum++

                # Ask "add another?" via engine yesno
                $AddMoreComponent = New-WizardStepComponent -Label 'Dodaj kolejny?' `
                    -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
                $AddMore = Invoke-EngineLifecycle -Component $AddMoreComponent -State $State
                if ($AddMore -ne $true) { break }
            }

            if ($Items.Count -eq 0) { return $null }
            return [string[]]$Items.ToArray()
        }

        'multi-entry-nested' {
            $Items = [System.Collections.Generic.List[PSCustomObject]]::new()
            $EntryNum = 1

            while ($true) {
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
                    if ($SubResult -eq '__back__') {
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

                # Ask "add another?" via engine yesno
                $AddMoreComponent = New-WizardStepComponent -Label 'Dodaj kolejny?' `
                    -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
                $AddMore = Invoke-EngineLifecycle -Component $AddMoreComponent -State $State
                if ($AddMore -ne $true) { break }
            }

            if ($Items.Count -eq 0) { return $null }
            return @(,$Items.ToArray())
        }

        default {
            # Fallback to text
            $TextStep = $Step.PSObject.Copy()
            $TextStep.StepType = 'text'
            return (Invoke-WizardStep -Step $TextStep -State $State -CurrentValue $CurrentValue `
                -StepNumber $StepNumber -TotalSteps $TotalSteps)
        }
    }
}

# ── Wizard step factory functions ────────────────────────────────────────────
# Reduce boilerplate for inline wizard step definitions in workflow files.

function New-WizardTextStep {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Label,
        [switch]$Required,
        [string]$Default
    )
    return [PSCustomObject]@{
        Name = $Name; Label = $Label; StepType = 'text'; Required = [bool]$Required
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $Default
    }
}

function New-WizardNumberStep {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Label,
        [switch]$Required,
        [string]$Default
    )
    return [PSCustomObject]@{
        Name = $Name; Label = $Label; StepType = 'number'; Required = [bool]$Required
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $Default
    }
}

function New-WizardDateStep {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Label,
        [switch]$Required,
        [string]$Default
    )
    return [PSCustomObject]@{
        Name = $Name; Label = $Label; StepType = 'date'; Required = [bool]$Required
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $Default
    }
}

function New-WizardChoiceStep {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string[]]$Options,
        [switch]$Required,
        [string]$Default
    )
    return [PSCustomObject]@{
        Name = $Name; Label = $Label; StepType = 'choice'; Required = [bool]$Required
        Source = $null; Options = $Options; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $Default
    }
}

function New-WizardFuzzyStep {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$Source
    )
    return [PSCustomObject]@{
        Name = $Name; Label = $Label; StepType = 'fuzzy'; Required = $true
        Source = $Source; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
}

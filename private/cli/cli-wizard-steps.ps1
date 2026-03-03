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
    Quit is signalled by '__quit__'. A $null return on a required field means
    "retry this step".
#>

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

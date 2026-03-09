<#
    .SYNOPSIS
    Wizard step component for the Robot CLI TUI engine.

    .DESCRIPTION
    Renders a single wizard step as a bordered input field with step counter,
    label, and contextual help hint. Used by the wizard orchestration system
    to display each parameter input within the engine's content region.

    Helpers:
    - New-WizardStepComponent:  creates a step component for text/number/date input

    Component contract:
    - Render:    draws bordered input box with step counter and label in Content region
    - HandleKey: Navigate (not used), Select (returns current input value)
    - Filterable: false (wizard steps don't support inline filtering)

    This component handles the visual rendering of wizard steps. The actual
    input collection and step type dispatch remain in cli-wizard.ps1 and
    cli-wizard-steps.ps1 (Phase C migration will wire them together).

    Dependencies:
    - cli-engine.ps1:  Get-Region, Get-RegionHeight, Get-CLIColor, $script:ScreenWidth
    - cli-buffer.ps1:  New-Segment, Set-BufferLine, Clear-BufferRegion, $script:BackBuffer
#>

# ── WizardStepComponent ─────────────────────────────────────────────────────

function New-WizardStepComponent {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [int]$StepNumber,
        [Parameter(Mandatory)] [int]$TotalSteps,
        [string]$StepType = 'text',
        [string]$DefaultValue,
        [string[]]$Options,
        [string[]]$HelpBrief,
        [switch]$Required
    )

    # Text input types need TextInputMode so printable chars route to component
    $IsTextType = $StepType -notin @('selection', 'yesno')

    $Component = @{
        Type          = 'WizardStep'
        Label         = $Label
        StepNumber    = $StepNumber
        TotalSteps    = $TotalSteps
        StepType      = $StepType
        InputBuffer   = [System.Text.StringBuilder]::new($(if ($DefaultValue) { $DefaultValue } else { '' }))
        DefaultValue  = $DefaultValue
        Options       = $Options
        SelectedOption = 0
        HelpBrief     = $HelpBrief
        Required      = [bool]$Required
        Filterable    = $false
        TextInputMode = $IsTextType
        ErrorMessage  = $null
        StatusHints   = "Enter zatwierdz  Esc $(if ($StepNumber -gt 1) { 'poprzedni krok' } else { 'anuluj' })"

        Render = {
            param($State, $ComponentRef)

            $Region = Get-Region -Name 'Content'
            if ($null -eq $Region) { return }

            Clear-BufferRegion -Buffer $script:BackBuffer -Region $Region

            $AccentColor   = Get-CLIColor -Role 'Accent'
            $DisabledColor = Get-CLIColor -Role 'Disabled'
            $InfoColor     = Get-CLIColor -Role 'Info'
            $WarningColor  = Get-CLIColor -Role 'Warning'

            $ContentHeight = Get-RegionHeight -Name 'Content'
            $Row = $Region.StartRow

            # Box-drawing
            $BorderH = [char]0x2500
            $BorderV = [char]0x2502
            $BorderTL = [char]0x250C
            $BorderTR = [char]0x2510
            $BorderBL = [char]0x2514
            $BorderBR = [char]0x2518

            $BoxLeft = 3
            $BoxInnerWidth = [Math]::Min(($script:ScreenWidth - 10), 60)
            $BoxInnerWidth = [Math]::Max($BoxInnerWidth, 20)
            $BoxWidth = $BoxInnerWidth + 4

            # Step counter (hidden when both are 0, e.g. filter inputs)
            if ($ComponentRef.StepNumber -gt 0 -and $ComponentRef.TotalSteps -gt 0) {
                $StepLabel = "Krok $($ComponentRef.StepNumber)/$($ComponentRef.TotalSteps)"
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "  $StepLabel" -Color $DisabledColor)
                )
                $Row++
            }

            # Top border with label
            $TitleStr = " $($ComponentRef.Label) "
            $RequiredMark = if ($ComponentRef.Required) { '*' } else { '' }
            $FullTitle = "$TitleStr$RequiredMark"
            $FillLen = $BoxWidth - 2 - $FullTitle.Length
            $LeftFill = [Math]::Max(0, [Math]::Floor($FillLen / 2))
            $RightFill = [Math]::Max(0, $FillLen - $LeftFill)
            $TopLine = "$(' ' * $BoxLeft)$BorderTL$([string]$BorderH * $LeftFill)$FullTitle$([string]$BorderH * $RightFill)$BorderTR"
            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                (New-Segment -Text $TopLine -Color $AccentColor)
            )
            $Row++

            # Input area depends on step type
            switch ($ComponentRef.StepType) {
                'selection' {
                    # Render options list
                    $Opts = $ComponentRef.Options
                    if ($Opts) {
                        for ($I = 0; $I -lt $Opts.Count; $I++) {
                            if (($Row - $Region.StartRow) -ge ($ContentHeight - 4)) { break }

                            $IsSelected = ($I -eq $ComponentRef.SelectedOption)
                            $Pointer = if ($IsSelected) { "$([char]0x25B8) " } else { '  ' }
                            $OptColor = if ($IsSelected) { $AccentColor } else { $InfoColor }
                            $OptText = "$Pointer$($Opts[$I])".PadRight($BoxInnerWidth)

                            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                                (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                                (New-Segment -Text $OptText -Color $OptColor -Bold:$IsSelected)
                                (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
                            )
                            $Row++
                        }
                    }
                }

                'yesno' {
                    # Yes/No toggle
                    $YesSelected = ($ComponentRef.SelectedOption -eq 0)
                    $YesText = if ($YesSelected) { "$([char]0x25B8) Tak" } else { '  Tak' }
                    $NoText  = if (-not $YesSelected) { "$([char]0x25B8) Nie" } else { '  Nie' }

                    $YesLine = $YesText.PadRight($BoxInnerWidth)
                    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                        (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                        (New-Segment -Text $YesLine -Color $(if ($YesSelected) { $AccentColor } else { $InfoColor }) -Bold:$YesSelected)
                        (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
                    )
                    $Row++

                    $NoLine = $NoText.PadRight($BoxInnerWidth)
                    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                        (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                        (New-Segment -Text $NoLine -Color $(if (-not $YesSelected) { $AccentColor } else { $InfoColor }) -Bold:$(-not $YesSelected))
                        (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
                    )
                    $Row++
                }

                default {
                    # Text/number/date/decimal — single input line with cursor
                    $InputText = $ComponentRef.InputBuffer.ToString()
                    $DisplayText = "$InputText$([char]0x2502)"  # cursor indicator
                    if ($DisplayText.Length -gt $BoxInnerWidth) {
                        # Show end of input with ellipsis at start
                        $VisibleLen = $BoxInnerWidth - 4
                        $DisplayText = "...$($InputText.Substring($InputText.Length - $VisibleLen))$([char]0x2502)"
                    }
                    $PaddedInput = $DisplayText.PadRight($BoxInnerWidth)

                    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                        (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                        (New-Segment -Text $PaddedInput -Color $AccentColor)
                        (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
                    )
                    $Row++

                    # Empty line for spacing
                    $EmptyLine = ' ' * $BoxInnerWidth
                    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                        (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                        (New-Segment -Text $EmptyLine -Color $null)
                        (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
                    )
                    $Row++
                }
            }

            # Bottom border
            $BottomLine = "$(' ' * $BoxLeft)$BorderBL$([string]$BorderH * ($BoxWidth - 2))$BorderBR"
            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                (New-Segment -Text $BottomLine -Color $DisabledColor -Dim)
            )
            $Row++

            # Error message
            if ($ComponentRef.ErrorMessage -and ($Row - $Region.StartRow) -lt ($ContentHeight - 1)) {
                $Row++
                $ErrorColor = Get-CLIColor -Role 'Error'
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "    $([char]0x2717) $($ComponentRef.ErrorMessage)" -Color $ErrorColor)
                )
                $Row++
            }

            # Help hint below box
            if ($ComponentRef.HelpBrief -and ($Row - $Region.StartRow) -lt ($ContentHeight - 1)) {
                $Row++  # blank line
                foreach ($HLine in $ComponentRef.HelpBrief) {
                    if (($Row - $Region.StartRow) -ge $ContentHeight) { break }
                    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                        (New-Segment -Text "    $([char]0x2139) $HLine" -Color $DisabledColor)
                    )
                    $Row++
                }
            }

            # Required field indicator
            if ($ComponentRef.Required -and ($Row - $Region.StartRow) -lt $ContentHeight) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text '    * pole wymagane' -Color $WarningColor)
                )
            }
        }

        HandleKey = {
            param($Action, $State, $ComponentRef)

            switch ($Action.Type) {
                'Navigate' {
                    switch ($ComponentRef.StepType) {
                        'selection' {
                            if ($Action.Value -eq 'Up' -and $ComponentRef.SelectedOption -gt 0) {
                                $ComponentRef.SelectedOption--
                            }
                            elseif ($Action.Value -eq 'Down' -and $ComponentRef.Options -and
                                    $ComponentRef.SelectedOption -lt ($ComponentRef.Options.Count - 1)) {
                                $ComponentRef.SelectedOption++
                            }
                        }
                        'yesno' {
                            if ($Action.Value -eq 'Up' -or $Action.Value -eq 'Down') {
                                $ComponentRef.SelectedOption = if ($ComponentRef.SelectedOption -eq 0) { 1 } else { 0 }
                            }
                        }
                    }
                }

                'Select' {
                    $ComponentRef.ErrorMessage = $null
                    switch ($ComponentRef.StepType) {
                        'selection' {
                            if ($ComponentRef.Options -and $ComponentRef.SelectedOption -lt $ComponentRef.Options.Count) {
                                return @{ Type = 'Return'; Value = $ComponentRef.Options[$ComponentRef.SelectedOption] }
                            }
                        }
                        'yesno' {
                            return @{ Type = 'Return'; Value = ($ComponentRef.SelectedOption -eq 0) }
                        }
                        default {
                            $InputText = $ComponentRef.InputBuffer.ToString()
                            if ($ComponentRef.Required -and [string]::IsNullOrWhiteSpace($InputText)) {
                                $ComponentRef.ErrorMessage = 'To pole jest wymagane.'
                                return $null
                            }
                            return @{ Type = 'Return'; Value = $InputText }
                        }
                    }
                }

                'TextInput' {
                    [void]$ComponentRef.InputBuffer.Append($Action.Value)
                    $ComponentRef.ErrorMessage = $null
                }

                'TextBackspace' {
                    if ($ComponentRef.InputBuffer.Length -gt 0) {
                        [void]$ComponentRef.InputBuffer.Remove($ComponentRef.InputBuffer.Length - 1, 1)
                    }
                    $ComponentRef.ErrorMessage = $null
                }

                'FilterStart' {
                    # Legacy: in case component is used outside TextInputMode
                    if ($ComponentRef.StepType -notin @('selection', 'yesno')) {
                        [void]$ComponentRef.InputBuffer.Append($Action.Value)
                    }
                }
            }

            return $null
        }
    }

    return $Component
}

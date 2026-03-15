<#
    .SYNOPSIS
    WhatIf preview and execution confirmation for the Robot CLI wizard system.

    .DESCRIPTION
    Contains the Show-Preview function, which displays a summary of collected
    wizard parameters via engine DetailCardComponent, asks for confirmation
    via engine WizardStepComponent (yesno), and executes the target function
    on confirmation.

    Split out from cli-wizard.ps1 for maintainability. Dot-sourced by
    cli-wizard.ps1 at load time.

    Helpers:
    - Show-Preview: parameter review card, yesno confirmation, and execution

    Design:
    - After successful execution, the result is displayed as an engine
      DetailCardComponent and NavState is refreshed so that subsequent CLI
      screens reflect the new data.
    - OperationResult objects (PSTypeName 'Robot.OperationResult') are
      destructured into a human-readable summary with action label, change
      diff, file path, warnings, and undo hint.
    - On error, an error detail card is shown instead of crashing the CLI.
#>

# ── Show-Preview ─────────────────────────────────────────────────────────────

function Show-Preview {
    param(
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Parameters,
        [Parameter(Mandatory)] [object]$State
    )

    # Build preview data object for engine detail card
    $PreviewProps = [ordered]@{}
    foreach ($Key in $Parameters.Keys) {
        $PreviewProps[$Key] = $Parameters[$Key]
    }
    $PreviewObj = [PSCustomObject]$PreviewProps

    # Show preview via engine detail card (user reviews parameters, Esc to proceed)
    $PreviewComponent = New-DetailCardComponent -Data $PreviewObj -Title "Podgląd: $FunctionName"
    $PreviewComponent.StatusHints = "$([char]0x2191)$([char]0x2193) przewiń  Esc dalej"
    $PreviewResult = Invoke-EngineLifecycle -Component $PreviewComponent -State $State
    if ($PreviewResult -eq '__quit__') { return '__quit__' }

    # Confirmation via engine yesno
    $ConfirmComponent = New-WizardStepComponent -Label 'Wykonać operację?' `
        -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
    $Confirm = Invoke-EngineLifecycle -Component $ConfirmComponent -State $State
    if ($Confirm -eq '__quit__') { return '__quit__' }
    if ($Confirm -ne $true) { return $null }

    # Execute
    [System.Console]::Clear()
    try {
        $SplatParams = @{}
        foreach ($Key in $Parameters.Keys) {
            if ($null -ne $Parameters[$Key]) {
                $SplatParams[$Key] = $Parameters[$Key]
            }
        }

        $ExecResult = & $FunctionName @SplatParams

        # Build result summary for engine detail card
        $ResultData = [ordered]@{}

        $OpResult = $null
        if ($ExecResult -is [PSCustomObject]) {
            if ($ExecResult.PSObject.TypeNames -contains 'Robot.OperationResult') {
                $OpResult = $ExecResult
            } elseif ($ExecResult.PSObject.Properties['OperationResult']) {
                $OpResult = $ExecResult.OperationResult
            }
        }

        if ($OpResult) {
            $ActionLabel = switch ($OpResult.Action) {
                'Create'     { 'Utworzono' }
                'Update'     { 'Zaktualizowano' }
                'SoftDelete' { 'Usunięto (soft)' }
                'Skipped'    { 'Pominięto' }
                default      { $OpResult.Action }
            }

            $ResultData['Status'] = "$([char]0x2713) $ActionLabel $($OpResult.TargetType) '$($OpResult.TargetName)'"

            if ($OpResult.Changes -and $OpResult.Changes.Count -gt 0) {
                $ChangeLines = [System.Collections.Generic.List[string]]::new()
                foreach ($Change in $OpResult.Changes) {
                    $OldStr = if ($null -eq $Change.OldValue) { '(brak)' } else { $Change.OldValue }
                    $NewStr = if ($null -eq $Change.NewValue) { '(brak)' } else { $Change.NewValue }
                    [void]$ChangeLines.Add("$($Change.Property): $OldStr $([char]0x2192) $NewStr")
                }
                $ResultData['Zmiany'] = [string[]]$ChangeLines.ToArray()
            }

            if ($OpResult.FilePath) {
                $FileDisplay = if ($OpResult.FilePath -is [array]) { $OpResult.FilePath -join ', ' } else { $OpResult.FilePath }
                $ResultData['Plik'] = [System.IO.Path]::GetFileName($FileDisplay)
            }

            if ($OpResult.Warnings -and $OpResult.Warnings.Count -gt 0) {
                $WarnLines = [System.Collections.Generic.List[string]]::new()
                foreach ($Warn in $OpResult.Warnings) {
                    $WarnText = "$([char]0x26A0) $($Warn.Message)"
                    if ($Warn.ActionHint) { $WarnText += " — $($Warn.ActionHint)" }
                    [void]$WarnLines.Add($WarnText)
                }
                $ResultData['Ostrzeżenia'] = [string[]]$WarnLines.ToArray()
            }

            if ($OpResult.UndoHint) {
                $ResultData['Cofnięcie'] = $OpResult.UndoHint
            }
        } else {
            $ResultData['Status'] = "$([char]0x2713) Operacja zakończona pomyślnie"
        }

        # Refresh NavState before showing result card
        try { Refresh-NavState -State $State } catch {}

        # Show result via engine detail card
        Invoke-EngineDetailCard -Data ([PSCustomObject]$ResultData) -Title 'Wynik operacji' -State $State

        return $ExecResult
    }
    catch {
        $ErrorData = [ordered]@{
            'Status'     = "$([char]0x2717) Błąd"
            'Szczegóły'  = [string]$_
        }
        Invoke-EngineDetailCard -Data ([PSCustomObject]$ErrorData) -Title 'Błąd operacji' -State $State
        return $null
    }
}

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
    - Show-Preview: three-phase pipeline:
      1. Parameter review card (engine DetailCardComponent, Esc to proceed)
      2. Yes/No confirmation (engine WizardStepComponent, yesno type)
      3. Execution with result summary or error card display

    Design:
    - After successful execution, the result is displayed as an engine
      DetailCardComponent and NavState is refreshed (via Refresh-NavState)
      so that subsequent CLI screens reflect the new data.
    - OperationResult objects (PSTypeName 'Robot.OperationResult') are
      destructured into a human-readable summary with Polish action labels
      (Utworzono/Zaktualizowano/Usunięto/Pominięto), property change diffs
      (OldValue → NewValue), file path, warnings with action hints, and
      undo hint text.
    - Non-OperationResult return values show a generic success status.
    - On error, a structured error detail card is shown instead of crashing
      the CLI — the exception message is captured as a 'Szczegóły' field.
    - '__quit__' sentinel propagates to caller for global quit handling.

    Dependencies: cli-wizard-steps.ps1 (Invoke-EngineLifecycle),
                  engine/ (New-DetailCardComponent, New-WizardStepComponent,
                  Invoke-EngineDetailCard), cli-routing.ps1 (Refresh-NavState)
#>

# ── Show-Preview ─────────────────────────────────────────────────────────────

function Show-Preview {
    param(
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Parameters,
        [Parameter(Mandatory)] [object]$State
    )

    # Convert collected parameters to PSCustomObject for detail card rendering
    $PreviewProps = [ordered]@{}
    foreach ($Key in $Parameters.Keys) {
        $PreviewProps[$Key] = $Parameters[$Key]
    }
    $PreviewObj = [PSCustomObject]$PreviewProps

    # Phase 1: User reviews parameters (Esc to proceed)
    $PreviewComponent = New-DetailCardComponent -Data $PreviewObj -Title "Podgląd: $FunctionName"
    $PreviewComponent.StatusHints = "$([char]0x2191)$([char]0x2193) przewiń  Esc dalej"
    $PreviewResult = Invoke-EngineLifecycle -Component $PreviewComponent -State $State
    if ($PreviewResult -eq '__quit__') { return '__quit__' }

    # Phase 2: Confirmation gate
    $ConfirmComponent = New-WizardStepComponent -Label 'Wykonać operację?' `
        -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
    $Confirm = Invoke-EngineLifecycle -Component $ConfirmComponent -State $State
    if ($Confirm -eq '__quit__') { return '__quit__' }
    if ($Confirm -ne $true) { return $null }

    # Phase 3: Execute and display result
    [System.Console]::Clear()
    try {
        $SplatParams = @{}
        foreach ($Key in $Parameters.Keys) {
            if ($null -ne $Parameters[$Key]) {
                $SplatParams[$Key] = $Parameters[$Key]
            }
        }

        $ExecResult = & $FunctionName @SplatParams

        # Build human-readable result summary
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

        # Refresh NavState so subsequent screens reflect the changes
        try { Refresh-NavState -State $State } catch {}

        # Display result card and return execution result to caller
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

<#
    .SYNOPSIS
    WhatIf preview and execution confirmation for the Robot CLI wizard system.

    .DESCRIPTION
    Contains the Show-Preview function, which displays a summary of collected
    wizard parameters, asks for Tak/Nie confirmation, and executes the target
    function on confirmation.

    Split out from cli-wizard.ps1 for maintainability. Dot-sourced by
    cli-wizard.ps1 at load time.

    After successful execution, the NavState is refreshed so that subsequent
    CLI screens reflect the new data.
#>

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

    # Check if function supports -WhatIf (needed for execution with -Confirm:$false)
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

        # Render OperationResult if available
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

            Write-Host ''
            Write-CLILine -Text "$([char]0x2713) $ActionLabel $($OpResult.TargetType) '$($OpResult.TargetName)'" -Color $SuccessColor

            if ($OpResult.Changes -and $OpResult.Changes.Count -gt 0) {
                Write-Host ''
                Write-CLILine -Text 'Zmiany:' -Color $AccentColor
                foreach ($Change in $OpResult.Changes) {
                    $OldStr = if ($null -eq $Change.OldValue) { '(brak)' } else { $Change.OldValue }
                    $NewStr = if ($null -eq $Change.NewValue) { '(brak)' } else { $Change.NewValue }
                    Write-Host "    $($Change.Property): $OldStr $([char]0x2192) $NewStr"
                }
            }

            if ($OpResult.FilePath) {
                Write-Host ''
                $FileDisplay = if ($OpResult.FilePath -is [array]) { $OpResult.FilePath -join ', ' } else { $OpResult.FilePath }
                Write-Host "  Plik: $([System.IO.Path]::GetFileName($FileDisplay))" -ForegroundColor (Get-CLIColor -Role 'Disabled')
            }

            if ($OpResult.Warnings -and $OpResult.Warnings.Count -gt 0) {
                Write-Host ''
                foreach ($Warn in $OpResult.Warnings) {
                    Write-CLILine -Text "$([char]0x26A0) $($Warn.Message)" -Color $WarningColor
                    if ($Warn.ActionHint) {
                        Write-Host "      $($Warn.ActionHint)" -ForegroundColor (Get-CLIColor -Role 'Disabled')
                    }
                }
            }

            if ($OpResult.UndoHint) {
                Write-Host ''
                Write-Host "  Cofnięcie: $($OpResult.UndoHint)" -ForegroundColor (Get-CLIColor -Role 'Disabled')
            }
        }

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

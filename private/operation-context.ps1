<#
    .SYNOPSIS
    Accumulator-based operation context for tracking changes, warnings,
    and files touched during write operations.

    .DESCRIPTION
    Non-exported helper functions consumed by write commands (Set-Entity,
    New-Entity, etc.) via dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Clear-OperationContext:  resets all three accumulators to empty
    - Add-OperationChange:     pushes a property change record (old/new value pair)
    - Add-OperationWarning:    pushes a warning record with severity and optional action hint
    - Add-OperationFile:       registers a touched file path (case-insensitive dedup via HashSet)
    - New-OperationResult:     drains accumulators into a Robot.OperationResult PSCustomObject

    Module-level data:
    - $script:OpChanges:   List[PSCustomObject] of change records { Property, OldValue, NewValue }
    - $script:OpWarnings:  List[PSCustomObject] of warning records { Message, Severity, ActionHint }
    - $script:OpFiles:     HashSet[string] of file paths (OrdinalIgnoreCase dedup)

    The three accumulators form a write-side sidecar: write helpers
    (Set-EntityTag, Write-EntityFile, Write-RobotWarning) push records as
    side effects during a write operation. The calling command drains all
    accumulated data at completion via New-OperationResult, which snapshots
    the accumulators into a Robot.OperationResult object and resets them
    in a finally block to guarantee cleanup even on errors.

    All Add-* functions are null-safe: if the accumulators have not been
    initialized (e.g. when operation-context.ps1 was not dot-sourced),
    they return silently. This allows write helpers to call them
    unconditionally.

    New-OperationResult collapses OpFiles into a scalar when only one file
    was touched (common case for single-entity operations), an array for
    multi-file operations, or $null when no files were written. The
    Timestamp field captures [datetime]::Now at drain time.
#>

$script:OpChanges  = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:OpWarnings = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:OpFiles    = [System.Collections.Generic.HashSet[string]]::new(
                         [System.StringComparer]::OrdinalIgnoreCase)

function Clear-OperationContext {
    if ($null -eq $script:OpChanges) { return }
    $script:OpChanges.Clear()
    $script:OpWarnings.Clear()
    $script:OpFiles.Clear()
}

function Add-OperationChange {
    param(
        [Parameter(Mandatory)] [string]$Property,
        $OldValue,
        $NewValue
    )
    if ($null -eq $script:OpChanges) { return }
    [void]$script:OpChanges.Add([PSCustomObject]@{
        Property = $Property
        OldValue = $OldValue
        NewValue = $NewValue
    })
}

function Add-OperationWarning {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [string]$Severity = 'Info',
        [string]$ActionHint
    )
    if ($null -eq $script:OpWarnings) { return }
    [void]$script:OpWarnings.Add([PSCustomObject]@{
        Message    = $Message
        Severity   = $Severity
        ActionHint = $ActionHint
    })
}

function Add-OperationFile {
    param([Parameter(Mandatory)] [string]$Path)
    if ($null -eq $script:OpFiles) { return }
    [void]$script:OpFiles.Add($Path)
}

function New-OperationResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Drains in-memory accumulators, not system state')]
    param(
        [Parameter(Mandatory)] [bool]$Success,
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [string]$TargetType,
        [Parameter(Mandatory)] [string]$TargetName,
        [string]$UndoHint
    )

    try {
        $Changes  = @($script:OpChanges)
        $Warnings = @($script:OpWarnings)

        # Collapse to scalar for the common single-file case
        $FileCount = $script:OpFiles.Count
        $FilePath = if ($FileCount -eq 0) { $null }
                    elseif ($FileCount -eq 1) { @($script:OpFiles)[0] }
                    else { @($script:OpFiles) }

        return [PSCustomObject]@{
            PSTypeName = 'Robot.OperationResult'
            Success    = $Success
            Action     = $Action
            TargetType = $TargetType
            TargetName = $TargetName
            FilePath   = $FilePath
            Changes    = $Changes
            Warnings   = $Warnings
            UndoHint   = $UndoHint
            Timestamp  = [datetime]::Now
        }
    } finally {
        Clear-OperationContext
    }
}

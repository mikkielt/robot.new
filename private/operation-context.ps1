<#
    .SYNOPSIS
    Accumulator-based operation context for tracking changes, warnings,
    and files touched during write operations.

    .DESCRIPTION
    Non-exported helper functions consumed by write commands (Set-Entity,
    New-Entity, etc.) via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Clear-OperationContext:   resets all three accumulators
    - Add-OperationChange:     pushes a property change record
    - Add-OperationWarning:    pushes a warning record with severity
    - Add-OperationFile:       registers a touched file path (deduped)
    - New-OperationResult:     drains accumulators into Robot.OperationResult

    Module-level data:
    - $script:OpChanges:   List of change records { Property, OldValue, NewValue }
    - $script:OpWarnings:  List of warning records { Message, Severity, ActionHint }
    - $script:OpFiles:     HashSet of file paths (case-insensitive dedup)

    Write helpers (Set-EntityTag, Write-EntityFile, Write-RobotWarning)
    push records as side effects. Calling commands drain via
    New-OperationResult at completion.
#>

# ── Accumulators ──────────────────────────────────────────────────────────────

$script:OpChanges  = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:OpWarnings = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:OpFiles    = [System.Collections.Generic.HashSet[string]]::new(
                         [System.StringComparer]::OrdinalIgnoreCase)

# ── Functions ─────────────────────────────────────────────────────────────────

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

    $Changes  = @($script:OpChanges)
    $Warnings = @($script:OpWarnings)

    # FilePath: scalar when 1 file, array when multiple, $null when none
    $FileCount = $script:OpFiles.Count
    $FilePath = if ($FileCount -eq 0) { $null }
                elseif ($FileCount -eq 1) { @($script:OpFiles)[0] }
                else { @($script:OpFiles) }

    Clear-OperationContext

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
}

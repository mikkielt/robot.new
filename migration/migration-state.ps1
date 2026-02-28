<#
    .SYNOPSIS
    State persistence helpers for the migration script.

    .DESCRIPTION
    Non-exported helper functions consumed by migrate.ps1 via dot-sourcing.
    Manages a JSON state file that tracks migration progress across sessions.

    Helpers:
    - Get-MigrationState:      reads state file, creates default if missing
    - Save-MigrationState:     writes updated state to JSON file
    - Get-PhaseStatus:         returns status string for a given phase
    - Set-PhaseCompleted:      marks phase done with timestamp
    - Set-PhaseInProgress:     marks phase in progress
    - Update-PhaseChecklist:   sets a checklist item for a phase
    - Add-DiagnosticSnapshot:  appends diagnostic run result to phase 3 history

    State file location: .robot/res/migration-state.json (committed to repo).
    Format: JSON with Phases dictionary keyed by phase number (as string).
#>

$script:UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

# Resolves the state file path relative to the parent repo root.
function Resolve-MigrationStatePath {
    $RepoRoot = Get-RepoRoot
    return [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'migration-state.json')
}

# Creates a default state hashtable with all phases set to NotStarted.
function New-DefaultMigrationState {
    $Phases = @{}
    for ($I = 0; $I -le 7; $I++) {
        $Phases["$I"] = @{
            Status    = 'NotStarted'
            Checklist = @{}
        }
    }

    return @{
        Version   = '1.0'
        StartedAt = [datetime]::UtcNow.ToString('o')
        Phases    = $Phases
    }
}

# Reads state file, creates default if missing.
# Handles PS 5.1 (PSCustomObject) vs PS 7 differences.
function Get-MigrationState {
    $Path = Resolve-MigrationStatePath

    if (-not [System.IO.File]::Exists($Path)) {
        return New-DefaultMigrationState
    }

    try {
        $Json = [System.IO.File]::ReadAllText($Path, $script:UTF8NoBOM)
        $Parsed = $Json | ConvertFrom-Json

        # Convert PSCustomObject to nested hashtables (PS 5.1 compatibility)
        $State = ConvertTo-HashtableDeep -InputObject $Parsed
        return $State
    }
    catch {
        [System.Console]::Error.WriteLine("[WARN Get-MigrationState] Nie udało się odczytać pliku stanu: $($_.Exception.Message)")
        [System.Console]::Error.WriteLine("[WARN Get-MigrationState] Tworzenie domyślnego stanu...")
        return New-DefaultMigrationState
    }
}

# Recursively converts a PSCustomObject (from ConvertFrom-Json) into nested hashtables.
# Required for PS 5.1 where ConvertFrom-Json returns PSCustomObject.
function ConvertTo-HashtableDeep {
    param([Parameter(Mandatory)] $InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $Result = @{}
        foreach ($Key in $InputObject.Keys) {
            $Result[$Key] = ConvertTo-HashtableDeep -InputObject $InputObject[$Key]
        }
        return $Result
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $Result = @{}
        foreach ($Prop in $InputObject.PSObject.Properties) {
            $Result[$Prop.Name] = ConvertTo-HashtableDeep -InputObject $Prop.Value
        }
        return $Result
    }

    if ($InputObject -is [System.Collections.IList] -and $InputObject -isnot [string]) {
        $Result = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in $InputObject) {
            $Result.Add((ConvertTo-HashtableDeep -InputObject $Item))
        }
        return , $Result.ToArray()
    }

    return $InputObject
}

# Writes updated state to JSON file (UTF-8 no BOM).
function Save-MigrationState {
    param([Parameter(Mandatory)] [hashtable]$State)

    $Path = Resolve-MigrationStatePath

    # Ensure directory exists
    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Json = $State | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $Json, $script:UTF8NoBOM)
}

# Returns status string for a given phase (Completed/InProgress/NotStarted).
function Get-PhaseStatus {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [int]$Phase
    )

    $Key = "$Phase"
    if ($State.Phases -and $State.Phases.ContainsKey($Key)) {
        $PhaseData = $State.Phases[$Key]
        if ($PhaseData -is [hashtable] -and $PhaseData.ContainsKey('Status')) {
            return $PhaseData.Status
        }
    }
    return 'NotStarted'
}

# Marks phase done with timestamp.
function Set-PhaseCompleted {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [int]$Phase
    )

    $Key = "$Phase"
    if (-not $State.Phases.ContainsKey($Key)) {
        $State.Phases[$Key] = @{ Checklist = @{} }
    }
    $State.Phases[$Key].Status = 'Completed'
    $State.Phases[$Key].CompletedAt = [datetime]::UtcNow.ToString('o')
}

# Marks phase in progress.
function Set-PhaseInProgress {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [int]$Phase
    )

    $Key = "$Phase"
    if (-not $State.Phases.ContainsKey($Key)) {
        $State.Phases[$Key] = @{ Checklist = @{} }
    }
    $State.Phases[$Key].Status = 'InProgress'
    if (-not $State.Phases[$Key].ContainsKey('StartedAt')) {
        $State.Phases[$Key].StartedAt = [datetime]::UtcNow.ToString('o')
    }
}

# Sets a checklist item for a phase.
function Update-PhaseChecklist {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [int]$Phase,
        [Parameter(Mandatory)] [string]$Item,
        $Value = $true
    )

    $Key = "$Phase"
    if (-not $State.Phases.ContainsKey($Key)) {
        $State.Phases[$Key] = @{ Status = 'NotStarted'; Checklist = @{} }
    }
    if (-not $State.Phases[$Key].ContainsKey('Checklist')) {
        $State.Phases[$Key].Checklist = @{}
    }
    $State.Phases[$Key].Checklist[$Item] = $Value
}

# Appends diagnostic run result to Phase 3 history.
function Add-DiagnosticSnapshot {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [bool]$OK,
        [Parameter(Mandatory)] [int]$IssueCount
    )

    $Key = '3'
    if (-not $State.Phases.ContainsKey($Key)) {
        $State.Phases[$Key] = @{ Status = 'NotStarted'; Checklist = @{} }
    }
    if (-not $State.Phases[$Key].ContainsKey('DiagnosticHistory')) {
        $State.Phases[$Key].DiagnosticHistory = @()
    }

    $Snapshot = @{
        Timestamp = [datetime]::UtcNow.ToString('o')
        OK        = $OK
        Issues    = $IssueCount
    }

    $State.Phases[$Key].DiagnosticHistory = @($State.Phases[$Key].DiagnosticHistory) + @($Snapshot)
}

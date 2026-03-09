<#
    .SYNOPSIS
    Validates session graph index integrity by comparing the stored index
    against current repository state.

    .DESCRIPTION
    This file contains Test-SessionGraphIntegrity which performs 5 validation checks:

    1. IndexMissing:      _index.json does not exist (graph never built)
    2. StaleNameVersion:  entity name set changed since last build (Tier 2 invalid)
    3. OrphanedSessions:  session header in index but not in current repo
    4. MissingSessions:   session header in repo but not in index
    5. EmptySessions:     index entries with zero participants

    Returns a structured diagnostic object following the same pattern as
    Test-SessionIntegrity: an OK boolean and categorized arrays.

    Dot-sources:
    - private/session-graphhelpers.ps1 (index I/O, NameIndexVersion)
    - private/session-hashhelpers.ps1 (Get-ContentHash via NameIndexVersion)
    - private/admin-config.ps1 (ResDir resolution)
#>

function Test-SessionGraphIntegrity {
    <#
        .SYNOPSIS
        Validates session graph index integrity against current repository state.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Directories to exclude from session scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Load helpers
    if (-not (Get-Command 'Read-SessionGraphIndex' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/session-graphhelpers.ps1"
    }
    if (-not (Get-Command 'Get-ContentHash' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/session-hashhelpers.ps1"
    }
    if (-not (Get-Command 'Get-AdminConfig' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/admin-config.ps1"
    }

    $Config = Get-AdminConfig
    $GraphDir = [System.IO.Path]::Combine($Config.ResDir, 'session-graph')
    $IndexPath = [System.IO.Path]::Combine($GraphDir, '_index.json')
    $MetaPath = [System.IO.Path]::Combine($GraphDir, '_meta.json')

    # Result collections
    $OrphanedSessions  = [System.Collections.Generic.List[object]]::new()
    $MissingSessions   = [System.Collections.Generic.List[object]]::new()
    $EmptySessions     = [System.Collections.Generic.List[object]]::new()
    $StaleNameVersion  = [System.Collections.Generic.List[object]]::new()

    # Check 1: Index existence
    $IndexMissing = -not [System.IO.File]::Exists($IndexPath)

    if ($IndexMissing) {
        return [PSCustomObject]@{
            OK                = $false
            IndexMissing      = $true
            StaleNameVersion  = @()
            OrphanedSessions  = @()
            MissingSessions   = @()
            EmptySessions     = @()
        }
    }

    $Index = Read-SessionGraphIndex -IndexPath $IndexPath
    $Meta = Read-SessionGraphMeta -MetaPath $MetaPath

    # Check 2: Stale name version
    $StoredNameVersion = $Meta['NameIndexVersion']
    if ($StoredNameVersion) {
        $AllEntityNames = [System.Collections.Generic.List[string]]::new()
        $NameIdx = Get-NameIndex
        foreach ($Key in $NameIdx.Index.Keys) {
            [void]$AllEntityNames.Add($Key)
        }
        $CurrentNameVersion = Get-NameIndexVersion -Names @($AllEntityNames)

        if (-not [string]::Equals($StoredNameVersion, $CurrentNameVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
            $StaleNameVersion.Add([PSCustomObject]@{
                StoredVersion  = $StoredNameVersion
                CurrentVersion = $CurrentNameVersion
                Issue          = "Entity name set changed since last graph build; Tier 2 matches may be invalid"
            })
        }
    }

    # Check 5: Empty sessions (check before Get-Session to avoid confusion)
    foreach ($Header in $Index.Keys) {
        $Entry = $Index[$Header]
        $ParticipantCount = 0
        if ($Entry.ContainsKey('Participants') -and $Entry['Participants']) {
            $ParticipantCount = $Entry['Participants'].Count
        }
        if ($ParticipantCount -eq 0) {
            $EmptySessions.Add([PSCustomObject]@{
                Header = $Header
                Date   = if ($Entry.ContainsKey('Date')) { $Entry['Date'] } else { $null }
                Issue  = "Session has zero participants in graph index"
            })
        }
    }

    # Load current sessions for orphan/missing checks
    $GetSessionArgs = @{}
    if ($ExcludeDirectory) { $GetSessionArgs['ExcludeDirectory'] = $ExcludeDirectory }
    $AllSessions = @(Get-Session @GetSessionArgs)

    $CurrentHeaders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Session in $AllSessions) {
        if (-not [string]::IsNullOrWhiteSpace($Session.Header)) {
            [void]$CurrentHeaders.Add($Session.Header)
        }
    }

    # Check 3: Orphaned sessions (in index but not in repo)
    foreach ($Header in $Index.Keys) {
        if (-not $CurrentHeaders.Contains($Header)) {
            $Entry = $Index[$Header]
            $OrphanedSessions.Add([PSCustomObject]@{
                Header = $Header
                Date   = if ($Entry.ContainsKey('Date')) { $Entry['Date'] } else { $null }
                Issue  = "Session header in graph index but not found in repository"
            })
        }
    }

    # Check 4: Missing sessions (in repo but not in index)
    $IndexHeaders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Key in $Index.Keys) {
        [void]$IndexHeaders.Add($Key)
    }
    foreach ($Session in $AllSessions) {
        if ([string]::IsNullOrWhiteSpace($Session.Header)) { continue }
        if (-not $IndexHeaders.Contains($Session.Header)) {
            $MissingSessions.Add([PSCustomObject]@{
                Header   = $Session.Header
                Date     = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { $null }
                FilePath = $Session.FilePath
                Issue    = "Session exists in repository but not in graph index"
            })
        }
    }

    $AllOK = $OrphanedSessions.Count -eq 0 -and
             $MissingSessions.Count -eq 0 -and
             $EmptySessions.Count -eq 0 -and
             $StaleNameVersion.Count -eq 0

    return [PSCustomObject]@{
        OK                = $AllOK
        IndexMissing      = $false
        StaleNameVersion  = $StaleNameVersion.ToArray()
        OrphanedSessions  = $OrphanedSessions.ToArray()
        MissingSessions   = $MissingSessions.ToArray()
        EmptySessions     = $EmptySessions.ToArray()
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

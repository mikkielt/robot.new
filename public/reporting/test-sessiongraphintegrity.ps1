<#
    .SYNOPSIS
    Validates session graph index integrity by comparing the stored index
    against current repository state.

    .DESCRIPTION
    This file contains Test-SessionGraphIntegrity which performs 5 validation
    checks against the session graph index:

    1. IndexMissing:     _index.json does not exist (graph never built).
                         Returns immediately with OK=$false.
    2. StaleNameVersion: entity name set changed since last build. Detected
                         by comparing the NameIndexVersion hash stored in
                         _meta.json against a freshly computed version from
                         Get-NameIndex. Indicates Tier 2 body-text matches
                         may be invalid.
    3. OrphanedSessions: session header present in index but not found in
                         current repository (session was renamed/deleted
                         after graph build).
    4. MissingSessions:  session header exists in repository but is absent
                         from the index (new session added since last build).
    5. EmptySessions:    index entries with zero participants (may indicate
                         a build failure or empty session content).

    Pipeline:
    1. Check index file existence (early return if missing)
    2. Load index and metadata via Read-SessionGraphIndex / Read-SessionGraphMeta
    3. Compare stored NameIndexVersion against current (check 2)
    4. Scan index for zero-participant entries (check 5, done before
       Get-Session to avoid conflating build issues with repo changes)
    5. Load current sessions and build HashSet of known headers
    6. Cross-reference index headers vs repo headers for orphan/missing
       detection (checks 3, 4)

    Returns a structured diagnostic object with OK boolean and categorized
    arrays, following the same pattern as Test-SessionIntegrity.
#>

function Test-SessionGraphIntegrity {
    <#
        .SYNOPSIS
        Validates the session graph index against current repository state.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Directories to exclude from session scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session (avoids redundant load)")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Pre-fetched name index from Get-NameIndex (avoids redundant load)")]
        [object]$NameIndex,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Lazy-load helpers to avoid import overhead when called from modules that already loaded them
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

    # Each check category accumulates its own list for structured output
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
        $NameIdx = if ($PSBoundParameters.ContainsKey('NameIndex') -and $NameIndex) { $NameIndex } else { Get-NameIndex }
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

    # Check 5: Empty sessions — checked before Get-Session to distinguish build
    # failures from repository changes
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

    # Load current repo sessions for cross-reference against index
    if ($PSBoundParameters.ContainsKey('Sessions') -and $Sessions) {
        $AllSessions = @($Sessions)
    }
    else {
        $GetSessionArgs = @{}
        if ($ExcludeDirectory) { $GetSessionArgs['ExcludeDirectory'] = $ExcludeDirectory }
        $AllSessions = @(Get-Session @GetSessionArgs)
    }

    $CurrentHeaders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $script:ProgressSessIdx = 0
    $script:ProgressSessTotal = $AllSessions.Count

    foreach ($Session in $AllSessions) {
        $script:ProgressSessIdx++
        if ($ProgressCallback -and ($script:ProgressSessIdx % 10 -eq 0 -or $script:ProgressSessIdx -eq $script:ProgressSessTotal)) {
            & $ProgressCallback $script:ProgressSessIdx $script:ProgressSessTotal $null
        }

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

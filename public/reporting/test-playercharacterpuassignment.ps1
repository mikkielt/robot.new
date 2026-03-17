<#
    .SYNOPSIS
    Detects unresolved character names and PU assignment inconsistencies.

    .DESCRIPTION
    This file contains Test-PlayerCharacterPUAssignment which runs the PU
    assignment pipeline in compute-only mode (WhatIf) and validates five
    categories of issues:

    1. UnresolvedCharacters: PU entries whose character name didn't match
       any known character in the player roster. Caught via
       ThrowTerminatingError with ErrorId 'UnresolvedPUCharacters' from
       Invoke-PlayerCharacterPUAssignment.
    2. MalformedPU:          entries with null or non-numeric PU values.
    3. DuplicateEntries:     same character appearing in multiple PU lines
                             within a single session.
    4. FailedSessionsWithPU: sessions that failed date parsing (e.g.
                             "2024-1-5") but whose content contains
                             PU-resolvable sections. The normal pipeline
                             silently drops these; this diagnostic
                             surfaces them by scanning raw content.
    5. StaleHistoryEntries:  headers in pu-sessions.json that no longer
                             match any session in the repository.

    Module-level data:
    - $script:PULikePattern: precompiled regex matching PU-like child
      lines (e.g. "  - CharName: 0,3") for failed session scanning
    - $script:PUSectionPattern: canonical definition in
      private/session-parsehelpers.ps1 (available via module scope)

    Pipeline:
    1. Run Invoke-PlayerCharacterPUAssignment with -WhatIf to compute
       assignments without side effects; catch UnresolvedPUCharacters
       error and extract structured TargetObject
    2. Fetch all sessions including failed ones with IncludeContent
    3. For failed sessions: scan raw content for PU section markers and
       PU-like child lines to detect silently dropped data
    4. For parsed sessions: check PU entries for null values and
       duplicate character names within the same session
    5. Cross-reference pu-sessions.json history against all known session
       headers to detect stale entries

    Returns a structured diagnostic object with OK boolean and categorized
    arrays, allowing callers to programmatically inspect results.

    Default range: last 2 months (legacy parity with
    Invoke-PlayerCharacterPUAssignmentCorrectnessCheckup).
#>

. "$script:ModuleRoot/private/admin-state.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

# Matches indented list items with "Name: numericValue" pattern for PU detection in raw content
$script:PULikePattern = [regex]::new('^\s+[-\*]\s+(.+?):\s*([\d,\.]+)\s*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# $script:PUSectionPattern — canonical definition in private/session-parsehelpers.ps1
# (available via module scope; loaded by get-session.ps1 at import time)

function Test-PlayerCharacterPUAssignment {
    <#
        .SYNOPSIS
        Validates PU assignment data for unresolved character names and data inconsistencies.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Year for the check period")]
        [int]$Year,

        [Parameter(HelpMessage = "Month for the check period")]
        [int]$Month,

        [Parameter(HelpMessage = "Start date for custom date range")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "End date for custom date range")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Directories to exclude from session file scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Pre-fetched full session list for stale history detection (avoids redundant Get-Session call)")]
        [object[]]$AllSessions,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Default to last 2 months to match legacy Invoke-PlayerCharacterPUAssignmentCorrectnessCheckup behavior
    if (-not $Year -and -not $Month -and -not $PSBoundParameters.ContainsKey('MinDate')) {
        $Now = [datetime]::Now
        $MinDate = [datetime]::new($Now.AddMonths(-1).Year, $Now.AddMonths(-1).Month, 1)
    }
    if (-not $Year -and -not $Month -and -not $PSBoundParameters.ContainsKey('MaxDate')) {
        $MaxDate = [datetime]::Now.AddDays(1)
    }

    # Mirror the user's date parameters to the assignment pipeline
    $AssignParams = @{}
    if ($Year) { $AssignParams['Year'] = $Year }
    if ($Month) { $AssignParams['Month'] = $Month }
    if ($PSBoundParameters.ContainsKey('MinDate')) { $AssignParams['MinDate'] = $MinDate }
    if ($PSBoundParameters.ContainsKey('MaxDate')) { $AssignParams['MaxDate'] = $MaxDate }
    if ($ExcludeDirectory) { $AssignParams['ExcludeDirectory'] = $ExcludeDirectory }

    # WhatIf prevents ShouldProcess writes; fail-early throws on unresolved characters
    # are caught here and converted to diagnostic entries via TargetObject extraction
    $Results = $null
    $UnresolvedCharacters = [System.Collections.Generic.List[object]]::new()
    $MalformedPU = [System.Collections.Generic.List[object]]::new()
    $DuplicateEntries = [System.Collections.Generic.List[object]]::new()
    $FailedSessionsWithPU = [System.Collections.Generic.List[object]]::new()
    $StaleHistoryEntries = [System.Collections.Generic.List[object]]::new()

    try {
        $Results = Invoke-PlayerCharacterPUAssignment @AssignParams -WhatIf
    } catch {
        if ($_.FullyQualifiedErrorId -eq 'UnresolvedPUCharacters,Invoke-PlayerCharacterPUAssignment') {
            # TargetObject contains the structured unresolved character array
            foreach ($Unresolved in $_.TargetObject) {
                $UnresolvedCharacters.Add($Unresolved)
            }
        } else {
            throw
        }
    }

    # IncludeContent is needed to scan failed session bodies for PU-like patterns
    # that the normal pipeline silently drops due to date parse failures
    $SessionParams = @{ IncludeFailed = $true; IncludeContent = $true }
    if ($Year -and $Month) {
        $DMinDate = [datetime]::new($Year, $Month, 1)
        $DMaxDate = $DMinDate.AddMonths(1).AddDays(-1)
        $SessionParams['MinDate'] = $DMinDate
        $SessionParams['MaxDate'] = $DMaxDate
    } else {
        $SessionParams['MinDate'] = $MinDate
        $SessionParams['MaxDate'] = $MaxDate
    }
    if ($ExcludeDirectory) { $SessionParams['ExcludeDirectory'] = $ExcludeDirectory }

    if (-not $PSBoundParameters.ContainsKey('AllSessions')) {
        $AllSessions = Get-Session @SessionParams
    }

    $script:ProgressSessIdx = 0
    $script:ProgressSessTotal = $AllSessions.Count

    foreach ($Session in $AllSessions) {
        $script:ProgressSessIdx++
        if ($ProgressCallback -and ($script:ProgressSessIdx % 10 -eq 0 -or $script:ProgressSessIdx -eq $script:ProgressSessTotal)) {
            & $ProgressCallback $script:ProgressSessIdx $script:ProgressSessTotal $null
        }

        # Scan failed sessions for PU-like content that was silently dropped
        if ($null -ne $Session.ParseError) {
            if (-not $Session.Content) { continue }

            $ContentLines = $Session.Content.Split([char]"`n")
            $InPUSection = $false
            $PUCandidates = [System.Collections.Generic.List[string]]::new()

            foreach ($Line in $ContentLines) {
                if ($script:PUSectionPattern.IsMatch($Line)) {
                    $InPUSection = $true
                    continue
                }

                if ($InPUSection) {
                    $Trimmed = $Line.TrimEnd()

                    # PU sections end at blank lines or non-indented content
                    if ([string]::IsNullOrWhiteSpace($Trimmed)) {
                        $InPUSection = $false
                        continue
                    }
                    if ($Trimmed.Length -gt 0 -and $Trimmed[0] -ne ' ' -and $Trimmed[0] -ne "`t") {
                        $InPUSection = $false
                        continue
                    }

                    $PUMatch = $script:PULikePattern.Match($Trimmed)
                    if ($PUMatch.Success) {
                        $PUCandidates.Add($PUMatch.Groups[1].Value.Trim())
                    }
                }
            }

            if ($PUCandidates.Count -gt 0) {
                $FailedSessionsWithPU.Add([PSCustomObject]@{
                    Header       = $Session.Header
                    FilePath     = $Session.FilePath
                    ParseError   = $Session.ParseError
                    PUCandidates = $PUCandidates.ToArray()
                })
            }

            continue
        }

        # Parsed sessions: validate PU values and detect duplicate character entries
        if (-not $Session.PU -or $Session.PU.Count -eq 0) { continue }

        $SeenCharacters = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($PUEntry in $Session.PU) {
            if ($null -eq $PUEntry.Value) {
                $MalformedPU.Add([PSCustomObject]@{
                    CharacterName = $PUEntry.Character
                    SessionHeader = $Session.Header
                    RawValue      = $null
                    Issue         = "Null PU value"
                })
            }

            $CName = $PUEntry.Character
            if ($SeenCharacters.ContainsKey($CName)) {
                $SeenCharacters[$CName]++
                if ($SeenCharacters[$CName] -eq 2) {
                    $DuplicateEntries.Add([PSCustomObject]@{
                        CharacterName = $CName
                        SessionHeader = $Session.Header
                        Count         = $SeenCharacters[$CName]
                    })
                }
            } else {
                $SeenCharacters[$CName] = 1
            }
        }
    }

    # Stale detection: headers in pu-sessions.json that no longer match any
    # repository session (renamed, deleted, or manually corrupted entries)
    $Config = Get-AdminConfig
    $PUSessionsPath = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.json')
    $HistoryHeaders = Get-AdminHistoryEntries -Path $PUSessionsPath

    if ($HistoryHeaders.Count -gt 0) {
        # Stale detection needs ALL headers, not just date-filtered ones
        if ($PSBoundParameters.ContainsKey('AllSessions') -and $AllSessions) {
            $AllRepoSessions = $AllSessions
        }
        else {
            $GetAllParams = @{}
            if ($ExcludeDirectory) { $GetAllParams['ExcludeDirectory'] = $ExcludeDirectory }
            $AllRepoSessions = Get-Session @GetAllParams
        }
        $KnownHeaders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($S in $AllRepoSessions) {
            $H = $S.Header.Trim()
            [void]$KnownHeaders.Add($H)
            # History entries are stored without ### prefix — add both forms for matching
            if ($H.StartsWith('### ')) {
                [void]$KnownHeaders.Add($H.Substring(4))
            }
        }

        foreach ($HistoryHeader in $HistoryHeaders) {
            if (-not $KnownHeaders.Contains($HistoryHeader)) {
                $StaleHistoryEntries.Add([PSCustomObject]@{
                    Header = $HistoryHeader
                    Issue  = "Header in pu-sessions.json not found in any repository session"
                })
            }
        }
    }

    # OK only reflects actionable issues; FailedSessionsWithPU and StaleHistoryEntries
    # are informational (fixes belong in Phase 4: format upgrade + mass review)
    $AllOK = $UnresolvedCharacters.Count -eq 0 -and
             $MalformedPU.Count -eq 0 -and
             $DuplicateEntries.Count -eq 0

    return [PSCustomObject]@{
        OK                   = $AllOK
        UnresolvedCharacters = $UnresolvedCharacters.ToArray()
        MalformedPU          = $MalformedPU.ToArray()
        DuplicateEntries     = $DuplicateEntries.ToArray()
        FailedSessionsWithPU = $FailedSessionsWithPU.ToArray()
        StaleHistoryEntries  = $StaleHistoryEntries.ToArray()
        AssignmentResults    = $Results
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

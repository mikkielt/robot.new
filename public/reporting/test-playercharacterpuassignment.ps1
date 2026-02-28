<#
    .SYNOPSIS
    Detects unresolved character names and PU assignment inconsistencies.

    .DESCRIPTION
    This file contains Test-PlayerCharacterPUAssignment which runs the PU
    assignment pipeline in compute-only mode (no side-effect switches) and
    validates:

    - Unresolved characters: PU entries whose character name didn't match
      any known character in the player roster.
    - Malformed PU values: entries with null or non-numeric PU values.
    - Duplicate entries: same character appearing in multiple PU lines
      within a single session.
    - Failed sessions with PU data: sessions that failed date parsing
      (e.g. wrong date format like "2024-1-5" or "2024-13-01") but whose
      content contains PU-resolvable sections. These are silently dropped
      by the normal pipeline - this diagnostic surfaces them.
    - Stale history entries: headers in pu-sessions.md that no longer
      match any session found in the repository (renamed/deleted/corrupted).

    Returns a structured diagnostic object, not just console output. This
    allows callers to programmatically inspect results.

    Default range: last 2 months (matches legacy behavior from
    Invoke-PlayerCharacterPUAssignmentCorrectnessCheckup).

    Dot-sources admin-state.ps1 and admin-config.ps1 for state file access.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/admin-state.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

# Precompiled pattern matching PU-like child lines: "  - CharName: 0,3"
$script:PULikePattern = [regex]::new('^\s+[-\*]\s+(.+?):\s*([\d,\.]+)\s*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Pattern matching PU section headers in content: "- PU:" or "- @PU:"
$script:PUSectionPattern = [regex]::new('^\s*[-\*]\s+@?[Pp][Uu]\s*:', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Test-PlayerCharacterPUAssignment {
    <#
        .SYNOPSIS
        Validates PU assignment data for unresolved names and inconsistencies.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Year for the check period")]
        [int]$Year,

        [Parameter(HelpMessage = "Month for the check period")]
        [int]$Month,

        [Parameter(HelpMessage = "Start date for custom date range")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "End date for custom date range")]
        [datetime]$MaxDate
    )

    # Default: last 2 months (legacy parity)
    if (-not $Year -and -not $Month -and -not $PSBoundParameters.ContainsKey('MinDate')) {
        $Now = [datetime]::Now
        $MinDate = [datetime]::new($Now.AddMonths(-1).Year, $Now.AddMonths(-1).Month, 1)
    }
    if (-not $Year -and -not $Month -and -not $PSBoundParameters.ContainsKey('MaxDate')) {
        $MaxDate = [datetime]::Now.AddDays(1)
    }

    # Build params for the assignment call
    $AssignParams = @{}
    if ($Year) { $AssignParams['Year'] = $Year }
    if ($Month) { $AssignParams['Month'] = $Month }
    if ($PSBoundParameters.ContainsKey('MinDate')) { $AssignParams['MinDate'] = $MinDate }
    if ($PSBoundParameters.ContainsKey('MaxDate')) { $AssignParams['MaxDate'] = $MaxDate }

    # Run compute-only (no switches) - WhatIf:$true prevents any ShouldProcess writes.
    # Invoke- now throws on unresolved characters (fail-early), so we catch and
    # extract the structured TargetObject for the diagnostic report.
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
            # Extract structured unresolved character data from TargetObject
            foreach ($Unresolved in $_.TargetObject) {
                $UnresolvedCharacters.Add($Unresolved)
            }
        } else {
            throw
        }
    }

    # Get all sessions including failed ones - IncludeContent needed to scan
    # failed session bodies for PU-like patterns that the pipeline missed
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

    $AllSessions = Get-Session @SessionParams

    foreach ($Session in $AllSessions) {
        # Failed sessions: scan content for PU data that was silently dropped
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

                    # Blank line or non-indented line ends the PU section
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

        # Successfully parsed sessions: check for malformed PU and duplicates
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

    # Cross-reference pu-sessions.md history against actual repository sessions.
    # Stale entries = headers logged as processed that no longer match any session
    # (renamed, deleted, or manually corrupted entries in the history file).
    $Config = Get-AdminConfig
    $PUSessionsPath = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.md')
    $HistoryHeaders = Get-AdminHistoryEntries -Path $PUSessionsPath

    if ($HistoryHeaders.Count -gt 0) {
        # Build a set of all known session headers across the full repo
        # (not date-filtered - stale detection needs the complete picture)
        $AllRepoSessions = Get-Session
        $KnownHeaders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($S in $AllRepoSessions) {
            $H = $S.Header.Trim()
            [void]$KnownHeaders.Add($H)
            # History entries are stored without ### prefix, so add both forms
            if ($H.StartsWith('### ')) {
                [void]$KnownHeaders.Add($H.Substring(4))
            }
        }

        foreach ($HistoryHeader in $HistoryHeaders) {
            if (-not $KnownHeaders.Contains($HistoryHeader)) {
                $StaleHistoryEntries.Add([PSCustomObject]@{
                    Header = $HistoryHeader
                    Issue  = "Header in pu-sessions.md not found in any repository session"
                })
            }
        }
    }

    $AllOK = $UnresolvedCharacters.Count -eq 0 -and
             $MalformedPU.Count -eq 0 -and
             $DuplicateEntries.Count -eq 0 -and
             $FailedSessionsWithPU.Count -eq 0 -and
             $StaleHistoryEntries.Count -eq 0

    return [PSCustomObject]@{
        OK                   = $AllOK
        UnresolvedCharacters = $UnresolvedCharacters.ToArray()
        MalformedPU          = $MalformedPU.ToArray()
        DuplicateEntries     = $DuplicateEntries.ToArray()
        FailedSessionsWithPU = $FailedSessionsWithPU.ToArray()
        StaleHistoryEntries  = $StaleHistoryEntries.ToArray()
        AssignmentResults    = $Results
    }
}

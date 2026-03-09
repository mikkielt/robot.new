<#
    .SYNOPSIS
    Builds and maintains a persistent session participation graph index.

    .DESCRIPTION
    This file contains Set-SessionGraph, which builds a participation index
    mapping sessions to their involved entities across three tiers:
    - Tier 0 (Filesystem): session file placed in entity directory
    - Tier 1 (Structured): entity in PU, @Zmiany, @Transfer, @Intel metadata
    - Tier 2 (Body Text): entity name mentioned in session body

    The index is stored as a single JSON file at {ResDir}/session-graph/_index.json
    (not per-file sidecars, because sessions span multiple files).

    Supports two modes:
    - Full (-Full): processes all sessions
    - Incremental (default): uses Get-GitChangeLog to find changed files,
      then processes only sessions whose FilePaths overlap

    Helpers:
    - Dot-sources private/session-graphhelpers.ps1 for classification/I/O
    - Dot-sources private/session-hashhelpers.ps1 for Get-ContentHash
    - Dot-sources private/admin-config.ps1 for ResDir resolution
#>

function Set-SessionGraph {
    <#
        .SYNOPSIS
        Build or update the persistent session participation graph index.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')] param(
        [Parameter(HelpMessage = "Rebuild entire index, not just changed sessions")]
        [switch]$Full,

        [Parameter(HelpMessage = "Only process sessions changed since this date (for incremental mode)")]
        [string]$Since,

        [Parameter(HelpMessage = "Directories to exclude from session scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Load helpers
    if (-not (Get-Command 'Get-FilePathInvolvement' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/session-graphhelpers.ps1"
    }
    if (-not (Get-Command 'Get-ContentHash' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/session-hashhelpers.ps1"
    }
    if (-not (Get-Command 'Get-AdminConfig' -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/../../private/admin-config.ps1"
    }

    $Config = Get-AdminConfig
    $RepoRoot = $Config.RepoRoot
    $GraphDir = [System.IO.Path]::Combine($Config.ResDir, 'session-graph')
    $IndexPath = [System.IO.Path]::Combine($GraphDir, '_index.json')
    $MetaPath = [System.IO.Path]::Combine($GraphDir, '_meta.json')

    # Read existing metadata
    $Meta = Read-SessionGraphMeta -MetaPath $MetaPath
    $StoredNameVersion = $Meta['NameIndexVersion']

    # Determine scope: full vs incremental
    $IsFullScan = $Full.IsPresent
    $ChangedFilePaths = $null

    if (-not $IsFullScan) {
        $MinDateStr = $Since
        if (-not $MinDateStr) {
            $MinDateStr = $Meta['LastIncrementalUpdate']
        }

        if ($MinDateStr) {
            try {
                $GitArgs = @{ NoPatch = $true; MinDate = $MinDateStr }
                $GitLog = Get-GitChangeLog @GitArgs

                $ChangedFilePaths = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)

                foreach ($Commit in $GitLog) {
                    foreach ($CF in $Commit.Files) {
                        if ($null -eq $CF.Path) { continue }
                        if (-not $CF.Path.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                        [void]$ChangedFilePaths.Add($CF.Path)
                    }
                }
            } catch {
                Write-RobotWarning "[WARN Set-SessionGraph] Git changelog failed: $_. Falling back to full scan."
                $IsFullScan = $true
            }
        } else {
            # No previous timestamp — full scan needed
            $IsFullScan = $true
        }
    }

    # Fetch all sessions with mentions (needed for Tier 2)
    $GetSessionArgs = @{ IncludeMentions = $true }
    if ($ExcludeDirectory) { $GetSessionArgs['ExcludeDirectory'] = $ExcludeDirectory }
    $AllSessions = @(Get-Session @GetSessionArgs)

    if ($AllSessions.Count -eq 0) {
        return [PSCustomObject]@{
            SessionsProcessed = 0
            ParticipantsFound = 0
            Tier0Count        = 0
            Tier1Count        = 0
            Tier2Count        = 0
        }
    }

    # Compute NameIndex version to detect entity name set changes
    $AllEntityNames = [System.Collections.Generic.List[string]]::new()
    $NameIdx = Get-NameIndex
    foreach ($Key in $NameIdx.Index.Keys) {
        [void]$AllEntityNames.Add($Key)
    }
    $CurrentNameVersion = Get-NameIndexVersion -Names @($AllEntityNames)

    # If name set changed, force full rebuild (Tier 2 matches may differ)
    $NameSetChanged = $false
    if ($StoredNameVersion -and -not [string]::Equals($StoredNameVersion, $CurrentNameVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        $NameSetChanged = $true
        $IsFullScan = $true
    }

    # Determine which sessions to process
    $SessionsToProcess = [System.Collections.Generic.List[object]]::new()

    if ($IsFullScan) {
        $SessionsToProcess.AddRange($AllSessions)
    } else {
        # Incremental: only sessions whose FilePaths overlap with changed files
        foreach ($Session in $AllSessions) {
            if (-not $Session.FilePaths) { continue }
            $Affected = $false
            foreach ($FP in $Session.FilePaths) {
                $NormFP = $FP.Replace('\', '/')
                if ($ChangedFilePaths.Contains($NormFP)) {
                    $Affected = $true
                    break
                }
            }
            if ($Affected) {
                [void]$SessionsToProcess.Add($Session)
            }
        }
    }

    if ($SessionsToProcess.Count -eq 0) {
        return [PSCustomObject]@{
            SessionsProcessed = 0
            ParticipantsFound = 0
            Tier0Count        = 0
            Tier1Count        = 0
            Tier2Count        = 0
        }
    }

    # Load existing index for incremental merge
    $Index = if ($IsFullScan) { @{} } else { Read-SessionGraphIndex -IndexPath $IndexPath }

    $TotalParticipants = 0
    $Tier0Total = 0
    $Tier1Total = 0
    $Tier2Total = 0

    foreach ($Session in $SessionsToProcess) {
        $Header = $Session.Header
        if ([string]::IsNullOrWhiteSpace($Header)) { continue }

        $Participants = ConvertTo-ParticipantRecord -Session $Session

        # Count by tier
        foreach ($P in $Participants) {
            $TotalParticipants++
            switch ($P.Tier) {
                0 { $Tier0Total++ }
                1 { $Tier1Total++ }
                2 { $Tier2Total++ }
            }
        }

        # Build index entry
        $DateStr = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { $null }
        $Format = if ($Session.PSObject.Properties['Format']) { $Session.Format } else { $null }

        # Serialize participants for JSON storage
        $ParticipantList = [System.Collections.Generic.List[object]]::new()
        foreach ($P in $Participants) {
            [void]$ParticipantList.Add(@{
                Name   = $P.Name
                Type   = $P.Type
                Tier   = $P.Tier
                Source = $P.Source
                Weight = $P.Weight
            })
        }

        $Index[$Header] = @{
            Date         = $DateStr
            Format       = $Format
            Participants = @($ParticipantList)
            FilePaths    = @($Session.FilePaths)
        }
    }

    # Write index
    if ($PSCmdlet.ShouldProcess('_index.json', 'Update session graph index')) {
        Write-SessionGraphIndex -IndexPath $IndexPath -Index $Index
    }

    # Update metadata
    $Now = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    if ($IsFullScan) {
        $Meta['LastFullUpdate'] = $Now
    }
    $Meta['LastIncrementalUpdate'] = $Now
    $Meta['NameIndexVersion'] = $CurrentNameVersion
    $Meta['SessionCount'] = $Index.Count

    if ($PSCmdlet.ShouldProcess('_meta.json', 'Update session graph metadata')) {
        Write-SessionGraphMeta -MetaPath $MetaPath -Meta $Meta
    }

    return [PSCustomObject]@{
        SessionsProcessed = $SessionsToProcess.Count
        ParticipantsFound = $TotalParticipants
        Tier0Count        = $Tier0Total
        Tier1Count        = $Tier1Total
        Tier2Count        = $Tier2Total
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

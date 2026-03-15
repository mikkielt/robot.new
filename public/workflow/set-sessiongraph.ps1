<#
    .SYNOPSIS
    Builds and maintains a persistent session participation graph index.

    .DESCRIPTION
    This file contains Set-SessionGraph, which builds a participation index
    mapping sessions to their involved entities across three tiers:
    - Tier 0 (Filesystem): session file placed in entity's directory
    - Tier 1 (Structured): entity referenced in PU, @Zmiany, @Transfer, @Intel metadata
    - Tier 2 (Body Text): entity name mentioned in session body text

    The index is stored as a single JSON file at {ResDir}/session-graph/_index.json
    (not per-file sidecars, because sessions span multiple files and the
    index must deduplicate across them).

    Three operating modes:
    - Full (-Full): processes all sessions, rebuilds Tier 2 mentions,
      clears Tier2Stale flag on completion. Forced automatically when the
      NameIndex version changes (entity name set changed, so Tier 2 matches
      may differ).
    - Incremental (default): uses Get-GitChangeLog to find changed files,
      then processes only sessions whose FilePaths overlap. Falls back to
      full scan when git changelog fails or no previous timestamp exists.
    - EagerOnly (-EagerOnly): refreshes only Tiers 0+1 for sessions already
      in the index (no mention resolution). Used by Set-Session's per-write
      eager refresh to keep structured data current without O(n) name scans.

    Tier 2 mention cache (_mentions.json) stores resolved mentions keyed by
    NameIndexVersion + content hash. Cache hits avoid redundant name resolution
    on repeated full rebuilds when body content hasn't changed.

    Metadata (_meta.json) tracks LastFullUpdate, LastIncrementalUpdate,
    LastEagerRefresh, EagerRefreshCount, NameIndexVersion, SessionCount,
    and Tier2Stale flag.

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

        [Parameter(HelpMessage = "Only refresh Tiers 0+1 for changed sessions (no mention resolution)")]
        [switch]$EagerOnly,

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

    if ($script:HasOpCtx) { Clear-OperationContext }

    # Lazy-load helpers: only dot-source if not already loaded (avoids re-parsing on repeated calls)
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
    $MentionCachePath = [System.IO.Path]::Combine($GraphDir, '_mentions.json')

    # Metadata carries state between runs (last update times, name version, etc.)
    $Meta = Read-SessionGraphMeta -MetaPath $MetaPath
    $StoredNameVersion = $Meta['NameIndexVersion']

    # Determine scope: full rebuild vs incremental delta vs eager-only refresh
    $IsFullScan = $Full.IsPresent
    $IsEagerOnly = $EagerOnly.IsPresent
    $ChangedFilePaths = $null

    if (-not $IsFullScan -and -not $IsEagerOnly) {
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
            # No previous timestamp — first run requires full scan
            $IsFullScan = $true
        }
    }

    # EagerOnly skips mention resolution (Tier 2) to avoid O(n) name scanning
    $GetSessionArgs = @{}
    if (-not $IsEagerOnly) {
        $GetSessionArgs['IncludeMentions'] = $true
    }
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

    # NameIndex version hash detects when the entity name set changes,
    # which invalidates Tier 2 matches (different names = different mentions)
    $AllEntityNames = [System.Collections.Generic.List[string]]::new()
    $NameIdx = Get-NameIndex
    foreach ($Key in $NameIdx.Index.Keys) {
        [void]$AllEntityNames.Add($Key)
    }
    $CurrentNameVersion = Get-NameIndexVersion -Names @($AllEntityNames)

    # Name set change forces full rebuild — Tier 2 matches may differ with new entity names
    $NameSetChanged = $false
    if ($StoredNameVersion -and -not [string]::Equals($StoredNameVersion, $CurrentNameVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        $NameSetChanged = $true
        if (-not $IsEagerOnly) {
            $IsFullScan = $true
        }
    }

    # Scope selection: full takes all, eager takes indexed-only, incremental takes changed-only
    $SessionsToProcess = [System.Collections.Generic.List[object]]::new()

    if ($IsFullScan) {
        $SessionsToProcess.AddRange($AllSessions)
    } elseif ($IsEagerOnly) {
        # EagerOnly: process sessions that already exist in the index
        $ExistingIndex = Read-SessionGraphIndex -IndexPath $IndexPath
        foreach ($Session in $AllSessions) {
            if (-not $Session.Header) { continue }
            if ($ExistingIndex.ContainsKey($Session.Header)) {
                [void]$SessionsToProcess.Add($Session)
            }
        }
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

    # Full mode starts fresh; incremental/eager merge into the existing index
    $Index = if ($IsFullScan) { @{} } else { Read-SessionGraphIndex -IndexPath $IndexPath }

    # Mention cache avoids redundant Tier 2 name resolution when content hasn't changed
    $MentionCache = $null
    $MentionCacheUpdated = $false
    if ($IsFullScan -and -not $IsEagerOnly) {
        $MentionCache = Read-MentionCache -CachePath $MentionCachePath
    }

    $TotalParticipants = 0
    $Tier0Total = 0
    $Tier1Total = 0
    $Tier2Total = 0
    $Total = $SessionsToProcess.Count
    $Idx = 0

    foreach ($Session in $SessionsToProcess) {
        $Header = $Session.Header
        if ([string]::IsNullOrWhiteSpace($Header)) { continue }

        $Idx++

        # Progress bar only for full rebuilds (incremental is usually fast enough)
        if ($IsFullScan -and $Total -gt 10) {
            Write-Progress -Activity 'Budowanie grafu sesji' -Status "Sesja $Idx z $Total" -PercentComplete (($Idx / $Total) * 100)
        }

        if ($IsEagerOnly) {
            # EagerOnly: Update-SessionGraphEntry preserves existing Tier 2 data
            Update-SessionGraphEntry -SessionHeader $Header -Session $Session -Index $Index

            # Tally per-tier counts from the merged entry
            $UpdatedEntry = $Index[$Header]
            if ($UpdatedEntry -and $UpdatedEntry['Participants']) {
                foreach ($P in $UpdatedEntry['Participants']) {
                    $TotalParticipants++
                    $PTier = if ($P.ContainsKey('Tier')) { $P['Tier'] } else { 2 }
                    switch ($PTier) {
                        0 { $Tier0Total++ }
                        1 { $Tier1Total++ }
                        2 { $Tier2Total++ }
                    }
                }
            }
        } else {
            # Full/Incremental: check mention cache before expensive name resolution
            if ($MentionCache -and $Session.PSObject.Properties['BodyHash']) {
                $CachedMentions = Get-CachedMentions -SessionHeader $Header -NameIndexVersion $CurrentNameVersion -ContentHash $Session.BodyHash -Cache $MentionCache
                if ($null -ne $CachedMentions) {
                    # Cache hit — reuse previously resolved mentions
                    $Session | Add-Member -NotePropertyName 'Mentions' -NotePropertyValue $CachedMentions -Force
                } else {
                    # Cache miss — store resolved mentions for future runs
                    if ($Session.Mentions -and $Session.BodyHash) {
                        $MentionCache[$Header] = @{
                            CacheKey = "${CurrentNameVersion}:$($Session.BodyHash)"
                            Mentions = @($Session.Mentions)
                        }
                        $MentionCacheUpdated = $true
                    }
                }
            }

            $Participants = ConvertTo-ParticipantRecord -Session $Session

            # Tally per-tier counts for the summary output
            foreach ($P in $Participants) {
                $TotalParticipants++
                switch ($P.Tier) {
                    0 { $Tier0Total++ }
                    1 { $Tier1Total++ }
                    2 { $Tier2Total++ }
                }
            }

            # Build index entry with date, format, participants, and file paths
            $DateStr = if ($Session.Date) { $Session.Date.ToString('yyyy-MM-dd') } else { $null }
            $Format = if ($Session.PSObject.Properties['Format']) { $Session.Format } else { $null }

            # Flatten participant objects to hashtables for JSON serialization
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
    }

    # Dismiss progress bar
    if ($IsFullScan -and $Total -gt 10) {
        Write-Progress -Activity 'Budowanie grafu sesji' -Completed
    }

    # Persist index and metadata — both gated by ShouldProcess for -WhatIf
    if ($PSCmdlet.ShouldProcess('_index.json', 'Update session graph index')) {
        Write-SessionGraphIndex -IndexPath $IndexPath -Index $Index
    }

    # Persist mention cache only when new entries were added (avoid no-op writes)
    if ($MentionCacheUpdated -and $PSCmdlet.ShouldProcess('_mentions.json', 'Update mention cache')) {
        Write-MentionCache -CachePath $MentionCachePath -Cache $MentionCache
    }

    # Update metadata timestamps and counters for next incremental run
    $Now = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    if ($IsFullScan) {
        $Meta['LastFullUpdate'] = $Now
        # Full rebuild resolves all mentions — clear staleness flag
        $Meta['Tier2Stale'] = $false
        $Meta['Tier2StaleReason'] = $null
    }
    if ($IsEagerOnly) {
        $Meta['LastEagerRefresh'] = $Now
        $Meta['EagerRefreshCount'] = $Meta['EagerRefreshCount'] + 1
    }
    $Meta['LastIncrementalUpdate'] = $Now
    $Meta['NameIndexVersion'] = $CurrentNameVersion
    $Meta['SessionCount'] = $Index.Count

    if ($PSCmdlet.ShouldProcess('_meta.json', 'Update session graph metadata')) {
        Write-SessionGraphMeta -MetaPath $MetaPath -Meta $Meta
    }

    $ReturnObj = [PSCustomObject]@{
        SessionsProcessed = $SessionsToProcess.Count
        ParticipantsFound = $TotalParticipants
        Tier0Count        = $Tier0Total
        Tier1Count        = $Tier1Total
        Tier2Count        = $Tier2Total
    }

    if ($script:HasOpCtx) {
        $OpResult = New-OperationResult -Success $true -Action 'Update' `
            -TargetType 'SessionGraph' -TargetName "($($SessionsToProcess.Count) sessions)" -UndoHint $null
        $ReturnObj | Add-Member -NotePropertyName 'OperationResult' -NotePropertyValue $OpResult
    }

    return $ReturnObj

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

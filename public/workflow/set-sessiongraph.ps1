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

    Supports three modes:
    - Full (-Full): processes all sessions, rebuilds Tier 2 mentions,
      clears Tier2Stale flag on completion
    - Incremental (default): uses Get-GitChangeLog to find changed files,
      then processes only sessions whose FilePaths overlap
    - EagerOnly (-EagerOnly): refreshes only Tiers 0+1 for changed sessions
      (no mention resolution), used by Set-Session eager refresh

    Tier 2 mention cache (_mentions.json) stores resolved mentions keyed by
    NameIndexVersion + content hash, avoiding redundant name resolution on
    repeated full rebuilds.

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
    $MentionCachePath = [System.IO.Path]::Combine($GraphDir, '_mentions.json')

    # Read existing metadata
    $Meta = Read-SessionGraphMeta -MetaPath $MetaPath
    $StoredNameVersion = $Meta['NameIndexVersion']

    # Determine scope: full vs incremental
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
            # No previous timestamp — full scan needed
            $IsFullScan = $true
        }
    }

    # Fetch sessions (with or without mentions depending on mode)
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

    # Compute NameIndex version to detect entity name set changes
    $AllEntityNames = [System.Collections.Generic.List[string]]::new()
    $NameIdx = Get-NameIndex
    foreach ($Key in $NameIdx.Index.Keys) {
        [void]$AllEntityNames.Add($Key)
    }
    $CurrentNameVersion = Get-NameIndexVersion -Names @($AllEntityNames)

    # If name set changed and not EagerOnly, force full rebuild (Tier 2 matches may differ)
    $NameSetChanged = $false
    if ($StoredNameVersion -and -not [string]::Equals($StoredNameVersion, $CurrentNameVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        $NameSetChanged = $true
        if (-not $IsEagerOnly) {
            $IsFullScan = $true
        }
    }

    # Determine which sessions to process
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

    # Load existing index for incremental/eager merge
    $Index = if ($IsFullScan) { @{} } else { Read-SessionGraphIndex -IndexPath $IndexPath }

    # Load mention cache for full rebuilds (Tier 2 speedup)
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

        # Progress reporting for full rebuilds
        if ($IsFullScan -and $Total -gt 10) {
            Write-Progress -Activity 'Budowanie grafu sesji' -Status "Sesja $Idx z $Total" -PercentComplete (($Idx / $Total) * 100)
        }

        if ($IsEagerOnly) {
            # EagerOnly: use Update-SessionGraphEntry (preserves Tier 2)
            Update-SessionGraphEntry -SessionHeader $Header -Session $Session -Index $Index

            # Count from the updated entry
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
            # Full/Incremental: use mention cache if available
            if ($MentionCache -and $Session.PSObject.Properties['BodyHash']) {
                $CachedMentions = Get-CachedMentions -SessionHeader $Header -NameIndexVersion $CurrentNameVersion -ContentHash $Session.BodyHash -Cache $MentionCache
                if ($null -ne $CachedMentions) {
                    # Override session mentions with cached data
                    $Session | Add-Member -NotePropertyName 'Mentions' -NotePropertyValue $CachedMentions -Force
                } else {
                    # Cache miss: store resolved mentions for next time
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
    }

    # Complete progress bar
    if ($IsFullScan -and $Total -gt 10) {
        Write-Progress -Activity 'Budowanie grafu sesji' -Completed
    }

    # Write index
    if ($PSCmdlet.ShouldProcess('_index.json', 'Update session graph index')) {
        Write-SessionGraphIndex -IndexPath $IndexPath -Index $Index
    }

    # Write mention cache if updated
    if ($MentionCacheUpdated -and $PSCmdlet.ShouldProcess('_mentions.json', 'Update mention cache')) {
        Write-MentionCache -CachePath $MentionCachePath -Cache $MentionCache
    }

    # Update metadata
    $Now = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    if ($IsFullScan) {
        $Meta['LastFullUpdate'] = $Now
        # Clear Tier2Stale after full rebuild
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

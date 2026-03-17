<#
    .SYNOPSIS
    Monthly PU assignment workflow with optional write, notification, and
    history logging.

    .DESCRIPTION
    This file contains Invoke-PlayerCharacterPUAssignment — the core monthly
    admin workflow that awards PU (Player Units) to characters based on
    session participation.

    Computation pipeline:
    1. Determine date range from Year/Month or MinDate/MaxDate parameters.
       Default: 2-month lookback (sessions are sometimes documented late).
    2. Optimize file scanning via Get-GitChangeLog -NoPatch to identify only
       files changed in the date range, then pass those to Get-Session.
       Falls back to full directory scan if git optimization fails.
    3. Filter to sessions with PU entries.
    4. Exclude already-processed session headers via Get-AdminHistoryEntries
       (pu-sessions.json tracks processed headers to prevent double-awarding).
    5. Resolve characters via Get-PlayerCharacter (merges Gracze.md +
       entities.md). Includes alias expansion for name matching.
    6. Fail-early: ALL character names must resolve before any writes. Partial
       assignments would corrupt state, so unresolved names produce a
       ThrowTerminatingError with structured ErrorRecord (TargetObject carries
       the unresolved list for callers to inspect).
    7. For each character, compute PU with overflow/underflow handling.
    8. Optionally apply side effects gated by switches.

    PU calculation algorithm (per pu-unification-logic.md):
    - BasePU = 1 + Sum(session PU for this character)
    - If BasePU <= 5 and PUExceeded > 0: supplement from overflow pool
    - If BasePU > 5: excess goes to overflow pool
    - Granted PU capped at 5 per month
    - PUExceeded updated: (Original - Used) + NewOverflow

    Side effects (all switch-gated, all ShouldProcess-guarded):
    - -UpdatePlayerCharacters: writes PU values to entities.md via Set-PlayerCharacter
    - -SendToDiscord: sends PU notification messages via player webhooks;
      logs each delivery (success/failure) to discord-delivery.json via
      Add-DiscordDeliveryEntry for retry and audit visibility
    - -AppendToLog: records processed session headers to pu-sessions.json
    - -ReconcileCurrency: runs currency reconciliation checks

    Module-level data:
    - $script:MultiSpacePattern: precompiled regex from admin-state.ps1
    - $script:SuppressWarnings: warning suppression flag (managed by -Quiet)
#>

. "$script:ModuleRoot/private/admin-state.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"
. "$script:ModuleRoot/private/discord-state.ps1"

function Invoke-PlayerCharacterPUAssignment {
    <#
        .SYNOPSIS
        Awards monthly PU to characters based on session participation.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param(
        [Parameter(HelpMessage = "Year for the PU assignment period")]
        [int]$Year,

        [Parameter(HelpMessage = "Month for the PU assignment period")]
        [int]$Month,

        [Parameter(HelpMessage = "Start date for custom date range")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "End date for custom date range")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Filter to specific player name(s)")]
        [string[]]$PlayerName,

        [Parameter(HelpMessage = "Write updated PU values to entities.md via Set-PlayerCharacter")]
        [switch]$UpdatePlayerCharacters,

        [Parameter(HelpMessage = "Send PU notification messages to Discord via player webhooks")]
        [switch]$SendToDiscord,

        [Parameter(HelpMessage = "Append processed session headers to pu-sessions.json history")]
        [switch]$AppendToLog,

        [Parameter(HelpMessage = "Run currency reconciliation checks after PU calculation")]
        [switch]$ReconcileCurrency,

        [Parameter(HelpMessage = "Directories to exclude from session file scanning")]
        [string[]]$ExcludeDirectory,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Config = Get-AdminConfig

    # Year/Month takes priority; otherwise default to a 2-month lookback
    # because sessions are sometimes documented after the fact
    if ($Year -and $Month) {
        $MinDate = [datetime]::new($Year, $Month, 1)
        $MaxDate = $MinDate.AddMonths(1).AddDays(-1)
    } elseif (-not $PSBoundParameters.ContainsKey('MinDate') -or -not $PSBoundParameters.ContainsKey('MaxDate')) {
        # Default range: first day of 2 months ago through end of last month
        $Now = [datetime]::Now
        $TwoMonthsAgo = $Now.AddMonths(-2)
        if (-not $PSBoundParameters.ContainsKey('MinDate')) {
            $MinDate = [datetime]::new($TwoMonthsAgo.Year, $TwoMonthsAgo.Month, 1)
        }
        if (-not $PSBoundParameters.ContainsKey('MaxDate')) {
            $MaxDate = [datetime]::new($Now.Year, $Now.Month, 1).AddDays(-1)
        }
    }

    $MinDateStr = $MinDate.ToString('yyyy-MM-dd')
    $MaxDateStr = $MaxDate.ToString('yyyy-MM-dd')

    # Narrow Get-Session's file scope via git history to avoid scanning the entire repo
    $ChangedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $GitLog = Get-GitChangeLog -MinDate $MinDateStr -MaxDate $MaxDateStr -NoPatch
        foreach ($Commit in $GitLog) {
            foreach ($FileEntry in $Commit.Files) {
                if ($FileEntry.Path -and $FileEntry.Path.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $FullPath = [System.IO.Path]::Combine($Config.RepoRoot, $FileEntry.Path)
                    if ([System.IO.File]::Exists($FullPath)) {
                        [void]$ChangedFiles.Add($FullPath)
                    }
                }
            }
        }
    } catch {
        Write-RobotWarning "[WARN Invoke-PlayerCharacterPUAssignment] Git optimization failed, falling back to full scan: $_"
    }

    # Git-scoped files avoid full-repo scan; fallback to Get-Session without -File
    $Sessions = if ($ChangedFiles.Count -gt 0) {
        $SessionResults = [System.Collections.Generic.List[object]]::new()
        foreach ($FilePath in $ChangedFiles) {
            try {
                $FileSessions = Get-Session -File $FilePath -MinDate $MinDate -MaxDate $MaxDate -ExcludeDirectory $ExcludeDirectory
                if ($FileSessions) {
                    if ($FileSessions -is [System.Collections.IEnumerable] -and $FileSessions -isnot [string]) {
                        foreach ($SessionItem in $FileSessions) { $SessionResults.Add($SessionItem) }
                    } else {
                        $SessionResults.Add($FileSessions)
                    }
                }
            } catch {
                Write-RobotWarning "[WARN Invoke-PlayerCharacterPUAssignment] Failed to parse '$FilePath': $_"
            }
        }
        $SessionResults
    } else {
        Get-Session -MinDate $MinDate -MaxDate $MaxDate -ExcludeDirectory $ExcludeDirectory
    }

    # Sessions without PU entries have no character awards to process
    $SessionsWithPU = [System.Collections.Generic.List[object]]::new()
    foreach ($Session in $Sessions) {
        if ($Session.PU -and $Session.PU.Count -gt 0) {
            $SessionsWithPU.Add($Session)
        }
    }

    if ($SessionsWithPU.Count -eq 0) {
        Write-RobotInfo "[INFO Invoke-PlayerCharacterPUAssignment] No sessions with PU entries found in range $MinDateStr to $MaxDateStr"
        return @()
    }

    # pu-sessions.json tracks processed headers to prevent double-awarding
    $PUSessionsPath = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.json')
    $DiscordLogPath = [System.IO.Path]::Combine($Config.ResDir, 'discord-delivery.json')
    $ProcessedHeaders = Get-AdminHistoryEntries -Path $PUSessionsPath

    $NewSessions = [System.Collections.Generic.List[object]]::new()
    foreach ($Session in $SessionsWithPU) {
        $NormalizedHeader = $Session.Header.Trim()
        $NormalizedHeader = $script:MultiSpacePattern.Replace($NormalizedHeader, ' ')
        # Compare without "### " prefix — pu-sessions.json stores bare headers
        $CompareHeader = if ($NormalizedHeader.StartsWith('### ')) { $NormalizedHeader.Substring(4) } else { $NormalizedHeader }

        if (-not $ProcessedHeaders.Contains($CompareHeader) -and -not $ProcessedHeaders.Contains($NormalizedHeader)) {
            $NewSessions.Add($Session)
        }
    }

    if ($NewSessions.Count -eq 0) {
        Write-RobotInfo "[INFO Invoke-PlayerCharacterPUAssignment] All sessions in range already processed"
        return @()
    }

    # Group PU entries by character for per-character cap and overflow logic
    $PUByCharacter = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Session in $NewSessions) {
        foreach ($PUEntry in $Session.PU) {
            $CharName = $PUEntry.Character
            if (-not $PUByCharacter.ContainsKey($CharName)) {
                $PUByCharacter[$CharName] = [System.Collections.Generic.List[object]]::new()
            }
            $PUByCharacter[$CharName].Add([PSCustomObject]@{
                Session   = $Session
                Character = $PUEntry.Character
                Value     = $PUEntry.Value
            })
        }
    }

    # Build character lookup including aliases — needed for fail-early name verification
    $AllCharacters = Get-PlayerCharacter
    $CharacterLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Char in $AllCharacters) {
        if (-not $CharacterLookup.ContainsKey($Char.Name)) {
            $CharacterLookup[$Char.Name] = $Char
        }
        if ($Char.Aliases) {
            foreach ($Alias in $Char.Aliases) {
                if (-not [string]::IsNullOrWhiteSpace($Alias) -and -not $CharacterLookup.ContainsKey($Alias)) {
                    $CharacterLookup[$Alias] = $Char
                }
            }
        }
    }

    # Fail-early: ALL names must resolve before any writes — partial assignments corrupt state
    $UnresolvedCharacters = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $PUByCharacter.GetEnumerator()) {
        $CharName = $Entry.Key
        if (-not $CharacterLookup.ContainsKey($CharName)) {
            $UnresolvedCharacters.Add([PSCustomObject]@{
                CharacterName = $CharName
                SessionCount  = $Entry.Value.Count
                Sessions      = @($Entry.Value | ForEach-Object { $_.Session.Header })
            })
        }
    }

    if ($UnresolvedCharacters.Count -gt 0) {
        $Names = ($UnresolvedCharacters | ForEach-Object { $_.CharacterName }) -join "', '"
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Unresolved character name(s) in PU entries: '$Names'. Fix data before running PU assignment."),
            'UnresolvedPUCharacters',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $UnresolvedCharacters.ToArray()
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    # PU algorithm per character: BasePU = 1 + sum, with overflow pool and 5/month cap
    $AssignmentResults = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in $PUByCharacter.GetEnumerator()) {
        $CharName = $Entry.Key
        $PUEntries = $Entry.Value
        $Character = $CharacterLookup[$CharName]

        # Player name filter allows scoping to specific players (e.g. for testing)
        if ($PlayerName -and $PlayerName.Count -gt 0) {
            $Matched = $false
            foreach ($Filter in $PlayerName) {
                if ([string]::Equals($Character.PlayerName, $Filter, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Matched = $true
                    break
                }
            }
            if (-not $Matched) { continue }
        }

        # Sum raw session PU values before applying cap and overflow
        $SessionPUSum = [decimal]0
        foreach ($PUItem in $PUEntries) {
            if ($null -ne $PUItem.Value) {
                $SessionPUSum += $PUItem.Value
            }
        }

        # PU calculation per pu-unification-logic.md section 4
        $BasePU = [decimal]1 + $SessionPUSum  # base participation bonus of 1
        $OriginalPUExceeded = if ($null -ne $Character.PUExceeded) { [decimal]$Character.PUExceeded } else { [decimal]0 }
        $UsedExceeded = [decimal]0
        $OverflowPU = [decimal]0

        # Supplement from overflow pool when under cap to use accumulated excess
        if ($BasePU -le 5 -and $OriginalPUExceeded -gt 0) {
            $UsedExceeded = [math]::Min(5 - $BasePU, $OriginalPUExceeded)
        }

        # Excess above cap goes to overflow pool for future months
        if ($BasePU -gt 5) {
            $OverflowPU = $BasePU - 5
        }

        $GrantedPU = [math]::Min($BasePU + $UsedExceeded, [decimal]5)  # 5 PU/month cap
        $RemainingPUExceeded = ($OriginalPUExceeded - $UsedExceeded) + $OverflowPU

        # Running totals: PUSum is lifetime, PUTaken is total granted (for charfile)
        $CurrentPUSum = if ($null -ne $Character.PUSum) { [decimal]$Character.PUSum } else { [decimal]0 }
        $CurrentPUTaken = if ($null -ne $Character.PUTaken) { [decimal]$Character.PUTaken } else { [decimal]0 }
        $NewPUSum = [math]::Round($CurrentPUSum + $GrantedPU, 2)
        $NewPUTaken = [math]::Round($CurrentPUTaken + $GrantedPU, 2)

        # Compose notification from templates: base message + optional overflow/remaining parts
        $MsgVars = @{
            CharacterName = $Character.Name
            PlayerName    = $Character.PlayerName
            GrantedPU     = $GrantedPU.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
            NewPUSum      = $NewPUSum.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $MsgText = Get-AdminTemplate -Name 'pu-notification-base.txt.template' -Variables $MsgVars

        if ($UsedExceeded -gt 0) {
            $MsgText += Get-AdminTemplate -Name 'pu-notification-overflow.txt.template' -Variables @{
                UsedExceeded = $UsedExceeded.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
        if ($RemainingPUExceeded -gt 0) {
            $MsgText += Get-AdminTemplate -Name 'pu-notification-remaining.txt.template' -Variables @{
                RemainingPUExceeded = $RemainingPUExceeded.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }

        $AssignmentResults.Add([PSCustomObject]@{
            CharacterName       = $Character.Name
            PlayerName          = $Character.PlayerName
            Character           = $Character
            BasePU              = $BasePU
            GrantedPU           = $GrantedPU
            OverflowPU          = $OverflowPU
            UsedExceeded        = $UsedExceeded
            OriginalPUExceeded  = $OriginalPUExceeded
            RemainingPUExceeded = $RemainingPUExceeded
            NewPUSum            = $NewPUSum
            NewPUTaken          = $NewPUTaken
            SessionCount        = $PUEntries.Count
            Sessions            = @($PUEntries | ForEach-Object { $_.Session.Header })
            Message             = $MsgText
            Resolved            = $true
        })
    }

    # Side effects — each gated by its own switch and ShouldProcess

    if ($UpdatePlayerCharacters) {
        foreach ($Item in $AssignmentResults) {
            if ($PSCmdlet.ShouldProcess("$($Item.CharacterName) (owner: $($Item.PlayerName))", "Set-PlayerCharacter: PU sum=$($Item.NewPUSum), exceeded=$($Item.RemainingPUExceeded)")) {
                Set-PlayerCharacter `
                    -PlayerName $Item.PlayerName `
                    -CharacterName $Item.CharacterName `
                    -PUSum $Item.NewPUSum `
                    -PUTaken $Item.NewPUTaken `
                    -PUExceeded ([math]::Max([decimal]0, $Item.RemainingPUExceeded))
            }
        }
    }

    if ($SendToDiscord) {
        # Group by player — one consolidated message per player, not per character
        $ByPlayer = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($Item in $AssignmentResults) {
            if (-not $Item.PlayerName) { continue }
            if (-not $ByPlayer.ContainsKey($Item.PlayerName)) {
                $ByPlayer[$Item.PlayerName] = [System.Collections.Generic.List[object]]::new()
            }
            $ByPlayer[$Item.PlayerName].Add($Item)
        }

        foreach ($PlayerEntry in $ByPlayer.GetEnumerator()) {
            $PName = $PlayerEntry.Key
            $Items = $PlayerEntry.Value
            $Webhook = $Items[0].Character.Player.PRFWebhook

            if (-not $Webhook) {
                Write-RobotWarning "[WARN Invoke-PlayerCharacterPUAssignment] No webhook for player '$PName' - skipping Discord notification"
                continue
            }

            $FullMessage = ($Items | ForEach-Object { $_.Message }) -join "`n`n"

            if ($PSCmdlet.ShouldProcess($PName, "Send-DiscordMessage: PU notification")) {
                $ContextStr = "$($MinDate.ToString('yyyy-MM')) PU: " + (
                    ($Items | ForEach-Object {
                        "$($_.CharacterName) +$($_.GrantedPU.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))"
                    }) -join ', '
                )

                try {
                    $SendResult = Send-DiscordMessage -Webhook $Webhook -Message $FullMessage -Username 'Bothen'
                    Add-DiscordDeliveryEntry -Path $DiscordLogPath `
                        -Operation 'PU' -Recipient $PName `
                        -Success $SendResult.Success `
                        -StatusCode $SendResult.StatusCode `
                        -Context $ContextStr
                } catch {
                    Write-RobotWarning "[WARN Invoke-PlayerCharacterPUAssignment] Discord send failed for '$PName': $_"
                    $CaughtStatusCode = 0
                    if ($_.Exception.Message -match 'HTTP\s+(\d+)') {
                        $CaughtStatusCode = [int]$Matches[1]
                    }
                    Add-DiscordDeliveryEntry -Path $DiscordLogPath `
                        -Operation 'PU' -Recipient $PName `
                        -Success $false `
                        -StatusCode $CaughtStatusCode `
                        -ErrorMessage $_.Exception.Message `
                        -Context $ContextStr
                }
            }
        }
    }

    if ($AppendToLog) {
        $NewHeaders = [System.Collections.Generic.List[string]]::new()
        foreach ($Session in $NewSessions) {
            [void]$NewHeaders.Add($Session.Header)
        }

        if ($NewHeaders.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($PUSessionsPath, "Add-AdminHistoryEntry: append $($NewHeaders.Count) session headers")) {
                Add-AdminHistoryEntry -Path $PUSessionsPath -Headers $NewHeaders.ToArray()
            }
        }
    }

    # Currency reconciliation: detects balance discrepancies across sessions
    $ReconciliationResult = $null
    if ($ReconcileCurrency) {
        $ReconciliationResult = Test-CurrencyReconciliation -Sessions @($Sessions)
        if ($ReconciliationResult.WarningCount -gt 0) {
            Write-RobotInfo "[INFO Invoke-PlayerCharacterPUAssignment] Currency reconciliation: $($ReconciliationResult.WarningCount) warning(s)"
            foreach ($Warning in $ReconciliationResult.Warnings) {
                [System.Console]::Error.WriteLine("  [$($Warning.Severity)] $($Warning.Check): $($Warning.Entity) - $($Warning.Detail)")
            }
        } else {
            Write-RobotInfo "[INFO Invoke-PlayerCharacterPUAssignment] Currency reconciliation: no warnings"
        }
    }

    # Attach reconciliation result as a note property when present
    if ($ReconciliationResult) {
        $AssignmentResults | Add-Member -NotePropertyName 'CurrencyReconciliation' -NotePropertyValue $ReconciliationResult -PassThru | Out-Null
    }

    return $AssignmentResults

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

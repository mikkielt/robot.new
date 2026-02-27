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
    2. Optimize file scanning via Get-GitChangeLog -NoPatch to identify only
       files changed in the date range, then pass those to Get-Session.
    3. Filter to sessions with PU entries.
    4. Exclude already-processed session headers via Get-AdminHistoryEntries.
    5. Resolve characters via Get-PlayerCharacter (merges Gracze.md + entities.md).
    6. For each character, compute PU with overflow/underflow handling.
    7. Optionally apply side effects gated by switches.

    PU calculation algorithm (per pu-unification-logic.md):
    - BasePU = 1 + Sum(session PU for this character)
    - If BasePU <= 5 and PUExceeded > 0: supplement from overflow pool
    - If BasePU > 5: excess goes to overflow pool
    - Granted PU capped at 5 per month
    - PUExceeded updated: (Original - Used) + NewOverflow
    - Unresolved character names cause fail-early abort (throw)

    Dot-sources admin-state.ps1 and admin-config.ps1 for state file handling
    and config resolution.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
. "$PSScriptRoot/admin-state.ps1"
. "$PSScriptRoot/admin-config.ps1"

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

        [Parameter(HelpMessage = "Append processed session headers to pu-sessions.md history")]
        [switch]$AppendToLog
    )

    $Config = Get-AdminConfig

    # Determine date range
    if ($Year -and $Month) {
        $MinDate = [datetime]::new($Year, $Month, 1)
        $MaxDate = $MinDate.AddMonths(1).AddDays(-1)
    } elseif (-not $PSBoundParameters.ContainsKey('MinDate') -or -not $PSBoundParameters.ContainsKey('MaxDate')) {
        # Default: 2-month lookback (sessions are sometimes documented late)
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

    # Git optimization: identify files changed in the date range
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
        [System.Console]::Error.WriteLine("[WARN Invoke-PlayerCharacterPUAssignment] Git optimization failed, falling back to full scan: $_")
    }

    # Get sessions in date range
    $Sessions = if ($ChangedFiles.Count -gt 0) {
        $SessionResults = [System.Collections.Generic.List[object]]::new()
        foreach ($FilePath in $ChangedFiles) {
            try {
                $FileSessions = Get-Session -File $FilePath -MinDate $MinDate -MaxDate $MaxDate
                if ($FileSessions) {
                    if ($FileSessions -is [System.Collections.IEnumerable] -and $FileSessions -isnot [string]) {
                        foreach ($S in $FileSessions) { $SessionResults.Add($S) }
                    } else {
                        $SessionResults.Add($FileSessions)
                    }
                }
            } catch {
                [System.Console]::Error.WriteLine("[WARN Invoke-PlayerCharacterPUAssignment] Failed to parse '$FilePath': $_")
            }
        }
        $SessionResults
    } else {
        Get-Session -MinDate $MinDate -MaxDate $MaxDate
    }

    # Filter to sessions with PU entries
    $SessionsWithPU = [System.Collections.Generic.List[object]]::new()
    foreach ($Session in $Sessions) {
        if ($Session.PU -and $Session.PU.Count -gt 0) {
            $SessionsWithPU.Add($Session)
        }
    }

    if ($SessionsWithPU.Count -eq 0) {
        [System.Console]::Error.WriteLine("[INFO Invoke-PlayerCharacterPUAssignment] No sessions with PU entries found in range $MinDateStr to $MaxDateStr")
        return @()
    }

    # Exclude already-processed sessions via state file
    $PUSessionsPath = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.md')
    $ProcessedHeaders = Get-AdminHistoryEntries -Path $PUSessionsPath

    $NewSessions = [System.Collections.Generic.List[object]]::new()
    foreach ($Session in $SessionsWithPU) {
        $NormalizedHeader = $Session.Header.Trim()
        $NormalizedHeader = $script:MultiSpacePattern.Replace($NormalizedHeader, ' ')
        # Strip leading ### if present for comparison
        $CompareHeader = if ($NormalizedHeader.StartsWith('### ')) { $NormalizedHeader.Substring(4) } else { $NormalizedHeader }

        if (-not $ProcessedHeaders.Contains($CompareHeader) -and -not $ProcessedHeaders.Contains($NormalizedHeader)) {
            $NewSessions.Add($Session)
        }
    }

    if ($NewSessions.Count -eq 0) {
        [System.Console]::Error.WriteLine("[INFO Invoke-PlayerCharacterPUAssignment] All sessions in range already processed")
        return @()
    }

    # Collect all PU entries grouped by character name
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

    # Resolve characters via Get-PlayerCharacter
    $AllCharacters = Get-PlayerCharacter

    # Build character lookup (case-insensitive, including aliases)
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

    # Fail-early: verify ALL character names resolve before any computation
    $UnresolvedCharacters = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $PUByCharacter.GetEnumerator()) {
        $CharName = $Entry.Key
        if (-not $CharacterLookup.ContainsKey($CharName)) {
            $UnresolvedCharacters.Add([PSCustomObject]@{
                CharacterName = $CharName
                SessionCount  = $Entry.Value.Count
                Sessions      = @($Entry.Value.ForEach({ $_.Session.Header }))
            })
        }
    }

    if ($UnresolvedCharacters.Count -gt 0) {
        $Names = ($UnresolvedCharacters.ForEach({ $_.CharacterName })) -join "', '"
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Unresolved character name(s) in PU entries: '$Names'. Fix data before running PU assignment."),
            'UnresolvedPUCharacters',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $UnresolvedCharacters.ToArray()
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    # Compute PU assignment for each character
    $AssignmentResults = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in $PUByCharacter.GetEnumerator()) {
        $CharName = $Entry.Key
        $PUEntries = $Entry.Value
        $Character = $CharacterLookup[$CharName]

        # Apply player name filter if specified
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

        # Sum session PU values for this character
        $SessionPUSum = [decimal]0
        foreach ($PUItem in $PUEntries) {
            if ($null -ne $PUItem.Value) {
                $SessionPUSum += $PUItem.Value
            }
        }

        # PU calculation (per pu-unification-logic.md §4)
        $BasePU = [decimal]1 + $SessionPUSum
        $OriginalPUExceeded = if ($null -ne $Character.PUExceeded) { [decimal]$Character.PUExceeded } else { [decimal]0 }
        $UsedExceeded = [decimal]0
        $OverflowPU = [decimal]0

        # Supplement from overflow pool when at or under cap
        if ($BasePU -le 5 -and $OriginalPUExceeded -gt 0) {
            $UsedExceeded = [math]::Min(5 - $BasePU, $OriginalPUExceeded)
        }

        # Excess above cap goes to overflow pool
        if ($BasePU -gt 5) {
            $OverflowPU = $BasePU - 5
        }

        # Cap at 5
        $GrantedPU = [math]::Min($BasePU + $UsedExceeded, [decimal]5)
        $RemainingPUExceeded = ($OriginalPUExceeded - $UsedExceeded) + $OverflowPU

        # Compute new totals
        $CurrentPUSum = if ($null -ne $Character.PUSum) { [decimal]$Character.PUSum } else { [decimal]0 }
        $CurrentPUTaken = if ($null -ne $Character.PUTaken) { [decimal]$Character.PUTaken } else { [decimal]0 }
        $NewPUSum = [math]::Round($CurrentPUSum + $GrantedPU, 2)
        $NewPUTaken = [math]::Round($CurrentPUTaken + $GrantedPU, 2)

        # Build notification message (Polish, per spec §5.2)
        $MsgSB = [System.Text.StringBuilder]::new(256)
        [void]$MsgSB.Append("Postać `"$($Character.Name)`" (Gracz `"$($Character.PlayerName)`") otrzymuje ")
        [void]$MsgSB.Append($GrantedPU.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))
        [void]$MsgSB.Append(" PU.")
        [void]$MsgSB.Append("`n")
        [void]$MsgSB.Append("Aktualna suma PU tej Postaci: ")
        [void]$MsgSB.Append($NewPUSum.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))

        if ($UsedExceeded -gt 0) {
            [void]$MsgSB.Append(", wykorzystano PU nadmiarowe: ")
            [void]$MsgSB.Append($UsedExceeded.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))
        }
        if ($RemainingPUExceeded -gt 0) {
            [void]$MsgSB.Append(", pozostałe PU nadmiarowe: ")
            [void]$MsgSB.Append($RemainingPUExceeded.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))
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
            Sessions            = @($PUEntries.ForEach({ $_.Session.Header }))
            Message             = $MsgSB.ToString()
            Resolved            = $true
        })
    }

    # Side effects (gated by switches)

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
        # Group by player to send one message per player
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
                [System.Console]::Error.WriteLine("[WARN Invoke-PlayerCharacterPUAssignment] No webhook for player '$PName' — skipping Discord notification")
                continue
            }

            $FullMessage = ($Items.ForEach({ $_.Message })) -join "`n`n"

            if ($PSCmdlet.ShouldProcess($PName, "Send-DiscordMessage: PU notification")) {
                try {
                    Send-DiscordMessage -Webhook $Webhook -Message $FullMessage -Username 'Bothen'
                } catch {
                    [System.Console]::Error.WriteLine("[WARN Invoke-PlayerCharacterPUAssignment] Discord send failed for '$PName': $_")
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

    return $AssignmentResults
}

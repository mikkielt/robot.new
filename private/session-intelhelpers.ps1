<#
    .SYNOPSIS
    Session notification routing and entity mention extraction helpers.

    .DESCRIPTION
    This file contains helpers extracted from get-session.ps1 that handle
    notification routing and entity mention extraction:

    Helpers:
    - Resolve-EntityWebhook: resolves Discord webhook URL for any entity, with
                             Player fallback for character entities
    - Test-LocationMatch:    checks if a @lokacja value matches any location in a set,
                             handling slash-separated path values
    - Resolve-IntelTargets:  resolves @Intel targeting directives (Grupa/, Lokacja/,
                             Direct) into recipient entities with webhook URLs
    - Get-SessionMentions:   extracts entity mentions from session body text using
                             stages 1/2/2b of name resolution (no fuzzy), excluding
                             metadata list items

    These helpers are dot-sourced by get-session.ps1 and are not auto-loaded
    by the module loader. Resolve-IntelTargets uses Test-TemporalActivity from
    temporal-helpers.ps1 (available via module scope).
#>

# Helper: resolve Discord webhook URL for any entity, with Player fallback
# for character entities. Checks entity @prfwebhook override first, then
# falls back to owning Player's PRFWebhook for Gracz/Postać types.
function Resolve-EntityWebhook {
    param(
        [object]$Entity,
        [object[]]$Players
    )

    $UrlPrefix = 'https://discord.com/api/webhooks/'

    # 1. Entity's own @prfwebhook override (last value)
    if ($Entity.Overrides -and $Entity.Overrides.ContainsKey('prfwebhook')) {
        $Values = $Entity.Overrides['prfwebhook']
        if ($Values.Count -gt 0) {
            $Candidate = $Values[-1]
            if ($Candidate.StartsWith($UrlPrefix)) { return $Candidate }
        }
    }

    # 2. For Postać or Gracz: find owning Player's webhook
    if ($Entity.Type -in @('Postać', 'Gracz')) {
        $PlayerName = if ($Entity.Owner) { $Entity.Owner }
                      elseif ($Entity.Type -eq 'Gracz') { $Entity.Name }
                      else { $null }

        if ($PlayerName) {
            foreach ($Player in $Players) {
                if ([string]::Equals($Player.Name, $PlayerName,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $Player.PRFWebhook
                }
            }
        }
    }

    # 3. For Player objects returned directly by Resolve-Name
    if ($null -ne ($Entity.PSObject.Properties['PRFWebhook'])) {
        $Candidate = $Entity.PRFWebhook
        if ($Candidate -and $Candidate.StartsWith($UrlPrefix)) { return $Candidate }
    }

    return $null
}

# Helper: check if a @lokacja value matches any location in a LocationSet.
# Handles slash-separated path values (e.g. "Ithan/Ratusz Ithan") by
# splitting on '/' and checking each segment.
function Test-LocationMatch {
    param(
        [string]$LocationValue,
        [System.Collections.Generic.HashSet[string]]$LocationSet
    )

    if ($LocationSet.Contains($LocationValue)) { return $true }

    if ($LocationValue.Contains('/')) {
        foreach ($Segment in $LocationValue.Split('/')) {
            $Trimmed = $Segment.Trim()
            if ($Trimmed.Length -gt 0 -and $LocationSet.Contains($Trimmed)) {
                return $true
            }
        }
    }

    return $false
}

# Helper: resolve @Intel targeting directives into recipient entities with webhooks.
# Supports three directives:
# - Grupa/:   fan-out to all entities with @grupa membership matching the target org
# - Lokacja/: fan-out to all entities @lokacja'd in the target location tree
# - Direct:   bare name or comma-separated names, no fan-out
function Resolve-IntelTargets {
    param(
        [System.Collections.Generic.List[object]]$RawIntel,
        [datetime]$SessionDate,
        [object[]]$Entities,
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,
        [object[]]$Players,
        [hashtable]$ResolveCache
    )

    $Result = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in $RawIntel) {
        $RawTarget = $Entry.RawTarget
        $Directive = 'Direct'
        $TargetName = $RawTarget

        if ($RawTarget.StartsWith('Grupa/')) {
            $Directive = 'Grupa'
            $TargetName = $RawTarget.Substring(6).Trim()
        }
        elseif ($RawTarget.StartsWith('Lokacja/')) {
            $Directive = 'Lokacja'
            $TargetName = $RawTarget.Substring(8).Trim()
        }

        # For direct targets, support comma-separated multi-recipient
        $TargetNames = if ($Directive -eq 'Direct') {
            $RawTarget.Split(',').ForEach({ $_.Trim() }).Where({ $_.Length -gt 0 })
        } else {
            @($TargetName)
        }

        $RecipientEntities = [System.Collections.Generic.List[object]]::new()

        foreach ($TName in $TargetNames) {
            $Resolved = Resolve-Name -Query $TName -Index $Index -StemIndex $StemIndex -Cache $ResolveCache -NoFuzzy

            if (-not $Resolved) {
                Write-RobotWarning "[WARN @Intel] Unresolved target '$TName'"
                continue
            }

            switch ($Directive) {
                'Grupa' {
                    $RecipientEntities.Add($Resolved)

                    $GroupNames = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase
                    )
                    if ($Resolved.Names) {
                        foreach ($N in $Resolved.Names) { [void]$GroupNames.Add($N) }
                    } else {
                        [void]$GroupNames.Add($Resolved.Name)
                    }

                    foreach ($Entity in $Entities) {
                        if ($Entity.Name -eq $Resolved.Name) { continue }
                        if ($Entity.GroupHistory.Count -eq 0) { continue }

                        foreach ($GH in $Entity.GroupHistory) {
                            if (-not (Test-TemporalActivity -Item $GH -ActiveOn $SessionDate)) { continue }
                            if ($GroupNames.Contains($GH.Group)) {
                                $RecipientEntities.Add($Entity)
                                break
                            }
                        }
                    }
                }

                'Lokacja' {
                    $RecipientEntities.Add($Resolved)

                    $LocationSet = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase
                    )
                    [void]$LocationSet.Add($Resolved.Name)

                    $Queue = [System.Collections.Generic.Queue[string]]::new()
                    $Queue.Enqueue($Resolved.Name)

                    while ($Queue.Count -gt 0) {
                        $Current = $Queue.Dequeue()
                        foreach ($Entity in $Entities) {
                            if ($Entity.Type -ne 'Lokacja') { continue }
                            if ($LocationSet.Contains($Entity.Name)) { continue }

                            foreach ($LH in $Entity.LocationHistory) {
                                if (-not (Test-TemporalActivity -Item $LH -ActiveOn $SessionDate)) { continue }
                                if ([string]::Equals($LH.Location, $Current,
                                    [System.StringComparison]::OrdinalIgnoreCase)) {
                                    [void]$LocationSet.Add($Entity.Name)
                                    $Queue.Enqueue($Entity.Name)
                                    $RecipientEntities.Add($Entity)
                                    break
                                }
                            }
                        }
                    }

                    foreach ($Entity in $Entities) {
                        if ($Entity.Type -eq 'Lokacja') { continue }
                        if ($Entity.Type -eq 'Mapa') { continue }
                        if ($Entity.LocationHistory.Count -eq 0) { continue }

                        foreach ($LH in $Entity.LocationHistory) {
                            if (-not (Test-TemporalActivity -Item $LH -ActiveOn $SessionDate)) { continue }
                            if (Test-LocationMatch -LocationValue $LH.Location -LocationSet $LocationSet) {
                                $RecipientEntities.Add($Entity)
                                break
                            }
                        }
                    }
                }

                'Direct' {
                    $RecipientEntities.Add($Resolved)
                }
            }
        }

        # Deduplicate recipients by name
        $SeenRecipients = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $Recipients = [System.Collections.Generic.List[object]]::new()

        foreach ($R in $RecipientEntities) {
            if (-not $SeenRecipients.Add($R.Name)) { continue }

            $Webhook = Resolve-EntityWebhook -Entity $R -Players $Players
            $Recipients.Add([PSCustomObject]@{
                Name    = $R.Name
                Type    = $R.Type
                Webhook = $Webhook
            })
        }

        $Result.Add([PSCustomObject]@{
            RawTarget  = $Entry.RawTarget
            Message    = $Entry.Message
            Directive  = $Directive
            TargetName = $TargetName
            Recipients = $Recipients.ToArray()
        })
    }

    return $Result
}

# Helper: extract entity mentions from session body text.
# Scans non-metadata text for entity references using stages 1, 2, 2b of
# name resolution (no fuzzy matching to avoid false positives).
# Excludes PU, Logi, Lokalizacje/Lokacje, Zmiany, and Intel list items.
function Get-SessionMentions {
    param(
        [string]$Content,
        [object]$SectionLists,
        [string]$Format,
        [string]$FirstNonEmptyLine,
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,
        [hashtable]$ResolveCache
    )

    # Phase 1: Build Excluded List-Item Set
    $ExcludedListItems = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($LI in $SectionLists) {
        if ($LI.Indent -ne 0) { continue }
        $TestText = if ($LI.Text.StartsWith('@')) { $LI.Text.Substring(1) } else { $LI.Text }
        $Lower = $TestText.ToLowerInvariant()

        $IsExcluded = $false
        if ($Lower.StartsWith('narrator') -and ($Lower.Length -eq 8 -or $Lower[8] -eq ':' -or $Lower[8] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('pu') -and ($Lower.Length -eq 2 -or $Lower[2] -eq ':' -or $Lower[2] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('logi') -and ($Lower.Length -eq 4 -or $Lower[4] -eq ':' -or $Lower[4] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('lokalizacj') -or $Lower.StartsWith('lokacj')) { $IsExcluded = $true }
        if ($Lower.StartsWith('zmiany') -and ($Lower.Length -eq 6 -or $Lower[6] -eq ':' -or $Lower[6] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('intel') -and ($Lower.Length -eq 5 -or $Lower[5] -eq ':' -or $Lower[5] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('data') -and ($Lower.Length -eq 4 -or $Lower[4] -eq ':' -or $Lower[4] -eq ' ')) { $IsExcluded = $true }

        if ($IsExcluded) {
            [void]$ExcludedListItems.Add([System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI))
        }
    }

    # Multi-pass: propagate exclusion to all descendants (arbitrary nesting depth)
    do {
        $Added = $false
        foreach ($LI in $SectionLists) {
            $LIId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI)
            if ($ExcludedListItems.Contains($LIId)) { continue }
            if ($null -eq $LI.ParentListItem) { continue }
            $ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI.ParentListItem)
            if ($ExcludedListItems.Contains($ParentId)) {
                [void]$ExcludedListItems.Add($LIId)
                $Added = $true
            }
        }
    } while ($Added)

    # Phase 2: Extract Scannable Text (Dual-Source)

    $ScannableTexts = [System.Collections.Generic.List[string]]::new()

    # Source A: Non-excluded list items
    foreach ($LI in $SectionLists) {
        $LIId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI)
        if ($ExcludedListItems.Contains($LIId)) { continue }
        $ScannableTexts.Add($LI.Text)
    }

    # Source B: Paragraph (non-list) content lines
    $ListLineRegex = [regex]::new('^\s*(\d+\.|[-\*\+])\s+')
    $LogiPlainRegex = [regex]::new('^Logi:\s*https?://')

    $ContentLines = $Content.Split([char]"`n")
    $SkippedFirstLine = $false

    foreach ($Line in $ContentLines) {
        $Trimmed = $Line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($Trimmed)) { continue }

        # Skip first non-empty line if it matches Gen2 italic location pattern
        if (-not $SkippedFirstLine) {
            $SkippedFirstLine = $true
            if ($Trimmed.StartsWith('*Lokalizacj')) { continue }
        }

        # Skip list-item lines (handled in Source A)
        if ($ListLineRegex.IsMatch($Trimmed)) { continue }

        # Skip plain-text Logi: lines (Gen1/Gen2 fallback format)
        if ($LogiPlainRegex.IsMatch($Trimmed)) { continue }

        $ScannableTexts.Add($Trimmed)
    }

    # Phase 3: Tokenize

    $MdLinkRegex = [regex]::new('\[(.+?)\]\(.+?\)')
    $PunctuationRegex = [regex]::new('[,\.\;\:\!\?\(\)\[\]\{\}\"' + "'" + '\-\-\/\>\<\#\^\=\+\~\`]+')

    $CandidateTokens = [System.Collections.Generic.List[string]]::new()

    foreach ($Text in $ScannableTexts) {
        # Extract markdown link display text
        foreach ($Match in $MdLinkRegex.Matches($Text)) {
            $LinkText = $Match.Groups[1].Value.Trim()
            if ($LinkText.Length -ge 3) {
                $CandidateTokens.Add($LinkText)
            }
        }

        # Strip markdown links, then formatting markers
        $CleanText = $MdLinkRegex.Replace($Text, ' ')
        $CleanText = $CleanText.Replace('**', ' ').Replace('*', ' ').Replace('__', ' ').Replace('_', ' ')

        # Split into words
        $Words = $PunctuationRegex.Replace($CleanText, ' ').Split(
            [char[]]@(' '), [System.StringSplitOptions]::RemoveEmptyEntries
        )

        foreach ($Word in $Words) {
            if ($Word.Length -ge 3) {
                $CandidateTokens.Add($Word)
            }
        }
    }

    # Phase 4: Resolve Tokens (stages 1, 2, 2b only - no fuzzy)

    $ResolvedEntities = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Token in $CandidateTokens) {
        $Resolved = Resolve-Name -Query $Token -Index $Index -StemIndex $StemIndex -Cache $ResolveCache -NoFuzzy

        if ($null -ne $Resolved -and -not $ResolvedEntities.ContainsKey($Resolved.Name)) {
            $OwnerType = if ($Resolved.PSObject.Properties['Type']) { $Resolved.Type } else { 'Player' }
            $ResolvedEntities[$Resolved.Name] = [PSCustomObject]@{
                Owner     = $Resolved
                OwnerType = $OwnerType
            }
        }
    }

    # Phase 5: Build Output

    $Mentions = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in $ResolvedEntities.GetEnumerator()) {
        $IndexEntry = $Entry.Value
        $Mentions.Add([PSCustomObject]@{
            Name  = $IndexEntry.Owner.Name
            Type  = $IndexEntry.OwnerType
            Owner = $IndexEntry.Owner
        })
    }

    return $Mentions
}

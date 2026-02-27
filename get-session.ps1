<#
    .SYNOPSIS
    Parses session metadata from Markdown files into structured objects with format
    detection, narrator resolution, and cross-file deduplication.

    .DESCRIPTION
    This file contains Get-Session and its helpers:

    Helpers:
    - ConvertFrom-SessionHeader: parses a yyyy-MM-dd date (with optional /DD range)
      from a session header string
    - Get-SessionTitle: strips date and trailing narrator segment from a header to
      extract the session title
    - Get-SessionFormat: classifies a section as Gen1/Gen2/Gen3/Gen4 based on content
      heuristics (italic location lines, structured list items, @-prefixed tags, etc.)
    - Get-SessionLocations: extracts location names using format-appropriate strategy
      (italic regex for Gen2, entity resolution or tag-based fallback for Gen3/Gen4)
    - Get-SessionListMetadata: extracts PU awards, log URLs, entity state changes
      (Zmiany), and @Intel entries from structured list items (Gen3/Gen4 format,
      @ stripped via $MatchText)
    - Get-SessionPlainTextLogs: scans raw content lines for "Logi: <url>" patterns
      as a Gen1/Gen2 fallback
    - Merge-SessionGroup: deduplicates sessions sharing the same header across files,
      selecting the metadata-richest primary and merging array fields
    - Resolve-EntityWebhook: resolves Discord webhook URL for any entity, with Player
      fallback for character entities
    - Test-LocationMatch: checks if a @lokacja value matches any location in a set,
      handling slash-separated path values
    - Resolve-IntelTargets: resolves @Intel targeting directives (Grupa/, Lokacja/,
      Direct) into recipient entities with webhook URLs
    - Get-SessionMentions: extracts entity mentions from session body text using
      stages 1/2/2b of name resolution (no fuzzy), excluding metadata list items

    Get-Session scans Markdown files for level-3 headers containing a yyyy-MM-dd date
    and extracts structured session objects. It supports four format generations that
    evolved over time:
    - Gen1 (START-2022): plain text with no structured metadata
    - Gen2 (2022-2023): italic location lines (*Lokalizacja: ...*)
    - Gen3 (2024-2026): fully structured list-based metadata (- Lokalizacje:, - Logi:, - PU:).
      - Zmiany: blocks contain entity state overrides and are extracted to session objects.
      - Efekty: and Objaśnienia: are present in source but not extracted to session object fields.
    - Gen4 (2026+): @-prefixed list-based metadata (- @Lokacje:, - @PU:, - @Logi:, - @Zmiany:).
      Backwards compatible — Gen3 sessions parse identically to before.

    Key implementation decisions:
    - All Markdown files are batch-parsed in a single Get-Markdown call to enable
      RunspacePool parallelism for large directory scans
    - Narrator resolution is batched per file (Resolve-Narrator takes all parseable
      sections at once) so the shared name index is built only once
    - NarratorIdx tracking must stay in sync with ParseableIndices even when sessions
      are date-filtered out, because Resolve-Narrator returns results for all sections
    - Cross-file deduplication groups by exact header text (Ordinal comparison) and
      merges array fields (locations, logs, PU) via HashSet union
#>

# Helper: parse session date from header
# Extracts a yyyy-MM-dd date (and optional /DD range suffix) from a session
# header string. Returns hashtable: @{ Date; DateEnd; Match } or $null when
# no valid date is found in the header.
function ConvertFrom-SessionHeader {
    param(
        [string]$Header,
        [regex]$DateRegex,
        [object]$Match  # optional pre-matched regex result to avoid redundant matching
    )

    if (-not $Match) { $Match = $DateRegex.Match($Header) }
    if (-not $Match.Success) { return $null }

    $DateStr    = $Match.Groups[1].Value
    $EndDayStr  = $Match.Groups[2].Value

    [datetime]$Parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($DateStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
        return $null
    }

    $DateEnd = $null
    if ($EndDayStr) {
        [datetime]$EndParsed = [datetime]::MinValue
        $EndStr = $DateStr.Substring(0, 8) + $EndDayStr
        if ([datetime]::TryParseExact($EndStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$EndParsed)) {
            $DateEnd = $EndParsed
        }
    }

    return @{
        Date      = $Parsed
        DateEnd   = $DateEnd
        DateStr   = $DateStr
        EndDayStr = $EndDayStr
    }
}

# Helper: extract title from session header
# Strips the date portion and the trailing narrator part (last comma-delimited
# segment) from a session header, returning the session title.
function Get-SessionTitle {
    param(
        [string]$Header,
        [object]$DateInfo   # hashtable from ConvertFrom-SessionHeader
    )

    if ($null -eq $DateInfo) { return $Header }

    $DateIdx = $Header.IndexOf($DateInfo.DateStr)
    $DateLen = 10  # "yyyy-MM-dd"
    if ($DateInfo.EndDayStr) {
        $DateLen += 1 + $DateInfo.EndDayStr.Length
    }

    $TitlePart = $Header.Substring($DateIdx + $DateLen).Trim()

    # Remove narrator part (last comma-delimited segment)
    $LastComma = $TitlePart.LastIndexOf(',')
    if ($LastComma -gt 0) {
        return $TitlePart.Substring(0, $LastComma).Trim(" ,-".ToCharArray())
    }
    return $TitlePart.Trim(" ,-".ToCharArray())
}

# Helper: detect session format generation
# Determines the format generation based on content heuristics:
#   Gen1 (START-2022): No structured metadata, plain text Logi/Rezultat lines
#   Gen2 (2022-2023): Italic location line (*Lokalizacja: ...*), plain text Logi
#   Gen3 (2024-2026): List-based metadata (- Lokalizacje:, - Logi:, - PU:, etc.)
#   Gen4 (2026+):     @-prefixed list-based metadata (- @Lokacje:, - @PU:, etc.)
# Returns: "Gen1", "Gen2", "Gen3", or "Gen4"
function Get-SessionFormat {
    param(
        [string]$FirstNonEmptyLine,
        [object]$SectionLists
    )

    if ($FirstNonEmptyLine -and $FirstNonEmptyLine.StartsWith('*Lokalizacj')) {
        return "Gen2"
    }
    foreach ($LI in $SectionLists) {
        if ($LI.Indent -ne 0) { continue }
        $LowerText = $LI.Text.ToLowerInvariant()
        if ($LowerText.Length -gt 1 -and $LowerText[0] -eq '@' -and [char]::IsLetter($LowerText[1])) {
            return "Gen4"
        }
        if ($LowerText.Length -gt 2 -and $LowerText.StartsWith('pu') -and ($LowerText[2] -eq ':' -or $LowerText[2] -eq ' ')) {
            return "Gen3"
        }
    }
    return "Gen1"
}

# Helper: extract locations from section
# Parses location data using format-appropriate strategy. Gen2 uses italic line
# regex, Gen3/Gen4 uses structured list items or inline colon-separated values.
# Returns [System.Collections.Generic.List[string]].
function Get-SessionLocations {
    param(
        [string]$Format,
        [string]$FirstNonEmptyLine,
        [object]$SectionLists,
        [regex]$LocItalicRegex,
        [System.Collections.Generic.Dictionary[string, object]]$Index
    )

    $Locations = [System.Collections.Generic.List[string]]::new()

    switch ($Format) {
        'Gen2' {
            $LocMatch = $LocItalicRegex.Match($FirstNonEmptyLine)
            if ($LocMatch.Success) {
                foreach ($Part in $LocMatch.Groups[1].Value.Split(',')) {
                    $Trimmed = $Part.Trim()
                    if ($Trimmed.Length -gt 0) { $Locations.Add($Trimmed) }
                }
            }
        }
        { $_ -eq 'Gen3' -or $_ -eq 'Gen4' } {
            # Strategy 1: Entity resolution — find a nested list where all
            # resolved names are Lokacja entities (tag-name-independent)
            if ($Index) {
                foreach ($TopLI in $SectionLists) {
                    if ($TopLI.Indent -ne 0) { continue }

                    $Children = [System.Collections.Generic.List[object]]::new()
                    foreach ($LI in $SectionLists) {
                        if ($LI.ParentListItem -eq $TopLI) { $Children.Add($LI) }
                    }
                    if ($Children.Count -eq 0) { continue }

                    $ResolvedLocCount    = 0
                    $ResolvedNonLocCount = 0
                    foreach ($Child in $Children) {
                        $ChildText = $Child.Text.Trim()
                        if ($Index.ContainsKey($ChildText)) {
                            $Entry = $Index[$ChildText]
                            if (-not $Entry.Ambiguous -and $Entry.OwnerType -eq 'Lokacja') {
                                $ResolvedLocCount++
                            } else {
                                $ResolvedNonLocCount++
                            }
                        }
                    }

                    if ($ResolvedLocCount -gt 0 -and $ResolvedNonLocCount -eq 0) {
                        foreach ($Child in $Children) {
                            $Locations.Add($Child.Text.Trim())
                        }
                        break
                    }
                }
            }

            # Strategy 2: Tag-based fallback — look for "Lokalizacj*" or "Lokacj*" list item
            # Normalizes leading @ for Gen4 compatibility
            if ($Locations.Count -eq 0) {
                $LocList = $null
                foreach ($LI in $SectionLists) {
                    if ($LI.Indent -ne 0) { continue }
                    $TestText = if ($LI.Text.StartsWith('@')) { $LI.Text.Substring(1) } else { $LI.Text }
                    if ($TestText.StartsWith('Lokalizacj') -or $TestText.StartsWith('Lokacj')) {
                        $LocList = $LI
                        break
                    }
                }
                if ($LocList) {
                    foreach ($LI in $SectionLists) {
                        if ($LI.ParentListItem -eq $LocList) {
                            $Locations.Add($LI.Text.Trim())
                        }
                    }
                    if ($Locations.Count -eq 0) {
                        $ColonIdx = $LocList.Text.IndexOf(':')
                        if ($ColonIdx -ge 0) {
                            foreach ($Part in $LocList.Text.Substring($ColonIdx + 1).Trim().Split(',')) {
                                $Trimmed = $Part.Trim()
                                if ($Trimmed.Length -gt 0) { $Locations.Add($Trimmed) }
                            }
                        }
                    }
                }
            }
        }
    }

    return $Locations
}

# Helper: extract list-based metadata from section
# Processes structured list items (Gen3/Gen4 format) to extract PU, Logs, and Changes (Zmiany).
# Leading @ is stripped via $MatchText to support both Gen3 and Gen4 tag syntax.
# Returns hashtable with all three collections.
function Get-SessionListMetadata {
    param(
        [object]$SectionLists,
        [regex]$PURegex,
        [regex]$UrlRegex
    )

    $Logs         = [System.Collections.Generic.List[string]]::new()
    $PU           = [System.Collections.Generic.List[object]]::new()
    $Changes      = [System.Collections.Generic.List[object]]::new()
    $Intel        = [System.Collections.Generic.List[object]]::new()
    $Transfers    = [System.Collections.Generic.List[object]]::new()

    foreach ($ListItem in $SectionLists) {
        $ItemText  = $ListItem.Text
        $LowerText = $ItemText.ToLowerInvariant()
        $MatchText = if ($LowerText.StartsWith('@')) { $LowerText.Substring(1) } else { $LowerText }

        # PU entries: "- PU:" or "- @PU:" with nested "- CharName: 0,3"
        if ($MatchText.StartsWith('pu') -and $MatchText.Length -gt 2 -and ($MatchText[2] -eq ':' -or $MatchText[2] -eq ' ')) {
            foreach ($PUItem in $SectionLists) {
                if ($PUItem.ParentListItem -ne $ListItem) { continue }
                $PUMatch = $PURegex.Match($PUItem.Text)
                if ($PUMatch.Success) {
                    $CharName = $PUMatch.Groups[1].Value.Trim()
                    $ValueStr = $PUMatch.Groups[2].Value.Trim().Replace(',', '.')
                    [decimal]$DecValue = [decimal]::Zero
                    if ([decimal]::TryParse($ValueStr, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$DecValue)) {
                        $PU.Add([PSCustomObject]@{ Character = $CharName; Value = $DecValue })
                    } else {
                        $PU.Add([PSCustomObject]@{ Character = $CharName; Value = $null })
                    }
                }
            }
        }

        # Logi: URLs (or @Logi: in Gen4)
        if ($MatchText.StartsWith('logi') -and $MatchText.Length -gt 4 -and ($MatchText[4] -eq ':' -or $MatchText[4] -eq ' ')) {
            foreach ($LogItem in $SectionLists) {
                if ($LogItem.ParentListItem -ne $ListItem) { continue }
                $UrlMatch = $UrlRegex.Match($LogItem.Text)
                if ($UrlMatch.Success) {
                    $Logs.Add($UrlMatch.Groups[1].Value)
                }
            }
            # Also check inline
            $InlineUrl = $UrlRegex.Match($ItemText)
            if ($InlineUrl.Success -and -not $Logs.Contains($InlineUrl.Groups[1].Value)) {
                $Logs.Add($InlineUrl.Groups[1].Value)
            }
        }

        # Zmiany: entity state changes (session-based overrides)
        # Structure: - Zmiany: / - EntityName / - @tag: value (or - @Zmiany: in Gen4)
        if ($MatchText.StartsWith('zmiany') -and ($MatchText.Length -eq 6 -or $MatchText[6] -eq ':' -or $MatchText[6] -eq ' ')) {
            foreach ($EntityItem in $SectionLists) {
                if ($EntityItem.ParentListItem -ne $ListItem) { continue }

                $EntityName = $EntityItem.Text.Trim()
                $Tags = [System.Collections.Generic.List[object]]::new()

                foreach ($TagItem in $SectionLists) {
                    if ($TagItem.ParentListItem -ne $EntityItem) { continue }

                    $TagText = $TagItem.Text.Trim()
                    if (-not $TagText.StartsWith('@')) { continue }

                    $ColonIdx = $TagText.IndexOf(':')
                    if ($ColonIdx -lt 0) { continue }

                    $Tags.Add([PSCustomObject]@{
                        Tag   = $TagText.Substring(0, $ColonIdx).Trim().ToLowerInvariant()
                        Value = $TagText.Substring($ColonIdx + 1).Trim()
                    })
                }

                if ($Tags.Count -gt 0) {
                    $Changes.Add([PSCustomObject]@{
                        EntityName = $EntityName
                        Tags       = $Tags.ToArray()
                    })
                }
            }
        }

        # Intel: targeted messages (or @Intel: in Gen4)
        if ($MatchText.StartsWith('intel') -and ($MatchText.Length -eq 5 -or $MatchText[5] -eq ':' -or $MatchText[5] -eq ' ')) {
            foreach ($IntelItem in $SectionLists) {
                if ($IntelItem.ParentListItem -ne $ListItem) { continue }

                $IntelText = $IntelItem.Text.Trim()
                $ColonIdx = $IntelText.IndexOf(':')
                if ($ColonIdx -lt 0) { continue }

                $RawTarget = $IntelText.Substring(0, $ColonIdx).Trim()
                $Message   = $IntelText.Substring($ColonIdx + 1).Trim()

                if ([string]::IsNullOrWhiteSpace($RawTarget) -or [string]::IsNullOrWhiteSpace($Message)) { continue }

                $Intel.Add([PSCustomObject]@{
                    RawTarget = $RawTarget
                    Message   = $Message
                })
            }
        }

        # Transfer: currency convenience shorthand
        # Format: "- @Transfer: {amount} {denomination}, {source} -> {destination}"
        if ($MatchText.StartsWith('transfer') -and $MatchText.Length -gt 8 -and ($MatchText[8] -eq ':' -or $MatchText[8] -eq ' ')) {
            $TransferValue = $ItemText
            $TColonIdx = $TransferValue.IndexOf(':')
            if ($TColonIdx -ge 0) {
                $TransferBody = $TransferValue.Substring($TColonIdx + 1).Trim()
                # Parse: "{amount} {denomination}, {source} -> {destination}"
                $ArrowIdx = $TransferBody.IndexOf('->')
                $CommaIdx = $TransferBody.IndexOf(',')
                if ($ArrowIdx -gt 0 -and $CommaIdx -gt 0 -and $CommaIdx -lt $ArrowIdx) {
                    $AmountDenom = $TransferBody.Substring(0, $CommaIdx).Trim()
                    $Source = $TransferBody.Substring($CommaIdx + 1, $ArrowIdx - $CommaIdx - 1).Trim()
                    $Destination = $TransferBody.Substring($ArrowIdx + 2).Trim()

                    # Split amount and denomination from "{amount} {denomination}"
                    $SpaceIdx = $AmountDenom.IndexOf(' ')
                    if ($SpaceIdx -gt 0) {
                        $AmountStr = $AmountDenom.Substring(0, $SpaceIdx).Trim()
                        $DenomStr = $AmountDenom.Substring($SpaceIdx + 1).Trim()
                        [int]$TransferAmount = 0
                        if ([int]::TryParse($AmountStr, [ref]$TransferAmount) -and $TransferAmount -gt 0 `
                            -and -not [string]::IsNullOrWhiteSpace($Source) `
                            -and -not [string]::IsNullOrWhiteSpace($Destination)) {
                            $Transfers.Add([PSCustomObject]@{
                                Amount       = $TransferAmount
                                Denomination = $DenomStr
                                Source       = $Source
                                Destination  = $Destination
                            })
                        }
                    }
                }
            }
        }

    }

    return @{
        Logs      = $Logs
        PU        = $PU
        Changes   = $Changes
        Intel     = $Intel
        Transfers = $Transfers
    }
}

# Helper: extract plain text log URLs (Gen1/Gen2 fallback)
# Scans raw content lines for "Logi: <url>" patterns when no list-based logs
# were found. Returns URLs as [System.Collections.Generic.List[string]].
function Get-SessionPlainTextLogs {
    param(
        [string[]]$ContentLines,
        [regex]$LogiLineRegex
    )

    $Logs = [System.Collections.Generic.List[string]]::new()
    foreach ($Line in $ContentLines) {
        $Match = $LogiLineRegex.Match($Line)
        if ($Match.Success) {
            $Logs.Add($Match.Groups[1].Value)
        }
    }
    return $Logs
}

# Helper: merge duplicate sessions
# Given a group of sessions sharing the same header, selects the primary (most
# metadata-rich) and merges array fields from all duplicates. Returns a single
# merged session object.
function Merge-SessionGroup {
    param(
        [System.Collections.Generic.List[object]]$Group,
        [bool]$IncludeContent
    )

    $Count = $Group.Count

    if ($Count -eq 1) {
        $S = $Group[0]
        $S.FilePaths      = @($S.FilePath)
        $S.IsMerged       = $false
        $S.DuplicateCount = 1
        return $S
    }

    # Pick primary: highest metadata score
    $Primary      = $Group[0]
    $PrimaryScore = 0
    foreach ($S in $Group) {
        $Score = 0
        if ($S.Date)       { $Score++ }
        if ($S.Title)      { $Score++ }
        if ($S.Narrator -and $S.Narrator.Narrators.Count -gt 0) { $Score++ }
        if ($S.Locations -and $S.Locations.Count -gt 0) { $Score++ }
        if ($S.Logs -and $S.Logs.Count -gt 0)           { $Score++ }
        if ($S.PU -and $S.PU.Count -gt 0)                { $Score++ }
        if ($S.Content) { $Score += 2 }
        if ($Score -gt $PrimaryScore) {
            $Primary      = $S
            $PrimaryScore = $Score
        }
    }

    # Collect all file paths (HashSet for O(1) dedup)
    $AllFilePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($S in $Group) {
        [void]$AllFilePaths.Add($S.FilePath)
    }

    # Conflict detection for scalar fields
    if ($null -ne $Primary.Date) {
        $ScalarFields = @('Title', 'Format')
        foreach ($FieldName in $ScalarFields) {
            $DistinctValues = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($S in $Group) {
                $Val = $S.$FieldName
                if ($null -ne $Val) { [void]$DistinctValues.Add($Val.ToString()) }
            }
            if ($DistinctValues.Count -gt 1) {
                $ValList = $DistinctValues -join ' vs '
                [System.Console]::Error.WriteLine("[WARN Get-Session] Dedup conflict on '$FieldName' for header '$($Primary.Header)': $ValList")
            }
        }
    }

    # Merge array fields: union unique values
    $MergedLocations    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedLogs         = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedPU           = [System.Collections.Generic.List[object]]::new()
    $PUSet              = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedChanges      = [System.Collections.Generic.List[object]]::new()
    $MergedTransfers    = [System.Collections.Generic.List[object]]::new()
    $MergedMentions     = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MergedIntel        = [System.Collections.Generic.List[object]]::new()
    $IntelSet           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($S in $Group) {
        if ($S.Locations) {
            foreach ($L in $S.Locations) { [void]$MergedLocations.Add($L) }
        }
        if ($S.Logs) {
            foreach ($L in $S.Logs) { [void]$MergedLogs.Add($L) }
        }
        if ($S.PU) {
            foreach ($P in $S.PU) {
                $PUKey = "$($P.Character)|$($P.Value)"
                if ($PUSet.Add($PUKey)) { $MergedPU.Add($P) }
            }
        }
        if ($S.Changes) {
            foreach ($C in $S.Changes) { $MergedChanges.Add($C) }
        }
        if ($S.Transfers) {
            foreach ($T in $S.Transfers) { $MergedTransfers.Add($T) }
        }
        if ($S.Mentions) {
            foreach ($M in $S.Mentions) {
                if (-not $MergedMentions.ContainsKey($M.Name)) {
                    $MergedMentions[$M.Name] = $M
                }
            }
        }
        if ($S.Intel) {
            foreach ($I in $S.Intel) {
                $IntelKey = "$($I.RawTarget)|$($I.Message)"
                if ($IntelSet.Add($IntelKey)) {
                    $MergedIntel.Add($I)
                }
            }
        }
    }

    $MergedContent = $null
    if ($IncludeContent) {
        $LongestLen = -1
        foreach ($S in $Group) {
            if ($S.Content -and $S.Content.Length -gt $LongestLen) {
                $LongestLen    = $S.Content.Length
                $MergedContent = $S.Content
            }
        }
    }

    $Merged = [PSCustomObject]@{
        FilePath       = $Primary.FilePath
        FilePaths      = [string[]]$AllFilePaths
        Header         = $Primary.Header
        Date           = $Primary.Date
        DateEnd        = $Primary.DateEnd
        Title          = $Primary.Title
        Narrator       = $Primary.Narrator
        Locations      = [string[]]$MergedLocations
        Logs           = [string[]]$MergedLogs
        PU             = $MergedPU.ToArray()
        Format         = $Primary.Format
        IsMerged       = $true
        DuplicateCount = $Count
        Content        = $MergedContent
        Changes        = $MergedChanges.ToArray()
        Transfers      = $MergedTransfers.ToArray()
        Mentions       = [object[]]$MergedMentions.Values
        Intel          = $MergedIntel.ToArray()
    }

    return $Merged
}

# Helper: resolve Discord webhook URL for any entity, with Player fallback
# for character entities. Checks entity @prfwebhook override first, then
# falls back to owning Player's PRFWebhook for Gracz/Postać (Gracz) types.
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

    # 2. For Postać (Gracz) or Gracz: find owning Player's webhook
    if ($Entity.Type -in @('Postać (Gracz)', 'Gracz')) {
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
            # Resolve via name index (stages 1, 2, 2b — no fuzzy)
            $Resolved = $null

            if ($Index.ContainsKey($TName)) {
                $IdxEntry = $Index[$TName]
                if (-not $IdxEntry.Ambiguous) { $Resolved = $IdxEntry.Owner }
            }

            if (-not $Resolved) {
                $Stem = Get-DeclensionStem -Text $TName
                if ($StemIndex -and $StemIndex.ContainsKey($Stem)) {
                    foreach ($TokenKey in $StemIndex[$Stem]) {
                        if ($Index.ContainsKey($TokenKey)) {
                            $IdxEntry = $Index[$TokenKey]
                            if (-not $IdxEntry.Ambiguous) { $Resolved = $IdxEntry.Owner; break }
                        }
                    }
                }
            }

            if (-not $Resolved) {
                $Candidates = Get-StemAlternationCandidates -Text $TName
                foreach ($Candidate in $Candidates) {
                    if ($Index.ContainsKey($Candidate)) {
                        $IdxEntry = $Index[$Candidate]
                        if (-not $IdxEntry.Ambiguous) { $Resolved = $IdxEntry.Owner; break }
                    }
                }
            }

            if (-not $Resolved) {
                [System.Console]::Error.WriteLine("[WARN @Intel] Unresolved target '$TName'")
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
        if ($Lower.StartsWith('pu') -and ($Lower.Length -eq 2 -or $Lower[2] -eq ':' -or $Lower[2] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('logi') -and ($Lower.Length -eq 4 -or $Lower[4] -eq ':' -or $Lower[4] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('lokalizacj') -or $Lower.StartsWith('lokacj')) { $IsExcluded = $true }
        if ($Lower.StartsWith('zmiany') -and ($Lower.Length -eq 6 -or $Lower[6] -eq ':' -or $Lower[6] -eq ' ')) { $IsExcluded = $true }
        if ($Lower.StartsWith('intel') -and ($Lower.Length -eq 5 -or $Lower[5] -eq ':' -or $Lower[5] -eq ' ')) { $IsExcluded = $true }

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
    $PunctuationRegex = [regex]::new('[,\.\;\:\!\?\(\)\[\]\{\}\"' + "'" + '\-\—\/\>\<\#\^\=\+\~\`]+')

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

    # Phase 4: Resolve Tokens (stages 1, 2, 2b only — no fuzzy)

    $ResolvedEntities = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Token in $CandidateTokens) {
        $CacheKey = $Token
        if ($ResolveCache.ContainsKey($CacheKey)) {
            $Cached = $ResolveCache[$CacheKey]
            if ($Cached -is [System.DBNull]) { continue }
            if (-not $ResolvedEntities.ContainsKey($Cached.Name)) {
                $ResolvedEntities[$Cached.Name] = [PSCustomObject]@{
                    Owner     = $Cached
                    OwnerType = if ($Cached.PSObject.Properties['Type']) { $Cached.Type } else { 'Player' }
                }
            }
            continue
        }

        $Resolved = $null

        # Stage 1: Exact index lookup
        if ($Index.ContainsKey($Token)) {
            $Entry = $Index[$Token]
            if (-not $Entry.Ambiguous) { $Resolved = $Entry }
        }

        # Stage 2: Declension-stripped match
        if (-not $Resolved) {
            $Stem = Get-DeclensionStem -Text $Token
            if ($StemIndex -and $StemIndex.ContainsKey($Stem)) {
                foreach ($TokenKey in $StemIndex[$Stem]) {
                    if ($Index.ContainsKey($TokenKey)) {
                        $Entry = $Index[$TokenKey]
                        if (-not $Entry.Ambiguous) { $Resolved = $Entry; break }
                    }
                }
            }
        }

        # Stage 2b: Stem alternation
        if (-not $Resolved) {
            $Candidates = Get-StemAlternationCandidates -Text $Token
            foreach ($Candidate in $Candidates) {
                if ($Index.ContainsKey($Candidate)) {
                    $Entry = $Index[$Candidate]
                    if (-not $Entry.Ambiguous) { $Resolved = $Entry; break }
                }
            }
        }

        if ($Resolved) {
            $ResolveCache[$CacheKey] = $Resolved.Owner
            if (-not $ResolvedEntities.ContainsKey($Resolved.Owner.Name)) {
                $ResolvedEntities[$Resolved.Owner.Name] = $Resolved
            }
        } else {
            $ResolveCache[$CacheKey] = [System.DBNull]::Value
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

function Get-Session {
    <#
        .SYNOPSIS
        Parses session metadata from Markdown files into structured objects with
        format detection, narrator resolution, and cross-file deduplication.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Include only sessions on or after this date")]
        [datetime]$MinDate = [datetime]::Parse("2000-01-01"),

        [Parameter(HelpMessage = "Include only sessions on or before this date")]
        [datetime]$MaxDate = [datetime]::Now,

        [Parameter(HelpMessage = "Path to a specific Markdown file to parse")]
        [string]$File,

        [Parameter(HelpMessage = "Path to a directory to scan for Markdown files")]
        [string]$Directory,

        [Parameter(HelpMessage = "Include full session content text in output")]
        [switch]$IncludeContent,

        [Parameter(HelpMessage = "Include entity mentions extracted from session body text")]
        [switch]$IncludeMentions,

        [Parameter(HelpMessage = "Include sessions that failed header parsing (no valid date)")]
        [switch]$IncludeFailed
    )

    $RepoRoot = Get-RepoRoot

    # Collect input files

    if (-not $File -and -not $Directory) {
        $Directory = $RepoRoot
    }

    $FilesToProcess = [System.Collections.Generic.List[string]]::new()

    if ($File) {
        if ([System.IO.File]::Exists($File)) {
            $FilesToProcess.Add($File)
        }
    } else {
        $SearchDir = if ($Directory) { $Directory } else { $RepoRoot }
        $AllFiles = [System.IO.Directory]::GetFiles($SearchDir, "*.md", [System.IO.SearchOption]::AllDirectories)
        $FilesToProcess.AddRange($AllFiles)
    }

    # Pre-fetch shared dependencies

    $Entities = Get-Entity
    $Players  = Get-Player -Entities $Entities
    $NameIndexResult = Get-NameIndex -Players $Players -Entities $Entities
    $Index     = $NameIndexResult.Index
    $StemIndex = $NameIndexResult.StemIndex
    $BKTree    = $NameIndexResult.BKTree

    $MentionCache = @{}
    $IntelCache   = @{}

    # Precompile regex patterns

    $DateRegex      = [regex]::new('\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b')
    $LocItalicRegex = [regex]::new('\*Lokalizacj[ae]?:\s*(.+?)\*')
    $PURegex        = [regex]::new('^(.+?):\s*([\d,\.]+)')
    $UrlRegex       = [regex]::new('(https?://\S+)')
    $LogiLineRegex  = [regex]::new('^Logi:\s*(https?://\S+)')

    # Results collection

    $AllSessions    = [System.Collections.Generic.List[object]]::new()
    $FailedSessions = [System.Collections.Generic.List[object]]::new()

    # Batch-parse all Markdown files in a single call

    $AllMarkdownResults = @(Get-Markdown -File ($FilesToProcess.ToArray()))
    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($md in $AllMarkdownResults) { $MarkdownByPath[$md.FilePath] = $md }

    # Main file processing loop

    foreach ($FilePath in $FilesToProcess) {

        $Markdown = if ($MarkdownByPath.ContainsKey($FilePath)) { $MarkdownByPath[$FilePath] } else { $null }
        if ($null -eq $Markdown) { continue }

        $SessionSections = $Markdown.Sections.Where({ $_.Header -and $_.Header.Level -eq 3 })
        if ($SessionSections.Count -eq 0) { continue }

        # Single pass: pre-filter + cache date regex matches + build parseable sections list.
        # Merges what was previously two separate passes over $SessionSections.
        $HasCandidateSession = $false
        $ParseableSections   = [System.Collections.Generic.List[object]]::new()
        $ParseableIndices    = [System.Collections.Generic.HashSet[int]]::new()
        $CachedDateMatches   = [System.Collections.Generic.Dictionary[int, object]]::new()

        for ($i = 0; $i -lt $SessionSections.Count; $i++) {
            $Sect = $SessionSections[$i]
            $DMatch = $DateRegex.Match($Sect.Header.Text)
            $CachedDateMatches[$i] = $DMatch

            if ($DMatch.Success) {
                $ParseableSections.Add($Sect)
                [void]$ParseableIndices.Add($i)

                if (-not $HasCandidateSession) {
                    $DStr = $DMatch.Groups[1].Value
                    [datetime]$DParsed = [datetime]::MinValue
                    if ([datetime]::TryParseExact($DStr, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$DParsed)) {
                        if ($DParsed -ge $MinDate -and $DParsed -le $MaxDate) {
                            $HasCandidateSession = $true
                        }
                    }
                }
            } else {
                # No date — can't filter out, must process (or skip as failed)
                $HasCandidateSession = $true
            }
        }
        if (-not $HasCandidateSession) { continue }

        $NarratorResults = $null
        if ($ParseableSections.Count -gt 0) {
            $NarratorResults = Resolve-Narrator -Sessions $ParseableSections.ToArray() -Index $Index -StemIndex $StemIndex -BKTree $BKTree
        }

        # Process each section

        $NarratorIdx = 0
        for ($i = 0; $i -lt $SessionSections.Count; $i++) {
            $Section = $SessionSections[$i]
            $Header  = $Section.Header.Text

            # Parse date from header (using cached regex match)
            $CachedMatch = if ($CachedDateMatches.ContainsKey($i)) { $CachedDateMatches[$i] } else { $null }
            $DateInfo = ConvertFrom-SessionHeader -Header $Header -DateRegex $DateRegex -Match $CachedMatch

            if ($null -eq $DateInfo) {
                # Header does not match session pattern — record as failed
                if ($IncludeFailed) {
                    $FailedSession = [PSCustomObject]@{
                        FilePath       = $FilePath
                        FilePaths      = @($FilePath)
                        Header         = $Header
                        Date           = $null
                        DateEnd        = $null
                        Title          = $Header
                        Narrator       = $null
                        Locations      = @()
                        Logs           = @()
                        PU             = @()
                        Format         = "Unknown"
                        IsMerged       = $false
                        DuplicateCount = 0
                        Content        = if ($IncludeContent) { $Section.Content } else { $null }
                        Changes        = @()
                        Mentions       = @()
                        Intel          = @()
                        ParseError     = "Header does not contain a valid yyyy-MM-dd date"
                    }
                    $FailedSessions.Add($FailedSession)
                }
                continue
            }

            # Narrator result (aligned with parseable sections index)
            # Must be extracted BEFORE date filtering to keep $NarratorIdx in sync
            # with $ParseableIndices — skipped sessions must still consume their slot.
            $NarratorResult = $null
            if ($NarratorResults -and $ParseableIndices.Contains($i)) {
                $NarratorResult = if ($NarratorResults -is [array]) { $NarratorResults[$NarratorIdx] } else { $NarratorResults }
                $NarratorIdx++
            }

            # Date filtering
            if ($DateInfo.Date -lt $MinDate -or $DateInfo.Date -gt $MaxDate) { continue }

            # Title extraction
            $Title = Get-SessionTitle -Header $Header -DateInfo $DateInfo

            # Format detection
            $ContentLines = $Section.Content.Split([char]"`n")

            $FirstNonEmptyLine = $null
            foreach ($CLine in $ContentLines) {
                if (-not [string]::IsNullOrWhiteSpace($CLine)) {
                    $FirstNonEmptyLine = $CLine
                    break
                }
            }

            $Format = Get-SessionFormat -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists

            # Location extraction
            $Locations = Get-SessionLocations -Format $Format -FirstNonEmptyLine $FirstNonEmptyLine -SectionLists $Section.Lists -LocItalicRegex $LocItalicRegex -Index $Index

            # List-based metadata (PU, Logs)
            $ListMeta = Get-SessionListMetadata -SectionLists $Section.Lists -PURegex $PURegex -UrlRegex $UrlRegex

            $Logs    = $ListMeta.Logs
            $PU      = $ListMeta.PU
            $Changes = $ListMeta.Changes
            $Transfers = $ListMeta.Transfers

            # Plain text log fallback (Gen 1/2)
            if ($Logs.Count -eq 0) {
                $Logs = Get-SessionPlainTextLogs -ContentLines $ContentLines -LogiLineRegex $LogiLineRegex
            }

            # Mention extraction
            $MentionsV = @()
            if ($IncludeMentions) {
                $RawMentions = Get-SessionMentions `
                    -Content $Section.Content `
                    -SectionLists $Section.Lists `
                    -Format $Format `
                    -FirstNonEmptyLine $FirstNonEmptyLine `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -ResolveCache $MentionCache
                $MentionsV = if ($RawMentions -and $RawMentions.Count -gt 0) { @($RawMentions) } else { @() }
            }

            # Intel resolution — always runs when @Intel entries exist
            $IntelV = @()
            if ($ListMeta.Intel -and $ListMeta.Intel.Count -gt 0 -and $null -ne $DateInfo.Date) {
                $ResolvedIntel = Resolve-IntelTargets `
                    -RawIntel $ListMeta.Intel `
                    -SessionDate $DateInfo.Date `
                    -Entities $Entities `
                    -Index $Index `
                    -StemIndex $StemIndex `
                    -Players $Players `
                    -ResolveCache $IntelCache
                $IntelV = if ($ResolvedIntel -and $ResolvedIntel.Count -gt 0) { @($ResolvedIntel) } else { @() }
            }

            # Build session object
            $LocationsV = if ($Locations) { @($Locations) } else { @() }
            $LogsV = if ($Logs) { @($Logs) } else { @() }
            $PUV = if ($PU) { @($PU) } else { @() }
            $ChangesV = if ($Changes -and $Changes.Count -gt 0) { @($Changes) } else { @() }
            $TransfersV = if ($Transfers -and $Transfers.Count -gt 0) { @($Transfers) } else { @() }

            $SessionProps = [ordered]@{
                FilePath       = $FilePath
                FilePaths      = $null
                Header         = $Header
                Date           = $DateInfo.Date
                DateEnd        = $DateInfo.DateEnd
                Title          = $Title
                Narrator       = $NarratorResult
                Locations      = $LocationsV
                Logs           = $LogsV
                PU             = $PUV
                Format         = $Format
                IsMerged       = $false
                DuplicateCount = 1
                Content        = if ($IncludeContent) { $Section.Content } else { $null }
                Changes        = $ChangesV
                Transfers      = $TransfersV
                Mentions       = $MentionsV
                Intel          = $IntelV
            }
            $AllSessions.Add([PSCustomObject]$SessionProps)
        }
    }

    # Deduplication pass

    $SessionsByHeader = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($Sess in $AllSessions) {
        if (-not $SessionsByHeader.ContainsKey($Sess.Header)) {
            $SessionsByHeader[$Sess.Header] = [System.Collections.Generic.List[object]]::new()
        }
        $SessionsByHeader[$Sess.Header].Add($Sess)
    }

    $DedupSessions = [System.Collections.Generic.List[object]]::new($SessionsByHeader.Count)

    foreach ($Entry in $SessionsByHeader.GetEnumerator()) {
        $Merged = Merge-SessionGroup -Group $Entry.Value -IncludeContent $IncludeContent.IsPresent
        $DedupSessions.Add($Merged)
    }

    # Filter out entries with no parsed date — these are non-session headers
    $Filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($S in $DedupSessions) {
        if ($null -ne $S.Date) { $Filtered.Add($S) }
    }

    # Append failed sessions if requested

    if ($IncludeFailed -and $FailedSessions.Count -gt 0) {
        foreach ($F in $FailedSessions) {
            $Filtered.Add($F)
        }
    }

    return $Filtered
}

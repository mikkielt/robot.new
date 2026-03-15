<#
    .SYNOPSIS
    Session content parsing helpers for format-specific metadata extraction.

    .DESCRIPTION
    This file contains helpers extracted from get-session.ps1 that handle
    format-specific parsing of session content:

    Helpers:
    - Get-SessionTitle:        strips date and trailing narrator segment from a header
                               to extract the session title
    - Get-SessionLocations:    extracts location names using format-appropriate strategy
                               (italic regex for Gen2, entity resolution or tag-based
                               fallback for Gen3/Gen4)
    - Get-SessionListMetadata: extracts PU awards, log URLs, entity state changes
                               (Zmiany), @Intel entries, @Transfer entries, @Narrator
                               overrides, and @Data overrides from structured list items
                               (Gen3/Gen4 format, @ stripped via $MatchText)
    - Get-SessionPlainTextLogs: scans raw content lines for "Logi: <url>" patterns
                               as a Gen1/Gen2 fallback

    Module-level data:
    - $PUSectionPattern:  precompiled regex matching PU section markers ("- PU:" or "- @PU:")

    These helpers are dot-sourced by get-session.ps1 and are not auto-loaded
    by the module loader.
#>

# PU section header pattern - matches "- PU:" or "- @PU:" list markers in session content.
# Used by Test-PlayerCharacterPUAssignment and Test-SessionIntegrity for diagnostics.
$script:PUSectionPattern = [regex]::new('^\s*[-\*]\s+@?[Pp][Uu]\s*:', [System.Text.RegularExpressions.RegexOptions]::Compiled)

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
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [Parameter(Mandatory)]
        [hashtable]$ChildrenOf
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
            $LocChildrenOf = $ChildrenOf

            # Strategy 1: Entity resolution - find a nested list where all
            # resolved names are Lokacja entities (tag-name-independent)
            if ($Index) {
                foreach ($TopLI in $SectionLists) {
                    if ($TopLI.Indent -ne 0) { continue }

                    $TopLIId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($TopLI)
                    $Children = if ($LocChildrenOf.ContainsKey($TopLIId)) { $LocChildrenOf[$TopLIId] } else { $null }
                    if (-not $Children -or $Children.Count -eq 0) { continue }

                    $CandidateNames      = [System.Collections.Generic.List[string]]::new($Children.Count)
                    $ResolvedLocCount    = 0
                    $ResolvedNonLocCount = 0
                    foreach ($Child in $Children) {
                        $ChildText = $Child.Text.Trim()
                        $CandidateNames.Add($ChildText)
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
                        $Locations.AddRange($CandidateNames)
                        break
                    }
                }
            }

            # Strategy 2: Tag-based fallback - look for "Lokalizacj*" or "Lokacj*" list item
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
                    $LocListId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LocList)
                    $LocChildren = if ($LocChildrenOf.ContainsKey($LocListId)) { $LocChildrenOf[$LocListId] } else { $null }
                    if ($LocChildren) {
                        foreach ($LI in $LocChildren) {
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
        [regex]$UrlRegex,
        [Parameter(Mandatory)]
        [hashtable]$ChildrenOf
    )

    $Logs         = [System.Collections.Generic.List[string]]::new()
    $PU           = [System.Collections.Generic.List[object]]::new()
    $Changes      = [System.Collections.Generic.List[object]]::new()
    $Intel        = [System.Collections.Generic.List[object]]::new()
    $Transfers    = [System.Collections.Generic.List[object]]::new()
    $Narrators    = [System.Collections.Generic.List[string]]::new()
    $DateOverride = $null

    foreach ($ListItem in $SectionLists) {
        $ItemText  = $ListItem.Text
        $LowerText = $ItemText.ToLowerInvariant()
        $MatchText = if ($LowerText.StartsWith('@')) { $LowerText.Substring(1) } else { $LowerText }

        # Pre-built parent-to-children hashtable avoids scanning the full list per item
        $ListItemId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ListItem)
        $Children = if ($ChildrenOf.ContainsKey($ListItemId)) { $ChildrenOf[$ListItemId] } else { $null }

        # PU entries: "- PU:" or "- @PU:" with nested "- CharName: 0,3"
        if ($MatchText.StartsWith('pu') -and $MatchText.Length -gt 2 -and ($MatchText[2] -eq ':' -or $MatchText[2] -eq ' ')) {
            if ($Children) {
                foreach ($PUItem in $Children) {
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
        }

        # Logi: URLs or local paths (or @Logi: in Gen4)
        if ($MatchText.StartsWith('logi') -and $MatchText.Length -gt 4 -and ($MatchText[4] -eq ':' -or $MatchText[4] -eq ' ')) {
            if ($Children) {
                foreach ($LogItem in $Children) {
                    $LogItemText = $LogItem.Text.Trim()
                    $UrlMatch = $UrlRegex.Match($LogItemText)
                    if ($UrlMatch.Success) {
                        $Logs.Add($UrlMatch.Groups[1].Value)
                    } elseif ($LogItemText.StartsWith('res/logs/')) {
                        # Local file path (URL localized during migration)
                        $Logs.Add($LogItemText)
                    }
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
            if ($Children) {
                foreach ($EntityItem in $Children) {
                    $EntityName = $EntityItem.Text.Trim()
                    $Tags = [System.Collections.Generic.List[object]]::new()

                    # Pre-built parent-to-children hashtable avoids scanning the full list per tag
                    $EntityItemId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($EntityItem)
                    $TagChildren = if ($ChildrenOf.ContainsKey($EntityItemId)) { $ChildrenOf[$EntityItemId] } else { $null }

                    if ($TagChildren) {
                        foreach ($TagItem in $TagChildren) {
                            $TagText = $TagItem.Text.Trim()
                            if (-not $TagText.StartsWith('@')) { continue }

                            $ColonIdx = $TagText.IndexOf(':')
                            if ($ColonIdx -lt 0) { continue }

                            $Tags.Add([PSCustomObject]@{
                                Tag   = $TagText.Substring(0, $ColonIdx).Trim().ToLowerInvariant()
                                Value = $TagText.Substring($ColonIdx + 1).Trim()
                            })
                        }
                    }

                    if ($Tags.Count -gt 0) {
                        $Changes.Add([PSCustomObject]@{
                            EntityName = $EntityName
                            Tags       = $Tags.ToArray()
                        })
                    }
                }
            }
        }

        # Intel: targeted messages (or @Intel: in Gen4)
        if ($MatchText.StartsWith('intel') -and ($MatchText.Length -eq 5 -or $MatchText[5] -eq ':' -or $MatchText[5] -eq ' ')) {
            if ($Children) {
                foreach ($IntelItem in $Children) {
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
        }

        # Narrator: canonical names for @Narrator metadata override
        if ($MatchText.StartsWith('narrator') -and ($MatchText.Length -eq 8 -or $MatchText[8] -eq ':' -or $MatchText[8] -eq ' ')) {
            if ($Children) {
                foreach ($NarrItem in $Children) {
                    $NarrName = $NarrItem.Text.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($NarrName)) {
                        $Narrators.Add($NarrName)
                    }
                }
            }
        }

        # Data: date override (YYYY-MM-DD) for sessions with malformed header dates
        if ($MatchText.StartsWith('data') -and $MatchText.Length -gt 4 -and ($MatchText[4] -eq ':' -or $MatchText[4] -eq ' ')) {
            # Inline value: "- @Data: 2024-07-14"
            $DataColonIdx = $ItemText.IndexOf(':')
            if ($DataColonIdx -ge 0) {
                $DataInline = $ItemText.Substring($DataColonIdx + 1).Trim()
                if ($DataInline.Length -gt 0) {
                    $DateOverride = $DataInline
                } else {
                    # Child list item: "- @Data:\n    - 2024-07-14"
                    if ($Children) {
                        foreach ($DataItem in $Children) {
                            $DataVal = $DataItem.Text.Trim()
                            if (-not [string]::IsNullOrWhiteSpace($DataVal)) {
                                $DateOverride = $DataVal
                                break
                            }
                        }
                    }
                }
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
        Logs         = $Logs
        PU           = $PU
        Changes      = $Changes
        Intel        = $Intel
        Transfers    = $Transfers
        Narrators    = $Narrators
        DateOverride = $DateOverride
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

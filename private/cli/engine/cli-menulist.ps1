<#
    .SYNOPSIS
    Menu list component for the Robot CLI TUI engine.

    .DESCRIPTION
    Arrow-navigable menu with role tags, InfoText display, inline filtering
    (stages 1-2 immediate, stage 3 fuzzy via debounce callback), and
    match highlighting.

    Helpers:
    - New-MenuListComponent:   creates a menu list component from item array
    - Invoke-MenuFilter:       applies stage 1+2 filter (prefix + contains) to items
    - Invoke-MenuFuzzyExtend:  appends stage 3 fuzzy/declension matches after debounce

    Component contract:
    - Render:    writes menu items into Content region with pointer, role tags, highlight
    - HandleKey: Navigate (Up/Down), Select (returns item ID), FilterStart/Update/Clear
    - Returns:   item ID (string) via Select action

    Dependencies:
    - cli-engine.ps1:  Get-Region, Get-RegionHeight, Get-CLIColor, $script:ScreenWidth
    - cli-buffer.ps1:  New-Segment, Set-BufferLine, Clear-BufferRegion, $script:BackBuffer
    - cli-chrome.ps1:  Split-HighlightSegments
    - cli-input.ps1:   Split-FilterQuery
#>

# ── MenuListComponent ────────────────────────────────────────────────────────

function New-MenuListComponent {
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [switch]$ShowBack,
        [string[]]$HelpContent,
        [string]$HelpTitle = 'Pomoc',
        [hashtable]$FilterPrefixes,
        [scriptblock]$FuzzyCallback
    )

    # Build selectable indices
    $SelectableIndices = [System.Collections.Generic.List[int]]::new()
    for ($I = 0; $I -lt $Items.Count; $I++) {
        if (-not $Items[$I].Disabled) {
            [void]$SelectableIndices.Add($I)
        }
    }

    # Pre-compute max label width (labels don't change during session)
    $PreMaxLabel = 0
    foreach ($Item in $Items) {
        $LLen = $Item.Label.Length
        if ($Item.RoleTag) { $LLen += $Item.RoleTag.Length + 3 }
        if ($LLen -gt $PreMaxLabel) { $PreMaxLabel = $LLen }
    }

    $Component = @{
        Type              = 'MenuList'
        Items             = $Items
        AllItems          = $Items
        SelectableIndices = $SelectableIndices
        SelectedPos       = 0
        ShowBack          = [bool]$ShowBack
        HelpContent       = $HelpContent
        HelpTitle         = $HelpTitle
        Filterable        = $true
        FilterPrefixes    = $FilterPrefixes
        FilteredCount     = $Items.Count
        TotalCount        = $Items.Count
        MatchInfoList     = @()
        FuzzyCallback     = $FuzzyCallback
        _MaxLabelWidth    = $PreMaxLabel
        StatusHints       = "$([char]0x2191)$([char]0x2193) nawigacja  Enter wybierz  /h pomoc  $(if ($ShowBack) { 'Esc wstecz' } else { 'Esc/q zakoncz' })"

        Render = {
            param($State, $ComponentRef)

            $Region = Get-Region -Name 'Content'
            if ($null -eq $Region) { return }

            # Clear content region first
            Clear-BufferRegion -Buffer $script:BackBuffer -Region $Region

            $AccentColor   = Get-CLIColor -Role 'Accent'
            $DisabledColor = Get-CLIColor -Role 'Disabled'
            $RoleTagColor  = Get-CLIColor -Role 'RoleTag'
            $InfoColor     = Get-CLIColor -Role 'Info'

            $Items = $ComponentRef.Items
            $SelIdx = $ComponentRef.SelectableIndices
            $SelPos = $ComponentRef.SelectedPos
            $CurrentIndex = if ($SelIdx.Count -gt 0) { $SelIdx[$SelPos] } else { -1 }

            # Use pre-computed max label width (recalculated on filter via _MaxLabelWidth)
            $MaxLabelWidth = [Math]::Min($ComponentRef._MaxLabelWidth + 4, $script:ScreenWidth - 20)

            $ContentHeight = Get-RegionHeight -Name 'Content'
            $Row = $Region.StartRow

            for ($I = 0; $I -lt $Items.Count; $I++) {
                if (($Row - $Region.StartRow) -ge $ContentHeight) { break }

                $Item = $Items[$I]
                $IsSelected = ($I -eq $CurrentIndex)
                $IsDisabled = [bool]$Item.Disabled

                $Pointer = if ($IsSelected) { "$([char]0x25B8) " } else { '  ' }
                $PointerColor = if ($IsSelected) { $AccentColor } else { $null }

                $Segments = [System.Collections.Generic.List[object]]::new()
                [void]$Segments.Add((New-Segment -Text "  $Pointer" -Color $PointerColor -Bold:$IsSelected))

                if ($Item.RoleTag) {
                    $TagColor = if ($IsDisabled) { $DisabledColor } elseif ($IsSelected) { $RoleTagColor } else { $RoleTagColor }
                    [void]$Segments.Add((New-Segment -Text "[$($Item.RoleTag)] " -Color $TagColor))
                }

                $LabelColor = if ($IsDisabled) { $DisabledColor } elseif ($IsSelected) { $AccentColor } else { $null }

                # Match highlighting when filter is active (not for selected or disabled items)
                $MI = if ($ComponentRef.MatchInfoList -and $I -lt $ComponentRef.MatchInfoList.Count) { $ComponentRef.MatchInfoList[$I] } else { $null }
                if ($MI -and -not $IsDisabled -and -not $IsSelected) {
                    $HighlightSegs = Split-HighlightSegments -Text $Item.Label -NormalColor $LabelColor -HighlightColor $AccentColor -MatchInfo $MI
                    foreach ($HSeg in $HighlightSegs) { [void]$Segments.Add($HSeg) }
                } else {
                    [void]$Segments.Add((New-Segment -Text $Item.Label -Color $LabelColor -Bold:$IsSelected))
                }

                if ($Item.Description) {
                    $DescColor = if ($IsDisabled) { $DisabledColor } elseif ($IsSelected) { $AccentColor } else { $DisabledColor }
                    $PadLen = [Math]::Max(1, $MaxLabelWidth - $Item.Label.Length - $(if ($Item.RoleTag) { $Item.RoleTag.Length + 3 } else { 0 }))
                    [void]$Segments.Add((New-Segment -Text (' ' * $PadLen) -Color $null))
                    [void]$Segments.Add((New-Segment -Text $Item.Description -Color $DescColor))
                }

                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @($Segments)
                $Row++
            }

            # InfoText for selected item
            if ($CurrentIndex -ge 0 -and $CurrentIndex -lt $Items.Count) {
                $InfoText = $Items[$CurrentIndex].InfoText
                if ($InfoText -and ($Row - $Region.StartRow) -lt ($ContentHeight - 1)) {
                    $Row++  # blank line
                    $InfoLines = if ($InfoText -is [array]) { $InfoText } else { @($InfoText) }
                    foreach ($ILine in $InfoLines) {
                        if (($Row - $Region.StartRow) -ge $ContentHeight) { break }
                        $Segs = @(
                            (New-Segment -Text "    $([char]0x2139) $ILine" -Color $InfoColor)
                        )
                        Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments $Segs
                        $Row++
                    }
                }
            }

            # Zero-match hint when filtering
            if ($Items.Count -eq 0) {
                $Segs = @(
                    (New-Segment -Text '    (brak wynikow)' -Color $DisabledColor)
                )
                Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments $Segs
            }
        }

        HandleKey = {
            param($Action, $State, $ComponentRef)

            switch ($Action.Type) {
                'Navigate' {
                    if ($Action.Value -eq 'Up') {
                        if ($ComponentRef.SelectedPos -gt 0) {
                            $ComponentRef.SelectedPos--
                        }
                    }
                    elseif ($Action.Value -eq 'Down') {
                        if ($ComponentRef.SelectedPos -lt ($ComponentRef.SelectableIndices.Count - 1)) {
                            $ComponentRef.SelectedPos++
                        }
                    }
                }

                'Select' {
                    if ($ComponentRef.SelectableIndices.Count -gt 0) {
                        $Idx = $ComponentRef.SelectableIndices[$ComponentRef.SelectedPos]
                        return @{ Type = 'Return'; Value = $ComponentRef.Items[$Idx].ID }
                    }
                }

                'FilterStart' {
                    Invoke-MenuFilter -Component $ComponentRef -FilterText $Action.Value
                }

                'FilterUpdate' {
                    Invoke-MenuFilter -Component $ComponentRef -FilterText $Action.Value
                }

                'FilterClear' {
                    $ComponentRef.Items = $ComponentRef.AllItems
                    $ComponentRef.MatchInfoList = @()
                    $ComponentRef.SelectableIndices = [System.Collections.Generic.List[int]]::new()
                    $ClearMax = 0
                    for ($I = 0; $I -lt $ComponentRef.AllItems.Count; $I++) {
                        if (-not $ComponentRef.AllItems[$I].Disabled) {
                            [void]$ComponentRef.SelectableIndices.Add($I)
                        }
                        $CLen = $ComponentRef.AllItems[$I].Label.Length
                        if ($ComponentRef.AllItems[$I].RoleTag) { $CLen += $ComponentRef.AllItems[$I].RoleTag.Length + 3 }
                        if ($CLen -gt $ClearMax) { $ClearMax = $CLen }
                    }
                    $ComponentRef._MaxLabelWidth = $ClearMax
                    $ComponentRef.SelectedPos = 0
                    $ComponentRef.FilteredCount = $ComponentRef.AllItems.Count
                }
            }

            return $null
        }
    }

    return $Component
}

# ── Menu Filter Helper ───────────────────────────────────────────────────────

function Invoke-MenuFilter {
    param(
        [Parameter(Mandatory)] [object]$Component,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FilterText
    )

    $Parsed = Split-FilterQuery -RawInput $FilterText -FilterPrefixes $Component.FilterPrefixes
    $Query = $Parsed.Query.ToLowerInvariant()

    $Filtered = [System.Collections.Generic.List[object]]::new()
    $MatchInfoList = [System.Collections.Generic.List[object]]::new()

    foreach ($Item in $Component.AllItems) {
        $Label = $Item.Label

        # Type prefix filter
        if ($Parsed.TypeFilter) {
            $TypeMatch = $false
            if ($Item.PSObject.Properties['Type'] -and
                [string]::Equals($Item.Type, $Parsed.TypeFilter, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TypeMatch = $true
            }
            if ($Item.PSObject.Properties['RoleTag'] -and
                [string]::Equals($Item.RoleTag, $Parsed.TypeFilter, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TypeMatch = $true
            }
            if (-not $TypeMatch) { continue }
        }

        # Empty query after prefix = show all of that type
        if ([string]::IsNullOrEmpty($Query)) {
            [void]$Filtered.Add($Item)
            [void]$MatchInfoList.Add($null)
            continue
        }

        # Stage 1: prefix match
        if ($Label.StartsWith($Query, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$Filtered.Add($Item)
            [void]$MatchInfoList.Add(@{ Type = 'prefix'; Start = 0; Length = $Query.Length })
            continue
        }

        # Stage 2: contains match
        $Pos = $Label.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase)
        if ($Pos -ge 0) {
            [void]$Filtered.Add($Item)
            [void]$MatchInfoList.Add(@{ Type = 'contains'; Start = $Pos; Length = $Query.Length })
            continue
        }
    }

    $Component.Items = @($Filtered)
    $Component.MatchInfoList = @($MatchInfoList)
    $Component.SelectableIndices = [System.Collections.Generic.List[int]]::new()
    # Recalculate max label width for filtered set
    $NewMax = 0
    for ($I = 0; $I -lt $Filtered.Count; $I++) {
        if (-not $Filtered[$I].Disabled) {
            [void]$Component.SelectableIndices.Add($I)
        }
        $LLen = $Filtered[$I].Label.Length
        if ($Filtered[$I].RoleTag) { $LLen += $Filtered[$I].RoleTag.Length + 3 }
        if ($LLen -gt $NewMax) { $NewMax = $LLen }
    }
    $Component._MaxLabelWidth = $NewMax
    $Component.SelectedPos = 0
    $Component.FilteredCount = $Filtered.Count
}

# ── Fuzzy Extend Helper ─────────────────────────────────────────────────────

# Extends stage 1+2 filter results with stage 3 fuzzy/declension matches
# Called after debounce timeout when component has a FuzzyCallback
function Invoke-MenuFuzzyExtend {
    param(
        [Parameter(Mandatory)] [object]$Component,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FilterText
    )

    if (-not $Component.FuzzyCallback) { return }

    $Parsed = Split-FilterQuery -RawInput $FilterText -FilterPrefixes $Component.FilterPrefixes
    $Query = $Parsed.Query
    if ([string]::IsNullOrEmpty($Query)) { return }

    # Collect labels already matched by stages 1+2
    $MatchedLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $Component.Items) {
        [void]$MatchedLabels.Add($Item.Label)
    }

    $Remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($Item in $Component.AllItems) {
        if (-not $MatchedLabels.Contains($Item.Label)) {
            [void]$Remaining.Add($Item)
        }
    }

    if ($Remaining.Count -eq 0) { return }

    $FuzzyMatches = & $Component.FuzzyCallback $Query @($Remaining)
    if (-not $FuzzyMatches -or $FuzzyMatches.Count -eq 0) { return }

    # Merge fuzzy results into the existing filtered set
    $NewItems = [System.Collections.Generic.List[object]]::new($Component.Items)
    $NewMatchInfo = [System.Collections.Generic.List[object]]::new()
    if ($Component.MatchInfoList) {
        foreach ($MI in $Component.MatchInfoList) { [void]$NewMatchInfo.Add($MI) }
    }

    foreach ($FM in $FuzzyMatches) {
        [void]$NewItems.Add($FM)
        [void]$NewMatchInfo.Add(@{ Type = 'fuzzy'; Start = -1; Length = 0 })
    }

    $Component.Items = @($NewItems)
    $Component.MatchInfoList = @($NewMatchInfo)

    # Rebuild selectable indices and update max label width
    $Component.SelectableIndices = [System.Collections.Generic.List[int]]::new()
    $FuzzyMax = $Component._MaxLabelWidth
    for ($I = 0; $I -lt $NewItems.Count; $I++) {
        if (-not $NewItems[$I].Disabled) {
            [void]$Component.SelectableIndices.Add($I)
        }
        $FLen = $NewItems[$I].Label.Length
        if ($NewItems[$I].RoleTag) { $FLen += $NewItems[$I].RoleTag.Length + 3 }
        if ($FLen -gt $FuzzyMax) { $FuzzyMax = $FLen }
    }
    $Component._MaxLabelWidth = $FuzzyMax
    $Component.FilteredCount = $NewItems.Count
}

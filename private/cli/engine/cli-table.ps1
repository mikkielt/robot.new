<#
    .SYNOPSIS
    Result table component for the Robot CLI TUI engine.

    .DESCRIPTION
    Paginated table with column headers, responsive column hiding,
    row selection, inline filtering, and cell truncation with ellipsis.

    Helpers:
    - New-ResultTableComponent:  creates a paginated table component
    - Invoke-TableFilter:        filters table rows by column content
    - Resolve-VisibleColumns:    hides low-priority columns at narrow widths

    Component contract:
    - Render:    writes header + rows into Content region with pointer on selected row
    - HandleKey: Navigate (Up/Down row, Left/Right page), Select (returns row object),
                 FilterStart/Update/Clear
    - Returns:   selected data row (PSCustomObject) via Select action

    Dependencies:
    - cli-engine.ps1:  Get-Region, Get-RegionHeight, Get-CLIColor, $script:ScreenWidth
    - cli-buffer.ps1:  New-Segment, Set-BufferLine, Clear-BufferRegion, $script:BackBuffer
    - cli-input.ps1:   Split-FilterQuery
#>

# ── ResultTableComponent ─────────────────────────────────────────────────────

function New-ResultTableComponent {
    param(
        [Parameter(Mandatory)] [object[]]$Data,
        [Parameter(Mandatory)] [string[]]$Columns,
        [Parameter(Mandatory)] [string[]]$Headers,
        [int[]]$Widths,
        [int[]]$ColumnPriority,
        [int]$PageSize = 15,
        [string]$Title,
        [hashtable]$FilterPrefixes
    )

    # Default widths
    if (-not $Widths -or $Widths.Count -eq 0) {
        $Widths = @(20) * $Headers.Count
    }

    $Component = @{
        Type           = 'ResultTable'
        Data           = $Data
        AllData        = $Data
        Columns        = $Columns
        Headers        = $Headers
        Widths         = $Widths
        ColumnPriority = $ColumnPriority
        PageSize       = $PageSize
        Title          = $Title
        SelectedAbs    = 0
        Filterable     = $true
        FilterPrefixes = $FilterPrefixes
        FilteredCount  = $Data.Count
        TotalCount     = $Data.Count
        StatusHints    = "$([char]0x2191)$([char]0x2193) nawigacja  $([char]0x2190)$([char]0x2192) strony  Enter szczegoly  Esc wstecz"

        Render = {
            param($State, $ComponentRef)

            $Region = Get-Region -Name 'Content'
            if ($null -eq $Region) { return }

            Clear-BufferRegion -Buffer $script:BackBuffer -Region $Region

            $AccentColor   = Get-CLIColor -Role 'Accent'
            $DisabledColor = Get-CLIColor -Role 'Disabled'

            $Data = $ComponentRef.Data
            $PageSize = $ComponentRef.PageSize
            $SelectedAbs = $ComponentRef.SelectedAbs
            $Columns = $ComponentRef.Columns
            $Headers = $ComponentRef.Headers
            $Widths = $ComponentRef.Widths

            # Responsive columns: hide low-priority columns at narrow widths
            $VisibleCols = Resolve-VisibleColumns -Columns $Columns -Headers $Headers `
                -Widths $Widths -ColumnPriority $ComponentRef.ColumnPriority `
                -AvailableWidth $script:ScreenWidth

            if ($Data.Count -eq 0) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Region.StartRow -Segments @(
                    (New-Segment -Text '    (brak danych)' -Color $DisabledColor)
                )
                return
            }

            $CurrentPage = [Math]::Floor($SelectedAbs / $PageSize)
            $TotalPages  = [Math]::Ceiling($Data.Count / $PageSize)
            $PageStart   = $CurrentPage * $PageSize
            $PageEnd     = [Math]::Min($PageStart + $PageSize, $Data.Count) - 1
            $PageData    = $Data[$PageStart..$PageEnd]
            $SelectedRow = $SelectedAbs - $PageStart

            $ContentHeight = Get-RegionHeight -Name 'Content'
            $Row = $Region.StartRow

            # Title
            if ($ComponentRef.Title) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "  $($ComponentRef.Title)" -Color $AccentColor -Bold)
                )
                $Row++
                $Row++  # blank line
            }

            # Header row
            $HdrSegs = [System.Collections.Generic.List[object]]::new()
            [void]$HdrSegs.Add((New-Segment -Text '  ' -Color $null))
            foreach ($VC in $VisibleCols) {
                [void]$HdrSegs.Add((New-Segment -Text $VC.Header.PadRight($VC.Width) -Color $AccentColor))
            }
            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @($HdrSegs)
            $Row++

            # Separator
            $SepSegs = [System.Collections.Generic.List[object]]::new()
            [void]$SepSegs.Add((New-Segment -Text '  ' -Color $null))
            foreach ($VC in $VisibleCols) {
                $SepText = ([string][char]0x2500 * ($VC.Width - 1)) + ' '
                [void]$SepSegs.Add((New-Segment -Text $SepText -Color $DisabledColor -Dim))
            }
            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @($SepSegs)
            $Row++

            # Data rows
            for ($R = 0; $R -lt $PageData.Count; $R++) {
                if (($Row - $Region.StartRow) -ge ($ContentHeight - 3)) { break }

                $DataRow = $PageData[$R]
                $IsSelected = ($R -eq $SelectedRow)
                $RowColor = if ($IsSelected) { $AccentColor } else { $null }

                $RowSegs = [System.Collections.Generic.List[object]]::new()
                $Pointer = if ($IsSelected) { "$([char]0x25B8) " } else { '  ' }
                [void]$RowSegs.Add((New-Segment -Text $Pointer -Color $RowColor -Bold:$IsSelected))

                foreach ($VC in $VisibleCols) {
                    $Val = ''
                    if ($DataRow.PSObject.Properties[$VC.Column]) {
                        $RawVal = $DataRow.($VC.Column)
                        if ($null -eq $RawVal) { $Val = '' }
                        elseif ($RawVal -is [System.Collections.IList] -or $RawVal -is [array]) { $Val = [string]$RawVal.Count }
                        else { $Val = [string]$RawVal }
                    }

                    # Truncation with ellipsis (… is 1 char, leave 1 char margin)
                    if ($Val.Length -gt ($VC.Width - 1)) {
                        $Val = $Val.Substring(0, $VC.Width - 2) + [string][char]0x2026
                    }

                    [void]$RowSegs.Add((New-Segment -Text $Val.PadRight($VC.Width) -Color $RowColor))
                }

                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @($RowSegs)
                $Row++
            }

            # Page info
            $Row++
            if (($Row - $Region.StartRow) -lt $ContentHeight) {
                $PageInfo = "  Strona $($CurrentPage + 1)/$TotalPages ($($Data.Count) wynikow)  |  Wiersz $($SelectedAbs + 1)/$($Data.Count)"
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text $PageInfo -Color $DisabledColor)
                )
            }
        }

        HandleKey = {
            param($Action, $State, $ComponentRef)

            $Data = $ComponentRef.Data
            $PageSize = $ComponentRef.PageSize

            switch ($Action.Type) {
                'Navigate' {
                    switch ($Action.Value) {
                        'Up' {
                            if ($ComponentRef.SelectedAbs -gt 0) { $ComponentRef.SelectedAbs-- }
                        }
                        'Down' {
                            if ($ComponentRef.SelectedAbs -lt ($Data.Count - 1)) { $ComponentRef.SelectedAbs++ }
                        }
                        'Left' {
                            $CurrentPage = [Math]::Floor($ComponentRef.SelectedAbs / $PageSize)
                            if ($CurrentPage -gt 0) {
                                $ComponentRef.SelectedAbs = ($CurrentPage - 1) * $PageSize
                            }
                        }
                        'Right' {
                            $CurrentPage = [Math]::Floor($ComponentRef.SelectedAbs / $PageSize)
                            $TotalPages = [Math]::Ceiling($Data.Count / $PageSize)
                            if ($CurrentPage -lt ($TotalPages - 1)) {
                                $ComponentRef.SelectedAbs = ($CurrentPage + 1) * $PageSize
                            }
                        }
                    }
                }

                'Select' {
                    if ($Data.Count -gt 0 -and $ComponentRef.SelectedAbs -lt $Data.Count) {
                        return @{ Type = 'Return'; Value = $Data[$ComponentRef.SelectedAbs] }
                    }
                }

                'FilterStart' {
                    Invoke-TableFilter -Component $ComponentRef -FilterText $Action.Value
                }

                'FilterUpdate' {
                    Invoke-TableFilter -Component $ComponentRef -FilterText $Action.Value
                }

                'FilterClear' {
                    $ComponentRef.Data = $ComponentRef.AllData
                    $ComponentRef.SelectedAbs = 0
                    $ComponentRef.FilteredCount = $ComponentRef.AllData.Count
                }
            }

            return $null
        }
    }

    return $Component
}

# ── Table Filter Helper ──────────────────────────────────────────────────────

function Invoke-TableFilter {
    param(
        [Parameter(Mandatory)] [object]$Component,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FilterText
    )

    $Parsed = Split-FilterQuery -RawInput $FilterText -FilterPrefixes $Component.FilterPrefixes
    $Query = $Parsed.Query.ToLowerInvariant()

    $Filtered = [System.Collections.Generic.List[object]]::new()

    foreach ($Row in $Component.AllData) {
        # Check any column for match
        $Matched = $false

        if ([string]::IsNullOrEmpty($Query) -and -not $Parsed.TypeFilter) {
            $Matched = $true
        } else {
            foreach ($Col in $Component.Columns) {
                if ($Row.PSObject.Properties[$Col]) {
                    $Val = [string]$Row.$Col
                    if ($Val -and $Val.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $Matched = $true
                        break
                    }
                }
            }
        }

        if ($Matched) { [void]$Filtered.Add($Row) }
    }

    $Component.Data = @($Filtered)
    $Component.SelectedAbs = 0
    $Component.FilteredCount = $Filtered.Count
}

# ── Responsive Column Helper ─────────────────────────────────────────────────

function Resolve-VisibleColumns {
    param(
        [string[]]$Columns,
        [string[]]$Headers,
        [int[]]$Widths,
        [int[]]$ColumnPriority,
        [int]$AvailableWidth
    )

    $AllCols = [System.Collections.Generic.List[object]]::new()
    for ($I = 0; $I -lt $Columns.Count; $I++) {
        $Priority = if ($ColumnPriority -and $I -lt $ColumnPriority.Count) { $ColumnPriority[$I] } else { 1 }
        [void]$AllCols.Add(@{
            Column   = $Columns[$I]
            Header   = if ($I -lt $Headers.Count) { $Headers[$I] } else { $Columns[$I] }
            Width    = if ($I -lt $Widths.Count) { $Widths[$I] } else { 20 }
            Priority = $Priority
        })
    }

    # Start with all columns, remove lowest priority first when too wide
    $Visible = [System.Collections.Generic.List[object]]::new()
    foreach ($C in $AllCols) { [void]$Visible.Add($C) }

    # Calculate total used width
    $UsedWidth = 4  # indent + pointer
    foreach ($C in $Visible) { $UsedWidth += $C.Width }

    # Remove priority 3, then 2 if still too wide
    foreach ($PriorityToRemove in @(3, 2)) {
        if ($UsedWidth -le $AvailableWidth) { break }

        $ToRemove = [System.Collections.Generic.List[int]]::new()
        for ($Idx = $Visible.Count - 1; $Idx -ge 0; $Idx--) {
            if ($Visible[$Idx].Priority -eq $PriorityToRemove) {
                [void]$ToRemove.Add($Idx)
            }
        }
        foreach ($Idx in $ToRemove) {
            $UsedWidth -= $Visible[$Idx].Width
            [void]$Visible.RemoveAt($Idx)
        }
    }

    return ,$Visible.ToArray()
}

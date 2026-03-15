<#
    .SYNOPSIS
    Detail card component for the Robot CLI TUI engine.

    .DESCRIPTION
    Renders a scrollable key-value card that displays all properties of a
    data object (entity, session, player, etc.) with type-aware formatting.

    Format-DetailValue handles the full range of property types encountered
    in the Nerthus data model: null sentinels, booleans (Polish Tak/Nie),
    datetimes (ISO format), HashSets (inline for small sets, bulleted for
    large), dictionaries (with @tag key display), and temporal objects with
    ValidFrom/ValidTo date range display. Arrays use a negative type check
    (not [string] and not [System.ValueType]) to distinguish complex objects
    from scalar values; complex objects are rendered as multi-property bullet
    lines, capped at 8 items to keep the card readable.

    Helpers:
    - New-DetailCardComponent:  creates a scrollable detail card from a data object
    - Format-DetailValue:       formats a property value for display (handles null,
                                bool, datetime, arrays, dicts, temporal objects)

    Component contract:
    - Render:    writes property lines into Content region with scroll indicators
    - HandleKey: Navigate (Up/Down for scroll)
    - Filterable: false (detail cards don't support inline filtering)

    Dependencies:
    - cli-engine.ps1:  Get-Region, Get-RegionHeight, Get-CLIColor
    - cli-buffer.ps1:  New-Segment, Set-BufferLine, Clear-BufferRegion, $script:BackBuffer
#>

# ── DetailCardComponent ──────────────────────────────────────────────────────

function New-DetailCardComponent {
    param(
        [Parameter(Mandatory)] [object]$Data,
        [string]$Title
    )

    # Skip PS-prefixed internals and infrastructure properties (Path, CN)
    # that are meaningful for lookups but not for human-readable display
    $Props = [System.Collections.Generic.List[object]]::new()
    foreach ($Prop in $Data.PSObject.Properties) {
        if ($Prop.Name.StartsWith('PS') -and $Prop.Name -ne 'PSTypeName') { continue }
        if ($Prop.Name -eq 'Path' -or $Prop.Name -eq 'CN') { continue }
        [void]$Props.Add(@{
            Name  = $Prop.Name
            Value = $Prop.Value
        })
    }

    $Component = @{
        Type        = 'DetailCard'
        Data        = $Data
        Title       = $Title
        Properties  = $Props
        ScrollOffset = 0
        Filterable  = $false
        StatusHints = "$([char]0x2191)$([char]0x2193) przewijanie  Esc wstecz"

        Render = {
            param($State, $ComponentRef)

            $Region = Get-Region -Name 'Content'
            if ($null -eq $Region) { return }

            Clear-BufferRegion -Buffer $script:BackBuffer -Region $Region

            $AccentColor   = Get-CLIColor -Role 'Accent'
            $DisabledColor = Get-CLIColor -Role 'Disabled'
            $InfoColor     = Get-CLIColor -Role 'Info'

            $ContentHeight = Get-RegionHeight -Name 'Content'
            $Props = $ComponentRef.Properties
            $Offset = $ComponentRef.ScrollOffset
            $Row = $Region.StartRow

            # Title
            if ($ComponentRef.Title -and ($Row - $Region.StartRow) -lt $ContentHeight) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "  $($ComponentRef.Title)" -Color $AccentColor -Bold)
                )
                $Row++
                $Row++  # blank line after title
            }

            # Pre-render all property lines so scroll offset can clamp against total count
            $AllLines = [System.Collections.Generic.List[object]]::new()
            foreach ($Prop in $Props) {
                $DisplayVal = Format-DetailValue -Value $Prop.Value
                if ($DisplayVal -is [array]) {
                    [void]$AllLines.Add(@{
                        Segments = @(
                            (New-Segment -Text "    $($Prop.Name): " -Color $AccentColor)
                        )
                    })
                    foreach ($SubLine in $DisplayVal) {
                        [void]$AllLines.Add(@{
                            Segments = @(
                                (New-Segment -Text "      $SubLine" -Color $InfoColor)
                            )
                        })
                    }
                } else {
                    [void]$AllLines.Add(@{
                        Segments = @(
                            (New-Segment -Text "    $($Prop.Name): " -Color $AccentColor)
                            (New-Segment -Text $DisplayVal -Color $InfoColor)
                        )
                    })
                }
            }

            # Clamp offset and emit visible slice into buffer region
            $VisibleLines = $ContentHeight - ($Row - $Region.StartRow)
            $MaxOffset = [Math]::Max(0, $AllLines.Count - $VisibleLines)
            if ($Offset -gt $MaxOffset) { $ComponentRef.ScrollOffset = $MaxOffset; $Offset = $MaxOffset }

            # Scroll indicator at top
            if ($Offset -gt 0 -and ($Row - $Region.StartRow) -lt $ContentHeight) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "    $([char]0x2191) wiecej powyzej" -Color $DisabledColor)
                )
                $Row++
                $VisibleLines--
            }

            for ($I = $Offset; $I -lt $AllLines.Count -and ($Row - $Region.StartRow) -lt ($ContentHeight - 1); $I++) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments $AllLines[$I].Segments
                $Row++
            }

            # Scroll indicator at bottom
            if (($Offset + $VisibleLines) -lt $AllLines.Count -and ($Row - $Region.StartRow) -lt $ContentHeight) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "    $([char]0x2193) wiecej ponizej" -Color $DisabledColor)
                )
            }
        }

        HandleKey = {
            param($Action, $State, $ComponentRef)

            switch ($Action.Type) {
                'Navigate' {
                    if ($Action.Value -eq 'Up') {
                        if ($ComponentRef.ScrollOffset -gt 0) { $ComponentRef.ScrollOffset-- }
                    }
                    elseif ($Action.Value -eq 'Down') {
                        $ComponentRef.ScrollOffset++
                    }
                }
            }

            return $null
        }
    }

    return $Component
}

# ── Detail Value Formatter ───────────────────────────────────────────────────

function Format-DetailValue {
    param($Value)

    if ($null -eq $Value) { return '(brak)' }
    if ($Value -is [bool]) { return $(if ($Value) { 'Tak' } else { 'Nie' }) }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd') }

    # HashSet[string] — inline for small sets to save vertical space;
    # bulleted for larger sets so each value gets its own scannable line
    if ($Value -is [System.Collections.Generic.HashSet[string]]) {
        $AsList = @($Value)
        if ($AsList.Count -eq 0) { return '(brak)' }
        if ($AsList.Count -le 3) { return ($AsList -join ', ') }
        $Lines = [System.Collections.Generic.List[string]]::new()
        foreach ($Item in $AsList) {
            [void]$Lines.Add("$([char]0x2022) $Item")
        }
        return @($Lines)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $Lines = [System.Collections.Generic.List[string]]::new()
        foreach ($Key in $Value.Keys) {
            $SubVal = $Value[$Key]
            $SubDisplay = if ($SubVal -is [array]) { $SubVal -join ', ' } else { [string]$SubVal }
            [void]$Lines.Add("@$Key`: $SubDisplay")
        }
        return @($Lines)
    }

    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        if ($Value.Count -eq 0) { return '(brak)' }

        # Scalar arrays (strings, numbers) can be safely joined inline
        $AllScalar = $true
        foreach ($V in $Value) {
            if (-not ($V -is [string] -or $V -is [System.ValueType])) { $AllScalar = $false; break }
        }

        if ($AllScalar -and $Value.Count -le 3) {
            return ($Value -join ', ')
        }

        # Temporal objects (entity @tag values with ValidFrom/ValidTo date ranges)
        if ($Value[0].PSObject.Properties['ValidFrom']) {
            $Lines = [System.Collections.Generic.List[string]]::new()
            $SkipNames = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@('ValidFrom','ValidTo','Path','CN'),
                [System.StringComparer]::Ordinal)
            $ShowCount = [Math]::Min($Value.Count, 8)  # cap at 8 to keep card readable; overflow shows "... i N wiecej"
            for ($I = 0; $I -lt $ShowCount; $I++) {
                $V = $Value[$I]
                $VF = if ($V.ValidFrom) { try { ([datetime]$V.ValidFrom).ToString('yyyy-MM-dd') } catch { [string]$V.ValidFrom } } else { '' }
                $VT = if ($V.ValidTo) { try { ([datetime]$V.ValidTo).ToString('yyyy-MM-dd') } catch { [string]$V.ValidTo } } else { '' }
                # Display value resolution: prefer Text, then Value, then first scalar property
                $VV = $null
                if ($V.PSObject.Properties['Text'] -and $V.Text) { $VV = $V.Text }
                elseif ($V.PSObject.Properties['Value'] -and $V.Value) { $VV = $V.Value }
                else {
                    foreach ($SP in $V.PSObject.Properties) {
                        if ($SkipNames.Contains($SP.Name)) { continue }
                        if ($null -eq $SP.Value) { continue }
                        if ($SP.Value -is [string] -or $SP.Value -is [decimal] -or $SP.Value -is [int]) {
                            $VV = [string]$SP.Value; break
                        }
                    }
                }
                if (-not $VV) { $VV = '?' }
                if ($VF -and $VT) { [void]$Lines.Add("$VV  ($VF $([char]0x2013) $VT)") }
                elseif ($VF) { [void]$Lines.Add("$VV  (od $VF)") }
                elseif ($VT) { [void]$Lines.Add("$VV  (do $VT)") }
                else { [void]$Lines.Add([string]$VV) }
            }
            if ($Value.Count -gt 8) {
                [void]$Lines.Add("... i $($Value.Count - 8) wiecej")
            }
            return @($Lines)
        }

        # Nested object arrays — negative type check excludes scalars so C# typed
        # objects (Robot.*) are handled here with multi-property summary lines
        if (-not ($Value[0] -is [string] -or $Value[0] -is [System.ValueType])) {
            $Lines = [System.Collections.Generic.List[string]]::new()
            $ShowCount = [Math]::Min($Value.Count, 8)
            for ($I = 0; $I -lt $ShowCount; $I++) {
                $Obj = $Value[$I]
                $Parts = [System.Collections.Generic.List[string]]::new()
                foreach ($SP in $Obj.PSObject.Properties) {
                    if ($Parts.Count -ge 3) { break }  # limit to 3 properties per line for readability
                    if ($null -eq $SP.Value) { continue }
                    if ($SP.Name -eq 'Path' -or $SP.Name -eq 'CN') { continue }
                    $SVal = if ($SP.Value -is [bool]) { if ($SP.Value) { 'Tak' } else { 'Nie' } }
                           elseif ($SP.Value -is [string] -or $SP.Value -is [decimal] -or $SP.Value -is [int]) { [string]$SP.Value }
                           elseif ($SP.Value -is [System.Collections.IList]) { "[$($SP.Value.Count)]" }
                           else { [string]$SP.Value }
                    if ($SVal) { [void]$Parts.Add("$($SP.Name): $SVal") }
                }
                [void]$Lines.Add("$([char]0x2022) $($Parts -join '  |  ')")
            }
            if ($Value.Count -gt 8) {
                [void]$Lines.Add("... i $($Value.Count - 8) wiecej")
            }
            return @($Lines)
        }

        # Generic array — bulleted list with overflow indicator
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Limit = [Math]::Min($Value.Count, 8)
        for ($I = 0; $I -lt $Limit; $I++) {
            [void]$Lines.Add("$([char]0x2022) $($Value[$I])")
        }
        if ($Value.Count -gt 8) {
            [void]$Lines.Add("... i $($Value.Count - 8) wiecej")
        }
        return @($Lines)
    }

    return [string]$Value
}

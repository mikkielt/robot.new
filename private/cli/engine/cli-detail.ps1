<#
    .SYNOPSIS
    Detail card component for the Robot CLI TUI engine.

    .DESCRIPTION
    Key-value card that displays object properties with type-aware
    formatting, scrolling support, and temporal range display.

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

    # Extract displayable properties — skip PS-prefixed internals (e.g., PSComputerName)
    # and infrastructure properties (Path, CN) that aren't meaningful in the card view
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

            # Build all property lines first
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

            # Render with scroll offset
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

    # HashSet[string] — inline comma-separated for ≤3 items to save vertical space;
    # bullet list for larger sets to maintain readability
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

        # Simple scalar arrays
        $AllScalar = $true
        foreach ($V in $Value) {
            if ($V -is [PSCustomObject] -or $V -is [hashtable]) { $AllScalar = $false; break }
        }

        if ($AllScalar -and $Value.Count -le 3) {
            return ($Value -join ', ')
        }

        # Temporal objects (have ValidFrom)
        if ($Value[0] -is [PSCustomObject] -and $Value[0].PSObject.Properties['ValidFrom']) {
            $Lines = [System.Collections.Generic.List[string]]::new()
            $SkipNames = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@('ValidFrom','ValidTo','Path','CN'),
                [System.StringComparer]::Ordinal)
            $ShowCount = [Math]::Min($Value.Count, 8)  # cap at 8 to keep card readable; overflow shows "... i N wiecej"
            for ($I = 0; $I -lt $ShowCount; $I++) {
                $V = $Value[$I]
                $VF = if ($V.ValidFrom) { try { ([datetime]$V.ValidFrom).ToString('yyyy-MM-dd') } catch { [string]$V.ValidFrom } } else { '' }
                $VT = if ($V.ValidTo) { try { ([datetime]$V.ValidTo).ToString('yyyy-MM-dd') } catch { [string]$V.ValidTo } } else { '' }
                # Prefer Text, fall back to Value, then find first scalar property
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

        # Nested PSCustomObject arrays — generic multi-property display
        if ($Value[0] -is [PSCustomObject]) {
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

        # Generic array
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

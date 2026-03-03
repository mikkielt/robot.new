<#
    .SYNOPSIS
    Shared display components for the Robot CLI - detail card rendering,
    validity-range formatting, and NavState refresh.

    .DESCRIPTION
    This file contains display helpers consumed by the routing layer
    (Show-DetailCard for query results) and the wizard system
    (Refresh-NavState after writes). Dot-sourced on demand.

    Helpers:
    - Format-DetailValidityRange: formats temporal range as "YYYY-MM-DD – YYYY-MM-DD"
    - Show-DetailCard:            generic key-value card for any PSCustomObject
    - Refresh-NavState:           reloads entities, players, and name index

    Design:
    - Show-DetailCard handles strings, numbers, arrays, nested objects, and nulls.
    - Temporal objects (with ValidFrom/ValidTo) are formatted smartly.
    - Returns when the user presses Escape.
#>

# ── Format-DetailValidityRange ───────────────────────────────────────────────

function Format-DetailValidityRange {
    param($ValidFrom, $ValidTo)
    $From = if ($ValidFrom) { try { ([datetime]$ValidFrom).ToString('yyyy-MM-dd') } catch { [string]$ValidFrom } } else { $null }
    $To   = if ($ValidTo)   { try { ([datetime]$ValidTo).ToString('yyyy-MM-dd') }   catch { [string]$ValidTo } }   else { $null }
    if ($From -and $To)   { return "$From $([char]0x2013) $To" }
    elseif ($From)        { return "od $From" }
    elseif ($To)          { return "do $To" }
    return $null
}

# ── Show-DetailCard ──────────────────────────────────────────────────────────

function Show-DetailCard {
    <#
        .SYNOPSIS
        Displays a formatted detail card for a single data row with scroll support.
    #>
    param(
        [Parameter(Mandatory)] [object]$Row,
        [string]$Title
    )

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    # ── Phase 1: Pre-render content into a line buffer ──────────────────────
    $LineBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($Title) {
        [void]$LineBuffer.Add([PSCustomObject]@{ Segments = @( @{ Text = "  $Title"; Color = $AccentColor } ) })
    }
    [void]$LineBuffer.Add([PSCustomObject]@{ Segments = @( @{ Text = "  $Sep"; Color = $AccentColor } ) })
    [void]$LineBuffer.Add([PSCustomObject]@{ Segments = @( @{ Text = ''; Color = $null } ) })

    foreach ($Prop in $Row.PSObject.Properties) {
        $PropName = $Prop.Name
        $PropVal  = $Prop.Value

        if ($PropName -eq 'Path' -or $PropName -eq 'CN') { continue }

        if ($null -eq $PropVal) {
            [void]$LineBuffer.Add([PSCustomObject]@{
                Segments = @(
                    @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                    @{ Text = '(brak)'; Color = $DisabledColor }
                )
            })
        }
        elseif ($PropVal -is [string]) {
            [void]$LineBuffer.Add([PSCustomObject]@{
                Segments = @(
                    @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                    @{ Text = $PropVal; Color = $null }
                )
            })
        }
        elseif ($PropVal -is [bool]) {
            $BoolText = if ($PropVal) { 'Tak' } else { 'Nie' }
            [void]$LineBuffer.Add([PSCustomObject]@{
                Segments = @(
                    @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                    @{ Text = $BoolText; Color = $null }
                )
            })
        }
        elseif ($PropVal -is [decimal] -or $PropVal -is [int] -or $PropVal -is [double]) {
            [void]$LineBuffer.Add([PSCustomObject]@{
                Segments = @(
                    @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                    @{ Text = ([string]$PropVal); Color = $null }
                )
            })
        }
        elseif ($PropVal -is [System.Collections.IDictionary]) {
            [void]$LineBuffer.Add([PSCustomObject]@{
                Segments = @( @{ Text = "  $PropName"; Color = $InfoColor } )
            })
            foreach ($DKey in $PropVal.Keys) {
                $DVal = $PropVal[$DKey]
                if ($DVal -is [System.Collections.IList]) {
                    [void]$LineBuffer.Add([PSCustomObject]@{
                        Segments = @(
                            @{ Text = "    $($DKey.PadRight(20))"; Color = $DisabledColor }
                            @{ Text = ($DVal -join ', '); Color = $null }
                        )
                    })
                }
                else {
                    [void]$LineBuffer.Add([PSCustomObject]@{
                        Segments = @(
                            @{ Text = "    $($DKey.PadRight(20))"; Color = $DisabledColor }
                            @{ Text = ([string]$DVal); Color = $null }
                        )
                    })
                }
            }
        }
        elseif ($PropVal -is [System.Collections.IList] -or $PropVal -is [array]) {
            if ($PropVal.Count -eq 0) {
                [void]$LineBuffer.Add([PSCustomObject]@{
                    Segments = @(
                        @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                        @{ Text = '(puste)'; Color = $DisabledColor }
                    )
                })
            }
            elseif ($PropVal[0] -is [string] -or $PropVal[0] -is [int] -or $PropVal[0] -is [decimal]) {
                if ($PropVal.Count -le 3) {
                    [void]$LineBuffer.Add([PSCustomObject]@{
                        Segments = @(
                            @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                            @{ Text = ($PropVal -join ', '); Color = $null }
                        )
                    })
                }
                else {
                    [void]$LineBuffer.Add([PSCustomObject]@{
                        Segments = @( @{ Text = "  $PropName ($($PropVal.Count))"; Color = $InfoColor } )
                    })
                    foreach ($Item in $PropVal) {
                        [void]$LineBuffer.Add([PSCustomObject]@{
                            Segments = @( @{ Text = "    $([char]0x2022) $Item"; Color = $null } )
                        })
                    }
                }
            }
            elseif ($PropVal[0] -is [PSCustomObject] -or $PropVal[0].PSObject) {
                $First = $PropVal[0]
                $HasText = $First.PSObject.Properties['Text']
                $HasValidFrom = $First.PSObject.Properties['ValidFrom']

                [void]$LineBuffer.Add([PSCustomObject]@{
                    Segments = @( @{ Text = "  $PropName ($($PropVal.Count))"; Color = $InfoColor } )
                })
                $ShowCount = [Math]::Min($PropVal.Count, 8)
                for ($I = 0; $I -lt $ShowCount; $I++) {
                    $Obj = $PropVal[$I]

                    if ($HasText -and $HasValidFrom) {
                        $MainText = if ($Obj.Text) { $Obj.Text } else { '?' }
                        $Range = Format-DetailValidityRange -ValidFrom $Obj.ValidFrom -ValidTo $Obj.ValidTo
                        $DisplayLine = if ($Range) { "$MainText ($Range)" } else { $MainText }
                        [void]$LineBuffer.Add([PSCustomObject]@{
                            Segments = @( @{ Text = "    $([char]0x2022) $DisplayLine"; Color = $null } )
                        })
                    }
                    elseif ($HasValidFrom) {
                        $LabelVal = $null
                        foreach ($SP in $Obj.PSObject.Properties) {
                            if ($SP.Name -in @('ValidFrom','ValidTo','Path') -or $null -eq $SP.Value) { continue }
                            if ($SP.Value -is [string] -or $SP.Value -is [decimal] -or $SP.Value -is [int]) {
                                $LabelVal = [string]$SP.Value; break
                            }
                        }
                        if (-not $LabelVal) { $LabelVal = '?' }
                        $Range = Format-DetailValidityRange -ValidFrom $Obj.ValidFrom -ValidTo $Obj.ValidTo
                        $DisplayLine = if ($Range) { "$LabelVal ($Range)" } else { $LabelVal }
                        [void]$LineBuffer.Add([PSCustomObject]@{
                            Segments = @( @{ Text = "    $([char]0x2022) $DisplayLine"; Color = $null } )
                        })
                    }
                    else {
                        $Parts = [System.Collections.Generic.List[string]]::new()
                        foreach ($SP in $Obj.PSObject.Properties) {
                            if ($Parts.Count -ge 3) { break }
                            if ($null -eq $SP.Value) { continue }
                            if ($SP.Name -eq 'Path') { continue }
                            $SVal = if ($SP.Value -is [bool]) { if ($SP.Value) { 'Tak' } else { 'Nie' } }
                                   elseif ($SP.Value -is [string] -or $SP.Value -is [decimal] -or $SP.Value -is [int]) { [string]$SP.Value }
                                   elseif ($SP.Value -is [System.Collections.IList]) { "[$($SP.Value.Count)]" }
                                   else { [string]$SP.Value }
                            if ($SVal) { [void]$Parts.Add("$($SP.Name): $SVal") }
                        }
                        [void]$LineBuffer.Add([PSCustomObject]@{
                            Segments = @( @{ Text = "    $([char]0x2022) $($Parts -join '  |  ')"; Color = $null } )
                        })
                    }
                }
                if ($PropVal.Count -gt 8) {
                    [void]$LineBuffer.Add([PSCustomObject]@{
                        Segments = @( @{ Text = "    ... i $($PropVal.Count - 8) więcej"; Color = $DisabledColor } )
                    })
                }
            }
            else {
                [void]$LineBuffer.Add([PSCustomObject]@{
                    Segments = @(
                        @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                        @{ Text = "[$($PropVal.Count) elementów]"; Color = $null }
                    )
                })
            }
        }
        elseif ($PropVal -is [System.Collections.Generic.HashSet[string]]) {
            $AsList = @($PropVal)
            if ($AsList.Count -le 3) {
                [void]$LineBuffer.Add([PSCustomObject]@{
                    Segments = @(
                        @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                        @{ Text = ($AsList -join ', '); Color = $null }
                    )
                })
            }
            else {
                [void]$LineBuffer.Add([PSCustomObject]@{
                    Segments = @( @{ Text = "  $PropName ($($AsList.Count))"; Color = $InfoColor } )
                })
                foreach ($Item in $AsList) {
                    [void]$LineBuffer.Add([PSCustomObject]@{
                        Segments = @( @{ Text = "    $([char]0x2022) $Item"; Color = $null } )
                    })
                }
            }
        }
        else {
            [void]$LineBuffer.Add([PSCustomObject]@{
                Segments = @(
                    @{ Text = "  $($PropName.PadRight(22))"; Color = $InfoColor }
                    @{ Text = ([string]$PropVal); Color = $null }
                )
            })
        }
    }

    # Footer separator
    [void]$LineBuffer.Add([PSCustomObject]@{ Segments = @( @{ Text = ''; Color = $null } ) })
    [void]$LineBuffer.Add([PSCustomObject]@{ Segments = @( @{ Text = "  $Sep"; Color = $DisabledColor } ) })

    # ── Phase 2: Render with optional scrolling ─────────────────────────────
    $ViewportHeight = [System.Console]::WindowHeight - 3

    if ($LineBuffer.Count -le $ViewportHeight) {
        # Content fits — render once, wait for Esc (no scroll needed)
        [System.Console]::Clear()
        foreach ($Line in $LineBuffer) {
            foreach ($Seg in $Line.Segments) {
                if ($Seg.Color) {
                    Write-Host $Seg.Text -NoNewline -ForegroundColor $Seg.Color
                } else {
                    Write-Host $Seg.Text -NoNewline
                }
            }
            Write-Host ''
        }
        Write-Host "  Esc wstecz" -ForegroundColor $DisabledColor
        [void](Read-ArrowKey)
    }
    else {
        # Content overflows — enter scroll loop
        $ScrollOffset = 0
        $MaxOffset = $LineBuffer.Count - $ViewportHeight

        while ($true) {
            [System.Console]::Clear()

            if ($ScrollOffset -gt 0) {
                Write-Host "  $([char]0x2191) więcej powyżej" -ForegroundColor $DisabledColor
            } else {
                Write-Host ''
            }

            $SliceEnd = [Math]::Min($ScrollOffset + $ViewportHeight, $LineBuffer.Count)
            for ($L = $ScrollOffset; $L -lt $SliceEnd; $L++) {
                $Line = $LineBuffer[$L]
                foreach ($Seg in $Line.Segments) {
                    if ($Seg.Color) {
                        Write-Host $Seg.Text -NoNewline -ForegroundColor $Seg.Color
                    } else {
                        Write-Host $Seg.Text -NoNewline
                    }
                }
                Write-Host ''
            }

            if ($ScrollOffset -lt $MaxOffset) {
                Write-Host "  $([char]0x2193) więcej poniżej" -ForegroundColor $DisabledColor
            } else {
                Write-Host ''
            }

            Write-Host "  $([char]0x2191)$([char]0x2193) przewijaj  |  Esc wstecz" -ForegroundColor $DisabledColor

            $Key = Read-ArrowKey
            switch ($Key.Key) {
                'UpArrow'   { if ($ScrollOffset -gt 0) { $ScrollOffset-- } }
                'DownArrow' { if ($ScrollOffset -lt $MaxOffset) { $ScrollOffset++ } }
                'Escape'    { return }
                default {
                    if ($Key.KeyChar -eq 'q' -or $Key.KeyChar -eq 'Q') { return }
                }
            }
        }
    }
}

# ── Refresh-NavState ─────────────────────────────────────────────────────────

function Refresh-NavState {
    param([Parameter(Mandatory)] [object]$State)

    Write-Host "  Odświeżanie danych..." -ForegroundColor (Get-CLIColor -Role 'Disabled')
    $State.Entities = Get-Entity -Quiet
    $State.Players  = Get-Player
    $State.NameIndex = Get-NameIndex -Players $State.Players -Entities $State.Entities
    $State.ResolveCache = @{}
}

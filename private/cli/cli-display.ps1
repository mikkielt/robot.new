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
        Displays a formatted detail card for a single data row.
    #>
    param(
        [Parameter(Mandatory)] [object]$Row,
        [string]$Title
    )

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    [System.Console]::Clear()

    if ($Title) {
        Write-CLILine -Text $Title -Color $AccentColor
    }
    Write-Host "  $Sep" -ForegroundColor $AccentColor
    Write-Host ''

    foreach ($Prop in $Row.PSObject.Properties) {
        $PropName = $Prop.Name
        $PropVal  = $Prop.Value

        # Skip internal/path-like properties
        if ($PropName -eq 'Path' -or $PropName -eq 'CN') { continue }

        if ($null -eq $PropVal) {
            Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host '(brak)' -ForegroundColor $DisabledColor
        }
        elseif ($PropVal -is [string]) {
            Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $PropVal
        }
        elseif ($PropVal -is [bool]) {
            Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            $BoolText = if ($PropVal) { 'Tak' } else { 'Nie' }
            Write-Host $BoolText
        }
        elseif ($PropVal -is [decimal] -or $PropVal -is [int] -or $PropVal -is [double]) {
            Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host ([string]$PropVal)
        }
        elseif ($PropVal -is [System.Collections.IDictionary]) {
            Write-Host "  $PropName" -ForegroundColor $InfoColor
            foreach ($DKey in $PropVal.Keys) {
                $DVal = $PropVal[$DKey]
                if ($DVal -is [System.Collections.IList]) {
                    Write-Host "    $($DKey.PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                    Write-Host ($DVal -join ', ')
                }
                else {
                    Write-Host "    $($DKey.PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                    Write-Host ([string]$DVal)
                }
            }
        }
        elseif ($PropVal -is [System.Collections.IList] -or $PropVal -is [array]) {
            if ($PropVal.Count -eq 0) {
                Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                Write-Host '(puste)' -ForegroundColor $DisabledColor
            }
            elseif ($PropVal[0] -is [string] -or $PropVal[0] -is [int] -or $PropVal[0] -is [decimal]) {
                # Simple list - join inline or multi-line
                if ($PropVal.Count -le 3) {
                    Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                    Write-Host ($PropVal -join ', ')
                }
                else {
                    Write-Host "  $PropName ($($PropVal.Count))" -ForegroundColor $InfoColor
                    foreach ($Item in $PropVal) {
                        Write-Host "    $([char]0x2022) $Item"
                    }
                }
            }
            elseif ($PropVal[0] -is [PSCustomObject] -or $PropVal[0].PSObject) {
                # Nested objects - detect temporal pattern and format smartly
                $First = $PropVal[0]
                $HasText = $First.PSObject.Properties['Text']
                $HasValidFrom = $First.PSObject.Properties['ValidFrom']

                Write-Host "  $PropName ($($PropVal.Count))" -ForegroundColor $InfoColor
                $ShowCount = [Math]::Min($PropVal.Count, 8)
                for ($I = 0; $I -lt $ShowCount; $I++) {
                    $Obj = $PropVal[$I]

                    if ($HasText -and $HasValidFrom) {
                        $MainText = if ($Obj.Text) { $Obj.Text } else { '?' }
                        $Range = Format-DetailValidityRange -ValidFrom $Obj.ValidFrom -ValidTo $Obj.ValidTo
                        $DisplayLine = if ($Range) { "$MainText ($Range)" } else { $MainText }
                        Write-Host "    $([char]0x2022) $DisplayLine"
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
                        Write-Host "    $([char]0x2022) $DisplayLine"
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
                        Write-Host "    $([char]0x2022) $($Parts -join '  |  ')"
                    }
                }
                if ($PropVal.Count -gt 8) {
                    Write-Host "    ... i $($PropVal.Count - 8) więcej" -ForegroundColor $DisabledColor
                }
            }
            else {
                Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                Write-Host "[$($PropVal.Count) elementów]"
            }
        }
        elseif ($PropVal -is [System.Collections.Generic.HashSet[string]]) {
            $AsList = @($PropVal)
            if ($AsList.Count -le 3) {
                Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                Write-Host ($AsList -join ', ')
            }
            else {
                Write-Host "  $PropName ($($AsList.Count))" -ForegroundColor $InfoColor
                foreach ($Item in $AsList) {
                    Write-Host "    $([char]0x2022) $Item"
                }
            }
        }
        else {
            Write-Host "  $($PropName.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host ([string]$PropVal)
        }
    }

    Write-Host ''
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  Esc wstecz" -ForegroundColor $DisabledColor

    [void](Read-ArrowKey)
}

# ── Refresh-NavState ─────────────────────────────────────────────────────────

function Refresh-NavState {
    param([Parameter(Mandatory)] [object]$State)

    Write-Host "  Odświeżanie danych..." -ForegroundColor (Get-CLIColor -Role 'Disabled')
    $State.Entities = Get-Entity
    $State.Players  = Get-Player
    $State.NameIndex = Get-NameIndex -Players $State.Players -Entities $State.Entities
    $State.ResolveCache = @{}
}

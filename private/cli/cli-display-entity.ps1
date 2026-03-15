<#
    .SYNOPSIS
    Entity-domain display helpers - validity range formatting and entity detail card.

    .DESCRIPTION
    This file contains display functions for entity presentation, extracted from
    cli-wf-entity.ps1. Dot-sourced by cli-wf-entity.ps1 on demand.

    Helpers:
    - Format-ValidityRange: formats temporal range as "YYYY-MM-DD – YYYY-MM-DD"
      with Polish "od"/"do" prefixes for open-ended ranges
    - Show-EntityCard:      renders entity detail card with all entity fields
      in a fixed vertical layout (core fields, info override, groups, doors,
      contains, aliases with temporal ranges, custom @tags, location history,
      group history). Waits for Escape before returning.

    Design:
    - Show-EntityCard accepts either an Entity parameter or a Row parameter
      (aliased for backward compatibility with detail-card call sites).
    - History lists (LocationHistory, GroupHistory) are capped at 5 entries
      to keep the card within a single terminal screen. Overflow is indicated
      with a "... i N więcej" line.
    - This file uses direct console rendering (Write-Host, Console.Clear)
      rather than the TUI engine, so it can be used from legacy workflows
      without engine lifecycle overhead.

    Dependencies: cli-primitives.ps1 (Get-CLIColor, Write-CLILine)
#>

# ── Format-ValidityRange ───────────────────────────────────────────────────

function Format-ValidityRange {
    param($ValidFrom, $ValidTo)
    $From = if ($ValidFrom) { ([datetime]$ValidFrom).ToString('yyyy-MM-dd') } else { $null }
    $To   = if ($ValidTo)   { ([datetime]$ValidTo).ToString('yyyy-MM-dd') }   else { $null }
    if ($From -and $To)   { return "$From $([char]0x2013) $To" }
    elseif ($From)        { return "od $From" }
    elseif ($To)          { return "do $To" }
    return $null
}

# ── Show-EntityCard ────────────────────────────────────────────────────────

function Show-EntityCard {
    param(
        [object]$Entity,
        [object]$State,
        [object]$Row
    )

    # Support both direct entity and detail-card Row parameter
    if (-not $Entity -and $Row) { $Entity = $Row }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50  # 50-char horizontal rule

    [System.Console]::Clear()

    Write-Host "  $Sep" -ForegroundColor $AccentColor
    Write-CLILine -Text "$($Entity.Name)" -Color $AccentColor
    Write-Host ''

    # Core fields — Type, Status, Location, Owner, Quantity (always shown if present)
    Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Entity.Type)"
    Write-Host "  $('Status'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Entity.Status)"

    if ($Entity.Location) {
        Write-Host "  $('Lokalizacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Entity.Location)"
    }

    if ($Entity.Owner) {
        Write-Host "  $('Właściciel'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Entity.Owner)"
    }

    if ($Entity.Quantity) {
        Write-Host "  $('Ilość'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Entity.Quantity)"
    }

    # @info override — last-active-wins for list values (consistent with entity model)
    if ($Entity.Overrides -and $Entity.Overrides.ContainsKey('info')) {
        $InfoValues = $Entity.Overrides['info']
        $InfoText = if ($InfoValues -is [System.Collections.IList]) { $InfoValues[-1] } else { [string]$InfoValues }
        Write-Host "  $('Info'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $InfoText
    }

    if ($Entity.Groups -and $Entity.Groups.Count -gt 0) {
        Write-Host "  $('Grupy'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Entity.Groups -join ', ')
    }

    if ($Entity.Doors -and $Entity.Doors.Count -gt 0) {
        Write-Host "  $('Drzwi'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Entity.Doors -join ', ')
    }

    if ($Entity.Contains -and $Entity.Contains.Count -gt 0) {
        Write-Host "  $('Zawiera'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Entity.Contains -join ', ')
    }

    # Aliases — format as "Text (range)" for temporal, plain text for scalar
    if ($Entity.Aliases -and $Entity.Aliases.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text 'Aliasy' -Color $InfoColor
        foreach ($Alias in $Entity.Aliases) {
            $AliasText = if ($Alias -is [string]) { $Alias }
                         elseif ($Alias.Text) {
                             $Range = Format-ValidityRange -ValidFrom $Alias.ValidFrom -ValidTo $Alias.ValidTo
                             if ($Range) { "$($Alias.Text) ($Range)" } else { $Alias.Text }
                         }
                         else { [string]$Alias }
            Write-CLILine -Text "  $([char]0x2022) $AliasText"
        }
    }

    # Custom @tags — skip 'info' (already rendered above)
    if ($Entity.Overrides -and $Entity.Overrides.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text 'Tagi' -Color $InfoColor
        foreach ($Key in $Entity.Overrides.Keys) {
            if ($Key -eq 'info') { continue }
            $Values = $Entity.Overrides[$Key]
            if ($Values -is [System.Collections.IList]) {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host ($Values -join ', ')
            }
            else {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host ([string]$Values)
            }
        }
    }

    if ($Entity.LocationHistory -and $Entity.LocationHistory.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text "Historia lokalizacji ($($Entity.LocationHistory.Count))" -Color $InfoColor
        $ShowMax = [Math]::Min($Entity.LocationHistory.Count, 5)  # keep card within single screen
        for ($I = 0; $I -lt $ShowMax; $I++) {
            $H = $Entity.LocationHistory[$I]
            $Loc = if ($H.Location) { $H.Location } else { '?' }
            $Range = Format-ValidityRange -ValidFrom $H.ValidFrom -ValidTo $H.ValidTo
            $RangeText = if ($Range) { " ($Range)" } else { '' }
            Write-CLILine -Text "  $([char]0x2022) $Loc$RangeText"
        }
        if ($Entity.LocationHistory.Count -gt 5) {
            Write-CLILine -Text "  ... i $($Entity.LocationHistory.Count - 5) więcej" -Color $DisabledColor
        }
    }

    if ($Entity.GroupHistory -and $Entity.GroupHistory.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text "Historia grup ($($Entity.GroupHistory.Count))" -Color $InfoColor
        $ShowMax = [Math]::Min($Entity.GroupHistory.Count, 5)
        for ($I = 0; $I -lt $ShowMax; $I++) {
            $H = $Entity.GroupHistory[$I]
            $Grp = if ($H.Group) { $H.Group } else { '?' }
            $Range = Format-ValidityRange -ValidFrom $H.ValidFrom -ValidTo $H.ValidTo
            $RangeText = if ($Range) { " ($Range)" } else { '' }
            Write-CLILine -Text "  $([char]0x2022) $Grp$RangeText"
        }
        if ($Entity.GroupHistory.Count -gt 5) {
            Write-CLILine -Text "  ... i $($Entity.GroupHistory.Count - 5) więcej" -Color $DisabledColor
        }
    }

    Write-Host ''
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  Esc wstecz" -ForegroundColor $DisabledColor
    [void][System.Console]::ReadKey($true)
}

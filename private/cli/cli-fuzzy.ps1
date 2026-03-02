<#
    .SYNOPSIS
    Fuzzy search system for the Robot CLI - candidate building, multi-stage
    filtering, and interactive typeahead.

    .DESCRIPTION
    This file contains the fuzzy search pipeline consumed by wizard steps
    (StepType = 'fuzzy') and workflow functions. Dot-sourced on demand.

    Helpers:
    - Get-FuzzySearchCandidates: builds candidate list from NavState for a given source
    - Filter-FuzzyCandidates:    prefix → contains → Resolve-Name filtering
    - Show-FuzzySearch:          live typeahead with scrollable results

    Design:
    - Three-stage filtering: prefix match (fastest) → contains match →
      Resolve-Name with declension + BK-tree fuzzy (for queries >= 3 chars).
    - Source types map NavState collections to typed candidate objects.
    - Viewport-based scrolling with arrow indicators.
#>

# ── Get-FuzzySearchCandidates ────────────────────────────────────────────────

function Get-FuzzySearchCandidates {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [object]$State
    )

    $Candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

    switch ($Source) {
        'players' {
            foreach ($P in $State.Players) {
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $P.Name
                    Type        = 'Gracz'
                    DisplayText = $P.Name
                    Owner       = $P
                })
            }
        }
        'characters' {
            foreach ($P in $State.Players) {
                if ($P.Characters) {
                    foreach ($Ch in $P.Characters) {
                        $CharName = if ($Ch.Name) { $Ch.Name } else { $Ch }
                        [void]$Candidates.Add([PSCustomObject]@{
                            Name        = $CharName
                            Type        = "Postać ($($P.Name))"
                            DisplayText = "$CharName ($($P.Name))"
                            Owner       = $Ch
                        })
                    }
                }
            }
        }
        'entities' {
            foreach ($E in $State.Entities) {
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $E.Name
                    Type        = $E.Type
                    DisplayText = "$($E.Name) [$($E.Type)]"
                    Owner       = $E
                })
            }
        }
        'locations' {
            foreach ($E in $State.Entities) {
                if ($E.Type -ieq 'Lokacja') {
                    [void]$Candidates.Add([PSCustomObject]@{
                        Name        = $E.Name
                        Type        = 'Lokacja'
                        DisplayText = $E.Name
                        Owner       = $E
                    })
                }
            }
        }
        'groups' {
            foreach ($E in $State.Entities) {
                if ($E.Type -ieq 'Grupa') {
                    [void]$Candidates.Add([PSCustomObject]@{
                        Name        = $E.Name
                        Type        = 'Grupa'
                        DisplayText = $E.Name
                        Owner       = $E
                    })
                }
            }
        }
        'npcs' {
            foreach ($E in $State.Entities) {
                if ($E.Type -ieq 'NPC') {
                    [void]$Candidates.Add([PSCustomObject]@{
                        Name        = $E.Name
                        Type        = 'NPC'
                        DisplayText = $E.Name
                        Owner       = $E
                    })
                }
            }
        }
        'currency' {
            foreach ($E in $State.Entities) {
                if ($E.Type -ieq 'Przedmiot' -and $E.Tags -and $E.Tags['ilość']) {
                    [void]$Candidates.Add([PSCustomObject]@{
                        Name        = $E.Name
                        Type        = 'Waluta'
                        DisplayText = "$($E.Name) ($($E.Tags['ilość']))"
                        Owner       = $E
                    })
                }
            }
        }
        'narrators' {
            foreach ($P in $State.Players) {
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $P.Name
                    Type        = 'Narrator'
                    DisplayText = $P.Name
                    Owner       = $P
                })
            }
        }
        default {
            # Fallback: all entities
            foreach ($E in $State.Entities) {
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $E.Name
                    Type        = $E.Type
                    DisplayText = "$($E.Name) [$($E.Type)]"
                    Owner       = $E
                })
            }
        }
    }

    return $Candidates
}

# ── Filter-FuzzyCandidates ───────────────────────────────────────────────────

function Filter-FuzzyCandidates {
    param(
        [string]$Query,
        [object[]]$Candidates,
        [object]$State,
        [int]$MaxResults = 10
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        $Count = [Math]::Min($Candidates.Count, $MaxResults)
        if ($Count -le 0) { return @() }
        return $Candidates[0..($Count - 1)]
    }

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Stage 1: Prefix match
    foreach ($C in $Candidates) {
        if ($C.Name.StartsWith($Query, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$Results.Add($C)
            if ($Results.Count -ge $MaxResults) { return $Results }
        }
    }

    # Stage 2: Contains match
    foreach ($C in $Candidates) {
        if ($Results.Contains($C)) { continue }
        if ($C.Name.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            [void]$Results.Add($C)
            if ($Results.Count -ge $MaxResults) { return $Results }
        }
    }

    # Stage 3: Resolve-Name (declension + fuzzy) for queries >= 3 chars
    if ($Query.Length -ge 3 -and $Results.Count -lt 3 -and $State.NameIndex) {
        $Resolved = Resolve-Name -Query $Query `
            -Index $State.NameIndex.Index `
            -StemIndex $State.NameIndex.StemIndex `
            -BKTree $State.NameIndex.BKTree `
            -Cache $State.ResolveCache

        if ($Resolved) {
            $ResolvedName = if ($Resolved.Name) { $Resolved.Name } else { [string]$Resolved }
            foreach ($C in $Candidates) {
                if ($Results.Contains($C)) { continue }
                if ([string]::Equals($C.Name, $ResolvedName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$Results.Add($C)
                    break
                }
            }
        }
    }

    return $Results
}

# ── Show-FuzzySearch ─────────────────────────────────────────────────────────

function Show-FuzzySearch {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [object]$State
    )

    $AllCandidates = Get-FuzzySearchCandidates -Source $Source -State $State
    $QueryBuffer = [System.Text.StringBuilder]::new()
    $SelectedIdx = 0   # Absolute index within $Filtered
    $ViewOffset  = 0   # First visible item index
    $MaxVisible  = 10

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    # Return all matching candidates (not capped at viewport size) so scrolling works
    $Filtered = Filter-FuzzyCandidates -Query '' -Candidates $AllCandidates -State $State -MaxResults 500

    $StartRow = [System.Console]::CursorTop

    while ($true) {
        # Clamp viewport to keep selection visible
        if ($SelectedIdx -lt $ViewOffset) {
            $ViewOffset = $SelectedIdx
        }
        if ($SelectedIdx -ge ($ViewOffset + $MaxVisible)) {
            $ViewOffset = $SelectedIdx - $MaxVisible + 1
        }

        [System.Console]::SetCursorPosition(0, $StartRow)

        # Prompt line with result count
        $ClearLine = ' ' * [System.Console]::WindowWidth
        [System.Console]::Write($ClearLine)
        [System.Console]::SetCursorPosition(0, $StartRow)
        Write-Host "  $Prompt`: " -NoNewline -ForegroundColor $AccentColor
        Write-Host $QueryBuffer.ToString() -NoNewline
        if ($Filtered.Count -gt $MaxVisible) {
            # Show count indicator after cursor gap
            $CountCol = 2 + $Prompt.Length + 2 + $QueryBuffer.Length + 2
            if ($CountCol -lt ([System.Console]::WindowWidth - 15)) {
                [System.Console]::SetCursorPosition($CountCol, $StartRow)
                Write-Host "($($SelectedIdx + 1)/$($Filtered.Count))" -NoNewline -ForegroundColor $DisabledColor
            }
        }

        # Results list (viewport slice)
        $HasMore_Above = ($ViewOffset -gt 0)
        $HasMore_Below = (($ViewOffset + $MaxVisible) -lt $Filtered.Count)

        for ($I = 0; $I -lt $MaxVisible; $I++) {
            $Row = $StartRow + 1 + $I
            [System.Console]::SetCursorPosition(0, $Row)
            [System.Console]::Write($ClearLine)
            [System.Console]::SetCursorPosition(0, $Row)

            $AbsIdx = $ViewOffset + $I

            # Show scroll arrows on first/last visible line
            if ($I -eq 0 -and $HasMore_Above) {
                Write-Host "    $([char]0x2191) " -NoNewline -ForegroundColor $DisabledColor
            }
            elseif ($I -eq ($MaxVisible - 1) -and $HasMore_Below) {
                Write-Host "    $([char]0x2193) " -NoNewline -ForegroundColor $DisabledColor
            }

            if ($AbsIdx -lt $Filtered.Count) {
                $C = $Filtered[$AbsIdx]
                $IsSelected = ($AbsIdx -eq $SelectedIdx)
                $Pointer = if ($IsSelected) { [char]0x25B8 } else { ' ' }
                $Color = if ($IsSelected) { $AccentColor } else { $null }

                # Only write prefix spacing if scroll arrow wasn't already written
                $NeedPrefix = ($I -ne 0 -or -not $HasMore_Above) -and ($I -ne ($MaxVisible - 1) -or -not $HasMore_Below)
                if ($NeedPrefix) {
                    Write-Host "      " -NoNewline
                }

                if ($Color) {
                    Write-Host "$Pointer $($C.DisplayText)" -ForegroundColor $Color
                } else {
                    Write-Host "$Pointer $($C.DisplayText)"
                }
            }
        }

        # Hints line
        $HintRow = $StartRow + 1 + $MaxVisible
        [System.Console]::SetCursorPosition(0, $HintRow)
        [System.Console]::Write($ClearLine)
        [System.Console]::SetCursorPosition(0, $HintRow)
        Write-Host "  Wpisz aby filtrować  |  $([char]0x2191)$([char]0x2193) nawigacja  |  Enter wybierz  |  Esc anuluj" -ForegroundColor $DisabledColor

        # Position cursor after the query text for visual feedback
        $CursorCol = 2 + $Prompt.Length + 2 + $QueryBuffer.Length
        [System.Console]::SetCursorPosition($CursorCol, $StartRow)

        # Read key
        $Key = [System.Console]::ReadKey($true)

        switch ($Key.Key) {
            'UpArrow' {
                if ($SelectedIdx -gt 0) { $SelectedIdx-- }
            }
            'DownArrow' {
                if ($SelectedIdx -lt ($Filtered.Count - 1)) { $SelectedIdx++ }
            }
            'Enter' {
                if ($Filtered.Count -gt 0 -and $SelectedIdx -lt $Filtered.Count) {
                    # Clear search area
                    for ($I = 0; $I -le ($MaxVisible + 1); $I++) {
                        [System.Console]::SetCursorPosition(0, $StartRow + $I)
                        [System.Console]::Write($ClearLine)
                    }
                    [System.Console]::SetCursorPosition(0, $StartRow)
                    $Selected = $Filtered[$SelectedIdx]
                    Write-CLILine -Text "$Prompt`: $($Selected.DisplayText)" -Color $AccentColor
                    return $Selected
                }
            }
            'Escape' {
                # Clear search area
                for ($I = 0; $I -le ($MaxVisible + 1); $I++) {
                    [System.Console]::SetCursorPosition(0, $StartRow + $I)
                    [System.Console]::Write($ClearLine)
                }
                [System.Console]::SetCursorPosition(0, $StartRow)
                return $null
            }
            'Backspace' {
                if ($QueryBuffer.Length -gt 0) {
                    [void]$QueryBuffer.Remove($QueryBuffer.Length - 1, 1)
                    $Filtered = Filter-FuzzyCandidates -Query $QueryBuffer.ToString() -Candidates $AllCandidates -State $State -MaxResults 500
                    $SelectedIdx = 0
                    $ViewOffset = 0
                }
            }
            default {
                $Ch = $Key.KeyChar
                if ($Ch -ge ' ') {
                    [void]$QueryBuffer.Append($Ch)
                    $Filtered = Filter-FuzzyCandidates -Query $QueryBuffer.ToString() -Candidates $AllCandidates -State $State -MaxResults 500
                    $SelectedIdx = 0
                    $ViewOffset = 0
                }
            }
        }
    }
}

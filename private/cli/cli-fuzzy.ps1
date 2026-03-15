<#
    .SYNOPSIS
    Fuzzy search system for the Robot CLI - candidate building, multi-stage
    filtering, and interactive typeahead.

    .DESCRIPTION
    This file contains the fuzzy search pipeline consumed by wizard steps
    (StepType = 'fuzzy') and workflow functions. Dot-sourced on demand.

    Active helpers (NOT deprecated):
    - Get-FuzzySearchCandidates: builds typed candidate list from NavState for
      a given source (players, characters, entities, locations, groups, npcs,
      currency, narrators). Uses EntityTypeIndex for O(1) type-filtered lookups
      when available, falling back to full scan otherwise.
    - Filter-FuzzyCandidates:    three-stage filtering pipeline:
      Stage 1 — prefix match (fastest, O(N) scan);
      Stage 2 — contains match (catches mid-word matches);
      Stage 3 — Resolve-Name with Polish declension stemming + BK-tree edit
      distance (only for queries >= 3 chars and when fewer than 3 results from
      stages 1-2, to avoid false positives on short queries).

    Module-level data:
    - Robot.FuzzyMatcher C# type (compiled centrally in robot.psm1): pre-lowercased
      two-stage prefix+contains filter that eliminates per-keystroke
      ToLowerInvariant overhead on 3,757+ candidates

    Design:
    - When the compiled Robot.FuzzyMatcher is available, stages 1-2 run in
      compiled C# and return index arrays; otherwise a PowerShell fallback
      performs the same logic with OrdinalIgnoreCase comparisons.
    - Candidates are PSCustomObjects with Name, Type, DisplayText, and Owner
      fields. Owner preserves the original entity/player reference so callers
      can navigate directly to the selected item without re-lookup.
    - Show-FuzzySearch uses viewport-based scrolling (10-item window) with
      arrow indicators and position counter for large result sets.

    Dependencies: cli-primitives.ps1 (Get-CLIColor, Write-CLILine),
                  resolve-name.ps1 (Resolve-Name), lib/FuzzyMatcher.cs
#>

# C# type: Robot.FuzzyMatcher (lib/FuzzyMatcher.cs) — compiled centrally in robot.psm1.
# Pre-lowercases candidate names at build time, eliminating per-keystroke
# ToLowerInvariant overhead on 3,757+ candidates.

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
            $TypeFiltered = if ($State.EntityTypeIndex -and $State.EntityTypeIndex.ContainsKey('Lokacja')) { $State.EntityTypeIndex['Lokacja'] } else { $null }
            $Items = if ($TypeFiltered) { $TypeFiltered } else { $State.Entities }
            foreach ($E in $Items) {
                if (-not $TypeFiltered -and $E.Type -ine 'Lokacja') { continue }
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $E.Name
                    Type        = 'Lokacja'
                    DisplayText = $E.Name
                    Owner       = $E
                })
            }
        }
        'groups' {
            $TypeFiltered = if ($State.EntityTypeIndex -and $State.EntityTypeIndex.ContainsKey('Grupa')) { $State.EntityTypeIndex['Grupa'] } else { $null }
            $Items = if ($TypeFiltered) { $TypeFiltered } else { $State.Entities }
            foreach ($E in $Items) {
                if (-not $TypeFiltered -and $E.Type -ine 'Grupa') { continue }
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $E.Name
                    Type        = 'Grupa'
                    DisplayText = $E.Name
                    Owner       = $E
                })
            }
        }
        'npcs' {
            $TypeFiltered = if ($State.EntityTypeIndex -and $State.EntityTypeIndex.ContainsKey('NPC')) { $State.EntityTypeIndex['NPC'] } else { $null }
            $Items = if ($TypeFiltered) { $TypeFiltered } else { $State.Entities }
            foreach ($E in $Items) {
                if (-not $TypeFiltered -and $E.Type -ine 'NPC') { continue }
                [void]$Candidates.Add([PSCustomObject]@{
                    Name        = $E.Name
                    Type        = 'NPC'
                    DisplayText = $E.Name
                    Owner       = $E
                })
            }
        }
        'currency' {
            $CurrItems = if ($State.EntityTypeIndex -and $State.EntityTypeIndex.ContainsKey('Przedmiot')) { $State.EntityTypeIndex['Przedmiot'] } else { $null }
            $CurrSource = if ($CurrItems) { $CurrItems } else { $State.Entities }
            foreach ($E in $CurrSource) {
                if (-not $CurrItems -and $E.Type -ine 'Przedmiot') { continue }
                if ($E.Tags -and $E.Tags['ilość']) {
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
    $Seen = [System.Collections.Generic.HashSet[object]]::new()

    # C# path: two-stage prefix+contains in compiled code, returns indices
    if (([System.Management.Automation.PSTypeName]'Robot.FuzzyMatcher').Type) {
        $NameArr = [string[]]::new($Candidates.Count)
        for ($I = 0; $I -lt $Candidates.Count; $I++) { $NameArr[$I] = $Candidates[$I].Name }
        $Matcher = [Robot.FuzzyMatcher]::new($NameArr)
        $Indices = $Matcher.Filter($Query, $MaxResults)
        foreach ($Idx in $Indices) {
            [void]$Results.Add($Candidates[$Idx])
            [void]$Seen.Add($Candidates[$Idx])
        }
    } else {
        # PowerShell fallback: Stage 1 prefix + Stage 2 contains
        foreach ($C in $Candidates) {
            if ($C.Name.StartsWith($Query, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$Results.Add($C)
                [void]$Seen.Add($C)
                if ($Results.Count -ge $MaxResults) { return $Results }
            }
        }

        foreach ($C in $Candidates) {
            if ($Seen.Contains($C)) { continue }
            if ($C.Name.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$Results.Add($C)
                [void]$Seen.Add($C)
                if ($Results.Count -ge $MaxResults) { return $Results }
            }
        }
    }

    if ($Results.Count -ge $MaxResults) { return $Results }

    # Stage 3: Resolve-Name uses declension stemming + BK-tree edit distance.
    # Only triggered for queries >= 3 chars (shorter queries produce too many
    # false positives) and when prefix/contains found fewer than 3 matches.
    if ($Query.Length -ge 3 -and $Results.Count -lt 3 -and $State.NameIndex) {
        $Resolved = Resolve-Name -Query $Query `
            -Index $State.NameIndex.Index `
            -StemIndex $State.NameIndex.StemIndex `
            -BKTree $State.NameIndex.BKTree `
            -Cache $State.ResolveCache

        if ($Resolved) {
            $ResolvedName = if ($Resolved.Name) { $Resolved.Name } else { [string]$Resolved }
            foreach ($C in $Candidates) {
                if ($Seen.Contains($C)) { continue }
                if ([string]::Equals($C.Name, $ResolvedName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$Results.Add($C)
                    break
                }
            }
        }
    }

    return $Results
}



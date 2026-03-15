<#
    .SYNOPSIS
    Typed projection from Get-Player - flattens player data into per-character rows.

    .DESCRIPTION
    This file contains Get-PlayerCharacter and its helpers:

    Helpers:
    - Merge-ScalarProperty: resolves a single-value property across three layers
      (character file baseline, entities.md overrides, session @zmiany) using
      temporal validity ranges; last-dated wins
    - Merge-MultiValuedProperty: same three-layer merge for list properties,
      returning all currently-active values
    - Merge-ReputationTier: three-layer merge for reputation entries, preserving
      Detail metadata from the character file where possible

    Get-PlayerCharacter wraps Get-Player and produces one output object per
    character, each carrying a PlayerName backreference to its parent player.
    Supports filtering by player name and character name (case-insensitive).
    Pass-through -Entities avoids redundant entity parsing.

    When -IncludeState is set, the function pre-fetches Get-EntityState and
    parses each character's file, then applies the three-layer merge pattern
    (character file baseline, entity overrides, session @zmiany) to produce
    enriched output properties (Condition, Reputation, SpecialItems, etc.).
    The merge helpers use ConvertFrom-ValidityString and Get-LastActiveValue /
    Get-AllActiveValues from temporal-helpers.ps1 for date-range resolution.
#>

function Get-PlayerCharacter {
    <#
        .SYNOPSIS
        Returns character objects with PlayerName backreference from Get-Player data.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by player name(s) (case-insensitive)")]
        [string[]]$PlayerName,

        [Parameter(HelpMessage = "Filter by character name(s) (case-insensitive)")]
        [string[]]$CharacterName,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity to avoid redundant parsing")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Include full character state (file + entity + session merge)")]
        [switch]$IncludeState,

        [Parameter(HelpMessage = "Date for temporal resolution of state properties")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Include soft-deleted characters (status = Usunięty)")]
        [switch]$IncludeDeleted
    )

    $GetPlayerParams = @{}
    if ($PlayerName) { $GetPlayerParams['Name'] = $PlayerName }
    if ($Entities) { $GetPlayerParams['Entities'] = $Entities }

    $Players = Get-Player @GetPlayerParams

    # Pre-fetching entity state in bulk avoids per-character Get-EntityState
    # calls, which would re-parse sessions N times instead of once
    $EntityLookup = $null
    $RepoRoot = $null
    if ($IncludeState) {
        . "$script:ModuleRoot/private/charfile-helpers.ps1"

        $RepoRoot = Get-RepoRoot

        # Get enriched entities (file + session @zmiany merged)
        $EntityStateParams = @{}
        if ($Entities) { $EntityStateParams['Entities'] = $Entities }
        if ($ActiveOn) { $EntityStateParams['ActiveOn'] = $ActiveOn }
        $EnrichedEntities = Get-EntityState @EntityStateParams

        # Dictionary keyed by all entity names for O(1) character-to-entity matching
        $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Entity in $EnrichedEntities) {
            foreach ($Name in $Entity.Names) {
                if (-not $EntityLookup.ContainsKey($Name)) {
                    $EntityLookup[$Name] = $Entity
                }
            }
        }
    }

    $EffectiveDate = if ($ActiveOn) { $ActiveOn } else { $null }
    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($Player in $Players) {
        foreach ($Character in $Player.Characters) {
            if ($CharacterName) {
                $Matched = $false
                foreach ($Filter in $CharacterName) {
                    if ([string]::Equals($Character.Name, $Filter, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $Matched = $true
                        break
                    }
                }
                if (-not $Matched) { continue }
            }

            # State fields remain $null when -IncludeState is not set,
            # keeping the output lightweight for callers that only need PU data
            $ActiveStatus       = $null
            $ActiveCharSheet    = $null
            $ActiveTopics       = $null
            $ActiveCondition    = $null
            $ActiveItems        = $null
            $ActiveReputation   = $null
            $ActiveNotes        = $null
            $SessionList        = $null

            if ($IncludeState) {
                $Entity = $null
                if ($EntityLookup.ContainsKey($Character.Name)) {
                    $Entity = $EntityLookup[$Character.Name]
                }

                # Entities default to Aktywny when no @status tag exists
                $ActiveStatus = if ($Entity -and $Entity.Status) { $Entity.Status } else { 'Aktywny' }

                # Soft-deleted characters pollute PU reports and CLI views;
                # callers that need them must opt in via -IncludeDeleted
                if ($ActiveStatus -eq 'Usunięty' -and -not $IncludeDeleted) {
                    continue
                }

                # Layer 1: character file provides undated baseline values that are
                # always active unless superseded by a dated entity override
                $CharFile = $null
                if ($Character.Path) {
                    $CharFilePath = [System.IO.Path]::Combine($RepoRoot, $Character.Path)
                    if ([System.IO.File]::Exists($CharFilePath)) {
                        $CharFile = Read-CharacterFile -Path $CharFilePath
                    }
                }

                # Three-layer merge: character file (undated baseline), entities.md
                # overrides, and session @Zmiany — all pre-merged by Get-EntityState.
                # Scalar properties resolve to last-dated-wins; multi-valued accumulate.
                $ActiveCharSheet = Merge-ScalarProperty -CharFileValue ($CharFile.CharacterSheet) -Entity $Entity -OverrideKey 'karta_postaci' -ActiveOn $EffectiveDate
                $ActiveTopics = Merge-ScalarProperty -CharFileValue ($CharFile.RestrictedTopics) -Entity $Entity -OverrideKey 'tematy_zastrzezone' -ActiveOn $EffectiveDate
                $ActiveCondition = Merge-ScalarProperty -CharFileValue ($CharFile.Condition) -Entity $Entity -OverrideKey 'stan' -ActiveOn $EffectiveDate
                $ActiveItems = Merge-MultiValuedProperty -CharFileValues ($CharFile.SpecialItems) -Entity $Entity -OverrideKey 'przedmiot_specjalny' -ActiveOn $EffectiveDate
                # Reputation tiers are each multi-valued but carry Location+Detail pairs
                $RepPositive = Merge-ReputationTier -CharFileTier ($CharFile.Reputation.Positive) -Entity $Entity -OverrideKey 'reputacja_pozytywna' -ActiveOn $EffectiveDate
                $RepNeutral  = Merge-ReputationTier -CharFileTier ($CharFile.Reputation.Neutral)  -Entity $Entity -OverrideKey 'reputacja_neutralna' -ActiveOn $EffectiveDate
                $RepNegative = Merge-ReputationTier -CharFileTier ($CharFile.Reputation.Negative) -Entity $Entity -OverrideKey 'reputacja_negatywna' -ActiveOn $EffectiveDate
                $ActiveReputation = [PSCustomObject]@{
                    Positive = $RepPositive
                    Neutral  = $RepNeutral
                    Negative = $RepNegative
                }

                $ActiveNotes = Merge-MultiValuedProperty -CharFileValues ($CharFile.AdditionalNotes) -Entity $Entity -OverrideKey 'dodatkowe_informacje' -ActiveOn $EffectiveDate

                # DescribedSessions come only from the character file (no entity override)
                $SessionList = if ($CharFile) { $CharFile.DescribedSessions } else { @() }
            }

            $Results.Add([PSCustomObject]@{
                PlayerName        = $Player.Name
                Player            = $Player
                Name              = $Character.Name
                IsActive          = $Character.IsActive
                Aliases           = $Character.Aliases
                Path              = $Character.Path
                PUExceeded        = $Character.PUExceeded
                PUStart           = $Character.PUStart
                PUSum             = $Character.PUSum
                PUTaken           = $Character.PUTaken
                AdditionalInfo    = $Character.AdditionalInfo
                Status            = $ActiveStatus
                CharacterSheet    = $ActiveCharSheet
                RestrictedTopics  = $ActiveTopics
                Condition         = $ActiveCondition
                SpecialItems      = $ActiveItems
                Reputation        = $ActiveReputation
                AdditionalNotes   = $ActiveNotes
                DescribedSessions = $SessionList
            })
        }
    }

    return $Results
}

# Scalar properties (e.g. Condition) need temporal resolution because entity
# overrides can supersede the character-file baseline within a date range.
function Merge-ScalarProperty {
    param(
        [AllowNull()][string]$CharFileValue,
        [AllowNull()][object]$Entity,
        [string]$OverrideKey,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    $History = [System.Collections.Generic.List[object]]::new()

    # Layer 1: character file baseline (no date = always active, sorts before dated entries)
    if (-not [string]::IsNullOrWhiteSpace($CharFileValue)) {
        $History.Add([PSCustomObject]@{ Value = $CharFileValue; ValidFrom = $null; ValidTo = $null })
    }

    # Layers 2+3: entity overrides (entities.md + session @zmiany, already merged)
    if ($Entity -and $Entity.Overrides.ContainsKey($OverrideKey)) {
        foreach ($Val in $Entity.Overrides[$OverrideKey]) {
            $Parsed = ConvertFrom-ValidityString -InputText $Val
            $History.Add([PSCustomObject]@{
                Value     = $Parsed.Text
                ValidFrom = $Parsed.ValidFrom
                ValidTo   = $Parsed.ValidTo
            })
        }
    }

    if ($History.Count -eq 0) { return $null }

    return Get-LastActiveValue -History $History -PropertyName 'Value' -ActiveOn $ActiveOn
}

# Multi-valued properties (e.g. SpecialItems) accumulate across layers
# rather than replacing, so all active entries are returned.
function Merge-MultiValuedProperty {
    param(
        [AllowNull()][string[]]$CharFileValues,
        [AllowNull()][object]$Entity,
        [string]$OverrideKey,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    $History = [System.Collections.Generic.List[object]]::new()

    # Layer 1: character file baseline entries
    if ($CharFileValues -and $CharFileValues.Count -gt 0) {
        foreach ($Val in $CharFileValues) {
            $History.Add([PSCustomObject]@{ Value = $Val; ValidFrom = $null; ValidTo = $null })
        }
    }

    # Layers 2+3: entity overrides
    if ($Entity -and $Entity.Overrides.ContainsKey($OverrideKey)) {
        foreach ($Val in $Entity.Overrides[$OverrideKey]) {
            $Parsed = ConvertFrom-ValidityString -InputText $Val
            $History.Add([PSCustomObject]@{
                Value     = $Parsed.Text
                ValidFrom = $Parsed.ValidFrom
                ValidTo   = $Parsed.ValidTo
            })
        }
    }

    if ($History.Count -eq 0) { return @() }

    return Get-AllActiveValues -History $History -PropertyName 'Value' -ActiveOn $ActiveOn
}

# Reputation tiers carry Location+Detail pairs; entity overrides only provide
# Location, so we preserve Detail from the character file when possible.
function Merge-ReputationTier {
    param(
        [AllowNull()][object[]]$CharFileTier,
        [AllowNull()][object]$Entity,
        [string]$OverrideKey,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    $History = [System.Collections.Generic.List[object]]::new()

    # Layer 1: character file baseline
    if ($CharFileTier -and $CharFileTier.Count -gt 0) {
        foreach ($Entry in $CharFileTier) {
            $History.Add([PSCustomObject]@{
                Value     = $Entry.Location
                ValidFrom = $null
                ValidTo   = $null
            })
        }
    }

    # Layers 2+3: entity overrides
    if ($Entity -and $Entity.Overrides.ContainsKey($OverrideKey)) {
        foreach ($Val in $Entity.Overrides[$OverrideKey]) {
            $Parsed = ConvertFrom-ValidityString -InputText $Val
            $History.Add([PSCustomObject]@{
                Value     = $Parsed.Text
                ValidFrom = $Parsed.ValidFrom
                ValidTo   = $Parsed.ValidTo
            })
        }
    }

    if ($History.Count -eq 0) { return @() }

    $ActiveLocations = Get-AllActiveValues -History $History -PropertyName 'Value' -ActiveOn $ActiveOn

    # Reconstitute Location/Detail pairs; entity overrides only carry Location,
    # so we recover Detail from the character file where names match
    $Result = [System.Collections.Generic.List[object]]::new()
    foreach ($Loc in $ActiveLocations) {
        $Detail = $null
        if ($CharFileTier) {
            foreach ($Entry in $CharFileTier) {
                if ([string]::Equals($Entry.Location, $Loc, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Detail = $Entry.Detail
                    break
                }
            }
        }
        $Result.Add([PSCustomObject]@{ Location = $Loc; Detail = $Detail })
    }

    return ,$Result.ToArray()
}

<#
    .SYNOPSIS
    Typed projection from Get-Player - flattens player data into per-character rows.

    .DESCRIPTION
    This file contains Get-PlayerCharacter which wraps Get-Player and produces
    one output object per character, each carrying a PlayerName backreference
    to its parent player. Supports filtering by player name and character name
    (case-insensitive). Pass-through -Entities avoids redundant entity parsing.

    When -IncludeState is set, parses each character's file and merges three
    layers of data (character file, entities.md overrides, session @zmiany)
    into enriched output properties (Condition, Reputation, SpecialItems, etc.).
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

    # When -IncludeState is set, pre-fetch entity state and build lookup
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

        # Build lookup by entity name (case-insensitive)
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
            # Apply character name filter if specified
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

            # State fields - $null when -IncludeState is not set
            $ActiveStatus       = $null
            $ActiveCharSheet    = $null
            $ActiveTopics       = $null
            $ActiveCondition    = $null
            $ActiveItems        = $null
            $ActiveReputation   = $null
            $ActiveNotes        = $null
            $SessionList        = $null

            if ($IncludeState) {
                # Find matching entity in EntityState
                $Entity = $null
                if ($EntityLookup.ContainsKey($Character.Name)) {
                    $Entity = $EntityLookup[$Character.Name]
                }

                # Resolve @status from entity (default: Aktywny)
                $ActiveStatus = if ($Entity -and $Entity.Status) { $Entity.Status } else { 'Aktywny' }

                # Skip soft-deleted characters unless -IncludeDeleted
                if ($ActiveStatus -eq 'Usunięty' -and -not $IncludeDeleted) {
                    continue
                }

                # Read character file (Layer 1: undated baseline)
                $CharFile = $null
                if ($Character.Path) {
                    $CharFilePath = [System.IO.Path]::Combine($RepoRoot, $Character.Path)
                    if ([System.IO.File]::Exists($CharFilePath)) {
                        $CharFile = Read-CharacterFile -Path $CharFilePath
                    }
                }

                # --- Three-layer merge per property ---
                # Layer 1: character file (base, no date = always-active)
                # Layers 2+3: entity Overrides (entities.md + session @zmiany, already merged by Get-EntityState)

                # CharacterSheet (scalar)
                $ActiveCharSheet = Merge-ScalarProperty -CharFileValue ($CharFile.CharacterSheet) -Entity $Entity -OverrideKey 'karta_postaci' -ActiveOn $EffectiveDate

                # RestrictedTopics (scalar)
                $ActiveTopics = Merge-ScalarProperty -CharFileValue ($CharFile.RestrictedTopics) -Entity $Entity -OverrideKey 'tematy_zastrzezone' -ActiveOn $EffectiveDate

                # Condition (scalar)
                $ActiveCondition = Merge-ScalarProperty -CharFileValue ($CharFile.Condition) -Entity $Entity -OverrideKey 'stan' -ActiveOn $EffectiveDate

                # SpecialItems (multi-valued)
                $ActiveItems = Merge-MultiValuedProperty -CharFileValues ($CharFile.SpecialItems) -Entity $Entity -OverrideKey 'przedmiot_specjalny' -ActiveOn $EffectiveDate

                # Reputation (three tiers, each multi-valued)
                $RepPositive = Merge-ReputationTier -CharFileTier ($CharFile.Reputation.Positive) -Entity $Entity -OverrideKey 'reputacja_pozytywna' -ActiveOn $EffectiveDate
                $RepNeutral  = Merge-ReputationTier -CharFileTier ($CharFile.Reputation.Neutral)  -Entity $Entity -OverrideKey 'reputacja_neutralna' -ActiveOn $EffectiveDate
                $RepNegative = Merge-ReputationTier -CharFileTier ($CharFile.Reputation.Negative) -Entity $Entity -OverrideKey 'reputacja_negatywna' -ActiveOn $EffectiveDate
                $ActiveReputation = [PSCustomObject]@{
                    Positive = $RepPositive
                    Neutral  = $RepNeutral
                    Negative = $RepNegative
                }

                # AdditionalNotes (multi-valued)
                $ActiveNotes = Merge-MultiValuedProperty -CharFileValues ($CharFile.AdditionalNotes) -Entity $Entity -OverrideKey 'dodatkowe_informacje' -ActiveOn $EffectiveDate

                # DescribedSessions (read-only from character file)
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

# Helper: merge a scalar property across three layers
# Character file value is undated baseline. Entity overrides (already merged
# with session @zmiany) may carry temporal ranges. Last-dated wins.
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

# Helper: merge a multi-valued property across three layers
# Character file values are undated baseline. Entity overrides augment.
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

# Helper: merge a reputation tier across three layers
# Character file tier entries are undated baseline. Entity overrides augment.
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

    # Convert back to Location/Detail objects - override entries lose Detail
    $Result = [System.Collections.Generic.List[object]]::new()
    foreach ($Loc in $ActiveLocations) {
        # Try to find matching char file entry for Detail preservation
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

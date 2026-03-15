<#
    .SYNOPSIS
    Estimates initial PU for a new character based on existing character data.

    .DESCRIPTION
    This file contains Get-NewPlayerCharacterPUCount which computes the starting
    PU value for a new character using the legacy-compatible formula:

        Include only characters with PUStart > 0 and status != Usunięty
        PU = Floor((Sum(PUTaken) / 2) + 20)

    Characters with @status: Usunięty are excluded from the calculation.
    Characters with @status: Nieaktywny are included (their PU still counts).

    When Entities are provided, entity status is resolved for each character.
    Without Entities, status-based filtering is skipped (backward-compatible).

    This is a pure computation function with no side effects.
    Used by New-PlayerCharacter as a fallback when InitialPUStart is not
    explicitly provided.
#>

function Get-NewPlayerCharacterPUCount {
    <#
        .SYNOPSIS
        Estimates initial PU for a new character based on existing characters' earned PU.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Player name to compute for")]
        [string]$PlayerName,

        [Parameter(HelpMessage = "Pre-fetched player list from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity for status resolution")]
        [object[]]$Entities
    )

    if (-not $Players) {
        $Players = Get-Player
    }

    $TargetPlayer = $null
    foreach ($Player in $Players) {
        if ([string]::Equals($Player.Name, $PlayerName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $TargetPlayer = $Player
            break
        }
    }

    if (-not $TargetPlayer) {
        throw "Player '$PlayerName' not found."
    }

    # Without entity data, deleted characters cannot be excluded from the sum
    $EntityStatusLookup = $null
    if ($Entities) {
        $EntityStatusLookup = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Entity in $Entities) {
            if ($Entity.Type -eq 'Postać' -and $Entity.Status) {
                $EntityStatusLookup[$Entity.Name] = $Entity.Status
            }
        }
    }

    # Only characters that actually started play (PUStart > 0) contribute;
    # deleted characters would inflate the average unfairly
    $PUTakenSum = [decimal]0
    $IncludedCount = 0
    $ExcludedCharacters = [System.Collections.Generic.List[string]]::new()

    foreach ($Character in $TargetPlayer.Characters) {
        if ($EntityStatusLookup -and $EntityStatusLookup.ContainsKey($Character.Name)) {
            if ($EntityStatusLookup[$Character.Name] -eq 'Usunięty') {
                $ExcludedCharacters.Add($Character.Name)
                continue
            }
        }

        if ($null -ne $Character.PUStart -and $Character.PUStart -gt 0) {
            if ($null -ne $Character.PUTaken) {
                $PUTakenSum += $Character.PUTaken
            }
            $IncludedCount++
        } else {
            $ExcludedCharacters.Add($Character.Name)
        }
    }

    # Legacy formula: half the earned PU plus 20-point base ensures new
    # characters start competitively without matching veteran power
    $Result = [math]::Floor(($PUTakenSum / 2) + 20)

    return [PSCustomObject]@{
        PlayerName         = $PlayerName
        PU                 = [decimal]$Result
        PUTakenSum         = $PUTakenSum
        IncludedCharacters = $IncludedCount
        ExcludedCharacters = $ExcludedCharacters
    }
}

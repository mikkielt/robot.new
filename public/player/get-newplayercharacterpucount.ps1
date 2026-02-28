<#
    .SYNOPSIS
    Estimates initial PU for a new character based on existing character data.

    .DESCRIPTION
    This file contains Get-NewPlayerCharacterPUCount which computes the starting
    PU value for a new character using the legacy-compatible formula:

        Include only characters with PUStart > 0
        PU = Floor((Sum(PUTaken) / 2) + 20)

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
        [object[]]$Players
    )

    if (-not $Players) {
        $Players = Get-Player
    }

    # Find the target player (case-insensitive)
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

    # Filter to characters with PUStart > 0
    $PUTakenSum = [decimal]0
    $IncludedCount = 0
    $ExcludedCharacters = [System.Collections.Generic.List[string]]::new()

    foreach ($Character in $TargetPlayer.Characters) {
        if ($null -ne $Character.PUStart -and $Character.PUStart -gt 0) {
            if ($null -ne $Character.PUTaken) {
                $PUTakenSum += $Character.PUTaken
            }
            $IncludedCount++
        } else {
            $ExcludedCharacters.Add($Character.Name)
        }
    }

    # Formula: Floor((Sum(PUTaken) / 2) + 20)
    $Result = [math]::Floor(($PUTakenSum / 2) + 20)

    return [PSCustomObject]@{
        PlayerName         = $PlayerName
        PU                 = [decimal]$Result
        PUTakenSum         = $PUTakenSum
        IncludedCharacters = $IncludedCount
        ExcludedCharacters = $ExcludedCharacters
    }
}

<#
    .SYNOPSIS
    Entity migration helpers -- bootstrap entities.md from legacy Gracze.md
    player data.

    .DESCRIPTION
    Non-exported helper function used exclusively by migration Phase 0
    (phase0-setup.ps1) to generate the initial entities.md file from
    Gracze.md player data.

    Helpers:
    - ConvertTo-EntitiesFromPlayers: generates entities.md content from Get-Player output

    Separated from entity-writehelpers.ps1 because this function is only
    needed during one-time migration and has no runtime consumers.

    ConvertTo-EntitiesFromPlayers iterates the Get-Player output twice:
    first pass emits "## Gracz" section entries with @margonemid,
    @prfwebhook, and @trigger tags; second pass emits "## Postac" section
    entries with @nalezy_do (ownership back-link), @plik, @alias, PU fields
    (@pu_startowe, @pu_nadmiar, @pu_suma, @pu_zdobyte), and @info.

    Character file paths are URI-decoded via [System.Uri]::UnescapeDataString
    because Gracze.md stores them percent-encoded. PU values are formatted
    with InvariantCulture 'G' specifier to ensure decimal separators are
    portable across locales.

    Output is written as UTF-8 no BOM to the target path (defaults to
    {RepoRoot}/.robot.new/entities.md). The function returns the output
    file path for caller chaining.
#>

function ConvertTo-EntitiesFromPlayers {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Plural noun is intentional - converts multiple entities from multiple players')]
    param(
        [Parameter(HelpMessage = "Path to output entities.md file")]
        [string]$OutputPath,

        [Parameter(HelpMessage = "Pre-fetched player list from Get-Player")]
        [object[]]$Players
    )

    if (-not $OutputPath) {
        $OutputPath = [System.IO.Path]::Combine((Get-RepoRoot), '.robot.new', 'entities.md')
    }

    if (-not $Players) {
        $Players = Get-Player -Entities @()
    }

    $SB = [System.Text.StringBuilder]::new(4096)

    [void]$SB.Append("## Gracz")
    [void]$SB.Append("`n")

    foreach ($Player in $Players) {
        if ([string]::IsNullOrWhiteSpace($Player.Name)) { continue }

        [void]$SB.Append("`n")
        [void]$SB.Append("* $($Player.Name)")
        [void]$SB.Append("`n")

        if (-not [string]::IsNullOrWhiteSpace($Player.MargonemID)) {
            [void]$SB.Append("    - @margonemid: $($Player.MargonemID)")
            [void]$SB.Append("`n")
        }

        if (-not [string]::IsNullOrWhiteSpace($Player.PRFWebhook)) {
            [void]$SB.Append("    - @prfwebhook: $($Player.PRFWebhook)")
            [void]$SB.Append("`n")
        }

        if ($Player.Triggers -and $Player.Triggers.Count -gt 0) {
            foreach ($Trigger in $Player.Triggers) {
                if (-not [string]::IsNullOrWhiteSpace($Trigger)) {
                    [void]$SB.Append("    - @trigger: $($Trigger.Trim())")
                    [void]$SB.Append("`n")
                }
            }
        }
    }

    [void]$SB.Append("`n")
    [void]$SB.Append("## Postać")
    [void]$SB.Append("`n")

    foreach ($Player in $Players) {
        foreach ($Character in $Player.Characters) {
            [void]$SB.Append("`n")
            [void]$SB.Append("* $($Character.Name)")
            [void]$SB.Append("`n")
            [void]$SB.Append("    - @należy_do: $($Player.Name)")
            [void]$SB.Append("`n")

            if (-not [string]::IsNullOrWhiteSpace($Character.Path)) {
                $DecodedPath = [System.Uri]::UnescapeDataString($Character.Path)
                [void]$SB.Append("    - @plik: $DecodedPath")
                [void]$SB.Append("`n")
            }

            if ($Character.Aliases -and $Character.Aliases.Count -gt 0) {
                foreach ($Alias in $Character.Aliases) {
                    if (-not [string]::IsNullOrWhiteSpace($Alias)) {
                        [void]$SB.Append("    - @alias: $Alias")
                        [void]$SB.Append("`n")
                    }
                }
            }

            if ($null -ne $Character.PUStart) {
                $Val = ([decimal]$Character.PUStart).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_startowe: $Val")
                [void]$SB.Append("`n")
            }

            if ($null -ne $Character.PUExceeded -and $Character.PUExceeded -ne 0) {
                $Val = ([decimal]$Character.PUExceeded).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_nadmiar: $Val")
                [void]$SB.Append("`n")
            }

            if ($null -ne $Character.PUSum) {
                $Val = ([decimal]$Character.PUSum).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_suma: $Val")
                [void]$SB.Append("`n")
            }

            if ($null -ne $Character.PUTaken) {
                $Val = ([decimal]$Character.PUTaken).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_zdobyte: $Val")
                [void]$SB.Append("`n")
            }

            if ($Character.AdditionalInfo) {
                $InfoParts = if ($Character.AdditionalInfo -is [System.Collections.IEnumerable] -and $Character.AdditionalInfo -isnot [string]) {
                    $Character.AdditionalInfo
                } else {
                    @($Character.AdditionalInfo)
                }
                foreach ($Info in $InfoParts) {
                    if (-not [string]::IsNullOrWhiteSpace($Info)) {
                        [void]$SB.Append("    - @info: $($Info.Trim())")
                        [void]$SB.Append("`n")
                    }
                }
            }
        }
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($OutputPath, $SB.ToString(), $UTF8NoBOM)

    return $OutputPath
}

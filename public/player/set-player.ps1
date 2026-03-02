<#
    .SYNOPSIS
    Updates player-level fields by writing to entities.md.

    .DESCRIPTION
    This file contains Set-Player which writes @prfwebhook, @margonemid,
    @trigger, and @alias tags to the player's entity entry in entities.md
    under the ## Gracz section.

    If the player has no entity entry yet, one is created.

    Validates Discord webhook URL format (must match
    https://discord.com/api/webhooks/*).

    Aliases are appended with deduplication (case-insensitive) - existing
    aliases with the same value are not duplicated.

    Player renaming is not supported via entity overrides - entity names
    are identity keys.

    Dot-sources entity-writehelpers.ps1 for file manipulation.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source entity write helpers
. "$script:ModuleRoot/private/entity-writehelpers.ps1"

function Set-Player {
    <#
        .SYNOPSIS
        Updates player metadata (webhook, Margonem ID, triggers) in entities.md.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Player name to update")]
        [string]$Name,

        [Parameter(HelpMessage = "Discord PRF webhook URL")]
        [string]$PRFWebhook,

        [Parameter(HelpMessage = "Margonem game profile ID")]
        [string]$MargonemID,

        [Parameter(HelpMessage = "Trigger topics (restricted content)")]
        [string[]]$Triggers,

        [Parameter(HelpMessage = "Player aliases (appended with deduplication)")]
        [string[]]$Aliases,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    if (-not $EntitiesFile) {
        $EntitiesFile = [System.IO.Path]::Combine((Get-RepoRoot), '.robot.new', 'entities.md')
    }

    # Validate webhook URL format
    if ($PRFWebhook -and $PRFWebhook -notlike "https://discord.com/api/webhooks/*") {
        throw "Invalid webhook URL format. Must match 'https://discord.com/api/webhooks/*'. Got: $PRFWebhook"
    }

    # Resolve entity target (creates file/section/bullet as needed)
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Gracz' -EntityName $Name
    $Lines = $Target.Lines
    $ChildEnd = $Target.ChildrenEnd

    # Set requested tags
    if ($PSBoundParameters.ContainsKey('MargonemID')) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'margonemid' -Value $MargonemID
    }

    if ($PSBoundParameters.ContainsKey('PRFWebhook')) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'prfwebhook' -Value $PRFWebhook
    }

    if ($PSBoundParameters.ContainsKey('Triggers')) {
        # Remove all existing @trigger lines first
        $LinesToRemove = [System.Collections.Generic.List[int]]::new()
        for ($i = $Target.ChildrenStart; $i -lt $ChildEnd; $i++) {
            $TagMatch = $script:TagPattern.Match($Lines[$i])
            if ($TagMatch.Success -and $TagMatch.Groups[1].Value.Trim().ToLowerInvariant() -eq 'trigger') {
                $LinesToRemove.Add($i)
            }
        }

        # Remove in reverse order to preserve indices
        for ($k = $LinesToRemove.Count - 1; $k -ge 0; $k--) {
            $Lines.RemoveAt($LinesToRemove[$k])
            $ChildEnd--
        }

        # Add new triggers
        if ($Triggers) {
            foreach ($Trigger in $Triggers) {
                if (-not [string]::IsNullOrWhiteSpace($Trigger)) {
                    $Lines.Insert($ChildEnd, "    - @trigger: $($Trigger.Trim())")
                    $ChildEnd++
                }
            }
        }
    }

    if ($Aliases) {
        foreach ($Alias in $Aliases) {
            if (-not [string]::IsNullOrWhiteSpace($Alias)) {
                # Check if alias already exists (case-insensitive dedup)
                $ExistingAlias = $null
                for ($i = $Target.ChildrenStart; $i -lt $ChildEnd; $i++) {
                    $AliasMatch = $script:TagPattern.Match($Lines[$i])
                    if ($AliasMatch.Success -and $AliasMatch.Groups[1].Value.Trim().ToLowerInvariant() -eq 'alias') {
                        if ([string]::Equals($AliasMatch.Groups[2].Value.Trim(), $Alias, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $ExistingAlias = $i
                            break
                        }
                    }
                }
                if (-not $ExistingAlias) {
                    $Lines.Insert($ChildEnd, "    - @alias: $Alias")
                    $ChildEnd++
                }
            }
        }
    }

    # Write with ShouldProcess
    if ($PSCmdlet.ShouldProcess($Target.FilePath, "Set-Player: update '$Name'")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Lines -NL $Target.NL
    }
}

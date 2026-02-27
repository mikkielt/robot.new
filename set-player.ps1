<#
    .SYNOPSIS
    Updates player-level fields by writing to entities.md.

    .DESCRIPTION
    This file contains Set-Player which writes @prfwebhook, @margonemid,
    and @trigger tags to the player's entity entry in entities.md under
    the ## Gracz section.

    If the player has no entity entry yet, one is created.

    Validates Discord webhook URL format (must match
    https://discord.com/api/webhooks/*).

    Player renaming is not supported via entity overrides — entity names
    are identity keys.

    Dot-sources entity-writehelpers.ps1 for file manipulation.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source entity write helpers
. "$PSScriptRoot/entity-writehelpers.ps1"

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

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    if (-not $EntitiesFile) {
        $EntitiesFile = [System.IO.Path]::Combine($PSScriptRoot, 'entities.md')
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
        $ChildEnd = Set-EntityTag -Lines $Lines -BulletIdx $Target.BulletIdx -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'margonemid' -Value $MargonemID
    }

    if ($PSBoundParameters.ContainsKey('PRFWebhook')) {
        $ChildEnd = Set-EntityTag -Lines $Lines -BulletIdx $Target.BulletIdx -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'prfwebhook' -Value $PRFWebhook
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

    # Write with ShouldProcess
    if ($PSCmdlet.ShouldProcess($Target.FilePath, "Set-Player: update '$Name'")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Lines -NL $Target.NL
    }
}

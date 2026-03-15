<#
    .SYNOPSIS
    Updates player-level fields by writing to entities.md.

    .DESCRIPTION
    This file contains Set-Player which writes @prfwebhook, @margonemid,
    @trigger, and @alias tags to the player's entity entry in entities.md
    under the ## Gracz section.

    If the player has no entity entry yet, one is created via
    Resolve-EntityTarget, making Set-Player an upsert operation.

    Validates Discord webhook URL format (must match
    https://discord.com/api/webhooks/*).

    Aliases use append-with-dedup semantics (case-insensitive) — existing
    aliases with the same value are not duplicated, preventing entity
    index bloat. Triggers use replace-all semantics because the full set
    is always provided as a unit.

    Player renaming is not supported via entity overrides — entity names
    are identity keys used as foreign keys by @należy_do references.

    Dot-sources entity-writehelpers.ps1 (file I/O and tag manipulation).
    Supports -WhatIf via SupportsShouldProcess.
#>

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

        [Parameter(HelpMessage = "Entity status (Aktywny, Nieaktywny, Usunięty)")]
        [ValidateSet("Aktywny", "Nieaktywny", "Usunięty")]
        [string]$Status,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    if ($script:HasOpCtx) { Clear-OperationContext }

    if (-not $EntitiesFile) {
        . "$script:ModuleRoot/private/admin-config.ps1"
        $Config = Get-AdminConfig
        $EntitiesFile = $Config.EntitiesFile
    }

    # Fail-early before any file I/O to avoid partial writes
    if ($PRFWebhook -and $PRFWebhook -notlike "https://discord.com/api/webhooks/*") {
        throw "Invalid webhook URL format. Must match 'https://discord.com/api/webhooks/*'. Got: $PRFWebhook"
    }

    # Resolve-EntityTarget creates the section and bullet if absent,
    # enabling upsert semantics for entity-only players
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Gracz' -EntityName $Name
    $Lines = $Target.Lines
    $ChildEnd = $Target.ChildrenEnd

    if ($PSBoundParameters.ContainsKey('MargonemID')) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'margonemid' -Value $MargonemID
    }

    if ($PSBoundParameters.ContainsKey('PRFWebhook')) {
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'prfwebhook' -Value $PRFWebhook
    }

    if ($PSBoundParameters.ContainsKey('Triggers')) {
        # Replace-all: triggers are always provided as a complete set,
        # so existing entries must be removed before inserting the new set
        $LinesToRemove = [System.Collections.Generic.List[int]]::new()
        for ($i = $Target.ChildrenStart; $i -lt $ChildEnd; $i++) {
            $TagMatch = $script:TagPattern.Match($Lines[$i])
            if ($TagMatch.Success -and $TagMatch.Groups[1].Value.Trim().ToLowerInvariant() -eq 'trigger') {
                $LinesToRemove.Add($i)
            }
        }

        for ($k = $LinesToRemove.Count - 1; $k -ge 0; $k--) {
            $Lines.RemoveAt($LinesToRemove[$k])
            $ChildEnd--
        }

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
                # Append-with-dedup: aliases accumulate over time,
                # unlike triggers which are always provided as a full replacement
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

    if ($PSBoundParameters.ContainsKey('Status')) {
        $DateStr = (Get-Date).ToString('yyyy-MM')
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'status' -Value "$Status ($DateStr`:)"
    }

    if ($PSCmdlet.ShouldProcess($Target.FilePath, "Set-Player: update '$Name'")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Lines -NL $Target.NL

        if ($script:HasOpCtx) {
            return (New-OperationResult -Success $true -Action 'Update' `
                -TargetType 'Gracz' -TargetName $Name -UndoHint $null)
        }
    }
}

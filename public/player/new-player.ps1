<#
    .SYNOPSIS
    Creates a new player entry in entities.md with optional first character.

    .DESCRIPTION
    This file contains New-Player which creates a Gracz entity and optionally
    a first Postać character in a single operation.

    Processing pipeline:
    1. Validate Discord webhook URL format (fail-early before any writes).
    2. Check for duplicate player names (would corrupt entity index).
    3. Build ordered tag set: @margonemid, @prfwebhook, @trigger.
    4. Resolve target file and insertion point via Resolve-EntityTarget.
    5. Write player bullet under ## Gracz, fire AfterCreate plugin hook.
    6. Optionally delegate to New-PlayerCharacter for first character
       (reuses its template rendering, PU computation, charfile generation).
    7. Return composite result with player and character details.

    Helpers (dot-sourced):
    - entity-writehelpers.ps1: Read-EntityFile, Find-EntitySection,
      Find-EntityBullet, Write-EntityFile, Resolve-EntityTarget
    - admin-config.ps1: Get-AdminConfig (entities file path resolution)

    Integration points:
    - Invoke-PluginHook 'AfterCreate': notifies plugins after player entry creation
    - New-PlayerCharacter: delegation target for optional first character
    - New-OperationResult: returns structured result when operation context is active
    - SupportsShouldProcess: -WhatIf/-Confirm support (ConfirmImpact = Medium)
#>

. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function New-Player {
    <#
        .SYNOPSIS
        Creates a new player entry in entities.md and optionally their first character.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Player name")]
        [string]$Name,

        [Parameter(HelpMessage = "Margonem game profile ID")]
        [string]$MargonemID,

        [Parameter(HelpMessage = "Discord PRF webhook URL")]
        [string]$PRFWebhook,

        [Parameter(HelpMessage = "Trigger topics (restricted content)")]
        [string[]]$Triggers,

        [Parameter(HelpMessage = "First character name (creates character entry if provided)")]
        [string]$CharacterName,

        [Parameter(HelpMessage = "URL to the first character's sheet")]
        [string]$CharacterSheetUrl,

        [Parameter(HelpMessage = "Initial PU start value for the first character")]
        [Nullable[decimal]]$InitialPUStart,

        [Parameter(HelpMessage = "Skip creating the Postaci/Gracze/ character file")]
        [switch]$NoCharacterFile,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    # Resolve config and reset operation context for fresh warning collection
    $Config = Get-AdminConfig
    if ($script:HasOpCtx) { Clear-OperationContext }

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    # Discord webhook format is validated early to fail before any file writes
    if ($PRFWebhook -and $PRFWebhook -notlike "https://discord.com/api/webhooks/*") {
        throw "Invalid webhook URL format. Must match 'https://discord.com/api/webhooks/*'. Got: $PRFWebhook"
    }

    # Fail-early: duplicate player names would corrupt the entity index
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType 'Gracz'
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
        if ($ExistingBullet) {
            throw "Player '$Name' already exists in entities.md"
        }
    }

    # Build ordered tag set — only non-empty values are included
    $InitialTags = [ordered]@{}

    if (-not [string]::IsNullOrWhiteSpace($MargonemID)) {
        $InitialTags['margonemid'] = $MargonemID
    }

    if (-not [string]::IsNullOrWhiteSpace($PRFWebhook)) {
        $InitialTags['prfwebhook'] = $PRFWebhook
    }

    # Triggers are stored as array — multi-value tag rendered as nested bullets
    if ($Triggers -and $Triggers.Count -gt 0) {
        $CleanTriggers = [System.Collections.Generic.List[string]]::new()
        foreach ($Trigger in $Triggers) {
            if (-not [string]::IsNullOrWhiteSpace($Trigger)) {
                $CleanTriggers.Add($Trigger.Trim())
            }
        }
        if ($CleanTriggers.Count -gt 0) {
            $InitialTags['trigger'] = $CleanTriggers.ToArray()
        }
    }

    # Resolve-EntityTarget determines the target file (entities.md or overflow)
    # and prepares the line array with the new bullet inserted
    $PlayerTarget = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Gracz' -EntityName $Name -InitialTags $InitialTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-Player: create player entry '$Name'")) {
        Write-EntityFile -Path $PlayerTarget.FilePath -Lines $PlayerTarget.Lines -NL $PlayerTarget.NL

        # Notify plugins after successful creation (e.g. API cache invalidation)
        if (Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue) {
            Invoke-PluginHook -Operation 'New-Player' -Phase 'AfterCreate' -Context @{
                Operation = 'New-Player'
                Name      = $Name
            }
        }
    }

    # Delegate to New-PlayerCharacter so character creation reuses its
    # template rendering, PU computation, and charfile generation
    $CharacterResult = $null
    if (-not [string]::IsNullOrWhiteSpace($CharacterName)) {
        $CharParams = @{
            PlayerName = $Name
            CharacterName = $CharacterName
            EntitiesFile = $EntitiesFile
        }

        if (-not [string]::IsNullOrWhiteSpace($CharacterSheetUrl)) {
            $CharParams['CharacterSheetUrl'] = $CharacterSheetUrl
        }

        if ($null -ne $InitialPUStart) {
            $CharParams['InitialPUStart'] = $InitialPUStart
        }

        if ($NoCharacterFile) {
            $CharParams['NoCharacterFile'] = $true
        }

        $CharacterResult = New-PlayerCharacter @CharParams
    }

    # Composite result includes both player and optional character details
    $ReturnObj = [PSCustomObject]@{
        PlayerName    = $Name
        MargonemID    = $MargonemID
        PRFWebhook    = $PRFWebhook
        Triggers      = $Triggers
        EntitiesFile  = $EntitiesFile
        CharacterName = if ($CharacterResult) { $CharacterResult.CharacterName } else { $null }
        CharacterFile = if ($CharacterResult) { $CharacterResult.CharacterFile } else { $null }
    }

    # Attach OperationResult for CLI undo tracking when operation context is active
    if ($script:HasOpCtx) {
        $OpResult = New-OperationResult -Success $true -Action 'Create' `
            -TargetType 'Gracz' -TargetName $Name -UndoHint "Remove-Entity -Name '$Name' -Type 'Gracz'"
        $ReturnObj | Add-Member -NotePropertyName 'OperationResult' -NotePropertyValue $OpResult
    }

    return $ReturnObj
}

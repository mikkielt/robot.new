<#
    .SYNOPSIS
    Creates a new player entry in entities.md with optional first character.

    .DESCRIPTION
    This file contains New-Player which:
    1. Creates an entity entry under ## Gracz with @margonemid, @prfwebhook,
       and @trigger tags in entities.md.
    2. Validates that the player does not already exist (throws if found).
    3. Validates Discord webhook URL format.
    4. Optionally creates a first character by delegating to New-PlayerCharacter.

    Dot-sources entity-writehelpers.ps1 and admin-config.ps1 for file
    manipulation and config resolution.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
. "$PSScriptRoot/entity-writehelpers.ps1"
. "$PSScriptRoot/admin-config.ps1"

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

    $Config = Get-AdminConfig

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    # Validate webhook URL format
    if ($PRFWebhook -and $PRFWebhook -notlike "https://discord.com/api/webhooks/*") {
        throw "Invalid webhook URL format. Must match 'https://discord.com/api/webhooks/*'. Got: $PRFWebhook"
    }

    # Check that the player does not already exist
    $EntitiesFilePath = Ensure-EntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType 'Gracz'
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Name
        if ($ExistingBullet) {
            throw "Player '$Name' already exists in entities.md"
        }
    }

    # Build initial tags
    $InitialTags = [ordered]@{}

    if (-not [string]::IsNullOrWhiteSpace($MargonemID)) {
        $InitialTags['margonemid'] = $MargonemID
    }

    if (-not [string]::IsNullOrWhiteSpace($PRFWebhook)) {
        $InitialTags['prfwebhook'] = $PRFWebhook
    }

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

    # Create player entity
    $PlayerTarget = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Gracz' -EntityName $Name -InitialTags $InitialTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-Player: create player entry '$Name'")) {
        Write-EntityFile -Path $PlayerTarget.FilePath -Lines $PlayerTarget.Lines -NL $PlayerTarget.NL
    }

    # Optionally create first character
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

    # Return summary object
    return [PSCustomObject]@{
        PlayerName    = $Name
        MargonemID    = $MargonemID
        PRFWebhook    = $PRFWebhook
        Triggers      = $Triggers
        EntitiesFile  = $EntitiesFile
        CharacterName = if ($CharacterResult) { $CharacterResult.CharacterName } else { $null }
        CharacterFile = if ($CharacterResult) { $CharacterResult.CharacterFile } else { $null }
    }
}

<#
    .SYNOPSIS
    Creates a new character entry for an existing or new player.

    .DESCRIPTION
    This file contains New-PlayerCharacter which:
    1. Creates an entity entry under ## Postać with @należy_do and
       @pu_startowe tags in entities.md.
    2. If the player has no entity entry yet, also creates one under ## Gracz.
    3. Optionally creates the character's Markdown file in Postaci/Gracze/
       from the player-character-file.md.template.
    4. Optionally applies initial character file property values (Condition,
       SpecialItems, Reputation, AdditionalNotes) via charfile-helpers.ps1.

    Dot-sources entity-writehelpers.ps1, admin-config.ps1, and charfile-helpers.ps1.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"
. "$script:ModuleRoot/private/charfile-helpers.ps1"

function New-PlayerCharacter {
    <#
        .SYNOPSIS
        Creates a new character entry in entities.md and optionally its file in Postaci/Gracze/.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Player name who owns the character")]
        [string]$PlayerName,

        [Parameter(Mandatory, HelpMessage = "New character name")]
        [string]$CharacterName,

        [Parameter(HelpMessage = "URL to the character sheet")]
        [string]$CharacterSheetUrl,

        [Parameter(HelpMessage = "Initial PU start value (computed from Get-NewPlayerCharacterPUCount if omitted)")]
        [Nullable[decimal]]$InitialPUStart,

        [Parameter(HelpMessage = "Skip creating the Postaci/Gracze/ character file")]
        [switch]$NoCharacterFile,

        [Parameter(HelpMessage = "Character condition (defaults to 'Zdrowy.')")]
        [string]$Condition,

        [Parameter(HelpMessage = "Initial special items")]
        [string[]]$SpecialItems,

        [Parameter(HelpMessage = "Initial positive reputation entries")]
        [PSCustomObject[]]$ReputationPositive,

        [Parameter(HelpMessage = "Initial neutral reputation entries")]
        [PSCustomObject[]]$ReputationNeutral,

        [Parameter(HelpMessage = "Initial negative reputation entries")]
        [PSCustomObject[]]$ReputationNegative,

        [Parameter(HelpMessage = "Initial additional notes entries")]
        [string[]]$AdditionalNotes,

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile
    )

    $Config = Get-AdminConfig

    if (-not $EntitiesFile) {
        $EntitiesFile = $Config.EntitiesFile
    }

    # Determine initial PU
    $PUStartValue = if ($null -ne $InitialPUStart) {
        $InitialPUStart
    } else {
        # Try to compute via Get-NewPlayerCharacterPUCount if available
        try {
            $Computed = Get-NewPlayerCharacterPUCount -PlayerName $PlayerName
            $Computed
        } catch {
            # Function not yet available (Phase 2) - default to 20
            [decimal]20
        }
    }

    $PUStartStr = $PUStartValue.ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)

    # Check if character already exists
    $EntitiesFilePath = Invoke-EnsureEntityFile -Path $EntitiesFile
    $File = Read-EntityFile -Path $EntitiesFilePath
    $Section = Find-EntitySection -Lines $File.Lines.ToArray() -EntityType 'Postać'
    if ($Section) {
        $ExistingBullet = Find-EntityBullet -Lines $File.Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $CharacterName
        if ($ExistingBullet) {
            throw "Character '$CharacterName' already exists in entities.md"
        }
    }

    # Ensure player entry exists under ## Gracz
    $PlayerTarget = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Gracz' -EntityName $PlayerName

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-PlayerCharacter: create player entry '$PlayerName' (if new)")) {
        if ($PlayerTarget.Created) {
            Write-EntityFile -Path $PlayerTarget.FilePath -Lines $PlayerTarget.Lines -NL $PlayerTarget.NL
        }
    }

    # Create character entry under ## Postać
    $InitialTags = [ordered]@{
        'należy_do'  = $PlayerName
        'pu_startowe' = $PUStartStr
    }

    $CharTarget = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Postać' -EntityName $CharacterName -InitialTags $InitialTags

    if ($PSCmdlet.ShouldProcess($EntitiesFile, "New-PlayerCharacter: create character entry '$CharacterName' (owner: $PlayerName, PU start: $PUStartStr)")) {
        Write-EntityFile -Path $CharTarget.FilePath -Lines $CharTarget.Lines -NL $CharTarget.NL
    }

    # Create character file in Postaci/Gracze/
    if (-not $NoCharacterFile) {
        $CharFilePath = [System.IO.Path]::Combine($Config.CharactersDir, "$CharacterName.md")

        if ([System.IO.File]::Exists($CharFilePath)) {
            [System.Console]::Error.WriteLine("[WARN New-PlayerCharacter] Character file already exists: $CharFilePath")
        } else {
            $TemplateVars = @{
                CharacterSheetUrl = if ($CharacterSheetUrl) { $CharacterSheetUrl } else { '<TU_WKLEJAMY_LINK>' }
                Triggers          = 'brak'
                AdditionalInfo    = '- Brak.'
            }

            $FileContent = Get-AdminTemplate -Name 'player-character-file.md.template' -Variables $TemplateVars

            if ($PSCmdlet.ShouldProcess($CharFilePath, "New-PlayerCharacter: create character file")) {
                # Ensure directory exists
                $Dir = [System.IO.Path]::GetDirectoryName($CharFilePath)
                if (-not [System.IO.Directory]::Exists($Dir)) {
                    [void][System.IO.Directory]::CreateDirectory($Dir)
                }

                $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($CharFilePath, $FileContent, $UTF8NoBOM)
            }
        }
    }

    # Apply initial character file property values if specified
    if (-not $NoCharacterFile -and $CharFilePath -and [System.IO.File]::Exists($CharFilePath)) {
        $HasInitialProps = (
            $PSBoundParameters.ContainsKey('Condition') -or
            $PSBoundParameters.ContainsKey('SpecialItems') -or
            $PSBoundParameters.ContainsKey('ReputationPositive') -or
            $PSBoundParameters.ContainsKey('ReputationNeutral') -or
            $PSBoundParameters.ContainsKey('ReputationNegative') -or
            $PSBoundParameters.ContainsKey('AdditionalNotes')
        )

        if ($HasInitialProps) {
            $CharFileData = Read-CharacterFile -Path $CharFilePath
            $CharLines = [System.Collections.Generic.List[string]]::new($CharFileData.Lines)

            if ($PSBoundParameters.ContainsKey('Condition')) {
                $Content = if ([string]::IsNullOrWhiteSpace($Condition)) { @('Zdrowy.') } else { @($Condition) }
                Write-CharacterFileSection -Lines $CharLines -SectionName 'Stan' -NewContent $Content
            }

            if ($PSBoundParameters.ContainsKey('SpecialItems')) {
                $Content = if (-not $SpecialItems -or $SpecialItems.Count -eq 0) {
                    @('Brak.')
                } else {
                    $SpecialItems | ForEach-Object { "- $_" }
                }
                Write-CharacterFileSection -Lines $CharLines -SectionName 'Przedmioty specjalne' -NewContent $Content
            }

            if ($PSBoundParameters.ContainsKey('ReputationPositive') -or
                $PSBoundParameters.ContainsKey('ReputationNeutral') -or
                $PSBoundParameters.ContainsKey('ReputationNegative')) {
                $EffPos = if ($PSBoundParameters.ContainsKey('ReputationPositive')) { $ReputationPositive } else { @() }
                $EffNeu = if ($PSBoundParameters.ContainsKey('ReputationNeutral'))  { $ReputationNeutral }  else { $CharFileData.Reputation.Neutral }
                $EffNeg = if ($PSBoundParameters.ContainsKey('ReputationNegative')) { $ReputationNegative } else { @() }
                $RepLines = Format-ReputationSection -Positive $EffPos -Neutral $EffNeu -Negative $EffNeg
                Write-CharacterFileSection -Lines $CharLines -SectionName 'Reputacja' -NewContent $RepLines
            }

            if ($PSBoundParameters.ContainsKey('AdditionalNotes')) {
                $Content = if (-not $AdditionalNotes -or $AdditionalNotes.Count -eq 0) {
                    @('- Brak.')
                } else {
                    $AdditionalNotes | ForEach-Object { "- $_" }
                }
                Write-CharacterFileSection -Lines $CharLines -SectionName 'Dodatkowe informacje' -NewContent $Content
            }

            if ($PSCmdlet.ShouldProcess($CharFilePath, "New-PlayerCharacter: apply initial properties to character file")) {
                $CharContent = [string]::Join($CharFileData.NL, $CharLines)
                $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($CharFilePath, $CharContent, $UTF8NoBOM)
            }
        }
    }

    # Return summary object
    return [PSCustomObject]@{
        PlayerName    = $PlayerName
        CharacterName = $CharacterName
        PUStart       = $PUStartValue
        EntitiesFile  = $EntitiesFile
        CharacterFile = if (-not $NoCharacterFile) { $CharFilePath } else { $null }
        PlayerCreated = $PlayerTarget.Created
    }
}

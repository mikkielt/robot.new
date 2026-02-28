<#
    .SYNOPSIS
    Updates character PU values, metadata, and character file properties.

    .DESCRIPTION
    This file contains Set-PlayerCharacter which performs dual-target writes:

    Target 1 - entities.md:
      @pu_startowe, @pu_nadmiar, @pu_suma, @pu_zdobyte, @alias, @status tags
      under ## Postać. Auto-creates Przedmiot entities for unknown items.

    Target 2 - Postaci/Gracze/<Name>.md:
      CharacterSheet, RestrictedTopics, Condition, SpecialItems,
      Reputation (Positive/Neutral/Negative), AdditionalNotes sections.

    If the character has no entity entry yet, one is created with
    @należy_do: <PlayerName>.

    Uses Complete-PUData derivation rule (from get-player.ps1):
    - If SUMA present and ZDOBYTE missing -> derive ZDOBYTE = SUMA - STARTOWE
    - If ZDOBYTE present and SUMA missing -> derive SUMA = STARTOWE + ZDOBYTE

    Dot-sources entity-writehelpers.ps1 and charfile-helpers.ps1.
    Supports -WhatIf via SupportsShouldProcess.
#>

# Dot-source helpers
. "$script:ModuleRoot/private/entity-writehelpers.ps1"
. "$script:ModuleRoot/private/charfile-helpers.ps1"

function Set-PlayerCharacter {
    <#
        .SYNOPSIS
        Updates character PU values, metadata in entities.md, and character file properties.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')] param(
        [Parameter(Mandatory, HelpMessage = "Player name who owns the character")]
        [string]$PlayerName,

        [Parameter(Mandatory, HelpMessage = "Character name to update")]
        [string]$CharacterName,

        # Entity-level properties (write to entities.md)

        [Parameter(HelpMessage = "PU overflow value (NADMIAR)")]
        [Nullable[decimal]]$PUExceeded,

        [Parameter(HelpMessage = "PU starting value (STARTOWE)")]
        [Nullable[decimal]]$PUStart,

        [Parameter(HelpMessage = "PU total sum (SUMA)")]
        [Nullable[decimal]]$PUSum,

        [Parameter(HelpMessage = "PU taken/earned value (ZDOBYTE)")]
        [Nullable[decimal]]$PUTaken,

        [Parameter(HelpMessage = "Character aliases to set")]
        [string[]]$Aliases,

        [Parameter(HelpMessage = "Entity status (Aktywny, Nieaktywny, Usunięty)")]
        [ValidateSet("Aktywny", "Nieaktywny", "Usunięty")]
        [string]$Status,

        # --- Character file properties (write to .md file) ---

        [Parameter(HelpMessage = "Character sheet URL")]
        [string]$CharacterSheet,

        [Parameter(HelpMessage = "Restricted topics")]
        [string]$RestrictedTopics,

        [Parameter(HelpMessage = "Character condition (freeform text)")]
        [string]$Condition,

        [Parameter(HelpMessage = "Special items list (replaces entire section)")]
        [string[]]$SpecialItems,

        [Parameter(HelpMessage = "Positive reputation entries")]
        [PSCustomObject[]]$ReputationPositive,

        [Parameter(HelpMessage = "Neutral reputation entries")]
        [PSCustomObject[]]$ReputationNeutral,

        [Parameter(HelpMessage = "Negative reputation entries")]
        [PSCustomObject[]]$ReputationNegative,

        [Parameter(HelpMessage = "Additional notes entries")]
        [string[]]$AdditionalNotes,

        # Paths

        [Parameter(HelpMessage = "Path to entities.md file")]
        [string]$EntitiesFile,

        [Parameter(HelpMessage = "Path to character .md file (auto-resolved if omitted)")]
        [string]$CharacterFile
    )

    if (-not $EntitiesFile) {
        $EntitiesFile = [System.IO.Path]::Combine($PSScriptRoot, 'entities.md')
    }

    # Target 1: entities.md

    # Derive missing PU values using the same rule as Complete-PUData
    $DerivedPUStart = $PUStart
    $DerivedPUSum = $PUSum
    $DerivedPUTaken = $PUTaken

    if ($null -ne $DerivedPUSum -and $null -eq $DerivedPUTaken -and $null -ne $DerivedPUStart) {
        $DerivedPUTaken = [math]::Round($DerivedPUSum - $DerivedPUStart, 2)
    }
    if ($null -ne $DerivedPUTaken -and $null -eq $DerivedPUSum -and $null -ne $DerivedPUStart) {
        $DerivedPUSum = [math]::Round($DerivedPUStart + $DerivedPUTaken, 2)
    }

    # Build initial tags for new entity creation
    $InitialTags = [ordered]@{
        'należy_do' = $PlayerName
    }

    # Resolve entity target (creates file/section/bullet as needed)
    $Target = Resolve-EntityTarget -FilePath $EntitiesFile -EntityType 'Postać' -EntityName $CharacterName -InitialTags $InitialTags
    $Lines = $Target.Lines

    # Set requested tags
    $ChildEnd = $Target.ChildrenEnd

    # Ensure @należy_do exists even for pre-existing entries
    if ($Target.Created -eq $false) {
        $OwnerTag = Find-EntityTag -Lines $Lines.ToArray() -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'należy_do'
        if (-not $OwnerTag) {
            $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'należy_do' -Value $PlayerName
        }
    }

    if ($PSBoundParameters.ContainsKey('PUStart') -and $null -ne $DerivedPUStart) {
        $Val = $DerivedPUStart.ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'pu_startowe' -Value $Val
    }

    if ($PSBoundParameters.ContainsKey('PUExceeded') -and $null -ne $PUExceeded) {
        $Val = $PUExceeded.ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'pu_nadmiar' -Value $Val
    }

    if (($PSBoundParameters.ContainsKey('PUSum') -or $null -ne $DerivedPUSum) -and $null -ne $DerivedPUSum) {
        $Val = $DerivedPUSum.ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'pu_suma' -Value $Val
    }

    if (($PSBoundParameters.ContainsKey('PUTaken') -or $null -ne $DerivedPUTaken) -and $null -ne $DerivedPUTaken) {
        $Val = $DerivedPUTaken.ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
        $ChildEnd = Set-EntityTag -Lines $Lines -ChildrenStart $Target.ChildrenStart -ChildrenEnd $ChildEnd -TagName 'pu_zdobyte' -Value $Val
    }

    if ($Aliases) {
        foreach ($Alias in $Aliases) {
            if (-not [string]::IsNullOrWhiteSpace($Alias)) {
                # Check if alias already exists
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

    # Write entities.md with ShouldProcess
    if ($PSCmdlet.ShouldProcess($Target.FilePath, "Set-PlayerCharacter: update '$CharacterName' entity (owner: $PlayerName)")) {
        Write-EntityFile -Path $Target.FilePath -Lines $Lines -NL $Target.NL
    }

    # Auto-create Przedmiot entities for unknown items
    if ($SpecialItems) {
        foreach ($ItemName in $SpecialItems) {
            if ([string]::IsNullOrWhiteSpace($ItemName)) { continue }
            # Check if item already exists as a Przedmiot entity
            $EntFile = Read-EntityFile -Path $Target.FilePath
            $ItemSection = Find-EntitySection -Lines $EntFile.Lines.ToArray() -EntityType 'Przedmiot'
            $ItemExists = $false
            if ($ItemSection) {
                $ItemBullet = Find-EntityBullet -Lines $EntFile.Lines.ToArray() -SectionStart $ItemSection.StartIdx -SectionEnd $ItemSection.EndIdx -EntityName $ItemName
                if ($ItemBullet) { $ItemExists = $true }
            }
            if (-not $ItemExists) {
                if ($PSCmdlet.ShouldProcess($Target.FilePath, "Set-PlayerCharacter: auto-create Przedmiot entity '$ItemName'")) {
                    [void](Resolve-EntityTarget -FilePath $Target.FilePath `
                        -EntityType 'Przedmiot' -EntityName $ItemName `
                        -InitialTags ([ordered]@{ 'należy_do' = $CharacterName }))
                    # Re-read after modification for next iteration
                }
            }
        }
    }

    # Target 2: Character file (Postaci/Gracze/<Name>.md)

    $HasCharFileChanges = (
        $PSBoundParameters.ContainsKey('CharacterSheet') -or
        $PSBoundParameters.ContainsKey('RestrictedTopics') -or
        $PSBoundParameters.ContainsKey('Condition') -or
        $PSBoundParameters.ContainsKey('SpecialItems') -or
        $PSBoundParameters.ContainsKey('ReputationPositive') -or
        $PSBoundParameters.ContainsKey('ReputationNeutral') -or
        $PSBoundParameters.ContainsKey('ReputationNegative') -or
        $PSBoundParameters.ContainsKey('AdditionalNotes')
    )

    if ($HasCharFileChanges) {
        # Resolve character file path
        if (-not $CharacterFile) {
            $Character = Get-PlayerCharacter -PlayerName $PlayerName -CharacterName $CharacterName
            if ($Character -and $Character.Path) {
                $CharacterFile = [System.IO.Path]::Combine((Get-RepoRoot), $Character.Path)
            } else {
                . "$script:ModuleRoot/private/admin-config.ps1"
                $Config = Get-AdminConfig
                $CharacterFile = [System.IO.Path]::Combine($Config.CharactersDir, "$CharacterName.md")
            }
        }

        if (-not [System.IO.File]::Exists($CharacterFile)) {
            [System.Console]::Error.WriteLine("[WARN Set-PlayerCharacter] Character file not found: $CharacterFile")
            return
        }

        $CharData = Read-CharacterFile -Path $CharacterFile
        $CharLines = [System.Collections.Generic.List[string]]::new($CharData.Lines)

        if ($PSBoundParameters.ContainsKey('CharacterSheet')) {
            Write-CharacterFileSection -Lines $CharLines -SectionName 'Karta Postaci' -InlineValue $CharacterSheet
        }

        if ($PSBoundParameters.ContainsKey('RestrictedTopics')) {
            $Content = if ([string]::IsNullOrWhiteSpace($RestrictedTopics)) { @('Brak.') } else { @($RestrictedTopics) }
            Write-CharacterFileSection -Lines $CharLines -SectionName 'Tematy zastrzeżone' -NewContent $Content
        }

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
            # Partial update: read existing reputation for unspecified tiers
            $ExistingRep = (Read-CharacterFile -Path $CharacterFile).Reputation
            $EffPos = if ($PSBoundParameters.ContainsKey('ReputationPositive')) { $ReputationPositive } else { $ExistingRep.Positive }
            $EffNeu = if ($PSBoundParameters.ContainsKey('ReputationNeutral'))  { $ReputationNeutral }  else { $ExistingRep.Neutral }
            $EffNeg = if ($PSBoundParameters.ContainsKey('ReputationNegative')) { $ReputationNegative } else { $ExistingRep.Negative }
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

        # Write character file with ShouldProcess
        if ($PSCmdlet.ShouldProcess($CharacterFile, "Set-PlayerCharacter: update character file '$CharacterName'")) {
            $CharContent = [string]::Join($CharData.NL, $CharLines)
            $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($CharacterFile, $CharContent, $UTF8NoBOM)
        }
    }
}

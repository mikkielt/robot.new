<#
    .SYNOPSIS
    Parses the player database (Gracze.md) into structured player objects with characters,
    PU data, metadata, and entity-based overrides.

    .DESCRIPTION
    This file contains Get-Player and its helper:

    Helpers:
    - Complete-PUData: derives missing PU SUMA/ZDOBYTE from the complementary value
      when only one of the pair is present (SUMA = STARTOWE + ZDOBYTE, or inverse)

    Get-Player reads the Gracze.md file and extracts structured information for each player
    listed under the "## Lista" section:
    - Character entries with names, file paths, aliases, and additional notes
    - PU (Player Unit) values: NADMIAR, STARTOWE, SUMA, ZDOBYTE
    - Triggers (restricted topics), Discord webhook, Margonem game ID
    - A consolidated name index for lookup (player name + character names + aliases)

    After parsing Gracze.md, the function applies overrides from entities.md. Entity entries
    of type "Gracz" or "Postac (Gracz)", or with an @owner tag, are matched to existing
    players (or create new player stubs). This allows the entity registry to extend player
    data without modifying Gracze.md directly - useful for aliases, PU values, triggers,
    and additional character metadata.

    The two-phase approach (Gracze.md parse + entity overlay) preserves backward
    compatibility with the legacy player database while enabling new players and
    characters to be registered entirely through entities.md.
#>

# Gracze.md and entity overrides often carry only one of SUMA/ZDOBYTE;
# derive the missing half so downstream consumers always see both.
function Complete-PUData {
    param([object]$Character)

    if ($null -ne $Character.PUSum -and $null -eq $Character.PUTaken -and $null -ne $Character.PUStart) {
        $Character.PUTaken = [math]::Round($Character.PUSum - $Character.PUStart, 2)
    }
    if ($null -ne $Character.PUTaken -and $null -eq $Character.PUSum -and $null -ne $Character.PUStart) {
        $Character.PUSum = [math]::Round($Character.PUStart + $Character.PUTaken, 2)
    }
}

function Get-Player {
    <#
        .SYNOPSIS
        Parses Gracze.md and returns structured player objects with characters, PU data, and metadata.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Player name(s) to filter by")]
        [string[]]$Name,

        [Parameter(HelpMessage = "Path to Gracze.md")]
        [string]$File = "$(Get-RepoRoot)/Gracze.md",

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity to avoid redundant parsing")]
        [object[]]$Entities
    )

    # Map between Polish PU field names in Gracze.md and property names on the output object
    $PUInfoMap = @{
        "NADMIAR"  = "PUExceeded"
        "STARTOWE" = "PUStart"
        "SUMA"     = "PUSum"
        "ZDOBYTE"  = "PUTaken"
    }

    $Players = [System.Collections.Generic.List[object]]::new()
    $Markdown = Get-Markdown -File $File

    # Gracze.md uses "## Lista" > "### PlayerName" structure; other H2 sections
    # (e.g. "## Archiwum") are intentionally excluded
    foreach ($Section in $Markdown.Sections.Where({ $_.Header.Level -eq 3 -and $_.Header.ParentHeader.Text -eq "Lista" })) {
        $PlayerName = $Section.Header.Text

        if ($Name -and $Name -notcontains $PlayerName) {
            continue
        }

        # Build parent->children lookup in one pass (avoids O(n²) repeated .Where() filtering)
        $ChildrenOf = @{}
        $RootChildren = [System.Collections.Generic.List[object]]::new()
        foreach ($LI in $Section.Lists) {
            if ($null -eq $LI.ParentListItem) {
                $RootChildren.Add($LI)
            } else {
                $ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI.ParentListItem)
                if (-not $ChildrenOf.ContainsKey($ParentId)) {
                    $ChildrenOf[$ParentId] = [System.Collections.Generic.List[object]]::new()
                }
                $ChildrenOf[$ParentId].Add($LI)
            }
        }

        $MargonemId = $null
        $PRFWebhook = $null
        $Triggers = @()
        $PostaciEntry = $null

        foreach ($RootItem in $RootChildren) {
            if ($RootItem.Text.StartsWith("ID Margonem")) {
                $MargonemId = $RootItem.Text.Split(":")[1].Trim()
            }
            elseif ($RootItem.Text.StartsWith("PRFWebhook")) {
                $RawWebhook = $RootItem.Text.Split("PRFWebhook:")[1].Trim()
                $PRFWebhook = if ($RawWebhook -like "https://discord.com/api/webhooks/*") { $RawWebhook } else { $null }
            }
            elseif ($RootItem.Text.StartsWith("Tematy zastrzeżone")) {
                $TriggerRaw = $RootItem.Text.Split(":")[1].Trim()
                if ($TriggerRaw -and $TriggerRaw -ne "brak") {
                    $Triggers = $TriggerRaw.Split(",").Trim()
                }
            }
            elseif ($RootItem.Text.StartsWith("Postaci")) {
                $PostaciEntry = $RootItem
            }
        }

        # Characters are nested under the "Postaci:" list item as [Name](Path) links;
        # bold (**) markers indicate the currently active character
        $Characters = [System.Collections.Generic.List[object]]::new()
        if ($PostaciEntry) {
            $PostaciId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($PostaciEntry)
            $PostaciChildren = if ($ChildrenOf.ContainsKey($PostaciId)) { $ChildrenOf[$PostaciId] } else { @() }

            foreach ($CharacterListItem in $PostaciChildren) {
                if ($CharacterListItem.Text -notmatch '\[.+\]\(.+\)') { continue }

                $CleanText = $CharacterListItem.Text.Replace("**", "")

                $CharacterName = [regex]::Match($CleanText, '\[(.+?)\]').Groups[1].Value
                $CharacterPath = [regex]::Match($CleanText, '\((.+?)\)').Groups[1].Value

                $IsActive = $CharacterListItem.Text.StartsWith("**")

                $CharId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($CharacterListItem)
                $CharChildren = if ($ChildrenOf.ContainsKey($CharId)) { $ChildrenOf[$CharId] } else { @() }

                $Aliases = @()
                $PUEntry = $null
                $AdditionalInfoParts = [System.Collections.Generic.List[string]]::new()

                foreach ($ChildItem in $CharChildren) {
                    if ($ChildItem.Text.StartsWith("Alias")) {
                        $Aliases = $ChildItem.Text.Split(":")[1].Split(",").Split(";").ForEach({ $_.Trim() }).Where({ $_ -ne "" })
                    }
                    elseif ($ChildItem.Text.StartsWith("PU:")) {
                        $PUEntry = $ChildItem
                    }
                    else {
                        $AdditionalInfoParts.Add($ChildItem.Text)
                    }
                }

                $Character = [PSCustomObject]@{
                    Name           = $CharacterName
                    IsActive       = $IsActive
                    Aliases        = $Aliases
                    Path           = $CharacterPath
                    PUExceeded     = $null
                    PUStart        = $null
                    PUSum          = $null
                    PUTaken        = $null
                    AdditionalInfo = $AdditionalInfoParts
                }

                if ($PUEntry) {
                    $PURaw = $PUEntry.Text.Replace("PU:", "").Trim()
                    $PUParts = $PURaw.Split(",").ForEach({ $_.Trim() })

                    foreach ($PUPart in $PUParts) {
                        $SplitParts = $PUPart.Split(":")
                        $PartKey = $SplitParts[0].Trim()
                        if ($SplitParts.Length -lt 2) { continue }
                        $PartValue = $SplitParts[1].Trim()

                        $PropertyName = $PUInfoMap[$PartKey]
                        if (-not $PropertyName) { continue }

                        # "BRAK" is a sentinel in Gracze.md for explicitly absent values
                        $Character.$PropertyName = if ($PartValue -eq "BRAK") {
                            $null
                        } else {
                            try {
                                $NormalizedValue = $PartValue.Replace(",", ".")
                                [math]::Round([decimal]::Parse($NormalizedValue, [System.Globalization.CultureInfo]::InvariantCulture), 2)
                            } catch { $null }
                        }
                    }

                    Complete-PUData -Character $Character
                }

                $Characters.Add($Character)
            }
        }

        # Name resolution (Resolve-Name) needs a flat set of all names that
        # identify this player, including character names and aliases
        $Names = [System.Collections.Generic.List[string]]::new()
        $Names.Add($PlayerName)
        foreach ($Character in $Characters) {
            $Names.Add($Character.Name)
            foreach ($Alias in $Character.Aliases) {
                $Names.Add($Alias)
            }
        }

        # HashSet provides O(1) Contains() for name resolution lookups
        $Names = [System.Collections.Generic.HashSet[string]]::new($Names, [System.StringComparer]::OrdinalIgnoreCase)

        # Player object aggregates Gracze.md metadata; entity overlay (Phase 2)
        # may extend it further with aliases, PU overrides, or new characters
        $Player = [PSCustomObject]@{
            Name       = $PlayerName
            Names      = $Names
            MargonemID = $MargonemId
            PRFWebhook = $PRFWebhook
            Triggers   = $Triggers
            Characters = $Characters
        }

        $Players.Add($Player)
    }

    # Phase 2: overlay entity data so players/characters registered only
    # in entities.md also appear, preserving backward compatibility with
    # the legacy Gracze.md database while allowing entities.md to be the
    # sole source of truth for new registrations
    if (-not $Entities) {
        $Entities = Get-Entity
    }
    # TypeHistory check catches entities reclassified away from Gracz/Postać
    $OverrideEntities = $Entities.Where({
        $_.Type -in @('Gracz', 'Postać') -or
        $_.TypeHistory.Where({ $_.Type -in @('Gracz', 'Postać') }).Count -gt 0
    })

    foreach ($Entity in $OverrideEntities) {
        # Characters reference their player via @należy_do (Owner); Gracz entities
        # are their own player. Orphaned characters without either are skipped.
        $TargetPlayerName = if ($Entity.Owner) { $Entity.Owner } elseif ($Entity.Type -eq 'Gracz') { $Entity.Name } else { $null }
        if (-not $TargetPlayerName) { continue }  # orphaned character entity, skip

        $TargetPlayer = $null
        foreach ($ExistingPlayer in $Players) {
            if ([string]::Equals($ExistingPlayer.Name, $TargetPlayerName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TargetPlayer = $ExistingPlayer
                break
            }
        }

        # Entity-only players (not in Gracze.md) get a minimal stub so
        # downstream code can treat all players uniformly
        $IsNewPlayer = $null -eq $TargetPlayer
        if ($IsNewPlayer) {
            $TargetPlayer = [PSCustomObject]@{
                Name       = $TargetPlayerName
                Names      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                MargonemID = $null
                PRFWebhook = $null
                Triggers   = @()
                Characters = [System.Collections.Generic.List[object]]::new()
            }
            [void]$TargetPlayer.Names.Add($TargetPlayerName)
            $Players.Add($TargetPlayer)
        }

        # Gracz entities carry player-level metadata; Postać entities carry character data
        if ($Entity.Type -eq 'Gracz') {
            foreach ($Alias in $Entity.Aliases.Text) { [void]$TargetPlayer.Names.Add($Alias) }

            if ($Entity.Overrides.ContainsKey("margonemid")) {
                $TargetPlayer.MargonemID = $Entity.Overrides["margonemid"][-1]
            }
            if ($Entity.Overrides.ContainsKey("prfwebhook")) {
                $RawWebhook = $Entity.Overrides["prfwebhook"][-1]
                if ($RawWebhook -like "https://discord.com/api/webhooks/*") { $TargetPlayer.PRFWebhook = $RawWebhook }
            }
            if ($Entity.Overrides.ContainsKey("trigger")) {
                $TargetPlayer.Triggers = @($Entity.Overrides["trigger"])
            }
            continue  # Gracz entities carry player-level data only
        }

        # Character-level: match by name or create a stub for entity-only characters
        $TargetChar = $null
        foreach ($ExistingChar in $TargetPlayer.Characters) {
            if ([string]::Equals($ExistingChar.Name, $Entity.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TargetChar = $ExistingChar
                break
            }
        }
        $IsNewChar = $null -eq $TargetChar

        if ($IsNewChar) {
            $TargetChar = [PSCustomObject]@{
                Name           = $Entity.Name
                IsActive       = $false
                Aliases        = [System.Collections.Generic.List[string]]::new()
                Path           = if ($Entity.FilePath) { $Entity.FilePath } else { "" }
                PUExceeded     = $null
                PUStart        = $null
                PUSum          = $null
                PUTaken        = $null
                AdditionalInfo = ""
            }
            $TargetPlayer.Characters.Add($TargetChar)
        }

        # Aliases must propagate to both the character and the player's Names
        # set so name resolution can find the character through either path
        [void]$TargetPlayer.Names.Add($Entity.Name)
        foreach ($Alias in $Entity.Aliases.Text) {
            if (-not $TargetChar.Aliases.Contains($Alias)) { $TargetChar.Aliases.Add($Alias) }
            [void]$TargetPlayer.Names.Add($Alias)
        }

        # Entity overrides win for PU values; @plik only fills in if Gracze.md had none
        if ($Entity.FilePath -and [string]::IsNullOrWhiteSpace($TargetChar.Path)) {
            $TargetChar.Path = $Entity.FilePath
        }
        if ($Entity.Overrides.ContainsKey("pu_startowe")) { $TargetChar.PUStart = [math]::Round([decimal]$Entity.Overrides["pu_startowe"][-1], 2) }
        if ($Entity.Overrides.ContainsKey("pu_nadmiar")) { $TargetChar.PUExceeded = [math]::Round([decimal]$Entity.Overrides["pu_nadmiar"][-1], 2) }
        if ($Entity.Overrides.ContainsKey("pu_suma")) { $TargetChar.PUSum = [math]::Round([decimal]$Entity.Overrides["pu_suma"][-1], 2) }
        if ($Entity.Overrides.ContainsKey("pu_zdobyte")) { $TargetChar.PUTaken = [math]::Round([decimal]$Entity.Overrides["pu_zdobyte"][-1], 2) }
        
        Complete-PUData -Character $TargetChar

        if ($Entity.Overrides.ContainsKey("info")) {
            $InfoStr = $Entity.Overrides["info"] -join "`n"
            $TargetChar.AdditionalInfo = if ($TargetChar.AdditionalInfo) { $TargetChar.AdditionalInfo + "`n" + $InfoStr } else { $InfoStr }
        }
    }

    # Re-apply Name filter — entity overrides may have added stubs for non-requested players
    if ($Name) {
        $Filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($P in $Players) {
            if ($Name -contains $P.Name) { $Filtered.Add($P) }
        }
        return $Filtered
    }

    return $Players
}

<#
    .SYNOPSIS
    Parses the player database (Gracze.md) into structured player objects with characters,
    PU data, metadata, and entity-based overrides.

    .DESCRIPTION
    This file contains Get-Player and its helper:

    Helper:
    - Complete-PUData: derives missing PU SUMA/ZDOBYTE from the complementary value

    Get-Player reads the Gracze.md file and extracts structured information for each player
    listed under the "## Lista" section:
    - Character entries with names, file paths, aliases, and additional notes
    - PU (Player Unit) values: NADMIAR, STARTOWE, SUMA, ZDOBYTE
    - Triggers (restricted topics), Discord webhook, Margonem game ID
    - A consolidated name index for lookup (player name + character names + aliases)

    After parsing Gracze.md, the function applies overrides from entities.md. Entity entries
    of type "Gracz" or "Postac (Gracz)", or with an @owner tag, are matched to existing
    players (or create new player stubs). This allows the entity registry to extend player
    data without modifying Gracze.md directly — useful for aliases, PU values, triggers,
    and additional character metadata.
#>

# Helper: derive PU SUMA/ZDOBYTE when partial data is provided
# If SUMA is given but ZDOBYTE is not, derive ZDOBYTE = SUMA - STARTOWE.
# If ZDOBYTE is given but SUMA is not, derive SUMA = STARTOWE + ZDOBYTE.
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

    # Only process sections under "## Lista" that are level-3 headers (one per player)
    foreach ($Section in $Markdown.Sections.Where({ $_.Header.Level -eq 3 -and $_.Header.ParentHeader.Text -eq "Lista" })) {
        $PlayerName = $Section.Header.Text

        # If Name filter is specified, skip players that don't match
        if ($Name -and $Name -notcontains $PlayerName) {
            continue
        }

        # Build parent→children lookup in one pass (avoids O(n²) repeated .Where() filtering)
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

        # Extract player-level metadata from root children in a single scan
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

        # Character entries are direct children of "Postaci:" containing [Name](Path)
        $Characters = [System.Collections.Generic.List[object]]::new()
        if ($PostaciEntry) {
            $PostaciId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($PostaciEntry)
            $PostaciChildren = if ($ChildrenOf.ContainsKey($PostaciId)) { $ChildrenOf[$PostaciId] } else { @() }

            foreach ($CharacterListItem in $PostaciChildren) {
                if ($CharacterListItem.Text -notmatch '\[.+\]\(.+\)') { continue }

                # Strip bold markers (**) before extracting name and path
                $CleanText = $CharacterListItem.Text.Replace("**", "")

                $CharacterName = [regex]::Match($CleanText, '\[(.+?)\]').Groups[1].Value
                $CharacterPath = [regex]::Match($CleanText, '\((.+?)\)').Groups[1].Value

                # Determine if this is the active (bolded) character
                $IsActive = $CharacterListItem.Text.StartsWith("**")

                # Look up children of this character via ChildrenOf (O(1) lookup)
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
                        $PartKey = $PUPart.Split(":")[0].Trim()
                        $PartValue = $PUPart.Split(":")[1].Trim()

                        $PropertyName = $PUInfoMap[$PartKey]
                        if (-not $PropertyName) { continue }

                        # "BRAK" means the value is not set
                        $Character.$PropertyName = if ($PartValue -eq "BRAK") {
                            $null
                        } else {
                            try { [math]::Round([decimal]$PartValue, 2) } catch { $null }
                        }
                    }

                    Complete-PUData -Character $Character
                }

                $Characters.Add($Character)
            }
        }

        # Build a consolidated name index for lookup: player name + all character names + all aliases
        $Names = [System.Collections.Generic.List[string]]::new()
        $Names.Add($PlayerName)
        foreach ($Character in $Characters) {
            $Names.Add($Character.Name)
            foreach ($Alias in $Character.Aliases) {
                $Names.Add($Alias)
            }
        }

        # Deduplicate via HashSet and cast to array
        $Names = [System.Collections.Generic.HashSet[string]]::new($Names, [System.StringComparer]::OrdinalIgnoreCase)

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

    # Inject overrides from entities.md
    if (-not $Entities) {
        $Entities = Get-Entity
    }
    # We only care about entities that are explicitly Players, Player Characters, or have an Owner
    $OverrideEntities = $Entities.Where({
        $_.Type -in @('Gracz', 'Postać (Gracz)') -or
        $null -ne $_.Owner -or
        $_.TypeHistory.Where({ $_.Type -in @('Gracz', 'Postać (Gracz)') }).Count -gt 0
    })

    foreach ($Entity in $OverrideEntities) {
        # Determine the target player name
        $TargetPlayerName = if ($Entity.Owner) { $Entity.Owner } elseif ($Entity.Type -eq 'Gracz') { $Entity.Name } else { $null }
        
        # If no explicit owner/player name, it's an orphaned character override, skip or log
        if (-not $TargetPlayerName) { continue }

        # Find the player in our roster (case-insensitive)
        $TargetPlayer = $null
        foreach ($p in $Players) {
            if ([string]::Equals($p.Name, $TargetPlayerName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TargetPlayer = $p
                break
            }
        }

        # If it's a completely new player (e.g. Vanda Vanissa), create a stub
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
            $TargetPlayer.Names.Add($TargetPlayerName)
            $Players.Add($TargetPlayer)
        }

        # Apply Player-level Overrides (if the entity IS the player, or provides player overrides)
        if ($Entity.Type -eq 'Gracz') {
            # Add all aliases of the player to the index
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
            continue # Done with player-level overrides
        }

        # Apply Character-level Overrides (if the entity IS a character/NPC owned by the player)
        # Find or create character stub
        $TargetChar = $null
        foreach ($c in $TargetPlayer.Characters) {
            if ([string]::Equals($c.Name, $Entity.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $TargetChar = $c
                break
            }
        }
        $IsNewChar = $null -eq $TargetChar

        if ($IsNewChar) {
            $TargetChar = [PSCustomObject]@{
                Name           = $Entity.Name
                IsActive       = $false
                Aliases        = [System.Collections.Generic.List[string]]::new()
                Path           = ""
                PUExceeded     = $null
                PUStart        = $null
                PUSum          = $null
                PUTaken        = $null
                AdditionalInfo = ""
            }
            $TargetPlayer.Characters.Add($TargetChar)
        }

        # Add character aliases to the player's lookup index and character list
        [void]$TargetPlayer.Names.Add($Entity.Name)
        foreach ($Alias in $Entity.Aliases.Text) {
            if (-not $TargetChar.Aliases.Contains($Alias)) { $TargetChar.Aliases.Add($Alias) }
            [void]$TargetPlayer.Names.Add($Alias)
        }

        # Apply character properties
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

    return $Players
}

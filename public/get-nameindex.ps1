<#
    .SYNOPSIS
    Builds a token-based reverse lookup index from players and named entities for name
    resolution in session text, with BK-tree support for fuzzy matching.

    .DESCRIPTION
    This file contains Get-NameIndex and its helpers:

    Helpers:
    - Add-BKTreeNode:        inserts a key into a BK-tree node (recursive by edit distance)
    - Search-BKTree:         finds all keys within a Levenshtein threshold using triangle inequality
    - Add-IndexToken:        inserts a single token into the index, handling priority-based collisions
    - Add-NamedObjectTokens: indexes all names of a player or entity (full names at priority 1,
                             individual word tokens at priority 2)

    Get-NameIndex produces a case-insensitive dictionary mapping every resolvable name token
    to its owning object. Tokens include full names, individual words from multi-word names,
    registered aliases, and location hierarchy components.

    The index handles ambiguity through a priority system:
    - Priority 1: full names and aliases (exact registered entries)
    - Priority 2: individual word tokens from multi-word names (partial matches)
    - Same-priority collisions from different owners are flagged as Ambiguous
    - Gracz/Postac (Gracz) entities defer to Player entries (same logical entity)
    - Postać wins over Gracz (character entity is more specific than roster entry)
    - wewnętrzna/zewnętrzna location subtypes defer to Lokacja (canonical form)

    Ambiguous entries store a typed Owners array (each element has .Owner and .Type
    properties) to enable downstream type-based disambiguation in Resolve-Name.

    Returns a hashtable with three keys:
    - Index:     the token dictionary (consumed by Resolve-Name stages 1, 2, 2b)
    - StemIndex: declension-stripped stems mapping to original token keys (stage 2)
    - BKTree:    BK-tree root node for O(log N) fuzzy matching (stage 3)
#>

. "$script:ModuleRoot/private/string-helpers.ps1"

# C# type: Robot.BKTree (lib/BKTree.cs) — compiled centrally in Robot.PowerShell.psm1.
# Eliminates PowerShell interpretation overhead on the hottest path
# (16,500+ calls per Get-Session run for fuzzy name resolution).

function Add-IndexToken {
    param(
        [string]$Token,
        [object]$Owner,
        [string]$OwnerType,
        [string]$Source,
        [int]$Priority,
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex
    )

    if ([string]::IsNullOrWhiteSpace($Token)) { return }

    if ($Index.ContainsKey($Token)) {
        $Existing = $Index[$Token]

        # Same owner — keep higher-priority (lower number) entry, no ambiguity
        if ($Existing.Owner -and $Existing.Owner.Name -eq $Owner.Name -and $Existing.OwnerType -eq $OwnerType) {
            if ($Priority -lt $Existing.Priority) {
                $Index[$Token] = [PSCustomObject]@{
                    Owner     = $Owner
                    OwnerType = $OwnerType
                    Source    = $Source
                    Priority  = $Priority
                    Ambiguous = $false
                }
            }
            return
        }

        # Incoming has strictly higher priority — it wins
        if ($Priority -lt $Existing.Priority) {
            $Index[$Token] = [PSCustomObject]@{
                Owner     = $Owner
                OwnerType = $OwnerType
                Source    = $Source
                Priority  = $Priority
                Ambiguous = $false
            }
            return
        }

        # Existing has strictly higher priority — skip incoming
        if ($Priority -gt $Existing.Priority) {
            return
        }

        # Gracz defers to Player (same logical person); Postać wins over Player
        # (character name is more specific than the owning player)
        if ($OwnerType -eq 'Gracz' -and $Existing.OwnerType -eq 'Player') {
            return
        }
        if ($OwnerType -eq 'Player' -and $Existing.OwnerType -eq 'Gracz') {
            $Index[$Token] = [PSCustomObject]@{
                Owner     = $Owner
                OwnerType = $OwnerType
                Source    = $Source
                Priority  = $Priority
                Ambiguous = $false
            }
            return
        }
        if ($OwnerType -eq 'Postać' -and $Existing.OwnerType -eq 'Player') {
            $Index[$Token] = [PSCustomObject]@{
                Owner     = $Owner
                OwnerType = $OwnerType
                Source    = $Source
                Priority  = $Priority
                Ambiguous = $false
            }
            return
        }
        if ($OwnerType -eq 'Player' -and $Existing.OwnerType -eq 'Postać') {
            return
        }

        # Postać wins over Gracz (character entity is more specific than roster entry)
        if ($OwnerType -eq 'Postać' -and $Existing.OwnerType -eq 'Gracz') {
            $Index[$Token] = [PSCustomObject]@{
                Owner     = $Owner
                OwnerType = $OwnerType
                Source    = $Source
                Priority  = $Priority
                Ambiguous = $false
            }
            return
        }
        if ($OwnerType -eq 'Gracz' -and $Existing.OwnerType -eq 'Postać') {
            return
        }

        # wewnętrzna/zewnętrzna defer to Lokacja (same physical location, Lokacja is canonical)
        if ($OwnerType -in @('wewnętrzna', 'zewnętrzna') -and $Existing.OwnerType -eq 'Lokacja') {
            return
        }
        if ($OwnerType -eq 'Lokacja' -and $Existing.OwnerType -in @('wewnętrzna', 'zewnętrzna')) {
            $Index[$Token] = [PSCustomObject]@{
                Owner     = $Owner
                OwnerType = $OwnerType
                Source    = $Source
                Priority  = $Priority
                Ambiguous = $false
            }
            return
        }

        # No type-based dedup applies — genuine ambiguity
        $AllOwners = if ($Existing.Ambiguous) {
            $Existing.Owners
        } else {
            @([PSCustomObject]@{ Owner = $Existing.Owner; Type = $Existing.OwnerType })
        }
        $AllOwners = @($AllOwners) + @([PSCustomObject]@{ Owner = $Owner; Type = $OwnerType })

        $Index[$Token] = [PSCustomObject]@{
            Owner     = $null
            OwnerType = $null
            Owners    = $AllOwners
            Source    = $Existing.Source
            Priority  = $Priority
            Ambiguous = $true
        }
    } else {
        $Index[$Token] = [PSCustomObject]@{
            Owner     = $Owner
            OwnerType = $OwnerType
            Source    = $Source
            Priority  = $Priority
            Ambiguous = $false
        }

        # Stem index built inline to avoid a second pass over all keys
        $Stem = Get-DeclensionStem -Text $Token
        if (-not $StemIndex.ContainsKey($Stem)) {
            $StemIndex[$Stem] = [System.Collections.Generic.List[string]]::new()
        }
        $StemIndex[$Stem].Add($Token)
    }
}

function Add-NamedObjectTokens {
    param(
        [object]$NamedObject,
        [string]$OwnerType,
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,
        [int]$MinTokenLength
    )

    # Priority 1: full names and aliases — exact registered entries
    foreach ($FullName in $NamedObject.Names) {
        Add-IndexToken -Token $FullName -Owner $NamedObject -OwnerType $OwnerType -Source $FullName -Priority 1 -Index $Index -StemIndex $StemIndex
    }

    # Priority 2: word tokens from multi-word names (partial matches)
    foreach ($FullName in $NamedObject.Names) {
        $Words = $FullName.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)

        if ($Words.Count -le 1) { continue }

        foreach ($Word in $Words) {
            if ($Word.Length -lt $MinTokenLength) { continue }
            Add-IndexToken -Token $Word -Owner $NamedObject -OwnerType $OwnerType -Source $FullName -Priority 2 -Index $Index -StemIndex $StemIndex
        }
    }
}

function Get-NameIndex {
    <#
        .SYNOPSIS
        Builds a token-based reverse lookup index from players and named entities for name resolution.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched player roster from Get-Player")]
        [object[]]$Players,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Minimum token length to index (filters out short words like 'de', 'IV')")]
        [int]$MinTokenLength = 3
    )

    if (-not $PSBoundParameters.ContainsKey('Players')) {
        $Players = Get-Player
    }

    # Token -> index entry, case-insensitive for Polish name matching
    $Index = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Declension-stripped stem -> original token keys (built inline during insertion)
    $StemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Players indexed first — Gracz/Postać dedup rules depend on Player entries existing
    foreach ($Player in $Players) {
        Add-NamedObjectTokens -NamedObject $Player -OwnerType "Player" -Index $Index -StemIndex $StemIndex -MinTokenLength $MinTokenLength
    }

    # Entity tokens added after players — Add-IndexToken handles priority collisions
    if ($Entities) {
        foreach ($Entity in $Entities) {
            Add-NamedObjectTokens -NamedObject $Entity -OwnerType $Entity.Type -Index $Index -StemIndex $StemIndex -MinTokenLength $MinTokenLength
        }
    }

    # Fisher-Yates shuffle with deterministic seed prevents degenerate tree depth
    # from sorted insertion order while keeping results reproducible across runs
    $BKTree = $null
    $AllKeys = [string[]]$Index.Keys
    if ($AllKeys.Count -gt 0) {
        $Rng = [System.Random]::new(42)  # deterministic seed for reproducibility
        for ($k = $AllKeys.Count - 1; $k -gt 0; $k--) {
            $j = $Rng.Next($k + 1)
            $Temp = $AllKeys[$k]
            $AllKeys[$k] = $AllKeys[$j]
            $AllKeys[$j] = $Temp
        }

        if (([System.Management.Automation.PSTypeName]'Robot.BKTree').Type) {  # C# path — O(log N) search
            $BKTree = [Robot.BKTree]::new($AllKeys[0])
            for ($k = 1; $k -lt $AllKeys.Count; $k++) {
                [void]$BKTree.Add($AllKeys[$k])
            }
        } else {
            $BKTree = $null
        }
    }

    return @{
        Index     = $Index
        StemIndex = $StemIndex
        BKTree    = $BKTree
    }
}

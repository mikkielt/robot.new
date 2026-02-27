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

    Returns a hashtable with three keys:
    - Index:     the token dictionary (consumed by Resolve-Name stages 1, 2, 2b)
    - StemIndex: declension-stripped stems mapping to original token keys (stage 2)
    - BKTree:    BK-tree root node for O(log N) fuzzy matching (stage 3)
#>

# Dot-source shared helpers
. "$PSScriptRoot/string-helpers.ps1"

# Helper: insert a key into a BK-tree node
# BK-trees partition strings by edit distance, enabling O(log N) Levenshtein lookups.
# Each node stores a key and children keyed by distance.
function Add-BKTreeNode {
    param(
        [hashtable]$Node,
        [string]$Key
    )

    $Distance = Get-LevenshteinDistance -Source $Node.Key -Target $Key
    if ($Distance -eq 0) { return }  # duplicate key, skip

    if ($Node.Children.ContainsKey($Distance)) {
        Add-BKTreeNode -Node $Node.Children[$Distance] -Key $Key
    } else {
        $Node.Children[$Distance] = @{ Key = $Key; Children = @{} }
    }
}

# Helper: search BK-tree for all keys within a Levenshtein threshold
# Exploits triangle inequality to prune branches: only children at distance d
# where |d - queryDistance| <= threshold can contain matches.
function Search-BKTree {
    param(
        [hashtable]$Tree,
        [string]$Query,
        [int]$Threshold
    )

    if ($null -eq $Tree -or $null -eq $Tree.Key) { return @() }

    $Results = [System.Collections.Generic.List[object]]::new()
    $Stack   = [System.Collections.Generic.Stack[hashtable]]::new()
    $Stack.Push($Tree)

    while ($Stack.Count -gt 0) {
        $Current  = $Stack.Pop()
        $Distance = Get-LevenshteinDistance -Source $Query -Target $Current.Key

        if ($Distance -le $Threshold) {
            $Results.Add([PSCustomObject]@{ Key = $Current.Key; Distance = $Distance })
        }

        $Low  = $Distance - $Threshold
        $High = $Distance + $Threshold

        foreach ($ChildDist in $Current.Children.Keys) {
            if ($ChildDist -ge $Low -and $ChildDist -le $High) {
                $Stack.Push($Current.Children[$ChildDist])
            }
        }
    }

    return $Results
}

# Helper: insert a single token into the index, handling priority-based collisions
# Priority 1 beats priority 2. Same-priority same-owner keeps higher priority.
# Same-priority different-owner marks the entry as Ambiguous (except Gracz vs Player dedup).
# Also builds the stem index inline — maps declension-stripped stems to original token keys.
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

        # Same owner — keep the higher-priority (lower number) entry, no ambiguity
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

        # Different owner, incoming has strictly higher priority — it wins
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

        # Existing has strictly higher priority — existing wins, skip
        if ($Priority -gt $Existing.Priority) {
            return
        }

        # Same priority, different owner — Gracz/Postac entities defer to Player entries
        # (they represent the same logical entity but Player has more resolution powers)
        if ($OwnerType -in @('Gracz', 'Postać (Gracz)') -and $Existing.OwnerType -eq 'Player') {
            return
        }
        if ($OwnerType -eq 'Player' -and $Existing.OwnerType -in @('Gracz', 'Postać (Gracz)')) {
            $Index[$Token] = [PSCustomObject]@{
                Owner     = $Owner
                OwnerType = $OwnerType
                Source    = $Source
                Priority  = $Priority
                Ambiguous = $false
            }
            return
        }

        # Genuine ambiguity — same priority, different owner, no type dedup
        $AllOwners = if ($Existing.Ambiguous) { $Existing.Owners } else { @($Existing.Owner) }
        $AllOwners = @($AllOwners) + @($Owner)

        $Index[$Token] = [PSCustomObject]@{
            Owner     = $null
            OwnerType = $null
            Owners    = $AllOwners
            Source    = $Existing.Source
            Priority  = $Priority
            Ambiguous = $true
        }
    } else {
        # New token — straightforward insert
        $Index[$Token] = [PSCustomObject]@{
            Owner     = $Owner
            OwnerType = $OwnerType
            Source    = $Source
            Priority  = $Priority
            Ambiguous = $false
        }

        # Build stem index inline — only needed for newly inserted keys
        $Stem = Get-DeclensionStem -Text $Token
        if (-not $StemIndex.ContainsKey($Stem)) {
            $StemIndex[$Stem] = [System.Collections.Generic.List[string]]::new()
        }
        $StemIndex[$Stem].Add($Token)
    }
}

# Helper: index all names of a player or entity
# Full names and aliases at priority 1, individual word tokens at priority 2.
# Word tokens shorter than $MinTokenLength are skipped to avoid noise from "de", "IV", etc.
function Add-NamedObjectTokens {
    param(
        [object]$NamedObject,
        [string]$OwnerType,
        [System.Collections.Generic.Dictionary[string, object]]$Index,
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$StemIndex,
        [int]$MinTokenLength
    )

    # Priority 1: Full names and aliases
    foreach ($FullName in $NamedObject.Names) {
        Add-IndexToken -Token $FullName -Owner $NamedObject -OwnerType $OwnerType -Source $FullName -Priority 1 -Index $Index -StemIndex $StemIndex
    }

    # Priority 2: Individual word tokens from multi-word names
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

    if (-not $Players) {
        $Players = Get-Player
    }

    # Case-insensitive dictionary: token string -> index entry
    $Index = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Stem index built inline during token insertion (avoids second pass over all keys).
    # Maps each declension-stripped stem -> list of original token keys that share it.
    $StemIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Index all players
    foreach ($Player in $Players) {
        Add-NamedObjectTokens -NamedObject $Player -OwnerType "Player" -Index $Index -StemIndex $StemIndex -MinTokenLength $MinTokenLength
    }

    # Index all entities (NPCs, organizations, locations) if provided
    if ($Entities) {
        foreach ($Entity in $Entities) {
            Add-NamedObjectTokens -NamedObject $Entity -OwnerType $Entity.Type -Index $Index -StemIndex $StemIndex -MinTokenLength $MinTokenLength
        }
    }

    # Build BK-tree from all index keys for O(log N) fuzzy matching in Resolve-Name Stage 3
    $BKTree = $null
    $AllKeys = [string[]]$Index.Keys
    if ($AllKeys.Count -gt 0) {
        $BKTree = @{ Key = $AllKeys[0]; Children = @{} }
        for ($k = 1; $k -lt $AllKeys.Count; $k++) {
            Add-BKTreeNode -Node $BKTree -Key $AllKeys[$k]
        }
    }

    return @{
        Index     = $Index
        StemIndex = $StemIndex
        BKTree    = $BKTree
    }
}

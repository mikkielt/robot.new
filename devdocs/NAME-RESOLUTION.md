# Name Resolution Pipeline - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the name resolution subsystem: `Get-NameIndex` (index construction), `Resolve-Name` (multi-stage lookup), and their supporting data structures (BK-tree, stem index, priority/ambiguity system).

**Shared dependency**: `private/string-helpers.ps1` provides `Get-LevenshteinDistance`, dot-sourced by `public/resolve/resolve-name.ps1`, `public/get-nameindex.ps1`, and `public/reporting/get-namedlocationreport.ps1`.

**Not covered**: How name resolution is consumed by `Get-Session`, `Get-EntityState`, or `Resolve-Narrator` - see [SESSIONS.md](SESSIONS.md) and [ENTITIES.md](ENTITIES.md).

---

## 2. Architecture Overview

```
Get-Player ──┐
             ├──> Get-NameIndex ──> { Index, StemIndex, BKTree }
Get-Entity ──┘                              │
                                            ▼
                    Query ──> Resolve-Name ──> Owner object (or $null)
                                  │
                         Stage 1: Exact lookup
                         Stage 2: Declension stripping
                         Stage 2b: Stem alternation
                         Stage 3: Levenshtein fuzzy (BK-tree)
```

`Get-NameIndex` is called once to build the lookup structures. `Resolve-Name` consumes them for each query. A shared `-Cache` hashtable enables cross-call memoization.

---

## 3. Index Construction (`Get-NameIndex`)

### 3.1 Functions

| Function | Purpose |
|---|---|
| `Get-NameIndex` | Main builder - produces `{ Index, StemIndex, BKTree }` |
| `Add-BKTreeNode` | Recursive BK-tree insertion by edit distance |
| `Search-BKTree` | Iterative BK-tree traversal with triangle-inequality pruning |
| `Add-IndexToken` | Inserts a single token with priority-based collision resolution |
| `Add-NamedObjectTokens` | Indexes all names of a player or entity (full names + word tokens) |

### 3.2 Token Priority System

| Priority | Source | Examples |
|---|---|---|
| 1 | Full names and registered aliases | `"Crag Hack"`, `"Sandro"` |
| 2 | Individual word tokens (≥ `MinTokenLength`, default 3) | `"Crag"`, `"Hack"` |

### 3.3 Collision Resolution

```
IF token already in index:
    Same owner -> keep higher priority (lower number wins)
    Different owner, incoming has higher priority -> replace, no ambiguity
    Different owner, same priority:
        Gracz/Postać vs Player -> Player wins (same logical entity, deduplicate)
        Otherwise -> mark Ambiguous, store all owners in Owners array
ELSE:
    Insert new entry
    Build stem index entry inline (declension stem -> list of token keys)
```

Ambiguous entries are skipped by `Resolve-Name` stages 1–2b and penalized in stage 3.

### 3.4 Stem Index

Built inline during token insertion. For each token key, the declension stem (suffix-stripped form) is computed and mapped to a list of original token keys sharing that stem. Consumed by `Resolve-Name` stage 2.

### 3.5 Output Structure

```powershell
@{
    Index     = Dictionary[string, PSCustomObject]  # OrdinalIgnoreCase
    StemIndex = Dictionary[string, List[string]]    # OrdinalIgnoreCase
    BKTree    = @{ Key = "..."; Children = @{} }    # Recursive hashtable
}
```

Each index entry:

| Field | Type | Description |
|---|---|---|
| `Owner` | object | Resolved entity (if not ambiguous) |
| `OwnerType` | string | `"Player"`, `"NPC"`, `"Organizacja"`, `"Lokacja"`, `"Gracz"`, `"Postać"` |
| `Owners` | object[] | All owners (if ambiguous) |
| `Source` | string | Original full name the token came from |
| `Priority` | int | 1 (full name) or 2 (word token) |
| `Ambiguous` | bool | True if multiple different owners share this token at the same priority |

---

## 4. BK-Tree

A [BK-tree](https://en.wikipedia.org/wiki/BK-tree) partitions strings by Levenshtein edit distance, enabling O(log N) approximate matching.

### 4.1 Structure

Each node is a hashtable:

```powershell
@{
    Key      = "korm"           # Lowercased token
    Children = @{               # Keyed by edit distance
        1 = @{ Key = "form"; Children = @{} }
        2 = @{ Key = "storm"; Children = @{} }
    }
}
```

### 4.2 Insertion

```
FUNCTION Add-BKTreeNode(node, key):
    distance = Levenshtein(node.Key, key)
    IF distance == 0 -> RETURN (skip duplicates)
    IF children[distance] exists -> recurse on that child
    ELSE -> create new child node at that distance
```

### 4.3 Search

```
FUNCTION Search-BKTree(tree, query, threshold):
    results = []
    stack = [tree]
    WHILE stack not empty:
        current = pop()
        distance = Levenshtein(query, current.Key)
        IF distance <= threshold -> add to results
        LOW = distance - threshold
        HIGH = distance + threshold
        FOR each child at childDistance:
            IF LOW <= childDistance <= HIGH -> push child
    RETURN results
```

The triangle inequality `|d(a,c) - d(a,b)| ≤ d(b,c)` guarantees that children outside `[LOW, HIGH]` cannot satisfy the threshold, pruning ~90% of the tree on each step.

### 4.4 Construction

Built lazily - only if at least 1 token key exists. `Search-BKTree` handles a `$null` tree safely (returns empty results).

---

## 5. Name Resolution (`Resolve-Name`)

### 5.1 Functions

| Function | Purpose |
|---|---|
| `Resolve-Name` | 4-stage lookup pipeline |
| `Get-DeclensionStem` | Strips Polish case suffixes |
| `Get-StemAlternationCandidates` | Reverses Polish consonant mutations |
| `Get-LevenshteinDistance` | Two-row matrix edit distance (from `private/string-helpers.ps1`) |
| `Test-TypeFilter` | Nested closure capturing `-OwnerType` filter |

### 5.2 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Query` | string | Name to resolve |
| `Index` | hashtable | Output of `Get-NameIndex` (or auto-built) |
| `OwnerType` | string | Optional type filter: `"Player"`, `"NPC"`, `"Organizacja"`, `"Lokacja"` |
| `Cache` | hashtable | Optional cross-call memoization cache |
| `Players` | object[] | Pre-fetched players (for auto-building index) |
| `Entities` | object[] | Pre-fetched entities (for auto-building index) |

### 5.3 Stage 1 - Exact Index Lookup

```
IF Query in Index (case-insensitive)
    AND NOT Ambiguous
    AND passes OwnerType filter
-> RETURN Entry.Owner
```

**Complexity**: O(1) dictionary lookup.

### 5.4 Stage 2 - Declension-Stripped Match

Strips Polish noun declension suffixes from the query and looks up the resulting stem in the pre-built stem index.

**Suffix list** (ordered longest-first to prevent partial stripping):

```
-owi, -ami, -ach, -iem, -em, -ą, -ę, -ie, -om, -a, -u, -y
```

```
stem = StripLongestMatchingSuffix(Query)    # minimum 3-char stem
IF stem in StemIndex:
    FOR each tokenKey in StemIndex[stem]:
        IF tokenKey in Index AND NOT Ambiguous AND type match:
            RETURN Owner
```

**Examples**: `"Solmyra"` -> stem `"Solmyr"` -> resolves to Solmyr. `"Sandrem"` -> stem `"Sandro"`.

### 5.5 Stage 2b - Stem Alternation Match

Handles Polish consonant mutations where the suffix replaces the stem ending. Generates candidate base forms by reversing known alternation patterns.

**Alternation mappings** (12 rules):

| Inflected ending | Base form | Example |
|---|---|---|
| `-dzie` | `-da` | `Vidominie` -> `Vidomina` |
| `-ce` | `-ka` | `Żylce` -> `Żylka` |
| `-rze` | `-ra` | `Solmyrze` -> `Solmyra` |
| `-dze` | `-ga` | - |
| `-ście` | `-sta` | - |
| `-ni` | `-ń` | - |
| `-si` | `-ś` | - |
| `-zi` | `-ź` | - |
| `-ci` | `-ć` | - |

```
candidates = ReverseConsonantMutations(Query)
FOR each candidate:
    IF candidate in Index AND NOT Ambiguous AND type match:
        RETURN Owner
```

### 5.6 Stage 3 - Levenshtein Fuzzy Match

**Threshold**: dynamic based on query length.

```
threshold = Query.Length < 5 ? 1 : floor(Query.Length / 3)
```

**Algorithm**:
1. If BK-tree is available -> `Search-BKTree(Query, threshold)` - O(log N)
2. Otherwise -> linear scan with length pre-filter

**Length pre-filter**: Skip tokens where `|Query.Length - token.Length| > threshold`. Eliminates ~60–70% of comparisons.

**Levenshtein implementation**: Two-row matrix (memory-efficient). Standard dynamic programming with insert/delete/replace operations.

**Early exit**: If `bestDistance ≤ 1`, stop scanning immediately.

---

## 6. Cache Pattern

The optional `-Cache` hashtable uses `[DBNull]::Value` as a sentinel for "looked up, found nothing":

```powershell
# Cache hit
if ($Cache.ContainsKey($CacheKey)) {
    $Cached = $Cache[$CacheKey]
    if ($Cached -is [System.DBNull]) { return $null }  # cached miss
    return $Cached                                       # cached hit
}

# ... resolution logic ...

# Cache the miss
if ($Cache) { $Cache[$CacheKey] = [System.DBNull]::Value }
```

This distinguishes between "never looked up" (`ContainsKey` = false) and "looked up, no match" (`[DBNull]` sentinel), avoiding redundant resolution for names known to be unresolvable.

---

## 7. Edge Cases

| Scenario | Behavior |
|---|---|
| Empty/whitespace query | Rejected at `Add-IndexToken` (`IsNullOrWhiteSpace` check) |
| Query matches ambiguous token | Stages 1–2b skip it; stage 3 penalizes but may still match |
| Stem too short (< 3 chars) | Declension stripping skipped; falls through to stage 2b/3 |
| Short tokens (< `MinTokenLength`) | Excluded from word-token indexing (priority 2) to reduce noise |
| Duplicate BK-tree keys | Silently skipped (distance 0 check) |
| `$null` BK-tree | `Search-BKTree` returns empty results; falls back to linear scan |
| Player/Entity dedup | `Gracz`/`Postać` entity entries defer to `Player` entries in collisions |

---

## 8. Testing

| Test file | Coverage |
|---|---|
| `tests/resolve-name.Tests.ps1` | All 4 stages, type filtering, cache behavior, edge cases |
| `tests/get-nameindex.Tests.ps1` | Priority collision, ambiguity, stem index, BK-tree construction |

---

## 9. Related Documents

- [ENTITIES.md](ENTITIES.md) - Entity name resolution in `Get-EntityState` (uses `Resolve-Name` internally)
- [SESSIONS.md](SESSIONS.md) - Mention extraction and narrator resolution (uses `Resolve-Name`)
- [MIGRATION.md](MIGRATION.md) - §1.5 Entity State Pipeline describes name resolution in context

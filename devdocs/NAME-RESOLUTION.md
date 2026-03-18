# Name Resolution Pipeline

---

## Scope

The name resolution subsystem consists of `Get-NameIndex` (index construction), `Resolve-Name` (multi-stage lookup), and their supporting data structures (BK-tree, stem index, priority/ambiguity system).

Shared dependency: `private/string-helpers.ps1` provides `Get-LevenshteinDistance` (PowerShell fallback), dot-sourced by `public/resolve/resolve-name.ps1`, `public/get-nameindex.ps1`, `public/reporting/get-namedlocationreport.ps1`, and `public/reporting/get-namedloglocationreport.ps1`.

Compiled C# dependency: `lib/BKTree.cs` provides the `Robot.BKTree` class — a compiled C# BK-tree with integrated case-insensitive Levenshtein distance. Loaded via `Add-Type` in `public/get-nameindex.ps1`. Called on every unresolved token during name resolution across all session processing. Falls back to the legacy PowerShell BK-tree helpers when `Add-Type` fails.

Compiled C# dependency: `lib/DeclensionEngine.cs` provides the `Robot.DeclensionEngine` class — Polish noun declension engine for suffix stripping and consonant alternation reversal. Constructed once at module load by `public/resolve/resolve-name.ps1`. Called on every unresolved name during `Resolve-Name` stages 2 and 2b. Falls back to the PowerShell functions `Get-DeclensionStem` and `Get-StemAlternationCandidates` when `Add-Type` fails.

How name resolution is consumed by `Get-Session`, `Get-EntityState`, or `Resolve-Narrator` is documented in [SESSIONS.md](SESSIONS.md) and [ENTITIES.md](ENTITIES.md). Log location analysis is documented in [LOGS.md](LOGS.md).

---

## Architecture Overview

```
Get-Player --+
             +--> Get-NameIndex --> { Index, StemIndex, BKTree }
Get-Entity --+                              |
                                            v
                    Query --> Resolve-Name --> Owner object (or $null)
                                  |
                         Stage 1: Exact lookup
                         Stage 2: Declension stripping
                         Stage 2b: Stem alternation
                         Stage 3: Levenshtein fuzzy (BK-tree)
```

`Get-NameIndex` is called once to build the lookup structures. `Resolve-Name` consumes them for each query. A shared `-Cache` hashtable enables cross-call memoization.

---

## Index Construction (`Get-NameIndex`)

| Function | Purpose |
|---|---|
| `Get-NameIndex` | Main builder - produces `{ Index, StemIndex, BKTree }` |
| `Add-BKTreeNode` | Recursive BK-tree insertion by edit distance |
| `Search-BKTree` | Iterative BK-tree traversal with triangle-inequality pruning |
| `Add-IndexToken` | Inserts a single token with priority-based collision resolution |
| `Add-NamedObjectTokens` | Indexes all names of a player or entity (full names + word tokens) |

Token priority system:

| Priority | Source | Examples |
|---|---|---|
| 1 | Full names, registered aliases, `@slug` values, `@nazwa_nerthus` values | `"Crag Hack"`, `"Sandro"`, `"komnata-rady-ratusz"` |
| 2 | Individual word tokens (>= `MinTokenLength`, default 3) | `"Crag"`, `"Hack"` |

Collision resolution:

```
IF token already in index:
    Same owner -> keep higher priority (lower number wins)
    Different owner, incoming has higher priority -> replace, no ambiguity
    Different owner, same priority:
        Gracz/Postac vs Player -> Player wins (same logical entity, deduplicate)
        Otherwise -> mark Ambiguous, store all owners in Owners array
ELSE:
    Insert new entry
    Build stem index entry inline (declension stem -> list of token keys)
```

Ambiguous entries are skipped by `Resolve-Name` stages 1-2b and penalized in stage 3.

The stem index is built inline during token insertion. For each token key, the declension stem (suffix-stripped form) is computed and mapped to a list of original token keys sharing that stem. Consumed by `Resolve-Name` stage 2.

Output structure:

```powershell
@{
    Index     = Dictionary[string, PSCustomObject]  # OrdinalIgnoreCase
    StemIndex = Dictionary[string, List[string]]    # OrdinalIgnoreCase
    BKTree    = [Robot.BKTree] or @{ Key = "..."; Children = @{} }  # C# or hashtable
}
```

The `BKTree` value is a `Robot.BKTree` instance when the C# type is available, or a recursive PowerShell hashtable as fallback. `Resolve-Name` uses `$BKTree -is [Robot.BKTree]` to dispatch to the correct search method.

Each index entry:

| Field | Type | Description |
|---|---|---|
| `Owner` | object | Resolved entity (if not ambiguous) |
| `OwnerType` | string | `"Player"`, `"NPC"`, `"Grupa"`, `"Lokacja"`, `"Mapa"`, `"Gracz"`, `"Postac"`, `"Przedmiot"` (set from entity `.Type` or `"Player"` for player objects) |
| `Owners` | object[] | All owners (if ambiguous) |
| `Source` | string | Original full name the token came from |
| `Priority` | int | 1 (full name) or 2 (word token) |
| `Ambiguous` | bool | True if multiple different owners share this token at the same priority |

---

## BK-Tree

A [BK-tree](https://en.wikipedia.org/wiki/BK-tree) partitions strings by Levenshtein edit distance, enabling O(log N) approximate matching. Two implementations exist: a compiled C# class (`Robot.BKTree`) and a legacy PowerShell hashtable fallback.

The `Robot.BKTree` class (`lib/BKTree.cs`) is the primary implementation, loaded via `Add-Type` at module import time. It provides:

- Integrated Levenshtein distance — `LevenshteinDistance(s, t, maxDist)` is a static two-row matrix, case-insensitive via `char.ToLowerInvariant`, with early-exit threshold (returns `maxDist + 1` when true distance exceeds threshold).
- Tree structure — sealed class with `string _key` and `Dictionary<int, BKTree> _children`.
- `Add(string word)` — recursive insertion by edit distance (skips duplicates at distance 0).
- `Search(string query, int threshold)` — iterative stack-based traversal. Returns `List<KeyValuePair<string, int>>` where `Key` is the matched token and `Value` is the distance. Uses full distance for correct lo/hi child pruning — early-exit would underestimate distance, causing missed children.

On the 4,700+ token index with 16,500+ lookups per session run, the C# implementation eliminates PowerShell interpretation overhead.

The legacy PowerShell fallback is kept for backward compatibility with test code and as a fallback when `Add-Type` fails (e.g., restricted environments). Each node is a hashtable:

```powershell
@{
    Key      = "korm"           # Lowercased token
    Children = @{               # Keyed by edit distance
        1 = @{ Key = "form"; Children = @{} }
        2 = @{ Key = "storm"; Children = @{} }
    }
}
```

Insertion (`Add-BKTreeNode`):

```
FUNCTION Add-BKTreeNode(node, key):
    distance = Levenshtein(node.Key, key)
    IF distance == 0 -> RETURN (skip duplicates)
    IF children[distance] exists -> recurse on that child
    ELSE -> create new child node at that distance
```

Search (`Search-BKTree`):

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

The triangle inequality `|d(a,c) - d(a,b)| <= d(b,c)` guarantees that children outside `[LOW, HIGH]` cannot satisfy the threshold, pruning ~90% of the tree on each step.

The BK-tree is built lazily in `Get-NameIndex` — only if at least 1 token key exists. Keys are Fisher-Yates shuffled with a deterministic seed (42) before insertion to prevent degenerate tree shape from sorted insertion order, ensuring reproducible tree shape across runs.

Type selection: If `Robot.BKTree` type is available (C# compiled successfully), a `Robot.BKTree` instance is created. Otherwise, falls back to the PowerShell hashtable BK-tree.

`Search-BKTree` (legacy) handles a `$null` tree safely (returns empty results). `Resolve-Name` dispatches to the correct search method based on `$BKTree -is [Robot.BKTree]`.

C# type loading in `public/get-nameindex.ps1` at file scope (before any function definitions):

```powershell
if (-not ([System.Management.Automation.PSTypeName]'Robot.BKTree').Type) {
    $CsPath = [System.IO.Path]::Combine($script:ModuleRoot, 'lib', 'BKTree.cs')
    if ([System.IO.File]::Exists($CsPath)) {
        Add-Type -TypeDefinition ([System.IO.File]::ReadAllText($CsPath)) -Language CSharp
    }
}
```

The type check ensures the class is loaded only once per session, even if `get-nameindex.ps1` is dot-sourced multiple times.

---

## `Robot.DeclensionEngine`

Source: `lib/DeclensionEngine.cs` — compiled centrally in `Robot.PowerShell.psm1`.

`Robot.DeclensionEngine` is a Polish noun declension engine for name resolution. It iterates suffix and alternation arrays using `.EndsWith()` + `.Substring()` with `OrdinalIgnoreCase` comparison. Constructed once at module load by `public/resolve/resolve-name.ps1` with Polish declension tables (locative, genitive, instrumental, dative suffixes and consonant alternation pairs).

`GetStem(string text)` strips the first matching inflection suffix from text. Suffixes are tried in constructor input order — longest-first ordering is critical to prevent partial stripping (e.g., `"ami"` must be tried before `"i"`). Minimum stem length of 3: `text.Length` must exceed `suffix.Length + 2`. Returns the original text if no suffix matches. Example: `"Erathii"` -> `"Erathi"`, `"Sandrem"` -> `"Sandr"`.

`GetAlternationCandidates(string text)` reverses stem alternation changes to produce candidate base forms. For each matching inflected ending, strips it and appends the corresponding base form suffix. Applies the same minimum stem length guard as `GetStem`. May return multiple candidates when multiple alternations match. Returns an empty array if no alternation matches. Example: `"Valesce"` -> strip `"ce"`, append `"ka"` -> `"Valeska"`.

Construction — the engine is instantiated with three parallel arrays:

| Parameter | Type | Description |
|---|---|---|
| `suffixes` | `string[]` | Declension suffixes ordered longest-first (`-owi`, `-ami`, `-ach`, `-iem`, `-em`, `-a`, `-u`, `-y`, etc.) |
| `altInflected` | `string[]` | Inflected endings to match (`-dzie`, `-ce`, `-rze`, `-dze`, `-scie`, `-ni`, `-si`, `-zi`, `-ci`) |
| `altBase` | `string[]` | Corresponding base form replacements (`-da`, `-ka`, `-ra`, `-ga`, `-sta`, `-n`, `-s`, `-z`, `-c`) |

Consumers:
- `Resolve-Name` Stage 2 (`public/resolve/resolve-name.ps1`) — calls `GetStem` for suffix stripping, then looks up the result in the pre-built `StemIndex`
- `Resolve-Name` Stage 2b (`public/resolve/resolve-name.ps1`) — calls `GetAlternationCandidates` to reverse consonant mutations, then looks up each candidate in the `Index`

When the C# type is unavailable, `Resolve-Name` falls back to the equivalent PowerShell functions `Get-DeclensionStem` and `Get-StemAlternationCandidates`.

---

## Name Resolution (`Resolve-Name`)

| Function | Purpose |
|---|---|
| `Resolve-Name` | 4-stage lookup pipeline |
| `Get-DeclensionStem` | Strips Polish case suffixes |
| `Get-StemAlternationCandidates` | Reverses Polish consonant mutations |
| `Get-LevenshteinDistance` | Two-row matrix edit distance — PowerShell fallback (from `private/string-helpers.ps1`) |
| `Robot.BKTree.LevenshteinDistance` | Two-row matrix edit distance — compiled C# (from `lib/BKTree.cs`) |

Parameters:

| Parameter | Type | Description |
|---|---|---|
| `Query` | string | Name to resolve |
| `Index` | `Dictionary[string, object]` | Token index from `Get-NameIndex` (or auto-built) |
| `StemIndex` | `Dictionary[string, List[string]]` | Stem index from `Get-NameIndex` for O(1) declension lookups |
| `BKTree` | `Robot.BKTree` or hashtable | BK-tree from `Get-NameIndex` for O(log N) fuzzy matching |
| `OwnerType` | string | Optional type filter: `"Player"`, `"NPC"`, `"Grupa"`, `"Lokacja"` |
| `MaxDistance` | int | Override maximum Levenshtein distance for fuzzy matching (default: `-1`, dynamic) |
| `Cache` | hashtable | Optional cross-call memoization cache |
| `NoFuzzy` | switch | Skip Stage 3 fuzzy/Levenshtein matching to avoid false positives |
| `Players` | object[] | Pre-fetched players (for auto-building index) |
| `Entities` | object[] | Pre-fetched entities (for auto-building index) |

Stage 1 — Exact Index Lookup:

```
IF Query in Index (case-insensitive)
    AND NOT Ambiguous
    AND passes OwnerType filter
-> RETURN Entry.Owner
```

Complexity: O(1) dictionary lookup.

Stage 2 — Declension-Stripped Match. Strips Polish noun declension suffixes from the query and looks up the resulting stem in the pre-built stem index.

Suffix list (ordered longest-first to prevent partial stripping):

```
-owi, -ami, -ach, -iem, -em, -a, -e, -ie, -om, -a, -u, -y
```

```
stem = StripLongestMatchingSuffix(Query)    # minimum 3-char stem
IF stem in StemIndex:
    FOR each tokenKey in StemIndex[stem]:
        IF tokenKey in Index AND NOT Ambiguous AND type match:
            RETURN Owner
```

Examples: `"Solmyra"` -> stem `"Solmyr"` -> resolves to Solmyr. `"Sandrem"` -> stem `"Sandro"`.

Stage 2b — Stem Alternation Match. Handles Polish consonant mutations where the suffix replaces the stem ending. Generates candidate base forms by reversing known alternation patterns.

Alternation mappings (12 rules):

| Inflected ending | Base form | Example |
|---|---|---|
| `-dzie` | `-da` | `Vidominie` -> `Vidomina` |
| `-ce` | `-ka` | `Zylce` -> `Zylka` |
| `-rze` | `-ra` | `Solmyrze` -> `Solmyra` |
| `-dze` | `-ga` | - |
| `-scie` | `-sta` | - |
| `-ni` | `-n` | - |
| `-si` | `-s` | - |
| `-zi` | `-z` | - |
| `-ci` | `-c` | - |

```
candidates = ReverseConsonantMutations(Query)
FOR each candidate:
    IF candidate in Index AND NOT Ambiguous AND type match:
        RETURN Owner
```

Stage 3 — Levenshtein Fuzzy Match.

When `-NoFuzzy` is set, stage 3 is skipped entirely and the function returns `$null` (caching the miss). Used by callers that want only exact/declension matches to avoid false positives.

Threshold — dynamic based on query length, overridable via `-MaxDistance`:

```
threshold = MaxDistance >= 0 ? MaxDistance
          : Query.Length < 5 ? 1
          : floor(Query.Length / 3)
```

Three-way dispatch:

1. C# BK-tree (`$BKTree -is [Robot.BKTree]`) — `$BKTree.Search($Query, $Threshold)` returns `List[KeyValuePair[string, int]]`. Each result's `.Value` is the distance, `.Key` is the token. O(log N).
2. Legacy PowerShell BK-tree (`$BKTree` is a hashtable) — `Search-BKTree -Tree $BKTree -Query $Query -Threshold $Threshold` returns `PSCustomObject` with `.Distance` and `.Key` properties.
3. Linear scan fallback (no BK-tree) — iterates all index keys with length-difference pruning and `Get-LevenshteinDistance -MaxDistance $Threshold`.

Length pre-filter (linear scan only): Skip tokens where `|Query.Length - token.Length| > threshold`. Eliminates ~60-70% of comparisons.

Levenshtein implementation: Two-row matrix (memory-efficient). Standard dynamic programming with insert/delete/replace operations. The C# version (`Robot.BKTree.LevenshteinDistance`) uses `char.ToLowerInvariant` for case-insensitive comparison; the PowerShell version (`Get-LevenshteinDistance`) uses `String.ToLowerInvariant`. Both support early-exit via a `MaxDistance` threshold.

Early exit (linear scan only): If `bestDistance <= 1`, stop scanning immediately.

---

## Cache Pattern

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

## Edge Cases

| Scenario | Behavior |
|---|---|
| Empty/whitespace query | Rejected at `Add-IndexToken` (`IsNullOrWhiteSpace` check) |
| Query matches ambiguous token | Stages 1-2b skip it; stage 3 penalizes but may still match |
| Stem too short (< 3 chars) | Declension stripping skipped; falls through to stage 2b/3 |
| Short tokens (< `MinTokenLength`) | Excluded from word-token indexing (priority 2) to reduce noise |
| Duplicate BK-tree keys | Silently skipped (distance 0 check in both C# and PowerShell implementations) |
| `$null` BK-tree | `Search-BKTree` (legacy) returns empty results; `Resolve-Name` falls back to linear scan |
| `Robot.BKTree` type unavailable | `Add-Type` failure is silent; `Get-NameIndex` falls back to PowerShell hashtable BK-tree |
| `-NoFuzzy` switch set | Stage 3 skipped entirely; returns `$null` and caches the miss |
| Player/Entity dedup | `Gracz`/`Postac` entity entries defer to `Player` entries in collisions |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/resolve-name.Tests.ps1` | All 4 stages, type filtering, cache behavior, edge cases |
| `tests/get-nameindex.Tests.ps1` | Priority collision, ambiguity, stem index, BK-tree construction |
| `tests/get-entity-mapa.Tests.ps1` | @slug indexing at priority 1, slug-based resolution via `Resolve-Name` |

---

## Related Documents

- [ENTITIES.md](ENTITIES.md) — Entity name resolution in `Get-EntityState` (uses `Resolve-Name` internally)
- [SESSIONS.md](SESSIONS.md) — Mention extraction and narrator resolution (uses `Resolve-Name`)
- [MIGRATION.md](MIGRATION.md) — Entity State Pipeline describes name resolution in context
- [REST-API.md](REST-API.md) — REST API `/resolve` endpoint and RSQL filter alias resolution via `ApiNameDictionary`

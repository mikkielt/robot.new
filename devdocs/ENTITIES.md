# Entity System

---

## Scope

The entity subsystem consists of `Get-Entity` (registry parsing, multi-file merge, canonical names), `Get-EntityState` (session override merging), and the three-layer character state merge in `Get-PlayerCharacter -IncludeState`.

Entity write operations are documented in [ENTITY-WRITES.md](ENTITY-WRITES.md). Character file format is documented in [CHARFILE.md](CHARFILE.md).

---

## Architecture Overview

```
Pass 1:  Get-Entity ──> Entity objects (file data only)
              │
              ├── Multi-file merge (numeric primacy)
              ├── @tag parsing + temporal scoping
              └── Canonical Name (CN) resolution

Pass 2:  Get-EntityState ──> Enriched entity objects
              │
              ├── Get-Entity (pass 1 output)
              ├── Get-Session (extracts Zmiany blocks)
              └── Chronological override application

Pass 3:  Get-PlayerCharacter -IncludeState ──> Three-layer character state
              │
              ├── Layer 1: Character file (undated baseline)
              ├── Layers 2+3: Get-EntityState result (entities.md + session Zmiany)
              └── Scalar: last-dated wins. Multi-valued: all active collected.
```

---

## `Get-Entity` — Registry Parsing

All temporal helpers live in `private/temporal-helpers.ps1`, which is dot-sourced by consuming files (`get-entity.ps1`, `get-entitystate.ps1`, `get-session.ps1`, etc.).

| Function | Purpose |
|---|---|
| `ConvertFrom-ValidityString` | Splits `"Value (2025-02:)"` into `{ Text, ValidFrom, ValidTo, Season }` |
| `Resolve-PartialDate` | Expands `YYYY` -> full year, `YYYY-MM` -> month bounds (uses `DaysInMonth`) |
| `Resolve-SeasonForDate` | Returns Polish season name (`wiosna`/`lato`/`jesień`/`zima`) for a given date |
| `Test-TemporalActivity` | Checks if item falls within `-ActiveOn` date window; `$null` bounds always pass. Also checks seasonal constraint. |
| `Get-NestedBulletText` | Collects child bullet text passing temporal filter; uses `RuntimeHelpers.GetHashCode()` for parent lookup |
| `Get-LastActiveValue` | Returns last active entry from a history list |
| `Get-AllActiveValues` | Returns all active entries as `string[]` |
| `ConvertTo-SessionDate` | Parses a `yyyy-MM-dd` date string via `TryParseExact`. Returns `[datetime]` on success, `$null` on failure. Used by session and reporting consumers that need strict date parsing without exceptions. |
| `ConvertFrom-CoordinateString` | Parses `"X, Y"` coordinate strings from `@koordynaty` tag values. Splits on comma, `TryParse`s both parts as `[int]`. Returns `@{ X = [int]; Y = [int] }` on success, `$null` on malformed input. |
| `Resolve-EntityCN` | Builds hierarchical canonical names for locations via `@lokacja` chain (in `public/get-entity.ps1`) |

Module-level regex patterns (defined at `$script:` scope in `temporal-helpers.ps1`):

| Variable | Purpose |
|---|---|
| `$ValidityPattern` | Captures text and optional parenthetical content from validity strings |
| `$DateRangePattern` | Matches `start:end` patterns within parenthetical content |
| `$SessionDatePattern` | Matches `YYYY-MM-DD` with optional `/DD` range suffix in session headers |
| `$SeasonKeywords` | `HashSet[string]` of valid Polish season keywords (`wiosna`, `lato`, `jesień`, `zima`) |

`Resolve-PartialDate` accepts partial date strings and expands them to `[datetime]` values. The `-IsEnd` flag controls which boundary is resolved.

| Parameter | Type | Description |
|---|---|---|
| `DateStr` | string | Partial or full date: `YYYY`, `YYYY-MM`, or `YYYY-MM-DD` |
| `IsEnd` | bool | When `$true`, resolves to last day of period; when `$false`, resolves to first day |

Expansion rules:
- `YYYY` + `IsEnd=$false` -> `YYYY-01-01`; `IsEnd=$true` -> `YYYY-12-31`
- `YYYY-MM` + `IsEnd=$false` -> `YYYY-MM-01`; `IsEnd=$true` -> `YYYY-MM-{DaysInMonth}`
- `YYYY-MM-DD` -> used as-is
- Empty/whitespace -> `$null`
- Unparseable -> `$null` (caught via `ParseExact` try/catch)

`Resolve-SeasonForDate` maps a `[datetime]` to a Polish season name. Supports custom season mappings via `$script:CachedSeasonMapping` (loaded from `local.config.psd1`); falls back to default meteorological seasons.

| Parameter | Type | Description |
|---|---|---|
| `Date` | datetime | Mandatory. The date to resolve. |

Default mapping (meteorological seasons):
- Months 3-5 — `wiosna` (spring)
- Months 6-8 — `lato` (summer)
- Months 9-11 — `jesień` (autumn)
- Months 12, 1-2 — `zima` (winter)

`Get-NestedBulletText` collects text from child bullets of a parent list item, filtered through `Test-TemporalActivity`.

| Parameter | Type | Description |
|---|---|---|
| `ParentBullet` | object | The parent list item object |
| `ChildrenOf` | hashtable | Identity-based lookup built via `RuntimeHelpers.GetHashCode()` |
| `ActiveOn` | datetime? | Temporal filter; `$null` passes all children |

Returns a single newline-joined string of all temporally-active child texts, or `$null` when no children match.

`ConvertTo-SessionDate` is a strict date parser for `yyyy-MM-dd` strings. Uses `[datetime]::TryParseExact` with `InvariantCulture`.

| Parameter | Type | Description |
|---|---|---|
| `DateString` | string | Mandatory. Date string in `yyyy-MM-dd` format. |

Returns `[datetime]` on success, `$null` on failure. Used by session and reporting code that needs date parsing without try/catch overhead (e.g., batch processing session headers).

`ConvertFrom-CoordinateString` parses `@koordynaty` tag values in `"X, Y"` format into a typed hashtable.

| Parameter | Type | Description |
|---|---|---|
| `Text` | string | Mandatory. Coordinate string (e.g., `"15, 23"`). |

Splits on comma, trims whitespace, and `[int]::TryParse`s both parts. Returns `@{ X = [int]; Y = [int] }` on success, `$null` when the string has fewer than two parts or either part is non-numeric. Called by `Get-Entity` and `Get-EntityState` when processing `@koordynaty` tags.

---

## Multi-File Merge

Entity registry files: `entities.md` and `*-NNN-ent.md` variants.

Sorting: Files sorted by numeric key descending. `entities.md` has sort key `MaxValue` (processed first, lowest primacy). Lower numbers are processed last, giving highest override primacy.

Merge rules: Same-name entities across files have their histories concatenated. Names, aliases, overrides, and all history lists are combined.

All files are loaded in a single `Get-Markdown` call for efficiency.

---

## Entity Type Sections

Level-2 headers define entity type sections, mapped via `$TypeMap`:

| Section header | Entity type |
|---|---|
| `## NPC` | NPC |
| `## Grupa` | Grupa |
| `## Lokacja` | Lokacja |
| `## Mapa` | Mapa |
| `## Gracz` | Gracz |
| `## Postać` | Postać |
| `## Przedmiot` | Przedmiot |

---

## @Tag Recognition

| Tag | Type | Property | Behavior |
|---|---|---|---|
| `@alias` | Temporal | `Aliases`, `Names` | Alternative names with validity ranges |
| `@lokacja` | Temporal | `Location`, `LocationHistory` | Location assignment / containment |
| `@drzwi` | Temporal | `Doors`, `DoorHistory` | Physical access connections. For Lokacja entities, active doors generate path-qualified names in `Names` (e.g. "Steadwick/Grota") |
| `@typ` | Temporal | `Type`, `TypeHistory` | Entity type override |
| `@należy_do` | Temporal | `Owner`, `OwnerHistory` | Ownership (entity -> player) |
| `@grupa` | Temporal | `Groups`, `GroupHistory` | Group/faction membership |
| `@status` | Temporal | `Status`, `StatusHistory` | `Aktywny`/`Nieaktywny`/`Usunięty` |
| `@ilość` | Temporal | `Quantity`, `QuantityHistory` | Item quantity (used for stackable items such as currency). Accepts integer values. In Zmiany blocks, supports `+N`/`-N` delta syntax to add/subtract from current quantity. |
| `@plik` | Temporal | `FilePath`, `FilePathHistory` | Relative path to the entity's file (e.g. character `.md` file). Supports temporal ranges for entities whose file reference changes over time. Populated automatically by `New-PlayerCharacter` and during migration from `Gracze.md` link paths. |
| `@nazwa_nerthus` | Temporal | `NerthusName`, `NerthusNameHistory` | RP override name for the entity. Active value added to `Names` for resolution. Scalar semantics: last-active-wins (like `@lokacja`). |
| `@slug` | Temporal | `Names` | Unique disambiguator string. Active value added to `Names` HashSet for resolution. Used to distinguish same-name entities (e.g., multiple "Komnata Rady" under different parents). No dedicated property — resolved via the name index like `@alias`. |
| `@koordynaty` | Temporal | `Coordinates`, `CoordinateHistory` | Map tile coordinates as `X, Y` (32x32px tile units). Active value: `@{ X = [int]; Y = [int] }` or `$null` for interiors. Presence implies exterior location (has a world-map position). |
| `@zawiera` | Non-temporal | `Contains` | Child containment declaration |
| `@generyczne_nazwy` | Non-temporal | `GenericNames`, `Names` | Comma-delimited generic names for the entity (e.g. "Straznik Miasta, Wartownik"). Added to `Names` for resolution. |
| Any other `@tag` | Temporal | `Overrides[tag]` | Generic key-value storage |

---

## Temporal Validity Ranges

Format: `(YYYY-MM:YYYY-MM)`, `(YYYY-MM:)`, `(:YYYY-MM)`, or absent (always active).

Partial dates resolved via `Resolve-PartialDate`:
- Start bound -> first day of period (`YYYY-01-01`, `YYYY-MM-01`)
- End bound -> last day of period (`YYYY-12-31`, `YYYY-MM-{DaysInMonth}`)

Seasonal markers: `(zima)`, `(lato)`, `(wiosna)`, `(jesień)` — or combined with date ranges: `(2024-01:, zima)`. All history entry objects include a `Season` property (`$null` when not seasonal). `Test-TemporalActivity` checks both date bounds and season match.

For Lokacja and Mapa entities with active `@drzwi` entries, path-qualified names are generated and added to `Names`:

```
Gwizdząca Grota with @drzwi: Steadwick and @drzwi: Czerwona Twierdza
-> Names: { "Gwizdząca Grota", "Steadwick/Gwizdząca Grota", "Czerwona Twierdza/Gwizdząca Grota" }
```

These path-qualified names enable session `@Lokacje` references like "Steadwick/Gwizdząca Grota" to resolve to the correct entity via the name index. CN remains single-valued (`Resolve-EntityCN` unchanged).

---

## Parent-Child Lookup Optimization

Uses `RuntimeHelpers.GetHashCode()` for O(1) identity-based parent lookups:

```powershell
$ParentId = [RuntimeHelpers]::GetHashCode($LI.ParentListItem)
$ChildrenOf[$ParentId].Add($LI)
```

Single O(n) pass builds the lookup hashtable, avoiding O(n^2) repeated `.Where()` filtering.

---

## Canonical Name Resolution

`Resolve-EntityCN` builds canonical names (CN) for entities.

Non-location/map entities use flat `Type/Name` paths (e.g., `NPC/Sandro`).

Lokacja and Mapa entities use hierarchical paths built by walking the `@lokacja` chain upward:

```
Resolve-EntityCN("Zamek Steadwick"):
    @lokacja = "Erathia"
    Resolve-EntityCN("Erathia"):
        @lokacja = "Antagarich"
        Resolve-EntityCN("Antagarich"):
            @lokacja = null -> "Lokacja/Antagarich"
        -> "Lokacja/Antagarich/Erathia"
    -> "Lokacja/Antagarich/Erathia/Zamek Steadwick"
```

Cycle detection uses a `HashSet[string]` of visited entity names. Warns to stderr and falls back to flat CN on cycle. A memoization cache dictionary prevents recomputation of already-resolved CNs.

---

## `Get-EntityState` — Session Override Merge

The function uses a two-pass architecture:

1. Input — Entities from `Get-Entity` + sessions from `Get-Session`
2. Filter — Sessions with `Changes` property and valid dates, sorted chronologically
3. Apply — Each session's Zmiany entries are applied to entity objects

For each entity name in Zmiany blocks, the name resolution pipeline applies:

```
1. Exact entity lookup (case-insensitive dictionary)
2. Fuzzy Resolve-Name (stem, Levenshtein)
3. If fuzzy returns a Player object -> search Player.Names for matching entity
4. If all fail -> warn to stderr, skip change
```

Tags in `- Zmiany:` without explicit temporal ranges receive the session date as `ValidFrom` (open-ended). Tags with explicit `(YYYY-MM:YYYY-MM)` ranges use those instead.

In Zmiany blocks, `@ilość` supports delta syntax:
- `@ilość: +25` -> adds 25 to the current quantity
- `@ilość: -3` -> subtracts 3 from the current quantity
- `@ilość: 100` -> sets absolute value (backward compatible)

When a `+N` or `-N` pattern is detected, the system looks up the last active quantity value and computes the new absolute value. If no prior quantity exists, the base is treated as 0. The computed absolute value is stored in `QuantityHistory` so downstream code is unaffected.

For each resolved entity change, the system appends to the appropriate history list (`LocationHistory`, `GroupHistory`, `StatusHistory`, `Overrides[tag]`, etc.) and tracks the entity in the `ModifiedEntities` HashSet.

After all sessions are processed, for each modified entity: all history lists are sorted by `ValidFrom` (custom comparer: `$null` sorts first so always-active entries are stable at start), and active values are recomputed via `Get-LastActiveValue` / `Get-AllActiveValues`.

Performance optimizations:
- NameIndex reuse — Callers processing multiple `Get-EntityState` invocations with the same entity set (e.g., `Get-EconomicTimeline`) can pre-build the name index via `Get-NameIndex` and pass it via `-NameIndex` to avoid repeated BK-tree construction.
- Lazy currency loading — `private/currency-helpers.ps1` is dot-sourced only when the first session with `Transfers` is encountered. A `CurrencyLookup` dictionary (from `Build-CurrencyEntityLookup`) is built once and reused for all `Find-CurrencyEntity` calls within the invocation.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-Entity` (auto-fetched if omitted) |
| `Sessions` | object[] | Pre-fetched from `Get-Session` (auto-fetched if omitted) |
| `Players` | object[] | Pre-fetched from `Get-Player` (auto-fetched if omitted) |
| `NameIndex` | hashtable | Pre-built name index from `Get-NameIndex`. When provided, avoids redundant BK-tree rebuild. |
| `ProgressCallback` | scriptblock | Optional callback for CLI progress reporting. Invoked with `(Current, Total, ItemDetail)` every 10 sessions and on completion. |
| `ActiveOn` | datetime | Temporal filter for merged state |

---

## Three-Layer Character State Merge

Performed by `Get-PlayerCharacter -IncludeState`.

| Layer | Source | Temporal behavior |
|---|---|---|
| 1 (Baseline) | Character `.md` file (`Read-CharacterFile`) | Undated - always active, sorts before dated entries |
| 2+3 (Overrides) | `Get-EntityState` result (entities.md + session Zmiany, already merged) | Temporal ranges parsed via `ConvertFrom-ValidityString` |

Scalar properties: last active value wins (most recent `ValidFrom`).

Multi-valued properties: all active values collected.

Merged properties: `Status`, `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (Positive/Neutral/Negative), `AdditionalNotes`, `DescribedSessions`.

Characters with `Status = 'Usuniety'` are excluded unless `-IncludeDeleted`.

---

## Entity Object Schema

| Property | Type | Description |
|---|---|---|
| `Name` | string | Canonical display name |
| `CN` | string | Hierarchical canonical name |
| `Names` | `HashSet[string]` | All resolvable names (OrdinalIgnoreCase) |
| `Aliases` | `List[object]` | Time-scoped alias objects `{ Text, ValidFrom, ValidTo }` |
| `Type` | string | Entity type |
| `Owner` | string | Owning player name |
| `Location` | string | Active location |
| `LocationHistory` | `List[object]` | All location assignments with validity ranges |
| `Groups` | string[] | Active group memberships |
| `GroupHistory` | `List[object]` | Full group history |
| `Status` | string | Active status (`Aktywny` default) |
| `StatusHistory` | `List[object]` | Status changes with validity ranges |
| `Quantity` | string | Active quantity (for stackable items such as currency) |
| `QuantityHistory` | `List[object]` | Quantity changes with validity ranges |
| `FilePath` | string | Active file path (from `@plik`; `$null` when absent) |
| `FilePathHistory` | `List[object]` | File path changes with validity ranges |
| `GenericNames` | `List[string]` | Generic names for the entity (from `@generyczne_nazwy`) |
| `Doors` | string[] | Active physical access connections |
| `DoorHistory` | `List[object]` | Full door history |
| `NerthusName` | string | Active RP override name (from `@nazwa_nerthus`; `$null` when absent) |
| `NerthusNameHistory` | `List[object]` | NerthusName changes with validity ranges |
| `Coordinates` | hashtable | Active map coordinates `@{ X = [int]; Y = [int] }` (from `@koordynaty`; `$null` for interiors) |
| `CoordinateHistory` | `List[object]` | Coordinate changes with validity ranges (`X`, `Y`, `ValidFrom`, `ValidTo`, `Season`) |
| `Contains` | `List[string]` | Child entity names |
| `Overrides` | hashtable | Generic `@tag` -> value list dictionary |
| `TypeHistory` | `List[object]` | Type changes with validity ranges |
| `OwnerHistory` | `List[object]` | Ownership changes with validity ranges |

---

## Player Object (`Get-Player`)

| Property | Type | Description |
|---|---|---|
| `Name` | string | Player's display name (from level-3 header) |
| `Names` | `HashSet[string]` | All resolvable names (player + characters + aliases) |
| `MargonemID` | string | Margonem game ID |
| `PRFWebhook` | string | Discord webhook URL for notifications |
| `Triggers` | string[] | Restricted session topics |
| `Characters` | `List[object]` | Character objects (see below) |

---

## Character Object (nested in Player)

| Property | Type | Description |
|---|---|---|
| `Name` | string | Character name |
| `IsActive` | bool | Whether this is the player's active character |
| `Aliases` | string[] | Alternative names |
| `Path` | string | Relative path to character file (from `Gracze.md` link or `@plik` entity tag) |
| `PUExceeded` | decimal? | PU exceeded/overflow value |
| `PUStart` | decimal? | Starting PU value |
| `PUSum` | decimal? | Total PU value |
| `PUTaken` | decimal? | PU earned (derived or explicit) |
| `AdditionalInfo` | string | Free-form notes |

---

## PlayerCharacter Object (`Get-PlayerCharacter`)

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Owning player's name |
| `Player` | object | Reference to parent Player object |
| `Name` | string | Character name |
| `IsActive` | bool | Whether this is the player's active character |
| `Aliases` | string[] | Alternative names |
| `Path` | string | Relative path to character file (from `Gracze.md` link or `@plik` entity tag) |
| `PUExceeded` | decimal? | PU exceeded/overflow value |
| `PUStart` | decimal? | Starting PU value |
| `PUSum` | decimal? | Total PU value |
| `PUTaken` | decimal? | PU earned (derived or explicit) |
| `AdditionalInfo` | string | Free-form notes |
| `Status` | string | Lifecycle status: `Aktywny`/`Nieaktywny`/`Usuniety` (only with `-IncludeState`) |
| `CharacterSheet` | string | Character sheet URL (only with `-IncludeState`) |
| `RestrictedTopics` | string | Restricted session topics (only with `-IncludeState`) |
| `Condition` | string | Character condition/health (only with `-IncludeState`) |
| `SpecialItems` | string[] | Special items list (only with `-IncludeState`) |
| `Reputation` | object | Three-tier reputation: Positive/Neutral/Negative arrays of `@{ Location; Detail }` (only with `-IncludeState`) |
| `AdditionalNotes` | string[] | Additional notes entries (only with `-IncludeState`) |
| `DescribedSessions` | object[] | Session entries from character file (only with `-IncludeState`) |

---

## Compiled C# Types

Three compiled C# types in the `Robot` namespace replace PowerShell-native `[PSCustomObject]` construction on the entity hot path. All are loaded via a single batch `Add-Type` call in `robot.psm1` at module import time (guarded by `PSTypeName` check to avoid recompilation). PowerShell fallback paths exist for all three when compilation fails.

`Robot.Entity` (`lib/EntityModel.cs`) is the central 27-property entity domain model. Each `Get-Entity` invocation constructs one `Robot.Entity` instance per registered entity. Collection properties (`Names`, `Aliases`, `Groups`, `Doors`, `Coordinates`, all `*History` lists, `Overrides`, `GenericNames`, `Contains`, `UnresolvedTransfers`) are typed as `object` to preserve compatibility with PowerShell's `List[object]` creation pattern and the `Comparison[object]` sort delegates used by `Robot.TemporalSorter`. PowerShell accesses these via dynamic dispatch (`.Count`, `.Add()`, `.Sort()`, indexer).

Consumers: `Get-Entity` (construction at lines 423/715), `Get-EntityState` (mutation of history lists, resorting), `Get-Player`, `Get-NameIndex`, `Resolve-Name`, `Get-EntityHistory`, CLI entity display, all reporting functions.

Fallback: When `Robot.Entity` is unavailable, `get-entity.ps1` falls back to `[PSCustomObject]@{}` with identical property names. Downstream code is unaffected because both paths expose the same property surface.

`Robot.TemporalEntry` / `Robot.CoordinateTemporalEntry` (`lib/TemporalEntry.cs`) are lightweight temporal value containers for entity history list entries.

`Robot.TemporalEntry` unifies all domain-specific property names (Location, Type, Owner, Group, Status, Quantity, FilePath, NerthusName, alias text) into a single `Value` field:

| Property | Type | Description |
|---|---|---|
| `Value` | `string` | The domain value (location name, status string, quantity, etc.) |
| `ValidFrom` | `DateTime?` | Start of validity range (`$null` = always active) |
| `ValidTo` | `DateTime?` | End of validity range (`$null` = open-ended) |
| `Season` | `string` | Polish season keyword (`$null` when not seasonal) |

`Robot.CoordinateTemporalEntry` carries `X`/`Y` integer fields instead of a string `Value`. Used exclusively by `@koordynaty` history entries.

| Property | Type | Description |
|---|---|---|
| `X` | `int` | Horizontal tile coordinate |
| `Y` | `int` | Vertical tile coordinate |
| `ValidFrom` | `DateTime?` | Start of validity range |
| `ValidTo` | `DateTime?` | End of validity range |
| `Season` | `string` | Polish season keyword |

Both types provide a default constructor and a parameterized constructor for inline creation (`[Robot.TemporalEntry]::new($Value, $ValidFrom, $ValidTo, $Season)`).

History lists are sorted by `ValidFrom` via `Robot.TemporalSorter` (see `lib/TemporalSorter.cs`), with `$null` sorting before dated entries so always-active items remain stable at the start.

Consumers: `get-entity.ps1` (construction in both C# and PowerShell paths), `get-entitystate.ps1` (session override application, `@Transfer` quantity deltas), `Get-EntityHistory`, `Get-LastActiveValue`, `Get-AllActiveValues`.

`Robot.EntityTagParser` (`lib/EntityTagParser.cs`) is a compiled 14-way entity tag dispatcher that replaces the per-bullet PowerShell tag parsing loop in `get-entity.ps1`.

API: `[Robot.EntityTagParser]::Parse($Texts, $ParentIndices, $Indents, $ValidityPattern, $DateRangePattern, $ActiveOn)` — static method accepting flat parallel arrays from `MarkdownScanner` output for a single entity type section.

Two-phase processing:

1. Phase 1 — Builds a `Dictionary<int, List<int>>` parent-to-children index in O(n) over the flat arrays, identifying root bullets (indent level 0) and child bullets.
2. Phase 2 — Iterates root bullets. For each root, dispatches child bullets through a 14-way tag prefix match:

| Tags (temporal) | Tags (non-temporal) |
|---|---|
| `@lokacja`, `@drzwi`, `@typ`, `@nalezy_do`, `@grupa`, `@status`, `@ilosc`, `@alias`, `@plik`, `@nazwa_nerthus`, `@slug`, `@koordynaty` | `@zawiera`, `@generyczne_nazwy` |

Unrecognized `@`-prefixed tags fall through to a generic overrides bucket (`Dictionary<string, List<string>>`).

Inlined logic: `ConvertFrom-ValidityString` is inlined as the private `ParseValidity` method, handling four syntactic forms: plain value, date range, season keyword, and combined date+season. `ResolvePartialDate` expands `YYYY`/`YYYY-MM` abbreviations to full `DateTime` bounds. Non-temporal parentheticals (no colon, not a season keyword) are preserved as literal name parts for backward compatibility with entity names like "Rada (Ithan)".

Temporal filtering: The `activeOn` parameter enables parse-time filtering for `@alias`, `@slug`, and generic override tags. Other temporal tags are returned unfiltered for downstream resolution by the PowerShell merge path. Season check uses default meteorological mapping only — custom season boundaries from `local.config.psd1` are not accessible from C#.

Output: `EntityParseResult` containing an array of `EntityTagEntry` objects (one per root entity bullet). Each entry carries typed `List<TemporalEntry>` fields for all temporal history properties and `List<string>` fields for non-temporal tags. The PowerShell merge path calls `.AddRange()` on each history list to accumulate across multiple entity definition file sections.

Dispatch: `get-entity.ps1` checks `([PSTypeName]'Robot.EntityTagParser').Type` at runtime and uses the C# path when available (line 276), falling back to the equivalent PowerShell loop (line 457+) when not compiled.

Consumer: `get-entity.ps1` (sole consumer via `[Robot.EntityTagParser]::Parse`).

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Circular `@lokacja` references | Detected via `HashSet`; warns, falls back to flat CN |
| Missing parent in `@lokacja` chain | Uses parent name as-is if entity not registered |
| Null/empty validity dates | Returns `$null`; item considered always active |
| `YYYY-02` end bound | Resolves to last day of February (auto-calculated via `DaysInMonth`) |
| Duplicate entity names across files | Merged: histories concatenated |
| Unresolved entity name in Zmiany | Warns to stderr, skips change |
| Player/Entity dedup in resolution | When fuzzy match returns Player, maps back via `Player.Names` |
| `$null` `ValidFrom` in history sorting | Sorts before dated entries (always-active items stable at start) |
| Missing `StatusHistory` | Lazily created before appending |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/get-entity.Tests.ps1` | Multi-file merge, @tag parsing, temporal filtering, CN resolution, cycle detection |
| `tests/get-entitystate.Tests.ps1` | Session override application, auto-dating, name resolution, history resorting |
| `tests/get-playercharacter.Tests.ps1` | Flat projection, filters, pass-through entities |
| `tests/get-playercharacter-state.Tests.ps1` | Three-layer merge, IncludeState, IncludeDeleted |
| `tests/entity-status.Tests.ps1` | Status lifecycle, temporal status transitions |
| `tests/przedmiot-entity.Tests.ps1` | Przedmiot type mappings, entity creation, duplicate detection |
| `tests/currency-entity.Tests.ps1` | Currency entity creation, @ilosc tag handling, quantity updates |
| `tests/get-entity-mapa.Tests.ps1` | Mapa type parsing, @slug resolution, @url/@url_nerthus overrides, hierarchical CN, door-paths |

Fixtures: `entities.md`, `entities-100-ent.md`, `entities-200-ent.md`, `sessions-zmiany.md`, `entities-mapa.md`, `entities-slug.md`.

---

## Related Documents

- [ENTITY-WRITES.md](ENTITY-WRITES.md) — Write operations on entity files
- [CHARFILE.md](CHARFILE.md) — Character file format (Layer 1 of three-layer merge)
- [SESSIONS.md](SESSIONS.md) — Session Zmiany extraction
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) — Name resolution used by `Get-EntityState`
- [CURRENCY.md](CURRENCY.md) — Currency tracking system (denominations, @Transfer, reconciliation)
- [LOCATION-GRAPH.md](LOCATION-GRAPH.md) — Location graph (coordinates, route edges, transition edges)
- [STRUCTURES.md](STRUCTURES.md) — Canonical data structure reference (Entity, Session, Player, etc.)
- [MIGRATION.md](MIGRATION.md) — Data Model Transition
- [REST-API.md](REST-API.md) — REST API entity endpoints, RSQL filtering, serializer Entity fast path

# Entity System — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the entity subsystem: `Get-Entity` (registry parsing, multi-file merge, canonical names), `Get-EntityState` (session override merging), and the three-layer character state merge in `Get-PlayerCharacter -IncludeState`.

**Not covered**: Entity write operations — see [ENTITY-WRITES.md](ENTITY-WRITES.md). Character file format — see [CHARFILE.md](CHARFILE.md).

---

## 2. Architecture Overview

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

## 3. `Get-Entity` — Registry Parsing

### 3.1 Helper Functions

| Function | Purpose |
|---|---|
| `ConvertFrom-ValidityString` | Splits `"Value (2025-02:)"` into `{ Text, ValidFrom, ValidTo }` |
| `Resolve-PartialDate` | Expands `YYYY` → full year, `YYYY-MM` → month bounds (uses `DaysInMonth`) |
| `Test-TemporalActivity` | Checks if item falls within `-ActiveOn` date window; `$null` bounds always pass |
| `Get-NestedBulletText` | Collects child bullet text passing temporal filter; uses `RuntimeHelpers.GetHashCode()` for parent lookup |
| `Get-LastActiveValue` | Returns last active entry from a history list |
| `Get-AllActiveValues` | Returns all active entries as `string[]` |
| `Resolve-EntityCN` | Builds hierarchical canonical names for locations via `@lokacja` chain |

### 3.2 Multi-File Merge

Entity registry files: `entities.md` and `*-NNN-ent.md` variants.

**Sorting**: Files sorted by numeric key descending. `entities.md` has sort key `MaxValue` (processed first, lowest primacy). Lower numbers are processed last → highest override primacy.

**Merge rules**: Same-name entities across files have their histories **concatenated**, not replaced. Names, aliases, overrides, and all history lists are combined.

All files are loaded in a single `Get-Markdown` call for efficiency.

### 3.3 Entity Type Sections

Level-2 headers define entity type sections, mapped via `$TypeMap`:

| Section header | Entity type |
|---|---|
| `## NPC` | NPC |
| `## Organizacja` | Organizacja |
| `## Lokacja` | Lokacja |
| `## Gracz` | Gracz |
| `## Postać (Gracz)` | Postać (Gracz) |
| `## Przedmiot` | Przedmiot |

### 3.4 @Tag Recognition

| Tag | Type | Property | Behavior |
|---|---|---|---|
| `@alias` | Temporal | `Aliases`, `Names` | Alternative names with validity ranges |
| `@lokacja` | Temporal | `Location`, `LocationHistory` | Location assignment / containment |
| `@drzwi` | Temporal | `Doors`, `DoorHistory` | Physical access connections |
| `@typ` | Temporal | `Type`, `TypeHistory` | Entity type override |
| `@należy_do` | Temporal | `Owner`, `OwnerHistory` | Ownership (entity → player) |
| `@grupa` | Temporal | `Groups`, `GroupHistory` | Group/faction membership |
| `@status` | Temporal | `Status`, `StatusHistory` | `Aktywny`/`Nieaktywny`/`Usunięty` |
| `@ilość` | Temporal | `Quantity`, `QuantityHistory` | Item quantity (used for stackable items such as currency). Accepts integer values. In Zmiany blocks, supports `+N`/`-N` delta syntax to add/subtract from current quantity. |
| `@zawiera` | Non-temporal | `Contains` | Child containment declaration |
| `@generyczne_nazwy` | Non-temporal | `GenericNames`, `Names` | Comma-delimited generic names for the entity (e.g. "Strażnik Miasta, Wartownik"). Added to `Names` for resolution. |
| Any other `@tag` | Temporal | `Overrides[tag]` | Generic key-value storage |

### 3.5 Temporal Validity Ranges

Format: `(YYYY-MM:YYYY-MM)`, `(YYYY-MM:)`, `(:YYYY-MM)`, or absent (always active).

Partial dates resolved via `Resolve-PartialDate`:
- Start bound → first day of period (`YYYY-01-01`, `YYYY-MM-01`)
- End bound → last day of period (`YYYY-12-31`, `YYYY-MM-{DaysInMonth}`)

### 3.6 Parent-Child Lookup Optimization

Uses `RuntimeHelpers.GetHashCode()` for O(1) identity-based parent lookups:

```powershell
$ParentId = [RuntimeHelpers]::GetHashCode($LI.ParentListItem)
$ChildrenOf[$ParentId].Add($LI)
```

Single O(n) pass builds the lookup hashtable, avoiding O(n²) repeated `.Where()` filtering.

### 3.7 Canonical Name Resolution (`Resolve-EntityCN`)

**Non-location entities**: `Type/Name` (e.g., `NPC/Sandro`)

**Location entities**: Hierarchical paths built by walking the `@lokacja` chain upward:

```
Resolve-EntityCN("Zamek Steadwick"):
    @lokacja = "Erathia"
    Resolve-EntityCN("Erathia"):
        @lokacja = "Antagarich"
        Resolve-EntityCN("Antagarich"):
            @lokacja = null → "Lokacja/Antagarich"
        → "Lokacja/Antagarich/Erathia"
    → "Lokacja/Antagarich/Erathia/Zamek Steadwick"
```

**Cycle detection**: `HashSet[string]` of visited entity names. Warns to stderr and falls back to flat CN on cycle.

**Memoization**: Cache dictionary prevents recomputation of already-resolved CNs.

---

## 4. `Get-EntityState` — Session Override Merge

### 4.1 Two-Pass Architecture

1. **Input**: Entities from `Get-Entity` + sessions from `Get-Session`
2. **Filter**: Sessions with `Changes` property and valid dates, sorted chronologically
3. **Apply**: Each session's Zmiany entries are applied to entity objects

### 4.2 Name Resolution Pipeline

For each entity name in Zmiany blocks:

```
1. Exact entity lookup (case-insensitive dictionary)
2. Fuzzy Resolve-Name (stem, Levenshtein)
3. If fuzzy returns a Player object → search Player.Names for matching entity
4. If all fail → warn to stderr, skip change
```

### 4.3 Auto-Dating

Tags in `- Zmiany:` without explicit temporal ranges receive the session date as `ValidFrom` (open-ended). Tags with explicit `(YYYY-MM:YYYY-MM)` ranges use those instead.

### 4.4 `@ilość` Arithmetic Deltas

In Zmiany blocks, `@ilość` supports delta syntax:
- `@ilość: +25` → adds 25 to the current quantity
- `@ilość: -3` → subtracts 3 from the current quantity
- `@ilość: 100` → sets absolute value (backward compatible)

When a `+N` or `-N` pattern is detected, the system looks up the last active quantity value and computes the new absolute value. If no prior quantity exists, the base is treated as 0. The computed absolute value is stored in `QuantityHistory` so downstream code is unaffected.

### 4.5 Override Application

For each resolved entity change:
- Append to appropriate history list (`LocationHistory`, `GroupHistory`, `StatusHistory`, `Overrides[tag]`, etc.)
- Track entity in `ModifiedEntities` HashSet

### 4.5 History Resorting

After all sessions processed, for each modified entity:
1. Sort all history lists by `ValidFrom` (custom comparer: `$null` sorts first → always-active entries stable at start)
2. Recompute active values via `Get-LastActiveValue` / `Get-AllActiveValues`

### 4.7 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-Entity` (auto-fetched if omitted) |
| `Sessions` | object[] | Pre-fetched from `Get-Session` (auto-fetched if omitted) |
| `ActiveOn` | datetime | Temporal filter for merged state |

---

## 5. Three-Layer Character State Merge

Performed by `Get-PlayerCharacter -IncludeState`.

| Layer | Source | Temporal behavior |
|---|---|---|
| 1 (Baseline) | Character `.md` file (`Read-CharacterFile`) | Undated — always active, sorts before dated entries |
| 2+3 (Overrides) | `Get-EntityState` result (entities.md + session Zmiany, already merged) | Temporal ranges parsed via `ConvertFrom-ValidityString` |

**Scalar properties**: Last active value wins (most recent `ValidFrom`).

**Multi-valued properties**: All active values collected.

**Merged properties**: `Status`, `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (Positive/Neutral/Negative), `AdditionalNotes`, `DescribedSessions`.

Characters with `Status = 'Usunięty'` are excluded unless `-IncludeDeleted`.

---

## 6. Entity Object Schema

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
| `GenericNames` | `List[string]` | Generic names for the entity (from `@generyczne_nazwy`) |
| `Doors` | string[] | Active physical access connections |
| `DoorHistory` | `List[object]` | Full door history |
| `Contains` | `List[string]` | Child entity names |
| `Overrides` | hashtable | Generic `@tag` → value list dictionary |
| `TypeHistory` | `List[object]` | Type changes with validity ranges |
| `OwnerHistory` | `List[object]` | Ownership changes with validity ranges |

### Player Object (`Get-Player`)

| Property | Type | Description |
|---|---|---|
| `Name` | string | Player's display name (from level-3 header) |
| `Names` | `HashSet[string]` | All resolvable names (player + characters + aliases) |
| `MargonemID` | string | Margonem game ID |
| `PRFWebhook` | string | Discord webhook URL for notifications |
| `Triggers` | string[] | Restricted session topics |
| `Characters` | `List[object]` | Character objects (see below) |

### Character Object (nested in Player)

| Property | Type | Description |
|---|---|---|
| `Name` | string | Character name |
| `IsActive` | bool | Whether this is the player's active character |
| `Aliases` | string[] | Alternative names |
| `Path` | string | Markdown file path |
| `PUExceeded` | decimal? | PU exceeded/overflow value |
| `PUStart` | decimal? | Starting PU value |
| `PUSum` | decimal? | Total PU value |
| `PUTaken` | decimal? | PU earned (derived or explicit) |
| `AdditionalInfo` | string | Free-form notes |

### PlayerCharacter Object (`Get-PlayerCharacter`)

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Owning player's name |
| `Player` | object | Reference to parent Player object |
| `Name` | string | Character name |
| `IsActive` | bool | Whether this is the player's active character |
| `Aliases` | string[] | Alternative names |
| `Path` | string | Markdown file path |
| `PUExceeded` | decimal? | PU exceeded/overflow value |
| `PUStart` | decimal? | Starting PU value |
| `PUSum` | decimal? | Total PU value |
| `PUTaken` | decimal? | PU earned (derived or explicit) |
| `AdditionalInfo` | string | Free-form notes |
| `Status` | string | Lifecycle status: `Aktywny`/`Nieaktywny`/`Usunięty` (only with `-IncludeState`) |
| `CharacterSheet` | string | Character sheet URL (only with `-IncludeState`) |
| `RestrictedTopics` | string | Restricted session topics (only with `-IncludeState`) |
| `Condition` | string | Character condition/health (only with `-IncludeState`) |
| `SpecialItems` | string[] | Special items list (only with `-IncludeState`) |
| `Reputation` | object | Three-tier reputation: Positive/Neutral/Negative arrays of `@{ Location; Detail }` (only with `-IncludeState`) |
| `AdditionalNotes` | string[] | Additional notes entries (only with `-IncludeState`) |
| `DescribedSessions` | object[] | Session entries from character file (only with `-IncludeState`) |

---

## 7. Edge Cases

| Scenario | Behavior |
|---|---|
| Circular `@lokacja` references | Detected via `HashSet`; warns, falls back to flat CN |
| Missing parent in `@lokacja` chain | Uses parent name as-is if entity not registered |
| Null/empty validity dates | Returns `$null`; item considered always active |
| `YYYY-02` end bound | Resolves to last day of February (auto-calculated via `DaysInMonth`) |
| Duplicate entity names across files | Merged: histories concatenated, not replaced |
| Unresolved entity name in Zmiany | Warns to stderr, skips change |
| Player/Entity dedup in resolution | When fuzzy match returns Player, maps back via `Player.Names` |
| `$null` `ValidFrom` in history sorting | Sorts before dated entries (always-active items stable at start) |
| Missing `StatusHistory` | Lazily created before appending |

---

## 8. Testing

| Test file | Coverage |
|---|---|
| `tests/get-entity.Tests.ps1` | Multi-file merge, @tag parsing, temporal filtering, CN resolution, cycle detection |
| `tests/get-entitystate.Tests.ps1` | Session override application, auto-dating, name resolution, history resorting |
| `tests/get-playercharacter.Tests.ps1` | Flat projection, filters, pass-through entities |
| `tests/get-playercharacter-state.Tests.ps1` | Three-layer merge, IncludeState, IncludeDeleted |
| `tests/entity-status.Tests.ps1` | Status lifecycle, temporal status transitions |
| `tests/przedmiot-entity.Tests.ps1` | Przedmiot type mappings, entity creation, duplicate detection |
| `tests/currency-entity.Tests.ps1` | Currency entity creation, @ilość tag handling, quantity updates |

Fixtures: `entities.md`, `entities-100-ent.md`, `entities-200-ent.md`, `sessions-zmiany.md`.

---

## 9. Related Documents

- [ENTITY-WRITES.md](ENTITY-WRITES.md) — Write operations on entity files
- [CHARFILE.md](CHARFILE.md) — Character file format (Layer 1 of three-layer merge)
- [SESSIONS.md](SESSIONS.md) — Session Zmiany extraction
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) — Name resolution used by `Get-EntityState`
- [MIGRATION.md](MIGRATION.md) — §1 Data Model Transition

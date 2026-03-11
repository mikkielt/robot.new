# Currency System - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the currency tracking subsystem: denomination constants, conversion utilities, currency entity identification, CRUD commands (`New-CurrencyEntity`, `Set-CurrencyEntity`, `Get-CurrencyEntity`, `Remove-CurrencyEntity`), reporting (`Get-CurrencyReport`), reconciliation (`Test-CurrencyReconciliation`), the `@Transfer` session directive, PU workflow integration, and out-of-game currency management patterns.

**Not covered**: General entity parsing - see [ENTITIES.md](ENTITIES.md). Generic entity write operations - see [ENTITY-WRITES.md](ENTITY-WRITES.md).

---

## 2. Architecture Overview

```
private/currency-helpers.ps1         Denomination constants, conversion, identification
    ├── $CurrencyDenominations       Canonical denomination definitions
    ├── ConvertTo-CurrencyBaseUnit   Amount -> Kogi conversion
    ├── ConvertFrom-CurrencyBaseUnit Kogi -> denomination breakdown
    ├── Resolve-CurrencyDenomination Stem/colloquial -> canonical denomination
    ├── Test-IsCurrencyEntity        Check if entity is currency
    ├── Find-CurrencyEntity          Find currency entity by denomination + owner
    └── Get-CurrencyEntitiesFiltered Identify, filter by status, and enrich currency entities

public/currency/                     Currency entity CRUD
    ├── New-CurrencyEntity           Create currency entity (denomination-validated, auto-named)
    ├── Set-CurrencyEntity           Update quantity (absolute/delta), owner, location
    ├── Get-CurrencyEntity           Filtered currency entity query with balance
    └── Remove-CurrencyEntity        Soft-delete with non-zero balance warning

public/reporting/get-currencyreport.ps1 Reporting command
    └── Get-CurrencyReport              Filtered currency holdings report

public/reporting/test-currencyreconciliation.ps1    Validation checks
    └── Test-CurrencyReconciliation                 7-check reconciliation report

public/reporting/get-economicsnapshot.ps1          Economic snapshot
    └── Get-EconomicSnapshot                       Point-in-time supply/distribution/Gini

public/reporting/get-economictimeline.ps1          Economic timeline
    └── Get-EconomicTimeline                       Monthly supply and transaction trends

public/reporting/get-materializationreport.ps1     Materialization report
    └── Get-MaterializationReport                  Physical vs virtual currency analysis

private/economy-helpers.ps1                        Shared economic helpers
    └── New-EconomicSnapshotData                 Supply breakdown, Gini, top holders

public/session/get-session.ps1                          @Transfer parsing (session-level directive)
public/get-entitystate.ps1                              @Transfer expansion (symmetric quantity deltas)
public/workflow/invoke-playercharacterpuassignment.ps1  -ReconcileCurrency integration
```

---

## 3. Denomination Constants

Defined in `private/currency-helpers.ps1` as `$script:CurrencyDenominations`:

| Name | Short | Tier | Multiplier (Kogi) | Stems |
|---|---|---|---|---|
| Korony Elanckie | Korony | Gold | 10000 | `kor` |
| Talary Hirońskie | Talary | Silver | 100 | `tal` |
| Kogi Skeltvorskie | Kogi | Copper | 1 | `kog` |

Exchange rates: 100 Kogi = 1 Talar, 100 Talarów = 1 Korona (10000 Kogi = 1 Korona).

---

## 4. Currency Entity Model

### 4.1 Entity Structure

Currency entities are `Przedmiot` entities with `@generyczne_nazwy` set to a canonical denomination name:

```markdown
## Przedmiot

* Korony Xeron Demonlorda
    - @generyczne_nazwy: Korony Elanckie
    - @należy_do: Xeron Demonlord (2024-06:)
    - @ilość: 50 (2024-06:)
    - @status: Aktywny (2024-06:)
```

**Identification**: An entity is recognized as currency when `Test-IsCurrencyEntity` finds a `GenericNames` entry that resolves via `Resolve-CurrencyDenomination`.

### 4.2 Naming Convention

- **Entity name**: `{Denomination} {OwnerGenitive}` - e.g., "Korony Xeron Demonlorda", "Kogi Gildi Kupców"
- **`@generyczne_nazwy`**: Always the canonical denomination name (enables lookup by currency type)
- **`@należy_do`**: Owner entity name (for carried currency)
- **`@lokacja`**: Location name (for dropped/hidden currency, mutually exclusive with `@należy_do`)

### 4.3 Ownership Lookup

`Find-CurrencyEntity` resolves a currency entity by matching:
1. `@generyczne_nazwy` contains the resolved denomination name (via `Resolve-CurrencyDenomination`)
2. Entity `Type` is `Przedmiot`
3. `Owner` property matches the target owner name (case-insensitive)

---

## 5. Conversion Utilities

### 5.1 `ConvertTo-CurrencyBaseUnit`

Converts a denomination amount to Kogi (base unit):

```powershell
ConvertTo-CurrencyBaseUnit -Amount 3 -Denomination 'Korony Elanckie'   # 30000
ConvertTo-CurrencyBaseUnit -Amount 50 -Denomination 'talarów'          # 5000
ConvertTo-CurrencyBaseUnit -Amount 250 -Denomination 'kogi'            # 250
```

| Parameter | Type | Description |
|---|---|---|
| `Amount` | int | **Mandatory**. The quantity in the source denomination. |
| `Denomination` | string | **Mandatory**. Denomination name (canonical, short, or stem). Resolved via `Resolve-CurrencyDenomination`. |

Throws on unknown denomination.

### 5.2 `ConvertFrom-CurrencyBaseUnit`

Converts Kogi amount to highest-denomination breakdown. Handles negative amounts (preserves sign across all components).

```powershell
ConvertFrom-CurrencyBaseUnit -Amount 35250
# @{ Korony = 3; Talary = 52; Kogi = 50 }
```

| Parameter | Type | Description |
|---|---|---|
| `Amount` | int | **Mandatory**. The quantity in Kogi (base units). May be negative. |

Returns: `@{ Korony = [int]; Talary = [int]; Kogi = [int] }`

### 5.3 `Resolve-CurrencyDenomination`

Resolves any denomination reference to its canonical definition. Uses three-tier matching:

1. Exact match on canonical name (case-insensitive)
2. Exact match on short name
3. Stem prefix match (`kor` -> Korony, `tal` -> Talary, `kog` -> Kogi)

| Parameter | Type | Description |
|---|---|---|
| `Name` | string | **Mandatory**. Denomination reference to resolve. Trimmed and lowercased before matching. |

Returns the denomination object (`Name`, `Short`, `Tier`, `Multiplier`, `Stems`) or `$null`.

### 5.4 `Get-CurrencyEntitiesFiltered`

Identifies currency entities from a collection, filters by status, and returns enriched objects with resolved denomination and parsed quantity. Used internally by `Get-CurrencyReport` and `Test-CurrencyReconciliation` to avoid duplicate identification/enrichment logic.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | **Mandatory** (allows empty). Entity collection from `Get-Entity` or `Get-EntityState`. |
| `IncludeInactive` | switch | Include entities with `Nieaktywny` status. |
| `IncludeDeleted` | switch | Include entities with `Usunięty` status. |
| `EntityLookup` | Dictionary[string,object] | Optional. Case-insensitive entity name → entity object lookup. When provided, enriched output includes `OwnerCategory` classification. |

**Return object** (per entity):

| Property | Type | Description |
|---|---|---|
| `Entity` | object | The original entity object (full entity with all properties) |
| `Denomination` | object | Resolved denomination definition (`Name`, `Short`, `Tier`, `Multiplier`) |
| `Owner` | string | Entity's `Owner` property |
| `Location` | string | Entity's `Location` property |
| `Quantity` | int | Parsed integer quantity (defaults to `0` if missing or unparseable) |
| `Status` | string | Entity status (`Aktywny` default) |
| `OwnerCategory` | string | Owner type: `Physical` (Postać), `Virtual` (NPC/Grupa/Gracz), `Unknown`. Only set when `-EntityLookup` is provided; `$null` otherwise. |

**Filtering pipeline**: Entity must pass `Test-IsCurrencyEntity` -> status filter -> denomination resolution.

---

## 6. `@Transfer` Session Directive

### 6.1 Syntax

A session-level directive (same level as `@Zmiany`, `@PU`, `@Logi`):

```markdown
### 2025-06-01, Handel na rynku, Solmyr

- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
- @Transfer: 50 talarów, Kupiec Orrin -> Kyrre
```

Format: `- @Transfer: {amount} {denomination}, {source} -> {destination}`

### 6.2 Parsing (public/session/get-session.ps1)

Parsed in `Get-SessionListMetadata` alongside other metadata blocks. The parser:

1. Detects `transfer:` prefix (case-insensitive, with `@` stripped for Gen4 compat)
2. Extracts: amount (integer), denomination (string), source (entity name), destination (entity name)
3. Stores as `[PSCustomObject]@{ Amount; Denomination; Source; Destination }` in `Session.Transfers`

Multiple `@Transfer` directives per session are supported.

### 6.3 Expansion (public/get-entitystate.ps1)
After processing regular Zmiany changes, `Get-EntityState` expands each Transfer:

1. Resolves denomination via `Resolve-CurrencyDenomination`
2. Finds source currency entity via `Find-CurrencyEntity` (denomination + `@należy_do` match)
3. Finds destination currency entity via `Find-CurrencyEntity`
4. Applies `-N` to source's `QuantityHistory` (session date as `ValidFrom`)
5. Applies `+N` to destination's `QuantityHistory`
6. Both entities are added to `ModifiedEntities` for history resorting

**Missing entities**: If source or destination entity is not found, a warning is emitted to stderr and that side of the transfer is skipped (the other side still applies). Balance defaults to 0.

### 6.4 Deduplication

`Transfers` are merged during session deduplication (same as `Changes`, `Intel`).

---

## 7. `Get-CurrencyReport`

### 7.1 Purpose

Read-only reporting command. Filters entities to currency items and produces a structured report.

### 7.2 Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Entities` | object[] | Pre-fetched entities (auto-fetched if omitted) |
| `-Owner` | string | Filter by owner entity name |
| `-Denomination` | string | Filter by denomination (canonical, short, or stem) |
| `-IncludeInactive` | switch | Include `Nieaktywny` entities |
| `-ActiveOn` | datetime | Temporal filter for balance state |
| `-ShowHistory` | switch | Include full `QuantityHistory` timeline |
| `-AsBaseUnit` | switch | Convert all amounts to Kogi equivalent |

### 7.3 Output Schema

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Currency entity name |
| `Denomination` | string | Canonical denomination name |
| `DenomShort` | string | Short denomination name |
| `Tier` | string | Gold/Silver/Copper |
| `Owner` | string | Owner entity name (or `$null`) |
| `Location` | string | Location name (or `$null`) |
| `OwnerType` | string | `Owner`, `Location`, or `Unowned` |
| `Balance` | int | Current quantity |
| `BaseUnitValue` | int | Kogi equivalent (only with `-AsBaseUnit`) |
| `Status` | string | Entity status |
| `LastChangeDate` | datetime | Date of last quantity change |
| `Warnings` | string[] | Status flags: `NegativeBalance`, `StaleBalance` |
| `History` | object[] | QuantityHistory entries (only with `-ShowHistory`) |

---

## 8. `Test-CurrencyReconciliation`

### 8.1 Purpose

Validation command that flags currency discrepancies. Designed for standalone use or integration into the monthly PU workflow.

### 8.2 Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Entities` | object[] | Pre-fetched entities (auto-fetched if omitted) |
| `-Sessions` | object[] | Pre-fetched sessions (auto-fetched if omitted) |
| `-Since` | datetime | Only check changes since this date |

### 8.3 Checks

| Check | Severity | What it detects |
|---|---|---|
| `NegativeBalance` | Error | Currency entity with `Quantity < 0` |
| `StaleBalance` | Warning | Owned currency with no changes in >3 months |
| `OrphanedCurrency` | Warning | Currency where `@należy_do` points to `Nieaktywny`/`Usunięty` entity. Includes `OwnerCategory` — Physical-owned orphans note "physical items need return to coordinators" |
| `AsymmetricTransaction` | Warning | Per-session per-denomination `@ilość` deltas that don't sum to zero |
| (Supply tracking) | Info | Total supply per denomination across all active entities |
| `PhysicalSupplyTracking` | Info | Per-denomination supply owned by Postać entities (physical currency in play) |
| `VirtualSupplyTracking` | Info | Per-denomination supply owned by NPC/Grupa/Gracz entities (virtual bookkeeping currency) |

### 8.4 Output Schema

| Property | Type | Description |
|---|---|---|
| `Warnings` | object[] | Array of `{ Check, Severity, Entity, Detail }` |
| `WarningCount` | int | Total number of warnings |
| `Supply` | hashtable | `{ DenominationName = TotalQuantity }` |
| `PhysicalSupply` | hashtable | `{ DenominationName = TotalQuantity }` for Postać-owned currency |
| `VirtualSupply` | hashtable | `{ DenominationName = TotalQuantity }` for NPC/Grupa/Gracz-owned currency |
| `EntityCount` | int | Number of currency entities found |
| `CheckedAt` | datetime | Timestamp of the check |

### 8.5 Symmetric Transaction Check

Only explicit `@ilość` deltas (`+N`/`-N`) in Zmiany blocks are counted. `@Transfer` directives are inherently symmetric (processed at entity-state level), so they don't appear in the Zmiany tag scan.

---

## 9. PU Workflow Integration

### 9.1 `-ReconcileCurrency` Switch

Added to `Invoke-PlayerCharacterPUAssignment`. When set:

1. Runs `Test-CurrencyReconciliation` after PU calculation (step 6.5)
2. Outputs warnings to stderr
3. Attaches `CurrencyReconciliation` property to the result object

```powershell
Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 6 -ReconcileCurrency
```

### 9.2 Integration Point

```
Step 1-6: PU calculation (unchanged)
Step 6.5: Test-CurrencyReconciliation
    ├── Load currency entities from enriched entity state
    ├── Run 5 validation checks
    ├── Output warnings to stderr
    └── Attach to result object
Step 7+: Side effects (UpdatePlayerCharacters, SendToDiscord, AppendToLog)
```

---

## 10. Currency Entity CRUD (`public/currency/`)

Four dedicated commands for managing currency entities. These wrap the generic entity primitives (`entity-writehelpers.ps1`) with denomination validation, auto-naming, and balance management. See [ENTITY-WRITES.md](ENTITY-WRITES.md) §6 for the full specification.

| Command | Purpose |
|---|---|
| `New-CurrencyEntity` | Creates a `Przedmiot` entity with validated denomination, auto-generated name `"{DenomShort} {Owner}"`, and `currency-entity.md.template` |
| `Set-CurrencyEntity` | Updates `@ilość` (absolute or delta arithmetic), `@należy_do` (owner transfer), `@lokacja` (dropped currency). Mutual exclusion: `Amount`/`AmountDelta`, `Owner`/`Location` |
| `Get-CurrencyEntity` | Read-only query with filtering by owner, denomination, name. Returns enriched objects with balance, tier, denomination metadata |
| `Remove-CurrencyEntity` | Soft-delete via `@status: Usunięty`. Warns on non-zero balance |

All mutating commands support `-WhatIf` / `-Confirm`. Remove has `ConfirmImpact = 'High'`.

---

## 11. Out-of-Game Currency Management

### 11.1 Problem

Not all currency is in active gameplay. Coordinators maintain a reserve pool (the "treasury") and distribute budgets to narrators before sessions. Narrators then award currency to player characters during sessions. This supply chain exists outside the normal `@Transfer` / `@Zmiany` session flow.

### 11.2 Modeling with Grupa Entities

Out-of-game currency reserves are modeled as currency entities owned by a `Grupa` entity representing the treasury:

```powershell
# One-time setup: create the treasury group
New-Entity -Type Grupa -Name "Skarbiec Koordynatorów"

# Mint initial currency supply
New-CurrencyEntity -Denomination Korony -Owner "Skarbiec Koordynatorów" -Amount 10000
New-CurrencyEntity -Denomination Talary -Owner "Skarbiec Koordynatorów" -Amount 50000
New-CurrencyEntity -Denomination Kogi   -Owner "Skarbiec Koordynatorów" -Amount 100000
```

### 11.3 Distribution Flow

```
Skarbiec Koordynatorów (Grupa)    ← total supply origin
        │
        │  Set-CurrencyEntity -AmountDelta (admin distribution)
        ▼
Narrator's currency entity              ← session budget
        │
        │  @Transfer in session (standard gameplay flow)
        ▼
Player Character currency entity        ← in-game holdings
```

**Coordinator → Narrator distribution** (out-of-game, administrative):

```powershell
# Create narrator's budget entity if it doesn't exist
New-CurrencyEntity -Denomination Korony -Owner "Narrator Dracon" -Amount 0

# Distribute from treasury
Set-CurrencyEntity -Name "Korony Skarbiec Koordynatorów" -AmountDelta -500 -ValidFrom "2026-02"
Set-CurrencyEntity -Name "Korony Narrator Dracon" -AmountDelta +500 -ValidFrom "2026-02"
```

**Narrator → Player Character** (in-game, during session):

```markdown
### 2026-02-15, Nagroda za misję, Dracon
- @Transfer: 100 koron, Narrator Dracon -> Erdamon
```

### 11.4 Reconciliation

`Test-CurrencyReconciliation` supply tracking includes treasury and narrator holdings in the total. This is correct - the total supply should be conserved across all holders (treasury + narrators + player characters). Supply drift indicates minting or loss errors.

**Note**: Paired `Set-CurrencyEntity` calls for admin distributions are not automatically linked. If one side is forgotten, `Test-CurrencyReconciliation` detects the supply drift at the next monthly reconciliation run.

---

## 12. Testing

| Test file | Coverage |
|---|---|
| `tests/currency-helpers.Tests.ps1` | Conversion utilities, denomination resolution, entity identification, entity lookup, owner type classification |
| `tests/get-currencyreport.Tests.ps1` | Report filtering, base unit conversion, history inclusion |
| `tests/test-currencyreconciliation.Tests.ps1` | Negative balance, orphaned currency, supply tracking, @Transfer symmetry, physical/virtual supply |
| `tests/get-entitystate.Tests.ps1` | @Transfer expansion (symmetric deltas), @Transfer session parsing, @Transfer fuzzy name resolution |
| `tests/currency-entity.Tests.ps1` | Currency entity creation, @ilość tag handling |
| `tests/new-currencyentity.Tests.ps1` | Denomination validation, auto-naming, duplicate detection, template rendering |
| `tests/set-currencyentity.Tests.ps1` | Absolute/delta quantity, owner/location update, mutual exclusion |
| `tests/get-currencyentity.Tests.ps1` | Filtering, denomination resolution, balance, inactive exclusion |
| `tests/remove-currencyentity.Tests.ps1` | Soft-delete, non-zero balance warning |
| `tests/get-economicsnapshot.Tests.ps1` | Supply breakdown, Gini coefficient, top holders, denomination filter, transfers |
| `tests/get-economictimeline.Tests.ps1` | Monthly data points, transfer counting, single month range, empty data |
| `tests/get-materializationreport.Tests.ps1` | Denomination breakdown, player mapping, orphaned physical currency |

---

## 13. @Transfer Fuzzy Name Resolution

### 13.1 Problem

Transfer source and destination names undergo the same fuzzy name resolution pipeline as Zmiany entity names. This was added because narrators may use inflected or approximate names in `@Transfer` directives (e.g., "Xeron Demonlorda" instead of "Xeron Demonlord").

### 13.2 Resolution Pipeline

For each Transfer source and destination:

1. **Exact match**: Check `$EntityByName` lookup (built from entity `Names` arrays)
2. **Fuzzy resolve**: Fall back to `Resolve-Name` with declension stripping + stem alternation + Levenshtein BK-tree
3. **Player mapping**: If `Resolve-Name` returns a Player entity, map through `$EntityByName` + `$Resolved.Names` to find the canonical entity name

The resolved name is then used for `Find-CurrencyEntity -OwnerName`.

---

## 14. Physical vs Virtual Currency

### 14.1 Concept

Currency entities are classified as **physical** or **virtual** based on their owner's entity type — no additional storage tags are needed.

| Owner entity type | Currency classification | Meaning |
|---|---|---|
| **Postać** | Physical | Actual Margonem items in player character equipment |
| **NPC** | Virtual | RP bookkeeping — narrative-only currency |
| **Grupa** | Virtual | Treasury reserves, guild holdings |
| **Gracz** | Virtual | Player-level (not character-level) currency |
| *(not found)* | Unknown | Owner not in entity lookup |

### 14.2 `Resolve-CurrencyOwnerType`

Utility function in `private/currency-helpers.ps1`. Accepts an owner name and an entity lookup dictionary, returns `'Physical'`, `'Virtual'`, or `'Unknown'`.

### 14.3 Design Rationale

Physical currency represents items that actually exist in Margonem player equipment. Virtual currency is pure RP bookkeeping — narrators can allocate virtual currency to NPCs and groups without needing corresponding game items. Players cannot have more virtual money than physical; virtual-only currency is reserved for narrators backing NPCs.

---

## 15. Economic Reporting

Three reporting functions provide economic analysis. All share the `New-EconomicSnapshotData` helper (`private/economy-helpers.ps1`). Full documentation: [ECONOMY.md](ECONOMY.md).

| Function | Purpose |
|---|---|
| `Get-EconomicSnapshot` | Point-in-time supply breakdown, wealth distribution, Gini coefficient |
| `Get-EconomicTimeline` | Monthly supply and transaction trends over a date range |
| `Get-MaterializationReport` | Physical vs virtual currency analysis with orphan detection |

---

## 16. Related Documents

- [ENTITIES.md](ENTITIES.md) - Entity system (tags, temporal scoping, multi-file merge)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Write operations on entity files
- [SESSIONS.md](SESSIONS.md) - Session parsing (Zmiany, @Transfer)
- [PU.md](PU.md) - PU assignment workflow
- [ECONOMY.md](ECONOMY.md) - Economic analysis subsystem (snapshot, timeline, materialization)

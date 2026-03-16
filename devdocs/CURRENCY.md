# Currency System

---

## Scope

The currency tracking subsystem covers denomination constants, conversion utilities, currency entity identification, CRUD commands (`New-CurrencyEntity`, `Set-CurrencyEntity`, `Get-CurrencyEntity`, `Remove-CurrencyEntity`), reporting (`Get-CurrencyReport`), reconciliation (`Test-CurrencyReconciliation`), the `@Transfer` session directive, PU workflow integration, and out-of-game currency management patterns.

General entity parsing is documented in [ENTITIES.md](ENTITIES.md). Generic entity write operations are documented in [ENTITY-WRITES.md](ENTITY-WRITES.md).

---

## Architecture Overview

```
private/currency-helpers.ps1              Denomination constants, conversion, identification
    +-- $CurrencyDenominations            Canonical denomination definitions
    +-- $DenomLookup                      Precomputed O(1) denomination lookup table
    +-- ConvertTo-CurrencyBaseUnit        Amount -> Kogi conversion
    +-- ConvertFrom-CurrencyBaseUnit      Kogi -> denomination breakdown
    +-- Resolve-CurrencyDenomination      Stem/colloquial -> canonical denomination
    +-- Test-IsCurrencyEntity             Check if entity is currency
    +-- Test-CurrencyOwnerMatch           Owner filter predicate
    +-- Test-CurrencyDenominationMatch    Denomination filter predicate
    +-- Build-CurrencyEntityLookup        Pre-build denomination+owner -> entity hashtable
    +-- Find-CurrencyEntity               Find currency entity by denomination + owner
    +-- Resolve-CurrencyOwnerType         Owner name -> Physical/Virtual/Unknown
    +-- Get-CurrencyEntitiesFiltered      Identify, filter by status, and enrich currency entities

public/currency/                     Currency entity CRUD
    +-- New-CurrencyEntity           Create currency entity (denomination-validated, auto-named)
    +-- Set-CurrencyEntity           Update quantity (absolute/delta), owner, location
    +-- Get-CurrencyEntity           Filtered currency entity query with balance
    +-- Remove-CurrencyEntity        Soft-delete with non-zero balance warning

public/reporting/get-currencyreport.ps1 Reporting command
    +-- Get-CurrencyReport              Filtered currency holdings report

public/reporting/test-currencyreconciliation.ps1    Validation checks
    +-- Test-CurrencyReconciliation                 7-check reconciliation report

public/reporting/get-economicsnapshot.ps1          Economic snapshot
    +-- Get-EconomicSnapshot                       Point-in-time supply/distribution/Gini

public/reporting/get-economictimeline.ps1          Economic timeline
    +-- Get-EconomicTimeline                       Monthly supply and transaction trends

public/reporting/get-materializationreport.ps1     Materialization report
    +-- Get-MaterializationReport                  Physical vs virtual currency analysis

private/economy-helpers.ps1                        Shared economic helpers
    +-- New-EconomicSnapshotData                 Supply breakdown, Gini, top holders

public/session/get-session.ps1                          @Transfer parsing (session-level directive)
public/get-entitystate.ps1                              @Transfer expansion (symmetric quantity deltas)
public/workflow/invoke-playercharacterpuassignment.ps1  -ReconcileCurrency integration
```

---

## Denomination Constants

Defined in `private/currency-helpers.ps1` as `$script:CurrencyDenominations`:

| Name | Short | Tier | Multiplier (Kogi) | Stems |
|---|---|---|---|---|
| Korony Elanckie | Korony | Gold | 10000 | `kor` |
| Talary Hironskie | Talary | Silver | 100 | `tal` |
| Kogi Skeltvorskie | Kogi | Copper | 1 | `kog` |

Exchange rates: 100 Kogi = 1 Talar, 100 Talarow = 1 Korona (10000 Kogi = 1 Korona).

---

## Currency Entity Model

Currency entities are `Przedmiot` entities with `@generyczne_nazwy` set to a canonical denomination name:

```markdown
## Przedmiot

* Korony Xeron Demonlorda
    - @generyczne_nazwy: Korony Elanckie
    - @nalezy_do: Xeron Demonlord (2024-06:)
    - @ilosc: 50 (2024-06:)
    - @status: Aktywny (2024-06:)
```

An entity is recognized as currency when `Test-IsCurrencyEntity` finds a `GenericNames` entry that resolves via `Resolve-CurrencyDenomination`.

Entity naming convention:
- Entity name — `{Denomination} {OwnerGenitive}` (e.g., "Korony Xeron Demonlorda", "Kogi Gildi Kupcow")
- `@generyczne_nazwy` — always the canonical denomination name (enables lookup by currency type)
- `@nalezy_do` — owner entity name (for carried currency)
- `@lokacja` — location name (for dropped/hidden currency, mutually exclusive with `@nalezy_do`)

`Find-CurrencyEntity` resolves a currency entity by matching denomination and owner:

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Mandatory. Entity collection to search. |
| `Denomination` | string | Mandatory. Denomination name (resolved via `Resolve-CurrencyDenomination`). |
| `OwnerName` | string | Mandatory. Owner entity name to match. |
| `CurrencyLookup` | Dictionary[string,object] | Optional. Pre-built lookup from `Build-CurrencyEntityLookup`. When provided, performs O(1) key lookup instead of linear scan. |

Without lookup: Linear scan — checks `@generyczne_nazwy` contains the resolved denomination, entity `Type` is `Przedmiot`, and `Owner` matches (case-insensitive).

With lookup: Constructs key `"{CanonicalDenom}|{OwnerName}"` and performs dictionary `TryGetValue`. Falls back to `$null` on miss.

---

## Conversion Utilities

`ConvertTo-CurrencyBaseUnit` converts a denomination amount to Kogi (base unit):

```powershell
ConvertTo-CurrencyBaseUnit -Amount 3 -Denomination 'Korony Elanckie'   # 30000
ConvertTo-CurrencyBaseUnit -Amount 50 -Denomination 'talarow'          # 5000
ConvertTo-CurrencyBaseUnit -Amount 250 -Denomination 'kogi'            # 250
```

| Parameter | Type | Description |
|---|---|---|
| `Amount` | int | Mandatory. The quantity in the source denomination. |
| `Denomination` | string | Mandatory. Denomination name (canonical, short, or stem). Resolved via `Resolve-CurrencyDenomination`. |

Throws on unknown denomination.

`ConvertFrom-CurrencyBaseUnit` converts Kogi amount to highest-denomination breakdown. Handles negative amounts (preserves sign across all components).

```powershell
ConvertFrom-CurrencyBaseUnit -Amount 35250
# @{ Korony = 3; Talary = 52; Kogi = 50 }
```

| Parameter | Type | Description |
|---|---|---|
| `Amount` | int | Mandatory. The quantity in Kogi (base units). May be negative. |

Returns: `@{ Korony = [int]; Talary = [int]; Kogi = [int] }`

`Resolve-CurrencyDenomination` resolves any denomination reference to its canonical definition. Uses a precomputed `$script:DenomLookup` hashtable built at dot-source time for O(1) exact match, with stem prefix fallback.

Precomputed lookup (`$script:DenomLookup`): Built once when `currency-helpers.ps1` is dot-sourced. Maps all canonical names, short names, and stems (lowercased) to their denomination objects. This avoids repeated linear scans of `$CurrencyDenominations`.

Resolution pipeline:
1. O(1) exact match on `$DenomLookup` (canonical name, short name, or stem — all lowercased)
2. Stem prefix fallback: iterates `$DenomLookup` keys, returns the first where the input `StartsWith` the key (for partial names like `"koron"` matching `"kor"` stem)

| Parameter | Type | Description |
|---|---|---|
| `Name` | string | Mandatory. Denomination reference to resolve. Trimmed and lowercased before matching. |

Returns the denomination object (`Name`, `Short`, `Tier`, `Multiplier`, `Stems`) or `$null`.

`Test-CurrencyOwnerMatch` is a predicate function for filtering currency entities by owner. Used internally by `Get-CurrencyEntity` and `Get-CurrencyReport` to centralize owner-matching logic.

| Parameter | Type | Description |
|---|---|---|
| `EntityOwner` | string | The currency entity's `Owner` property value. |
| `FilterOwner` | string | The owner filter string (from `-Owner` parameter). |

Returns `$true` if `FilterOwner` is null/empty (no filter) or if `EntityOwner` matches `FilterOwner` (case-insensitive via `OrdinalIgnoreCase`). Returns `$false` when the filter is set but the entity has no owner or the names do not match.

`Test-CurrencyDenominationMatch` is a predicate function for filtering currency entities by denomination. Used internally by `Get-CurrencyEntity`, `Get-CurrencyReport`, and `Get-TransactionLedger` to centralize denomination-matching logic.

| Parameter | Type | Description |
|---|---|---|
| `DenominationName` | string | The resolved denomination canonical name (from entity). |
| `DenomFilter` | object | The resolved denomination filter object (from `Resolve-CurrencyDenomination`). |

Returns `$true` if `DenomFilter` is null (no filter) or if `DenominationName` matches `DenomFilter.Name` (case-insensitive). Callers resolve the user-supplied denomination string via `Resolve-CurrencyDenomination` before passing it as `DenomFilter`.

`Get-CurrencyEntitiesFiltered` identifies currency entities from a collection, filters by status, and returns enriched objects with resolved denomination and parsed quantity. Used internally by `Get-CurrencyReport` and `Test-CurrencyReconciliation` to avoid duplicate identification/enrichment logic.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Mandatory (allows empty). Entity collection from `Get-Entity` or `Get-EntityState`. |
| `IncludeInactive` | switch | Include entities with `Nieaktywny` status. |
| `IncludeDeleted` | switch | Include entities with `Usuniety` status. |
| `EntityLookup` | Dictionary[string,object] | Optional. Case-insensitive entity name -> entity object lookup. When provided, enriched output includes `OwnerCategory` classification. |

Return object (per entity):

| Property | Type | Description |
|---|---|---|
| `Entity` | object | The original entity object (full entity with all properties) |
| `Denomination` | object | Resolved denomination definition (`Name`, `Short`, `Tier`, `Multiplier`) |
| `Owner` | string | Entity's `Owner` property |
| `Location` | string | Entity's `Location` property |
| `Quantity` | int | Parsed integer quantity (defaults to `0` if missing or unparseable) |
| `Status` | string | Entity status (`Aktywny` default) |
| `OwnerCategory` | string | Owner type: `Physical` (Postac), `Virtual` (NPC/Grupa/Gracz), `Unknown`. Only set when `-EntityLookup` is provided; `$null` otherwise. |

Filtering pipeline: Entity must pass `Test-IsCurrencyEntity` -> status filter -> denomination resolution.

`Build-CurrencyEntityLookup` pre-builds a denomination+owner lookup hashtable for O(1) currency entity resolution. Used by `Get-EntityState` to avoid repeated linear scans when processing multiple `@Transfer` directives within a session batch.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Mandatory. Entity collection from `Get-Entity`. |

Filtering pipeline: Iterates all entities, skipping those without `GenericNames`, those where `Type` is not `Przedmiot`, and those without an `Owner`. For each qualifying entity, resolves each generic name via `Resolve-CurrencyDenomination`. On match, builds a composite key `"{CanonicalDenom}|{Owner}"` and stores the first matching entity (duplicates are silently ignored via `ContainsKey` guard).

Returns `Dictionary[string, object]` with `OrdinalIgnoreCase` comparer.

---

## `@Transfer` Session Directive

Syntax — a session-level directive (same level as `@Zmiany`, `@PU`, `@Logi`):

```markdown
### 2025-06-01, Handel na rynku, Solmyr

- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
- @Transfer: 50 talarow, Kupiec Orrin -> Kyrre
```

Format: `- @Transfer: {amount} {denomination}, {source} -> {destination}`

Parsing (`public/session/get-session.ps1`) happens in `Get-SessionListMetadata` alongside other metadata blocks. The parser:

1. Detects `transfer:` prefix (case-insensitive, with `@` stripped for Gen4 compat)
2. Extracts: amount (integer), denomination (string), source (entity name), destination (entity name)
3. Stores as `[PSCustomObject]@{ Amount; Denomination; Source; Destination }` in `Session.Transfers`

Multiple `@Transfer` directives per session are supported.

Expansion (`public/get-entitystate.ps1`) — after processing regular Zmiany changes, `Get-EntityState` expands each Transfer:

1. Resolves denomination via `Resolve-CurrencyDenomination`
2. Finds source currency entity via `Find-CurrencyEntity` (denomination + `@nalezy_do` match)
3. Finds destination currency entity via `Find-CurrencyEntity`
4. Applies `-N` to source's `QuantityHistory` (session date as `ValidFrom`)
5. Applies `+N` to destination's `QuantityHistory`
6. Both entities are added to `ModifiedEntities` for history resorting

Currency helpers (`private/currency-helpers.ps1`) are dot-sourced lazily — only when the first session with `Transfers` is encountered. A `CurrencyLookup` dictionary is built once via `Build-CurrencyEntityLookup` and reused for all subsequent `Find-CurrencyEntity` calls within the same `Get-EntityState` invocation.

If source or destination entity is not found, a warning is emitted to stderr and that side of the transfer is skipped (the other side still applies). Balance defaults to 0.

`Transfers` are merged during session deduplication (same as `Changes`, `Intel`).

---

## `Get-CurrencyReport`

Read-only reporting command. Filters entities to currency items and produces a structured report.

| Parameter | Type | Description |
|---|---|---|
| `-Entities` | object[] | Pre-fetched entities (auto-fetched if omitted) |
| `-Owner` | string | Filter by owner entity name |
| `-Denomination` | string | Filter by denomination (canonical, short, or stem) |
| `-IncludeInactive` | switch | Include `Nieaktywny` entities |
| `-ActiveOn` | datetime | Temporal filter for balance state |
| `-ShowHistory` | switch | Include full `QuantityHistory` timeline |
| `-AsBaseUnit` | switch | Convert all amounts to Kogi equivalent |

Output schema:

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

## `Test-CurrencyReconciliation`

Validation command that flags currency discrepancies. Designed for standalone use or integration into the monthly PU workflow.

| Parameter | Type | Description |
|---|---|---|
| `-Entities` | object[] | Pre-fetched entities (auto-fetched if omitted) |
| `-Sessions` | object[] | Pre-fetched sessions (auto-fetched if omitted) |
| `-Since` | datetime | Only check changes since this date |

Checks:

| Check | Severity | What it detects |
|---|---|---|
| `NegativeBalance` | Error | Currency entity with `Quantity < 0` |
| `StaleBalance` | Warning | Owned currency with no changes in >3 months |
| `OrphanedCurrency` | Warning | Currency where `@nalezy_do` points to `Nieaktywny`/`Usuniety` entity. Includes `OwnerCategory` — Physical-owned orphans note "physical items need return to coordinators" |
| `AsymmetricTransaction` | Warning | Per-session per-denomination `@ilosc` deltas that do not sum to zero |
| (Supply tracking) | Info | Total supply per denomination across all active entities |
| `PhysicalSupplyTracking` | Info | Per-denomination supply owned by Postac entities (physical currency in play) |
| `VirtualSupplyTracking` | Info | Per-denomination supply owned by NPC/Grupa/Gracz entities (virtual bookkeeping currency) |

Output schema:

| Property | Type | Description |
|---|---|---|
| `Warnings` | object[] | Array of `{ Check, Severity, Entity, Detail }` |
| `WarningCount` | int | Total number of warnings |
| `Supply` | hashtable | `{ DenominationName = TotalQuantity }` |
| `PhysicalSupply` | hashtable | `{ DenominationName = TotalQuantity }` for Postac-owned currency |
| `VirtualSupply` | hashtable | `{ DenominationName = TotalQuantity }` for NPC/Grupa/Gracz-owned currency |
| `EntityCount` | int | Number of currency entities found |
| `CheckedAt` | datetime | Timestamp of the check |

The symmetric transaction check counts only explicit `@ilosc` deltas (`+N`/`-N`) in Zmiany blocks. `@Transfer` directives are inherently symmetric (processed at entity-state level), so they do not appear in the Zmiany tag scan.

---

## PU Workflow Integration

The `-ReconcileCurrency` switch is added to `Invoke-PlayerCharacterPUAssignment`. When set:

1. Runs `Test-CurrencyReconciliation` after PU calculation (step 6.5)
2. Outputs warnings to stderr
3. Attaches `CurrencyReconciliation` property to the result object

```powershell
Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 6 -ReconcileCurrency
```

Integration point:

```
Step 1-6: PU calculation (unchanged)
Step 6.5: Test-CurrencyReconciliation
    +-- Load currency entities from enriched entity state
    +-- Run 5 validation checks
    +-- Output warnings to stderr
    +-- Attach to result object
Step 7+: Side effects (UpdatePlayerCharacters, SendToDiscord, AppendToLog)
```

---

## Currency Entity CRUD

Four dedicated commands in `public/currency/` for managing currency entities. These wrap the generic entity primitives (`entity-writehelpers.ps1`) with denomination validation, auto-naming, and balance management. See [ENTITY-WRITES.md](ENTITY-WRITES.md) for the full specification.

| Command | Purpose |
|---|---|
| `New-CurrencyEntity` | Creates a `Przedmiot` entity with validated denomination, auto-generated name `"{DenomShort} {Owner}"`, and `currency-entity.md.template` |
| `Set-CurrencyEntity` | Updates `@ilosc` (absolute or delta arithmetic), `@nalezy_do` (owner transfer), `@lokacja` (dropped currency). Mutual exclusion: `Amount`/`AmountDelta`, `Owner`/`Location` |
| `Get-CurrencyEntity` | Read-only query with filtering by owner, denomination, name. Returns enriched objects with balance, tier, denomination metadata |
| `Remove-CurrencyEntity` | Soft-delete via `@status: Usuniety`. Warns on non-zero balance |

All mutating commands support `-WhatIf` / `-Confirm`. Remove has `ConfirmImpact = 'High'`.

---

## Out-of-Game Currency Management

Coordinators maintain a reserve pool (the "treasury") and distribute budgets to narrators before sessions. Narrators then award currency to player characters during sessions. This supply chain exists outside the normal `@Transfer` / `@Zmiany` session flow.

Out-of-game currency reserves are modeled as currency entities owned by a `Grupa` entity representing the treasury:

```powershell
# One-time setup: create the treasury group
New-Entity -Type Grupa -Name "Skarbiec Koordynatorow"

# Mint initial currency supply
New-CurrencyEntity -Denomination Korony -Owner "Skarbiec Koordynatorow" -Amount 10000
New-CurrencyEntity -Denomination Talary -Owner "Skarbiec Koordynatorow" -Amount 50000
New-CurrencyEntity -Denomination Kogi   -Owner "Skarbiec Koordynatorow" -Amount 100000
```

Distribution flow:

```
Skarbiec Koordynatorow (Grupa)    <- total supply origin
        |
        |  Set-CurrencyEntity -AmountDelta (admin distribution)
        v
Narrator's currency entity              <- session budget
        |
        |  @Transfer in session (standard gameplay flow)
        v
Player Character currency entity        <- in-game holdings
```

Coordinator -> Narrator distribution (out-of-game, administrative):

```powershell
# Create narrator's budget entity if it doesn't exist
New-CurrencyEntity -Denomination Korony -Owner "Narrator Dracon" -Amount 0

# Distribute from treasury
Set-CurrencyEntity -Name "Korony Skarbiec Koordynatorow" -AmountDelta -500 -ValidFrom "2026-02"
Set-CurrencyEntity -Name "Korony Narrator Dracon" -AmountDelta +500 -ValidFrom "2026-02"
```

Narrator -> Player Character (in-game, during session):

```markdown
### 2026-02-15, Nagroda za misje, Dracon
- @Transfer: 100 koron, Narrator Dracon -> Erdamon
```

`Test-CurrencyReconciliation` supply tracking includes treasury and narrator holdings in the total. The total supply should be conserved across all holders (treasury + narrators + player characters). Supply drift indicates minting or loss errors.

Paired `Set-CurrencyEntity` calls for admin distributions are not automatically linked. If one side is forgotten, `Test-CurrencyReconciliation` detects the supply drift at the next monthly reconciliation run.

---

## `@Transfer` Fuzzy Name Resolution

Transfer source and destination names undergo the same fuzzy name resolution pipeline as Zmiany entity names. Narrators may use inflected or approximate names in `@Transfer` directives (e.g., "Xeron Demonlorda" instead of "Xeron Demonlord").

For each Transfer source and destination:

1. Exact match — Check `$EntityByName` lookup (built from entity `Names` arrays)
2. Fuzzy resolve — Fall back to `Resolve-Name` with declension stripping + stem alternation + Levenshtein BK-tree
3. Player mapping — If `Resolve-Name` returns a Player entity, map through `$EntityByName` + `$Resolved.Names` to find the canonical entity name

The resolved name is then used for `Find-CurrencyEntity -OwnerName`.

---

## Physical vs Virtual Currency

Currency entities are classified as physical or virtual based on their owner's entity type — no additional storage tags are needed.

| Owner entity type | Currency classification | Meaning |
|---|---|---|
| Postac | Physical | Actual Margonem items in player character equipment |
| NPC | Virtual | RP bookkeeping — narrative-only currency |
| Grupa | Virtual | Treasury reserves, guild holdings |
| Gracz | Virtual | Player-level (not character-level) currency |
| (not found) | Unknown | Owner not in entity lookup |

`Resolve-CurrencyOwnerType` is a utility function in `private/currency-helpers.ps1`. Accepts an owner name and an entity lookup dictionary, returns `'Physical'`, `'Virtual'`, or `'Unknown'`.

Physical currency represents items that actually exist in Margonem player equipment. Virtual currency is pure RP bookkeeping — narrators can allocate virtual currency to NPCs and groups without needing corresponding game items.

---

## Economic Reporting

Three reporting functions provide economic analysis. All share the `New-EconomicSnapshotData` helper (`private/economy-helpers.ps1`). Full documentation: [ECONOMY.md](ECONOMY.md).

| Function | Purpose |
|---|---|
| `Get-EconomicSnapshot` | Point-in-time supply breakdown, wealth distribution, Gini coefficient |
| `Get-EconomicTimeline` | Monthly supply and transaction trends over a date range |
| `Get-MaterializationReport` | Physical vs virtual currency analysis with orphan detection |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/currency-helpers.Tests.ps1` | Conversion utilities, denomination resolution, entity identification, entity lookup, owner type classification |
| `tests/get-currencyreport.Tests.ps1` | Report filtering, base unit conversion, history inclusion |
| `tests/test-currencyreconciliation.Tests.ps1` | Negative balance, orphaned currency, supply tracking, @Transfer symmetry, physical/virtual supply |
| `tests/get-entitystate.Tests.ps1` | @Transfer expansion (symmetric deltas), @Transfer session parsing, @Transfer fuzzy name resolution |
| `tests/currency-entity.Tests.ps1` | Currency entity creation, @ilosc tag handling |
| `tests/new-currencyentity.Tests.ps1` | Denomination validation, auto-naming, duplicate detection, template rendering |
| `tests/set-currencyentity.Tests.ps1` | Absolute/delta quantity, owner/location update, mutual exclusion |
| `tests/get-currencyentity.Tests.ps1` | Filtering, denomination resolution, balance, inactive exclusion |
| `tests/remove-currencyentity.Tests.ps1` | Soft-delete, non-zero balance warning |
| `tests/get-economicsnapshot.Tests.ps1` | Supply breakdown, Gini coefficient, top holders, denomination filter, transfers |
| `tests/get-economictimeline.Tests.ps1` | Monthly data points, transfer counting, single month range, empty data |
| `tests/get-materializationreport.Tests.ps1` | Denomination breakdown, player mapping, orphaned physical currency |

---

## Related Documents

- [ENTITIES.md](ENTITIES.md) — Entity system (tags, temporal scoping, multi-file merge)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) — Write operations on entity files
- [SESSIONS.md](SESSIONS.md) — Session parsing (Zmiany, @Transfer)
- [PU.md](PU.md) — PU assignment workflow
- [STRUCTURES.md](STRUCTURES.md) — Canonical data structure reference (CurrencyEntity, CurrencyReport, etc.)
- [ECONOMY.md](ECONOMY.md) — Economic analysis subsystem (snapshot, timeline, materialization)

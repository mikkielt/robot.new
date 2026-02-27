# Currency System — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the currency tracking subsystem: denomination constants, conversion utilities, currency entity identification, reporting (`Get-CurrencyReport`), reconciliation (`Test-CurrencyReconciliation`), the `@Transfer` session directive, and PU workflow integration.

**Not covered**: General entity parsing — see [ENTITIES.md](ENTITIES.md). Entity write operations — see [ENTITY-WRITES.md](ENTITY-WRITES.md).

---

## 2. Architecture Overview

```
currency-helpers.ps1          Denomination constants, conversion, identification
    ├── $CurrencyDenominations     Canonical denomination definitions
    ├── ConvertTo-CurrencyBaseUnit   Amount → Kogi conversion
    ├── ConvertFrom-CurrencyBaseUnit Kogi → denomination breakdown
    ├── Resolve-CurrencyDenomination Stem/colloquial → canonical denomination
    ├── Test-IsCurrencyEntity        Check if entity is currency
    └── Find-CurrencyEntity          Find currency entity by denomination + owner

get-currencyreport.ps1        Reporting command
    └── Get-CurrencyReport           Filtered currency holdings report

test-currencyreconciliation.ps1  Validation checks
    └── Test-CurrencyReconciliation  5-check reconciliation report

get-session.ps1               @Transfer parsing (session-level directive)
get-entitystate.ps1           @Transfer expansion (symmetric quantity deltas)
invoke-playercharacterpuassignment.ps1  -ReconcileCurrency integration
```

---

## 3. Denomination Constants

Defined in `currency-helpers.ps1` as `$script:CurrencyDenominations`:

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

- **Entity name**: `{Denomination} {OwnerGenitive}` — e.g., "Korony Xeron Demonlorda", "Kogi Gildi Kupców"
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
ConvertTo-CurrencyBaseUnit -Amount 3 -Denomination 'Korony Elanckie'  # 30000
ConvertTo-CurrencyBaseUnit -Amount 50 -Denomination 'talarów'          # 5000
ConvertTo-CurrencyBaseUnit -Amount 250 -Denomination 'kogi'            # 250
```

Accepts canonical names, short names, and stem-matched colloquial names.

### 5.2 `ConvertFrom-CurrencyBaseUnit`

Converts Kogi amount to highest-denomination breakdown:

```powershell
ConvertFrom-CurrencyBaseUnit -Amount 35250
# @{ Korony = 3; Talary = 52; Kogi = 50 }
```

### 5.3 `Resolve-CurrencyDenomination`

Resolves any denomination reference to its canonical definition. Uses three-tier matching:

1. Exact match on canonical name (case-insensitive)
2. Exact match on short name
3. Stem prefix match (`kor` → Korony, `tal` → Talary, `kog` → Kogi)

Returns the denomination object or `$null`.

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

### 6.2 Parsing (get-session.ps1)

Parsed in `Get-SessionListMetadata` alongside other metadata blocks. The parser:

1. Detects `transfer:` prefix (case-insensitive, with `@` stripped for Gen4 compat)
2. Extracts: amount (integer), denomination (string), source (entity name), destination (entity name)
3. Stores as `[PSCustomObject]@{ Amount; Denomination; Source; Destination }` in `Session.Transfers`

Multiple `@Transfer` directives per session are supported.

### 6.3 Expansion (get-entitystate.ps1)

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
| `OrphanedCurrency` | Warning | Currency where `@należy_do` points to `Nieaktywny`/`Usunięty` entity |
| `AsymmetricTransaction` | Warning | Per-session per-denomination `@ilość` deltas that don't sum to zero |
| (Supply tracking) | Info | Total supply per denomination across all active entities |

### 8.4 Output Schema

| Property | Type | Description |
|---|---|---|
| `Warnings` | object[] | Array of `{ Check, Severity, Entity, Detail }` |
| `WarningCount` | int | Total number of warnings |
| `Supply` | hashtable | `{ DenominationName = TotalQuantity }` |
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

## 10. Testing

| Test file | Coverage |
|---|---|
| `tests/currency-helpers.Tests.ps1` | Conversion utilities, denomination resolution, entity identification, entity lookup |
| `tests/get-currencyreport.Tests.ps1` | Report filtering, base unit conversion, history inclusion |
| `tests/test-currencyreconciliation.Tests.ps1` | Negative balance, orphaned currency, supply tracking, @Transfer symmetry |
| `tests/get-entitystate.Tests.ps1` | @Transfer expansion (symmetric deltas), @Transfer session parsing |
| `tests/currency-entity.Tests.ps1` | Currency entity creation, @ilość tag handling |

---

## 11. Related Documents

- [ENTITIES.md](ENTITIES.md) — Entity system (tags, temporal scoping, multi-file merge)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) — Write operations on entity files
- [SESSIONS.md](SESSIONS.md) — Session parsing (Zmiany, @Transfer)
- [PU.md](PU.md) — PU assignment workflow

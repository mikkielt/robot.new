# Economic Analysis Subsystem - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the economic analysis subsystem: physical vs virtual currency classification, supply breakdown, wealth distribution (Gini coefficient), economic snapshots, monthly timelines, and materialization reporting.

**Not covered**: Currency CRUD, denomination constants, @Transfer parsing — see [CURRENCY.md](CURRENCY.md). Entity parsing — see [ENTITIES.md](ENTITIES.md).

---

## 2. Architecture Overview

```
private/currency-helpers.ps1              Owner type classification
    ├── Resolve-CurrencyOwnerType         Owner name → Physical/Virtual/Unknown
    └── Get-CurrencyEntitiesFiltered      -EntityLookup → enriched with OwnerCategory

private/economy-helpers.ps1               Shared economic computation
    └── New-EconomicSnapshotData        Supply breakdown, Gini, top holders, transaction stats

public/reporting/
    ├── get-economicsnapshot.ps1           Point-in-time economic snapshot
    │   └── Get-EconomicSnapshot
    ├── get-economictimeline.ps1           Monthly trend data
    │   └── Get-EconomicTimeline
    └── get-materializationreport.ps1      Physical vs virtual analysis
        └── Get-MaterializationReport
```

---

## 3. Physical vs Virtual Currency Model

### 3.1 Classification

Currency entities are classified by their owner's entity type — no new storage tags required:

| Owner Type | Classification | Meaning |
|---|---|---|
| Postać | Physical | Actual Margonem items in player character equipment |
| NPC | Virtual | RP bookkeeping — narrative-only currency |
| Grupa | Virtual | Treasury reserves, guild holdings |
| Gracz | Virtual | Player-level currency (not character-level) |
| *(not found)* | Unknown | Owner not in entity lookup |

### 3.2 Design Rationale

Physical currency represents items that actually exist in Margonem player equipment. Virtual currency is pure RP bookkeeping — narrators can allocate virtual currency to NPCs and groups without needing corresponding game items.

### 3.3 `Resolve-CurrencyOwnerType`

```powershell
Resolve-CurrencyOwnerType -OwnerName 'Crag Hack' -EntityLookup $Lookup
# Returns: 'Physical' (Crag Hack is a Postać)
```

| Parameter | Type | Description |
|---|---|---|
| `OwnerName` | string | **Mandatory**. Entity name to classify. |
| `EntityLookup` | Dictionary[string,object] | **Mandatory**. Case-insensitive name → entity lookup. |

Returns: `'Physical'`, `'Virtual'`, or `'Unknown'`.

---

## 4. `New-EconomicSnapshotData`

Shared helper in `private/economy-helpers.ps1`. Computes supply breakdown, Gini coefficient, top holders, and transaction statistics from enriched currency items. Used by both `Get-EconomicSnapshot` and `Get-EconomicTimeline`.

### 4.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `CurrencyItems` | object[] | Enriched currency items from `Get-CurrencyEntitiesFiltered` (with `OwnerCategory`). Allows null/empty. |
| `TransferEntries` | object[] | Transfer directive entries from `Get-SessionDirectiveEntries`. Allows null/empty. |
| `Top` | int | Number of top holders to include (default: 10). |

### 4.2 Return Hashtable

| Key | Type | Description |
|---|---|---|
| `SupplyByDenomination` | hashtable | `{ DenomName = @{ Total; Physical; Virtual } }` |
| `TotalSupplyKogi` | int | Total supply in base unit (Kogi) |
| `PhysicalSupplyKogi` | int | Postać-owned supply in base unit |
| `VirtualSupplyKogi` | int | NPC/Grupa/Gracz-owned supply in base unit |
| `PhysicalRatio` | double | Physical / Total (rounded to 4 decimal places) |
| `HolderCount` | int | Distinct owners with balance > 0 |
| `TopHolders` | object[] | Top N by wealth (Kogi), each with `Owner`, `WealthKogi`, `OwnerCategory` |
| `GiniCoefficient` | double | 0.0 = perfectly equal, 1.0 = one entity holds all (rounded to 4 places) |
| `TransactionVolume` | int | Number of @Transfer entries |
| `TransactionValueKogi` | int | Sum of @Transfer amounts in base unit |

### 4.3 Gini Coefficient Formula

Wealth inequality measure using the sorted-values formula:

```
G = (2 * Σ(i * w[i])) / (n * Σ(w)) - (n+1)/n
```

Where `w[i]` are per-owner wealth values sorted ascending, `i` is 1-indexed position, `n` is the count of owners with positive wealth.

- `G = 0.0`: All owners hold equal wealth
- `G → 1.0`: One owner holds nearly all wealth
- Computed only when 2+ owners have positive wealth; otherwise 0.0

### 4.4 Filtering

Entities with status `Usunięty` are excluded from supply calculations. Supply is computed from `Quantity * Denomination.Multiplier` (converting to Kogi base unit).

---

## 5. `Get-EconomicSnapshot`

Point-in-time economic snapshot with supply breakdown, wealth distribution, and transaction volume.

### 5.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-EntityState` (auto-fetched if omitted). |
| `Sessions` | object[] | Pre-fetched from `Get-Session` (auto-fetched if omitted). |
| `ActiveOn` | datetime | Temporal filter for entity state. |
| `Owner` | string | Scope to a specific owner entity. |
| `Denomination` | string | Scope to a specific denomination. |
| `Top` | int | Number of top holders (default: 10). |
| `Quiet` | switch | Suppress warnings to stderr. |

### 5.2 Output Schema

| Property | Type | Description |
|---|---|---|
| `SnapshotDate` | datetime | Effective date (ActiveOn or now) |
| `SupplyByDenomination` | hashtable | `{ DenomName = @{ Total; Physical; Virtual } }` |
| `TotalSupplyKogi` | int | Total in base unit |
| `PhysicalSupplyKogi` | int | Postać-owned in base unit |
| `VirtualSupplyKogi` | int | NPC/Grupa/Gracz-owned in base unit |
| `PhysicalRatio` | double | Physical / Total |
| `HolderCount` | int | Distinct owners with balance > 0 |
| `TopHolders` | object[] | Top N by wealth with OwnerCategory |
| `GiniCoefficient` | double | Wealth inequality (0–1) |
| `TransactionVolume` | int | @Transfer count in scope |
| `TransactionValueKogi` | int | @Transfer sum in base unit |

### 5.3 Implementation Flow

1. Auto-fetch entities and sessions if not provided
2. Build `$EntityLookup` (case-insensitive name → entity dictionary)
3. `Get-CurrencyEntitiesFiltered -EntityLookup` for enriched currency items with OwnerCategory
4. Apply denomination and owner filters
5. `Get-SessionDirectiveEntries -DirectiveName 'Transfers'` for transaction volume
6. `New-EconomicSnapshotData` for computation
7. Return PSCustomObject with all snapshot fields

---

## 6. `Get-EconomicTimeline`

Monthly supply and transaction trends over a date range.

### 6.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-Entity` (auto-fetched if omitted). |
| `Sessions` | object[] | Pre-fetched from `Get-Session` (auto-fetched if omitted). |
| `MinDate` | datetime | **Mandatory**. Start date for timeline. |
| `MaxDate` | datetime | **Mandatory**. End date for timeline. |
| `Entity` | string | Scope to a specific owner entity. |
| `Denomination` | string | Scope to a specific denomination. |
| `ProgressCallback` | scriptblock | Optional callback for CLI progress reporting. Invoked with `(Current, Total, ItemDetail)` on each month iteration, where `ItemDetail` is the `yyyy-MM` month label. |
| `Quiet` | switch | Suppress warnings to stderr. |

### 6.2 Output Schema

Array of monthly data points:

| Property | Type | Description |
|---|---|---|
| `Month` | string | Month label (`yyyy-MM` format) |
| `TotalSupplyKogi` | int | Total supply in base unit at month end |
| `PhysicalSupplyKogi` | int | Postać-owned supply at month end |
| `VirtualSupplyKogi` | int | NPC/Grupa/Gracz-owned supply at month end |
| `SupplyByDenomination` | hashtable | `{ DenomName = @{ Total; Physical; Virtual } }` |
| `TransferCount` | int | @Transfer count within the month |

### 6.3 Implementation Flow

1. Auto-fetch entities and sessions if not provided
2. Pre-build `$NameIndex` once via `Get-NameIndex` (shared across all months)
3. Compute total month count for progress reporting
4. Iterate month boundaries from MinDate to MaxDate
5. For each month:
   a. Invoke `ProgressCallback` if provided (sends month index, total, `yyyy-MM` label)
   b. Compute `$EffectiveDate` = last day of month (capped at MaxDate)
   c. Obtain month entities (see §6.4 for pre-provided vs auto-fetch paths)
   d. `Get-EntityState -NameIndex $NameIndex -Sessions $Sessions -ActiveOn $EffectiveDate -Quiet` with pre-built name index
   e. Build entity lookup -> `Get-CurrencyEntitiesFiltered -EntityLookup`
   f. Apply denomination/entity filters
   g. `Get-SessionDirectiveEntries` scoped to month boundaries for transfer count
   h. `New-EconomicSnapshotData` for supply computation
6. Return array of monthly PSCustomObjects

**Note**: The `NameIndex` is shared across months since the entity roster does not change within a timeline query. Sessions are passed explicitly to avoid redundant re-parsing each month.

### 6.4 Pre-Provided Entities Optimization

When `-Entities` is provided by the caller, the function avoids re-reading entity files from disk on each month iteration. Instead of calling `Get-Entity -ActiveOn` per month (which re-parses `entities.md`), it filters the pre-provided entities in-memory by status:

- For each entity, `Get-LastActiveValue` checks `StatusHistory` at the effective date
- Entities with `Usunięty` status at the effective date are excluded
- All other entities are passed to `Get-EntityState -ActiveOn` for temporal tag resolution

This reduces I/O from N file reads (one per month) to a single file read, which is a significant speedup for long date ranges (e.g., 12+ months).

When `-Entities` is not provided, the original per-month `Get-Entity -ActiveOn` path is used for full temporal filtering including entity-level `ActiveOn` scoping.

---

## 7. `Get-MaterializationReport`

Physical vs virtual currency analysis with per-player breakdown and orphan detection.

### 7.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-EntityState` (auto-fetched if omitted). |
| `Players` | object[] | Pre-fetched from `Get-Player` (auto-fetched if omitted). |
| `ActiveOn` | datetime | Temporal filter for entity state. |
| `Quiet` | switch | Suppress warnings to stderr. |

### 7.2 Output Schema

| Property | Type | Description |
|---|---|---|
| `DenominationBreakdown` | object[] | Per-denomination: `Denomination`, `Total`, `Physical`, `Virtual`, `PhysicalPct` |
| `PlayerBreakdown` | object[] | Per-player: `PlayerName`, `Characters`, `TotalPhysicalKogi`, `PerDenomination` |
| `OrphanedPhysical` | object[] | Inactive/deleted Postać with active currency: `EntityName`, `Owner`, `Denomination`, `Quantity`, `OwnerStatus` |
| `Summary` | hashtable | `TotalPhysical`, `TotalVirtual`, `OrphanedCount` |

### 7.3 Orphaned Physical Currency

Currency owned by a Postać entity with status `Nieaktywny` or `Usunięty` but the currency itself is `Aktywny` with balance > 0. These represent physical items that need return to coordinators — the player character is no longer active but their Margonem items still exist.

### 7.4 Player Breakdown

Uses `Get-Player` to map Postać entities to their owning players. For each player:
- Lists all characters (Postać entities)
- Sums total physical currency (Kogi base unit)
- Breaks down per denomination with quantities

---

## 8. CLI Integration

Three workflow functions in `private/cli/cli-wf-economy.ps1`:

| Function | Menu Label | Category |
|---|---|---|
| `Invoke-EconomicSnapshotWorkflow` | Obraz gospodarki | Waluta |
| `Invoke-EconomicTimelineWorkflow` | Oś czasu gospodarki | Waluta |
| `Invoke-MaterializationReportWorkflow` | Raport materializacji | Waluta |

Registered in `private/cli/cli-registry.ps1` under the `Waluta` menu category.

---

## 9. Testing

| Test file | Coverage |
|---|---|
| `tests/get-economicsnapshot.Tests.ps1` | Supply breakdown, physical/virtual split, Gini coefficient, top holders, denomination filter, transfers |
| `tests/get-economictimeline.Tests.ps1` | Monthly data points, transfer counting, single month range, empty data handling |
| `tests/get-materializationreport.Tests.ps1` | Denomination breakdown, player mapping, orphaned physical detection, empty entities |
| `tests/currency-helpers.Tests.ps1` | `Resolve-CurrencyOwnerType` (all entity types), `Get-CurrencyEntitiesFiltered` with EntityLookup |

### 9.1 Fixtures

| Fixture | Purpose |
|---|---|
| `tests/fixtures/entities-economy.md` | Mixed Postać/NPC/Grupa owners with known quantities for Gini testing |
| `tests/fixtures/entities-economy-materialization.md` | Active + inactive Postać + NPC owners for orphan detection |
| `tests/fixtures/sessions-zmiany.md` | Sessions with @Transfer directives for transfer counting |

---

## 10. Related Documents

- [CURRENCY.md](CURRENCY.md) - Currency system (denominations, CRUD, reconciliation, @Transfer)
- [ENTITIES.md](ENTITIES.md) - Entity system (tags, temporal scoping)
- [SESSIONS.md](SESSIONS.md) - Session parsing

# Economic Analysis Subsystem

## Scope

The economic analysis subsystem provides physical vs virtual currency classification, supply breakdown, wealth distribution (Gini coefficient), economic snapshots, monthly timelines, and materialization reporting.

Currency CRUD, denomination constants, and @Transfer parsing are documented in [CURRENCY.md](CURRENCY.md). Entity parsing is documented in [ENTITIES.md](ENTITIES.md).

---

## Architecture Overview

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

## Physical vs Virtual Currency Model

Currency entities are classified by their owner's entity type -- no new storage tags required:

| Owner Type | Classification | Meaning |
|---|---|---|
| Postać | Physical | Actual Margonem items in player character equipment |
| NPC | Virtual | RP bookkeeping -- narrative-only currency |
| Grupa | Virtual | Treasury reserves, guild holdings |
| Gracz | Virtual | Player-level currency (not character-level) |
| *(not found)* | Unknown | Owner not in entity lookup |

Physical currency represents items that actually exist in Margonem player equipment. Virtual currency is pure RP bookkeeping -- narrators can allocate virtual currency to NPCs and groups without needing corresponding game items.

`Resolve-CurrencyOwnerType` classifies an owner name:

```powershell
Resolve-CurrencyOwnerType -OwnerName 'Crag Hack' -EntityLookup $Lookup
# Returns: 'Physical' (Crag Hack is a Postać)
```

| Parameter | Type | Description |
|---|---|---|
| `OwnerName` | string | Mandatory. Entity name to classify. |
| `EntityLookup` | Dictionary[string,object] | Mandatory. Case-insensitive name to entity lookup. |

Returns: `'Physical'`, `'Virtual'`, or `'Unknown'`.

---

## New-EconomicSnapshotData

Shared helper in `private/economy-helpers.ps1`. Computes supply breakdown, Gini coefficient, top holders, and transaction statistics from enriched currency items. Used by both `Get-EconomicSnapshot` and `Get-EconomicTimeline`.

| Parameter | Type | Description |
|---|---|---|
| `CurrencyItems` | object[] | Enriched currency items from `Get-CurrencyEntitiesFiltered` (with `OwnerCategory`). Allows null/empty. |
| `TransferEntries` | object[] | Transfer directive entries from `Get-SessionDirectiveEntries`. Allows null/empty. |
| `Top` | int | Number of top holders to include (default: 10). |

Return hashtable:

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

Gini coefficient formula using sorted values:

```
G = (2 * Sigma(i * w[i])) / (n * Sigma(w)) - (n+1)/n
```

Where `w[i]` are per-owner wealth values sorted ascending, `i` is 1-indexed position, `n` is the count of owners with positive wealth. G = 0.0 means all owners hold equal wealth. G approaching 1.0 means one owner holds nearly all wealth. Computed only when 2+ owners have positive wealth; otherwise 0.0.

Entities with status `Usunięty` are excluded from supply calculations. Supply is computed from `Quantity * Denomination.Multiplier` (converting to Kogi base unit).

---

## Get-EconomicSnapshot

Point-in-time economic snapshot with supply breakdown, wealth distribution, and transaction volume.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-EntityState` (auto-fetched if omitted). |
| `Sessions` | object[] | Pre-fetched from `Get-Session` (auto-fetched if omitted). |
| `ActiveOn` | datetime | Temporal filter for entity state. |
| `Owner` | string | Scope to a specific owner entity. |
| `Denomination` | string | Scope to a specific denomination. |
| `Top` | int | Number of top holders (default: 10). |
| `Quiet` | switch | Suppress warnings to stderr. |

Output:

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
| `GiniCoefficient` | double | Wealth inequality (0--1) |
| `TransactionVolume` | int | @Transfer count in scope |
| `TransactionValueKogi` | int | @Transfer sum in base unit |

Implementation flow: (1) Auto-fetch entities and sessions if not provided. (2) Build `$EntityLookup` (case-insensitive name to entity dictionary). (3) `Get-CurrencyEntitiesFiltered -EntityLookup` for enriched currency items with OwnerCategory. (4) Apply denomination and owner filters. (5) `Get-SessionDirectiveEntries -DirectiveName 'Transfers'` for transaction volume. (6) `New-EconomicSnapshotData` for computation. (7) Return PSCustomObject with all snapshot fields.

---

## Get-EconomicTimeline

Monthly supply and transaction trends over a date range.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-Entity` (auto-fetched if omitted). |
| `Sessions` | object[] | Pre-fetched from `Get-Session` (auto-fetched if omitted). |
| `MinDate` | datetime | Mandatory. Start date for timeline. |
| `MaxDate` | datetime | Mandatory. End date for timeline. |
| `Entity` | string | Scope to a specific owner entity. |
| `Denomination` | string | Scope to a specific denomination. |
| `ProgressCallback` | scriptblock | Optional callback for CLI progress reporting. Invoked with `(Current, Total, ItemDetail)` on each month iteration, where `ItemDetail` is the `yyyy-MM` month label. |
| `Quiet` | switch | Suppress warnings to stderr. |

Output is an array of monthly data points:

| Property | Type | Description |
|---|---|---|
| `Month` | string | Month label (`yyyy-MM` format) |
| `TotalSupplyKogi` | int | Total supply in base unit at month end |
| `PhysicalSupplyKogi` | int | Postać-owned supply at month end |
| `VirtualSupplyKogi` | int | NPC/Grupa/Gracz-owned supply at month end |
| `SupplyByDenomination` | hashtable | `{ DenomName = @{ Total; Physical; Virtual } }` |
| `TransferCount` | int | @Transfer count within the month |

Implementation flow: (1) Auto-fetch entities and sessions if not provided. (2) Pre-build `$NameIndex` once via `Get-NameIndex` (shared across all months). (3) Compute total month count for progress reporting. (4) Iterate month boundaries from MinDate to MaxDate. (5) For each month: invoke `ProgressCallback` if provided (sends month index, total, `yyyy-MM` label); compute `$EffectiveDate` = last day of month (capped at MaxDate); obtain month entities (see Pre-Provided Entities Optimization below); `Get-EntityState -NameIndex $NameIndex -Sessions $Sessions -ActiveOn $EffectiveDate -Quiet` with pre-built name index; build entity lookup and `Get-CurrencyEntitiesFiltered -EntityLookup`; apply denomination/entity filters; `Get-SessionDirectiveEntries` scoped to month boundaries for transfer count; `New-EconomicSnapshotData` for supply computation. (6) Return array of monthly PSCustomObjects.

The `NameIndex` is shared across months since the entity roster does not change within a timeline query. Sessions are passed explicitly to avoid redundant re-parsing each month.

When `-Entities` is provided by the caller, the function avoids re-reading entity files from disk on each month iteration. For each entity, `Get-LastActiveValue` checks `StatusHistory` at the effective date. Entities with `Usunięty` status at the effective date are excluded. All other entities are passed to `Get-EntityState -ActiveOn` for temporal tag resolution. This reduces I/O from N file reads (one per month) to a single file read, a significant speedup for long date ranges (e.g., 12+ months). When `-Entities` is not provided, the original per-month `Get-Entity -ActiveOn` path is used for full temporal filtering including entity-level `ActiveOn` scoping.

---

## Get-MaterializationReport

Physical vs virtual currency analysis with per-player breakdown and orphan detection.

| Parameter | Type | Description |
|---|---|---|
| `Entities` | object[] | Pre-fetched from `Get-EntityState` (auto-fetched if omitted). |
| `Players` | object[] | Pre-fetched from `Get-Player` (auto-fetched if omitted). |
| `ActiveOn` | datetime | Temporal filter for entity state. |
| `Quiet` | switch | Suppress warnings to stderr. |

Output:

| Property | Type | Description |
|---|---|---|
| `DenominationBreakdown` | object[] | Per-denomination: `Denomination`, `Total`, `Physical`, `Virtual`, `PhysicalPct` |
| `PlayerBreakdown` | object[] | Per-player: `PlayerName`, `Characters`, `TotalPhysicalKogi`, `PerDenomination` |
| `OrphanedPhysical` | object[] | Inactive/deleted Postać with active currency: `EntityName`, `Owner`, `Denomination`, `Quantity`, `OwnerStatus` |
| `Summary` | hashtable | `TotalPhysical`, `TotalVirtual`, `OrphanedCount` |

Orphaned physical currency represents currency owned by a Postać entity with status `Nieaktywny` or `Usunięty` but the currency itself is `Aktywny` with balance > 0. These represent physical items that need return to coordinators -- the player character is no longer active but their Margonem items still exist.

Player breakdown uses `Get-Player` to map Postać entities to their owning players. For each player: lists all characters (Postać entities), sums total physical currency (Kogi base unit), and breaks down per denomination with quantities.

---

## CLI Integration

Three workflow functions in `private/cli/cli-wf-economy.ps1`:

| Function | Menu Label | Category |
|---|---|---|
| `Invoke-EconomicSnapshotWorkflow` | Obraz gospodarki | Waluta |
| `Invoke-EconomicTimelineWorkflow` | Oś czasu gospodarki | Waluta |
| `Invoke-MaterializationReportWorkflow` | Raport materializacji | Waluta |

Registered in `private/cli/cli-registry.ps1` under the `Waluta` menu category.

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/get-economicsnapshot.Tests.ps1` | Supply breakdown, physical/virtual split, Gini coefficient, top holders, denomination filter, transfers |
| `tests/get-economictimeline.Tests.ps1` | Monthly data points, transfer counting, single month range, empty data handling |
| `tests/get-materializationreport.Tests.ps1` | Denomination breakdown, player mapping, orphaned physical detection, empty entities |
| `tests/currency-helpers.Tests.ps1` | `Resolve-CurrencyOwnerType` (all entity types), `Get-CurrencyEntitiesFiltered` with EntityLookup |

Fixtures:

| Fixture | Purpose |
|---|---|
| `tests/fixtures/entities-economy.md` | Mixed Postać/NPC/Grupa owners with known quantities for Gini testing |
| `tests/fixtures/entities-economy-materialization.md` | Active + inactive Postać + NPC owners for orphan detection |
| `tests/fixtures/sessions-zmiany.md` | Sessions with @Transfer directives for transfer counting |

---

## Compiled C# Type — Robot.EconomicAnalyzer

Source: `lib/EconomicAnalyzer.cs` -- compiled centrally in `robot.psm1`.

`Robot.EconomicAnalyzer` provides economic analysis for snapshot and timeline reporting. Two static operations:

`ComputeGini(int[] positiveWealth)` computes the Gini coefficient from positive-wealth values using the standard formula: `G = (2 * SUM(i * w[i])) / (n * SUM(w)) - (n+1)/n`. O(n log n) from `Array.Sort`, O(n) accumulation. Mutates the input array (sorts ascending in place). Returns `0.0` for `n <= 1` or `sumW == 0`.

`GetTopHolders(string[] ownerNames, int[] ownerWealth, string[] ownerCategories, int top, out string[] topNames, out int[] topWealth, out string[] topCategories)` performs top-N extraction via index-array sort. Uses full sort (simpler than partial sort for typical sizes of 50--200 holders). Returns parallel arrays through `out` parameters for direct PowerShell consumption via `[ref]`. Returns empty arrays when input is null/empty or `top <= 0`. Sorts by wealth descending via index indirection to preserve parallel array alignment.

Compiled centrally in `robot.psm1` at module import time. Consumer code checks availability with `([System.Management.Automation.PSTypeName]'Robot.EconomicAnalyzer').Type` and falls back to an equivalent PowerShell implementation when the type is unavailable.

Consumer: `New-EconomicSnapshotData` (`private/economy-helpers.ps1`) -- calls both `ComputeGini` and `GetTopHolders` when the C# type is available, falling back to PowerShell Sort-Object/ScriptBlock comparisons otherwise.

---

## Related Documents

- [CURRENCY.md](CURRENCY.md) -- Currency system (denominations, CRUD, reconciliation, @Transfer)
- [ENTITIES.md](ENTITIES.md) -- Entity system (tags, temporal scoping)
- [SESSIONS.md](SESSIONS.md) -- Session parsing
- [REST-API.md](REST-API.md) -- REST API economy endpoints (`/economy/snapshot`, `/economy/timeline`)

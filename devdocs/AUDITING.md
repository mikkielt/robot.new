# Audit Utility Functions - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the five read-only audit/reporting functions in `public/reporting/`:

| Function | File | Purpose |
|---|---|---|
| `Get-EntityHistory` | `get-entityhistory.ps1` | Unified timeline of a single entity's changes |
| `Get-ChangeLog` | `get-changelog.ps1` | Cross-entity `@Zmiany` extraction from sessions |
| `Get-TransactionLedger` | `get-transactionledger.ps1` | `@Transfer` directive ledger with running balance |
| `Get-PUAssignmentLog` | `get-puassignmentlog.ps1` | Structured parse of `pu-sessions.md` state file |
| `Get-NotificationLog` | `get-notificationlog.ps1` | `@Intel` directive extraction from sessions |

All functions are read-only. None modify entity files, session files, or state files.

**Not covered**: Currency reporting (`Get-CurrencyReport`) and reconciliation (`Test-CurrencyReconciliation`) - see [CURRENCY.md](CURRENCY.md). PU diagnostic validation (`Test-PlayerCharacterPUAssignment`) - see [PU.md](PU.md). Named location analysis (`Get-NamedLocationReport`) - standalone reporting function.

---

## 2. Architecture Overview

```
public/reporting/
├── get-entityhistory.ps1       Entity timeline (reads entity history arrays)
├── get-changelog.ps1           Session Zmiany extraction
├── get-transactionledger.ps1   Session Transfer extraction
│   └── dot-sources: private/currency-helpers.ps1
├── get-puassignmentlog.ps1     State file parsing
│   └── dot-sources: private/admin-state.ps1
└── get-notificationlog.ps1     Session Intel extraction
```

All functions follow the module's established patterns:
- Pre-fetched data parameters (`$Entities`, `$Sessions`) with auto-fetch if omitted
- `[CmdletBinding()]` with `HelpMessage` on all parameters
- `.NET generic collections` (`List[object]`) for result accumulation
- `PSCustomObject` output wrapped in `@()` for consistent array return
- Warnings to stderr via `[System.Console]::Error.WriteLine`
- Compatible with PowerShell 5.1 and 7.0+

---

## 3. `Get-EntityHistory`

### 3.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Name` | string | Yes (Position 0) | Entity name to look up |
| `MinDate` | datetime | No | Filter: include only entries with `ValidFrom >= MinDate` |
| `MaxDate` | datetime | No | Filter: include only entries with `ValidFrom <= MaxDate` |
| `Entities` | object[] | No | Pre-fetched entities from `Get-EntityState` |
| `Sessions` | object[] | No | Pre-fetched sessions (passed through to `Get-EntityState`) |

### 3.2 Algorithm

1. Auto-fetch `Get-EntityState` if `$Entities` not provided
2. Find entity by name: first exact match on `.Name`, then scan `.Names` list (aliases). Case-insensitive (`OrdinalIgnoreCase`)
3. Iterate all seven history arrays, mapping each to a uniform output shape:

| History Array | Display Name | Value Property |
|---|---|---|
| `LocationHistory` | `Lokacja` | `.Location` |
| `StatusHistory` | `Status` | `.Status` |
| `GroupHistory` | `Grupa` | `.Group` |
| `OwnerHistory` | `Właściciel` | `.OwnerName` |
| `TypeHistory` | `Typ` | `.Type` |
| `DoorHistory` | `Drzwi` | `.Location` |
| `QuantityHistory` | `Ilość` | `.Quantity` |

4. Apply date range filter on `ValidFrom` (skip entries outside range; `$null` ValidFrom entries pass through unless `MinDate` is set)
5. Sort by `Date` ascending (`$null` sorts before dated entries)

### 3.3 Output Schema

| Property | Type | Description |
|---|---|---|
| `Date` | datetime? | `ValidFrom` from the history entry |
| `DateEnd` | datetime? | `ValidTo` from the history entry |
| `Property` | string | Human-readable tag name (Polish) |
| `Value` | string | The property-specific value |

### 3.4 Edge Cases

| Scenario | Behavior |
|---|---|
| Entity not found | Warning to stderr, returns `@()` |
| Entity found by alias | Works (scans `.Names` list) |
| History array is `$null` | Skipped (StatusHistory and QuantityHistory are lazy-initialized) |
| Empty history array | Skipped |
| All entries filtered by date range | Returns `@()` |
| `$null` ValidFrom | Entry included (sorts first); filtered out only if `MinDate` is set |

---

## 4. `Get-ChangeLog`

### 4.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `MinDate` | datetime | No | Filter sessions by date |
| `MaxDate` | datetime | No | Filter sessions by date |
| `EntityName` | string | No | Filter to changes affecting this entity |
| `Property` | string | No | Filter to a specific tag name (e.g. `lokacja`, `grupa`) |
| `Sessions` | object[] | No | Pre-fetched sessions from `Get-Session` |

### 4.2 Algorithm

1. Auto-fetch `Get-Session` if `$Sessions` not provided (passes `MinDate`/`MaxDate` to fetch)
2. Iterate sessions with non-empty `.Changes` and non-null `.Date`
3. Apply date range filter on `Session.Date`
4. For each `Change` in `Session.Changes`, for each `TagEntry` in `Change.Tags`:
   - Strip `@` prefix from `TagEntry.Tag`
   - Apply `EntityName` filter (case-insensitive)
   - Apply `Property` filter (case-insensitive match on stripped tag name)
5. Sort by date ascending, then entity name ascending

### 4.3 Output Schema

| Property | Type | Description |
|---|---|---|
| `Date` | datetime | Session date |
| `SessionTitle` | string | Session title |
| `Narrator` | string | Narrator name (from `Session.Narrator.Name`) |
| `EntityName` | string | Entity name from the Change entry |
| `Property` | string | Tag name without `@` prefix |
| `Value` | string | Tag value (raw, including temporal annotations) |

### 4.4 Data Source

Reads from `Session.Changes`, which is populated by `Get-Session` when parsing `@Zmiany` / `Zmiany:` blocks. Each change has:
- `EntityName` (string) - the entity targeted
- `Tags` (array of `@{ Tag; Value }`) - the `@tag: value` pairs

See [SESSIONS.md](SESSIONS.md) for the session parsing specification.

---

## 5. `Get-TransactionLedger`

### 5.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Entity` | string | No | Filter to transactions involving this entity (source or destination) |
| `Denomination` | string | No | Filter by denomination (canonical, short, or stem) |
| `MinDate` | datetime | No | Filter sessions by date |
| `MaxDate` | datetime | No | Filter sessions by date |
| `Sessions` | object[] | No | Pre-fetched sessions from `Get-Session` |
| `Entities` | object[] | No | Pre-fetched entities (unused currently, reserved for future denomination context) |

### 5.2 Algorithm

1. Auto-fetch `Get-Session` if `$Sessions` not provided
2. Resolve `$Denomination` filter via `Resolve-CurrencyDenomination` (returns `$null` + stderr warning if unrecognized)
3. Iterate sessions with non-empty `.Transfers` and non-null `.Date`
4. For each `Transfer` in `Session.Transfers`:
   - Resolve denomination via `Resolve-CurrencyDenomination`
   - Apply denomination filter
   - Apply entity filter (case-insensitive match on `.Source` or `.Destination`)
   - When entity filter is active: add `Direction` property (`'In'` if entity is destination, `'Out'` if source)
5. Sort chronologically by session date
6. When entity filter is active: compute running balance (cumulative sum, `+Amount` for In, `-Amount` for Out), add `RunningBalance` property via `Add-Member`

### 5.3 Output Schema

| Property | Type | Conditional | Description |
|---|---|---|---|
| `Date` | datetime | Always | Session date |
| `SessionTitle` | string | Always | Session title |
| `Narrator` | string | Always | Narrator name |
| `Amount` | int | Always | Transfer amount |
| `Denomination` | string | Always | Canonical denomination name |
| `Source` | string | Always | Source entity name |
| `Destination` | string | Always | Destination entity name |
| `Direction` | string | `-Entity` only | `'In'` or `'Out'` relative to filtered entity |
| `RunningBalance` | int | `-Entity` only | Cumulative balance from transfers |

### 5.4 Dot-Sources

- `private/currency-helpers.ps1` - for `Resolve-CurrencyDenomination`

### 5.5 Edge Cases

| Scenario | Behavior |
|---|---|
| Unknown denomination in filter | Warning to stderr, returns `@()` |
| Unknown denomination in transfer | Falls back to raw `Transfer.Denomination` string |
| Entity is both source and destination in same transfer | Not possible (self-transfer); if it were, `Direction` would be `'Out'` (source match checked first) |
| No `-Entity` filter | `Direction` and `RunningBalance` properties are not added |

---

## 6. `Get-PUAssignmentLog`

### 6.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Path` | string | No | Path to the PU sessions state file. Default: `<CWD>/.robot/res/pu-sessions.md` |
| `MinDate` | datetime | No | Filter runs by `ProcessedAt` timestamp |
| `MaxDate` | datetime | No | Filter runs by `ProcessedAt` timestamp |

### 6.2 Algorithm

1. Default `$Path` to `Join-Path (Get-Location) '.robot/res/pu-sessions.md'`
2. Read file via `[System.IO.File]::ReadAllText()` (UTF-8 no BOM)
3. Line-by-line parsing with two precompiled regex patterns:
   - **Timestamp line**: `^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+\(([^)]+)\):\s*$` (captures datetime and timezone)
   - **Session header line**: `^\s+-\s+###\s+(.+)$` (reuses `$script:HistoryEntryPattern` from `admin-state.ps1`)
4. Groups session headers under their preceding timestamp
5. Parses each session header by splitting on `,` to extract date, title, narrator
6. Apply date range filter on `ProcessedAt`
7. Sort by `ProcessedAt` descending (most recent first)

### 6.3 Output Schema

| Property | Type | Description |
|---|---|---|
| `ProcessedAt` | datetime | When the PU run was executed |
| `Timezone` | string | Timezone string (e.g. `UTC+02:00`) |
| `SessionCount` | int | Number of sessions in this run |
| `Sessions` | object[] | Array of parsed session objects |

**Session sub-object:**

| Property | Type | Description |
|---|---|---|
| `Header` | string | Normalized session header string |
| `Date` | datetime? | Parsed date from header (first comma-separated element) |
| `Title` | string? | Session title (second element) |
| `Narrator` | string? | Narrator name (third element) |

### 6.4 Dot-Sources

- `private/admin-state.ps1` - for `$script:HistoryEntryPattern` and `$script:MultiSpacePattern`

### 6.5 State File Format

The function reads the append-only state file written by `Add-AdminHistoryEntry`. Format:

```
- 2025-07-15 14:30 (UTC+02:00):
    - ### 2025-06-01, Powrót zdrowia, Crag Hack
    - ### 2025-06-15, Ucieczka z Erathii, Catherine
```

See [CONFIG-STATE.md](CONFIG-STATE.md) for the complete state file specification.

### 6.6 Edge Cases

| Scenario | Behavior |
|---|---|
| File does not exist | Warning to stderr, returns `@()` |
| File exists but has no timestamp lines | Returns `@()` |
| Session header with fewer than 3 comma-separated parts | Missing parts are `$null` |
| Unparseable date in session header | `Date` is `$null` |
| Unparseable timestamp line | Skipped (neither regex matches) |

---

## 7. `Get-NotificationLog`

### 7.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Target` | string | No | Filter by recipient or target name |
| `Directive` | string | No | Filter by directive type. `ValidateSet`: `Direct`, `Grupa`, `Lokacja` |
| `MinDate` | datetime | No | Filter sessions by date |
| `MaxDate` | datetime | No | Filter sessions by date |
| `Sessions` | object[] | No | Pre-fetched sessions from `Get-Session` |
| `Entities` | object[] | No | Pre-fetched entities (passed to `Get-Session` for Intel resolution) |

### 7.2 Algorithm

1. Auto-fetch `Get-Session` if `$Sessions` not provided (passes `MinDate`, `MaxDate`, `Entities`)
2. Iterate sessions with non-empty `.Intel` and non-null `.Date`
3. Apply date range filter on `Session.Date`
4. For each `Intel` entry in `Session.Intel`:
   - Apply `$Directive` filter (case-insensitive match on `Intel.Directive`)
   - Extract recipient names from `Intel.Recipients[].Name`
   - Apply `$Target` filter: case-insensitive match against `Intel.TargetName` or any recipient name
5. Sort chronologically by session date

### 7.3 Output Schema

| Property | Type | Description |
|---|---|---|
| `Date` | datetime | Session date |
| `SessionTitle` | string | Session title |
| `Narrator` | string | Narrator name |
| `Directive` | string | `'Direct'`, `'Grupa'`, or `'Lokacja'` |
| `TargetName` | string | The targeting name (group, location, or entity name) |
| `Message` | string | Intel message content |
| `RecipientCount` | int | Number of resolved recipients |
| `Recipients` | string[] | Array of resolved recipient names |

### 7.4 Data Source

Reads from `Session.Intel`, populated by `Get-Session` during Intel resolution. Each Intel entry has:
- `RawTarget` (string) - original target text
- `Message` (string) - message content
- `Directive` (string) - `'Direct'`, `'Grupa'`, or `'Lokacja'`
- `TargetName` (string) - resolved target name
- `Recipients` (object[]) - array of `@{ Name; Type; Webhook }` objects

Intel resolution (fan-out for `Grupa/` and `Lokacja/` directives) happens inside `Get-Session`, not in `Get-NotificationLog`. See [SESSIONS.md](SESSIONS.md) §Intel for the resolution algorithm.

### 7.5 Limitation

This function reconstructs notification **intent** from session data. It does not track actual Discord delivery (no delivery logging exists in the current implementation). To confirm delivery, cross-reference with Discord channel history.

---

## 8. Common Patterns

### 8.1 Pre-Fetch Pattern

All functions that accept `$Entities` or `$Sessions` auto-fetch when not provided:

```powershell
if (-not $Entities) {
    $Entities = Get-EntityState @FetchArgs
}
if (-not $Sessions) {
    $Sessions = Get-Session @FetchArgs
}
```

When calling multiple audit functions on the same data, pre-fetch once and pass to all:

```powershell
$Entities = Get-EntityState
$Sessions = Get-Session -MinDate '2025-01-01' -MaxDate '2025-12-31'

$History     = Get-EntityHistory -Name 'Kupiec Orrin' -Entities $Entities
$Changes     = Get-ChangeLog -Sessions $Sessions
$Transfers   = Get-TransactionLedger -Sessions $Sessions
$Notifications = Get-NotificationLog -Sessions $Sessions -Entities $Entities
```

### 8.2 Sorting

All functions sort output chronologically using `System.Comparison[object]` delegates:

```powershell
$List.Sort([System.Comparison[object]]{
    param($a, $b)
    return $a.Date.CompareTo($b.Date)
})
```

`Get-EntityHistory` handles `$null` dates (sorts before dated entries). `Get-PUAssignmentLog` sorts descending (most recent first).

### 8.3 String Comparison

All name matching uses `[System.StringComparison]::OrdinalIgnoreCase`:

```powershell
[string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)
```

---

## 9. Testing

| Test file | Coverage |
|---|---|
| `tests/get-entityhistory.Tests.ps1` | Timeline merging, history type coverage, date filtering, chronological sorting, unknown entity handling, alias lookup, empty history |
| `tests/get-changelog.Tests.ps1` | Zmiany extraction, entity/property/date filtering, @-prefix stripping, multi-session aggregation, empty sessions |
| `tests/get-transactionledger.Tests.ps1` | Transfer extraction, entity filter (source/destination), direction tagging, running balance, denomination filter, empty sessions |
| `tests/get-puassignmentlog.Tests.ps1` | Timestamp parsing, session grouping, descending sort, header parsing (date/title/narrator), date filtering, missing/empty file |
| `tests/get-notificationlog.Tests.ps1` | Intel extraction, directive filtering, target name filtering, date filtering, recipient resolution, empty sessions |

**Fixture files used:**

| Fixture | Used by |
|---|---|
| `entities.md` | Get-EntityHistory, Get-NotificationLog |
| `sessions-deep-zmiany.md` | Get-EntityHistory, Get-ChangeLog |
| `sessions-changes.md` | Get-ChangeLog |
| `sessions-multi-transfer.md` | Get-TransactionLedger |
| `sessions-zmiany.md` | Get-TransactionLedger |
| `sessions-gen4-full.md` | Get-NotificationLog |
| `pu-sessions-sample.md` | Get-PUAssignmentLog |

---

## 10. Related Documents

- [ENTITIES.md](ENTITIES.md) - Entity data model and temporal history arrays
- [SESSIONS.md](SESSIONS.md) - Session parsing (Changes, Transfers, Intel)
- [CURRENCY.md](CURRENCY.md) - Currency reporting and reconciliation
- [PU.md](PU.md) - PU assignment pipeline and diagnostic validation
- [CONFIG-STATE.md](CONFIG-STATE.md) - State file formats (pu-sessions.md)

# Data Structures - Technical Reference

## Scope

All PSCustomObject shapes and compiled C# types returned by Robot module functions are catalogued with exact property names, types, and the source file where each structure originates.

Behavioral documentation (algorithms, edge cases, parameters) lives in the per-subsystem devdocs; only shapes are covered below.

General entity behavior: [ENTITIES.md](ENTITIES.md). Session parsing: [SESSIONS.md](SESSIONS.md). Currency subsystem: [CURRENCY.md](CURRENCY.md). Player management: [CHARFILE.md](CHARFILE.md). Reporting: [ECONOMY.md](ECONOMY.md), [SESSION-GRAPH.md](SESSION-GRAPH.md), [LOCATION-GRAPH.md](LOCATION-GRAPH.md), [LOGS.md](LOGS.md). Auditing: [AUDITING.md](AUDITING.md). Write internals: [ENTITY-WRITES.md](ENTITY-WRITES.md).

## Architecture Overview

```
                    C# Compiled Types (lib/*.cs)
                    ============================
Robot.Entity ─────────────────────── Central 28-property domain model
Robot.TemporalEntry ──────────────── History list entries (string value)
Robot.CoordinateTemporalEntry ────── History list entries (X/Y coordinates)
Robot.NarratorResult ─────────────── Narrator resolution with confidence
Robot.Narrator ───────────────────── Individual narrator entry
Robot.SessionPU ──────────────────── PU award from session
Robot.SessionChange ──────────────── @Zmiany entity directive
Robot.SessionTag ─────────────────── @tag: value pair
Robot.SessionIntel ───────────────── @Intel message
Robot.SessionTransfer ────────────── @Transfer currency directive
Robot.LogParser.ParseResult ──────── Parsed log file container
Robot.LogParser.LogLine ──────────── Single log line (struct)
Robot.LogParser.LocationSegment ──── Location boundary in log
Robot.MarkdownScanner.ScanResult ─── Parsed markdown file
Robot.MarkdownScanner.HeaderEntry ── Markdown header (struct)
Robot.MarkdownScanner.SectionEntry ─ Section between headers
Robot.MarkdownScanner.ListEntry ──── Bullet/numbered list item
Robot.MarkdownScanner.LinkEntry ──── Markdown link or plain URL (struct)
Robot.MapEntry ───────────────────── Mapa entity input for traversal graph
Robot.MapEdge ────────────────────── Mapa→Mapa transition edge (struct)
Robot.LocationEdge ───────────────── Lokacja→Lokacja projected edge (struct)
Robot.ResolvedSegment ────────────── Per-segment resolution detail (struct)
Robot.TraversalResult ────────────── Map traversal graph output container

                    PowerShell PSCustomObjects
                    ==========================
Session ──────────────────────────── Full session with metadata
Player ───────────────────────────── Player with character list
Character ────────────────────────── Character nested in Player
PlayerCharacter ──────────────────── Character with merged state
CharacterFile ────────────────────── Parsed character file
Reputation ───────────────────────── Three-tier reputation container
ReputationEntry ──────────────────── Location + detail pair
DescribedSession ─────────────────── Session entry from character file
CurrencyDenomination ─────────────── Denomination constant definition
CurrencyEntity ───────────────────── Currency entity query result
CurrencyReport ───────────────────── Currency holdings report entry
CurrencyReconciliation ───────────── Reconciliation check result
ReconciliationWarning ────────────── Individual warning entry
EconomicSnapshot ─────────────────── Point-in-time economic state
EconomicTimelineEntry ────────────── Monthly economic data point
MaterializationReport ────────────── Physical vs virtual analysis
LocationEntity ───────────────────── Enriched location query result
LocationGraphEdge ────────────────── Location connectivity edge
SessionGraphParticipant ──────────── Entity participation record
SessionGraphSummary ──────────────── Graph-level statistics
EntityHistory ────────────────────── Property timeline entry
ChangeLog ────────────────────────── Session change report entry
TransactionLedger ────────────────── Transfer report entry
PUAssignmentLog ──────────────────── PU batch processing entry
NotificationLog ──────────────────── Intel delivery report entry
```

## Entity Object

Compiled C# type `Robot.Entity` in `lib/EntityModel.cs`. Returned by `Get-Entity` and enriched by `Get-EntityState`.

| Property | Type | Description |
|---|---|---|
| `Name` | string | Canonical display name |
| `CN` | string | Hierarchical canonical name (type-qualified path) |
| `Names` | HashSet[string] | All searchable names (name + aliases + Nerthus name + slugs) |
| `Aliases` | List[TemporalEntry] | Alternative names with temporal validity |
| `Type` | string | Entity type: NPC, Grupa, Lokacja, Mapa, Gracz, Postać, Przedmiot |
| `Owner` | string | Current owner entity name |
| `Groups` | List[string] | Current group memberships (all active values) |
| `Location` | string | Current permanent location |
| `Doors` | List[string] | Door connections to other locations |
| `Status` | string | Aktywny, Nieaktywny, or Usunięty |
| `Quantity` | string | Numeric quantity (used by currency entities for balance) |
| `FilePath` | string | Associated file path (character files, overflow entities) |
| `NerthusName` | string | RP override name (Nerthus server name for a Margonem location) |
| `Coordinates` | hashtable | `@{ X = [int]; Y = [int] }` map coordinates |
| `IsExterior` | bool? | Computed exterior classification: `$true` (exterior), `$false` (interior with evidence), `$null` (no data). Lokacja only. |
| `TypeHistory` | List[TemporalEntry] | Full type change timeline |
| `OwnerHistory` | List[TemporalEntry] | Full owner change timeline |
| `GroupHistory` | List[TemporalEntry] | Full group membership timeline |
| `LocationHistory` | List[TemporalEntry] | Full location change timeline |
| `DoorHistory` | List[TemporalEntry] | Full door connection timeline |
| `StatusHistory` | List[TemporalEntry] | Full status change timeline |
| `QuantityHistory` | List[TemporalEntry] | Full quantity change timeline |
| `FilePathHistory` | List[TemporalEntry] | Full file path change timeline |
| `NerthusNameHistory` | List[TemporalEntry] | Full Nerthus name change timeline |
| `CoordinateHistory` | List[CoordinateTemporalEntry] | Full coordinate change timeline |
| `Overrides` | Dictionary[string, List[string]] | Tag overrides from character files |
| `GenericNames` | List[string] | Generic/canonical names (e.g., denomination names for currency) |
| `Contains` | List[string] | Child entity names (location hierarchy) |
| `UnresolvedTransfers` | List[string] | Transfer directives that could not be resolved (diagnostics) |

Current scalar properties (`Type`, `Owner`, `Location`, `Status`, etc.) hold the last-active value resolved from their corresponding history list. History lists contain `TemporalEntry` or `CoordinateTemporalEntry` objects sorted by `ValidFrom`.

## Temporal History Types

Compiled C# types in `lib/TemporalEntry.cs`. Used in all entity history lists.

`Robot.TemporalEntry` — temporal value container for string-valued properties:

| Property | Type | Description |
|---|---|---|
| `Value` | string | The property value |
| `ValidFrom` | DateTime? | Start of validity period (`$null` = always active) |
| `ValidTo` | DateTime? | End of validity period (`$null` = open-ended) |
| `Season` | string | Season restriction: wiosna, lato, jesień, zima (`$null` = no season filter) |

`Robot.CoordinateTemporalEntry` — spatial variant for `@koordynaty` history:

| Property | Type | Description |
|---|---|---|
| `X` | int | X coordinate |
| `Y` | int | Y coordinate |
| `ValidFrom` | DateTime? | Start of validity period |
| `ValidTo` | DateTime? | End of validity period |
| `Season` | string | Season restriction |

## Map Traversal Types

Compiled C# types in `lib/MapTraversalGraph.cs`. Used by `Get-MapTraversalGraph` and consumed by `Get-LocationGraph`.

`Robot.MapEntry` — input entry for map traversal graph building (one per Mapa entity):

| Property | Type | Description |
|---|---|---|
| `Name` | string | Mapa entity name |
| `Aliases` | string[] | All names from entity `Names[]` array (includes primary Name) |
| `MargonemId` | string | `@margonemid` value |
| `ParentLocation` | string | `@lokacja` value (parent Lokacja name) |
| `MapType` | string | Entity Type: `zewnętrzna` or `wewnętrzna` |

`Robot.MapEdge` (struct) — Mapa-to-Mapa transition edge:

| Property | Type | Description |
|---|---|---|
| `Source` | string | Source map name (resolved) |
| `Target` | string | Target map name (resolved) |
| `Weight` | int | Number of times this transition was observed |
| `FirstSeenDate` | string | Earliest session date (`yyyy-MM-dd`) |
| `LastSeenDate` | string | Latest session date (`yyyy-MM-dd`) |

`Robot.LocationEdge` (struct) — projected Lokacja-to-Lokacja edge:

| Property | Type | Description |
|---|---|---|
| `Source` | string | Source Lokacja name (from `MapEntry.ParentLocation`) |
| `Target` | string | Target Lokacja name |
| `Weight` | int | Aggregated weight from contributing MapEdges |
| `FirstSeenDate` | string | Earliest date (`yyyy-MM-dd`) |
| `LastSeenDate` | string | Latest date (`yyyy-MM-dd`) |

`Robot.ResolvedSegment` (struct) — per-segment resolution detail:

| Property | Type | Description |
|---|---|---|
| `Raw` | string | Original raw map name from log |
| `Resolved` | string | Resolved Mapa entity name (`null` if unresolved) |
| `Stage` | string | Resolution stage: `Exact`, `SuffixStrip`, `WordDrop`, or `Unresolved` |
| `StrippedName` | string | Intermediate candidate that matched (for SuffixStrip/WordDrop) |
| `ParentLocation` | string | Parent Lokacja of resolved map (`null` if unresolved) |
| `SessionIndex` | int | Index into the sessionSegments array |

`Robot.TraversalResult` — map traversal graph output container:

| Property | Type | Description |
|---|---|---|
| `MapEdges` | MapEdge[] | Mapa-to-Mapa transition edges |
| `LocationEdges` | LocationEdge[] | Projected Lokacja-to-Lokacja edges |
| `Segments` | ResolvedSegment[] | Per-segment resolution detail |
| `UnresolvedNames` | string[] | Distinct names that failed all resolution stages |
| `TotalSegments` | int | Total segments processed |
| `ResolvedCount` | int | Number of resolved segments |
| `UnresolvedCount` | int | Number of unresolved segments |

`TraversalUpdateResult` — return type of `Set-TraversalEntities`:

| Property | Type | Description |
|---|---|---|
| `DoorCandidates` | PSCustomObject[] | All `@drzwi` candidate pairs above weight threshold |
| `DoorsApplied` | PSCustomObject[] | Pairs where at least one direction was written |
| `DoorsSkipped` | PSCustomObject[] | Pairs skipped due to existing `@drzwi` |
| `MapSuggestions` | PSCustomObject[] | Unresolved map names meeting count threshold |
| `TraversalSummary` | PSCustomObject | Stats from `Get-MapTraversalGraph` |
| `GraphSummary` | PSCustomObject | Stats from `Get-LocationGraph` |

`DoorCandidate` — entry in `DoorCandidates`/`DoorsApplied`/`DoorsSkipped`:

| Property | Type | Description |
|---|---|---|
| `Source` | string | Lokacja A (alphabetically first in canonical key) |
| `Target` | string | Lokacja B |
| `Weight` | int | Aggregated traversal weight |
| `FirstSeen` | datetime | Earliest date this transition was observed |
| `LastSeen` | datetime | Latest date |
| `PossiblyStale` | bool | Coordinates changed after edge creation |

`MapSuggestion` — entry in `MapSuggestions`:

| Property | Type | Description |
|---|---|---|
| `RawName` | string | Most frequent raw form of the unresolved name |
| `BaseName` | string | After suffix stripping |
| `InferredParent` | string | Most frequent adjacent Lokacja parent |
| `Count` | int | Total occurrences across all sessions |
| `Variants` | string[] | All distinct raw forms seen |

## Session Object

PSCustomObject built in `public/session/get-session.ps1` (lines 902-922). Returned by `Get-Session`.

| Property | Type | Description |
|---|---|---|
| `FilePath` | string | Source Markdown file path |
| `FilePaths` | string[] | All file paths (populated after cross-file deduplication) |
| `Header` | string | Raw header text: `### YYYY-MM-DD, Title, Narrator` |
| `Date` | DateTime | Parsed session date |
| `DateEnd` | DateTime | End date (from `/DD` suffix, or same as `Date`) |
| `Title` | string | Extracted session title |
| `Narrator` | Robot.NarratorResult | Resolved narrator with confidence (see Narrator Types) |
| `Locations` | string[] | Location names extracted from session metadata |
| `Logs` | string[] | Log URLs |
| `PU` | Robot.SessionPU[] | PU award entries |
| `Format` | string | Generation format: Gen1, Gen2, Gen3, or Gen4 |
| `IsMerged` | bool | Whether this session was deduplicated from multiple files |
| `DuplicateCount` | int | Number of source copies merged (1 = no duplicates) |
| `Content` | string | Raw session body text (only with `-IncludeContent`) |
| `Changes` | Robot.SessionChange[] | `@Zmiany` entity change directives |
| `Transfers` | Robot.SessionTransfer[] | `@Transfer` currency directives |
| `Mentions` | object[] | Entity names mentioned in session content |
| `Intel` | object[] | Resolved `@Intel` messages with recipients |
| `ParseError` | string | Error message (only for failed sessions with `-IncludeFailed`) |
| `LogData` | object | Fetched and parsed log content (only with `-IncludeLogs`) |

`Intel` array elements after resolution contain: `RawTarget` (string), `Message` (string), `Directive` (string: Grupa, Lokacja, or Direct), `TargetName` (string), `Recipients` (object[] with `Name`, `Type`, `Webhook`).

`Mentions` array elements contain: `Name` (string), `Type` (string), `Owner` (object).

## Session Metadata Types

Compiled C# types in `lib/SessionMetadata.cs`. Extracted by `Robot.SessionExtractor` or PowerShell fallback.

`Robot.SessionPU` — PU award entry:

| Property | Type | Description |
|---|---|---|
| `Character` | string | Character name |
| `Value` | object | PU value (decimal or `$null` for malformed entries) |

`Robot.SessionChange` — entity change directive from `@Zmiany` block:

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Target entity name |
| `Tags` | Robot.SessionTag[] | Array of tag overrides |

`Robot.SessionTag` — single tag within a change directive:

| Property | Type | Description |
|---|---|---|
| `Tag` | string | Tag name (e.g., `@lokacja`, `@grupa`, `@status`) |
| `Value` | string | Tag value |

`Robot.SessionIntel` — intelligence message from `@Intel` block:

| Property | Type | Description |
|---|---|---|
| `RawTarget` | string | Target specification (group name, location name, or direct entity) |
| `Message` | string | Intel message text |

`Robot.SessionTransfer` — currency transfer from `@Transfer` directive:

| Property | Type | Description |
|---|---|---|
| `Amount` | int | Transfer quantity |
| `Denomination` | string | Denomination reference (canonical, short, or stem) |
| `Source` | string | Source entity name |
| `Destination` | string | Destination entity name |

## Narrator Types

Compiled C# types in `lib/NarratorResult.cs`. Returned as `Session.Narrator`.

`Robot.NarratorResult` — narrator resolution result:

| Property | Type | Description |
|---|---|---|
| `Narrators` | Robot.Narrator[] | Array of resolved narrator entries |
| `IsCouncil` | bool | Whether the session is a Council (Rada) session |
| `Confidence` | string | Overall confidence level |
| `RawText` | string | Original narrator text from session header |

`Robot.Narrator` — individual narrator entry:

| Property | Type | Description |
|---|---|---|
| `Name` | string | Narrator name |
| `Player` | object | Resolved Player PSCustomObject (backreference) |
| `Confidence` | string | Resolution confidence for this narrator |

## Player Object

PSCustomObject built in `public/player/get-player.ps1` (lines 217-224). Returned by `Get-Player`.

| Property | Type | Description |
|---|---|---|
| `Name` | string | Player name |
| `CN` | string | Hierarchical canonical name (`Gracz/{PlayerName}`) |
| `Names` | HashSet[string] | All searchable names (player name + character names + aliases), case-insensitive |
| `MargonemID` | string | Margonem game ID (or `$null`) |
| `PRFWebhook` | string | Discord webhook URL for notifications (or `$null`) |
| `Triggers` | string[] | Restricted topic triggers |
| `Characters` | List[object] | List of Character objects |

## Character Object

PSCustomObject built in `public/player/get-player.ps1` (lines 158-168). Nested in `Player.Characters`.

| Property | Type | Description |
|---|---|---|
| `Name` | string | Character name |
| `CN` | string | Hierarchical canonical name (`Postać/{CharacterName}`) |
| `IsActive` | bool | Whether the character is marked active in Gracze.md |
| `Aliases` | string[] | Alternative names |
| `Path` | string | Character file path (empty string if none) |
| `PUExceeded` | decimal? | PU overflow amount (or `$null`) |
| `PUStart` | decimal? | Starting PU value (or `$null`) |
| `PUSum` | decimal? | Total PU accumulated (or `$null`) |
| `PUTaken` | decimal? | PU taken/used (or `$null`) |
| `AdditionalInfo` | string or List[string] | Extra metadata from Gracze.md |

## PlayerCharacter Object

PSCustomObject built in `public/player/get-playercharacter.ps1` (lines 163-183). Returned by `Get-PlayerCharacter`. Merges Character, entity state, and character file data.

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Parent player name |
| `Player` | object | Parent Player PSCustomObject (backreference) |
| `Name` | string | Character name |
| `IsActive` | bool | Active status from Gracze.md |
| `Aliases` | string[] | Alternative names |
| `Path` | string | Character file path |
| `PUExceeded` | decimal? | PU overflow |
| `PUStart` | decimal? | Starting PU |
| `PUSum` | decimal? | Total PU |
| `PUTaken` | decimal? | PU taken |
| `AdditionalInfo` | string or List[string] | Extra metadata |
| `Status` | string | Active entity status from `Get-EntityState` |
| `CharacterSheet` | string | Character sheet URL (three-layer merge: entity override > charfile > `$null`) |
| `RestrictedTopics` | string | Restricted topics (three-layer merge) |
| `Condition` | string | Character condition (three-layer merge) |
| `SpecialItems` | string[] | Special item list (three-layer merge) |
| `Reputation` | object | Reputation PSCustomObject (see Reputation Object) |
| `AdditionalNotes` | string[] | Additional notes (three-layer merge) |
| `DescribedSessions` | object[] | Session entries from character file (see DescribedSession) |

## Character File Object

PSCustomObject built in `private/charfile-helpers.ps1` (lines 311-323). Returned by `Read-CharacterFile`.

| Property | Type | Description |
|---|---|---|
| `FilePath` | string | Absolute file path |
| `Lines` | string[] | Raw file lines (for in-place rewriting) |
| `NL` | string | Detected newline style: `"\r\n"` (CRLF) or `"\n"` (LF) |
| `CharacterSheet` | string | URL from **Karta Postaci:** section (or `$null`) |
| `RestrictedTopics` | string | Text from **Tematy zastrzeżone:** section (or `$null`) |
| `Condition` | string | Text from **Stan:** section (or `$null`) |
| `SpecialItems` | string[] | Bullet items from **Przedmioty specjalne:** section |
| `Reputation` | object | Reputation PSCustomObject (see Reputation Object) |
| `AdditionalNotes` | string[] | Bullet items from **Dodatkowe informacje:** section |
| `DescribedSessions` | object[] | Entries from **Opisane sesje:** section (see DescribedSession) |
| `Sections` | Dictionary[string, object] | Section metadata for in-place rewrites (see CharacterSection) |

## Reputation Object

PSCustomObject built in `private/charfile-helpers.ps1` (lines 221-225). Nested in CharacterFile and PlayerCharacter.

| Property | Type | Description |
|---|---|---|
| `Positive` | object[] | Positive reputation entries (array of ReputationEntry) |
| `Neutral` | object[] | Neutral reputation entries (array of ReputationEntry) |
| `Negative` | object[] | Negative reputation entries (array of ReputationEntry) |

`ReputationEntry` — PSCustomObject built in `private/charfile-reputation.ps1` (lines 57-60):

| Property | Type | Description |
|---|---|---|
| `Location` | string | Location name |
| `Detail` | string | Description or detail text (or `$null`) |

## DescribedSession Object

PSCustomObject built in `private/charfile-helpers.ps1` (lines 302-306). Nested in CharacterFile and PlayerCharacter.

| Property | Type | Description |
|---|---|---|
| `Date` | DateTime? | Parsed session date (or `$null` if unparseable) |
| `Title` | string | Session title |
| `Narrator` | string | Narrator name (or `$null`) |

## CharacterSection Object

Hashtable returned by `Find-CharacterSection` in `private/charfile-helpers.ps1` (lines 104-109). Used for in-place section rewriting.

| Property | Type | Description |
|---|---|---|
| `HeaderIdx` | int | Line index of the bold section header |
| `InlineContent` | string | Content after `**Header:**` on the same line |
| `ContentStart` | int | First content line index (after header) |
| `ContentEnd` | int | Line index past the last content line |

## Currency Denomination

PSCustomObject defined in `private/currency-helpers.ps1` (lines 40-60). Three constant objects in `$script:CurrencyDenominations`.

| Property | Type | Description |
|---|---|---|
| `Name` | string | Full canonical name (Korony Elanckie, Talary Hirońskie, Kogi Skeltvorskie) |
| `Short` | string | Short display name (Korony, Talary, Kogi) |
| `Tier` | string | Classification: Gold, Silver, or Copper |
| `Multiplier` | int | Kogi conversion factor (10000, 100, 1) |
| `Stems` | string[] | Stem prefixes for fuzzy matching (kor, tal, kog) |

`ConvertFrom-CurrencyBaseUnit` returns a hashtable with keys `Korony` (int), `Talary` (int), `Kogi` (int).

## Currency Entity Object

PSCustomObject built in `public/currency/get-currencyentity.ps1` (lines 100-109). Returned by `Get-CurrencyEntity`.

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Currency entity name |
| `Denomination` | string | Canonical denomination name |
| `DenomShort` | string | Short denomination name |
| `Tier` | string | Gold, Silver, or Copper |
| `Owner` | string | Owner entity name (or `$null`) |
| `Location` | string | Location name (or `$null`) |
| `Balance` | int | Current quantity |
| `Status` | string | Entity status |

## Currency Report Object

PSCustomObject built in `public/reporting/get-currencyreport.ps1` (lines 126-139). Returned by `Get-CurrencyReport`.

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Currency entity name |
| `Denomination` | string | Canonical denomination name |
| `DenomShort` | string | Short denomination |
| `Tier` | string | Gold, Silver, or Copper |
| `Owner` | string | Owner entity name |
| `Location` | string | Location name |
| `OwnerType` | string | Owner, Location, or Unowned |
| `Balance` | int | Current quantity |
| `BaseUnitValue` | int | Kogi equivalent (only with `-AsBaseUnit`) |
| `Status` | string | Entity status |
| `LastChangeDate` | DateTime | Date of last quantity change |
| `Warnings` | string[] | Status flags: NegativeBalance, StaleBalance |
| `History` | object[] | QuantityHistory TemporalEntry array (only with `-ShowHistory`) |

## Currency Reconciliation Object

PSCustomObject returned by `Test-CurrencyReconciliation` in `public/reporting/test-currencyreconciliation.ps1`.

| Property | Type | Description |
|---|---|---|
| `Warnings` | object[] | Array of ReconciliationWarning objects |
| `WarningCount` | int | Total warning count |
| `Supply` | hashtable | `{ DenominationName = TotalQuantity }` across all active entities |
| `PhysicalSupply` | hashtable | `{ DenominationName = TotalQuantity }` for Postać-owned currency |
| `VirtualSupply` | hashtable | `{ DenominationName = TotalQuantity }` for NPC/Grupa/Gracz-owned currency |
| `EntityCount` | int | Number of currency entities found |
| `CheckedAt` | DateTime | Timestamp of the check |

`ReconciliationWarning` — PSCustomObject for individual warnings:

| Property | Type | Description |
|---|---|---|
| `Check` | string | Check name: NegativeBalance, StaleBalance, OrphanedCurrency, AsymmetricTransaction |
| `Severity` | string | Error or Warning |
| `Entity` | string | Affected entity name (or session header for AsymmetricTransaction) |
| `Detail` | string | Human-readable description |

## Economic Snapshot Object

PSCustomObject built in `public/reporting/get-economicsnapshot.ps1` (lines 129-141). Returned by `Get-EconomicSnapshot`. Inner data computed by `New-EconomicSnapshotData` in `private/economy-helpers.ps1`.

| Property | Type | Description |
|---|---|---|
| `SnapshotDate` | DateTime | Snapshot timestamp |
| `SupplyByDenomination` | hashtable | `{ DenomName = @{ Total = int; Physical = int; Virtual = int } }` |
| `TotalSupplyKogi` | int | Total supply in base units |
| `PhysicalSupplyKogi` | int | Postać-owned supply in base units |
| `VirtualSupplyKogi` | int | NPC/Grupa/Gracz-owned supply in base units |
| `PhysicalRatio` | double | Physical / total ratio (4 decimal places) |
| `HolderCount` | int | Number of unique currency holders |
| `TopHolders` | object[] | Top holders by wealth (see TopHolder) |
| `GiniCoefficient` | double | Wealth distribution metric (4 decimal places) |
| `TransactionVolume` | int | Number of transfers in scope |
| `TransactionValueKogi` | int | Total transfer value in base units |

`TopHolder` — PSCustomObject built in `private/economy-helpers.ps1` (lines 118-122):

| Property | Type | Description |
|---|---|---|
| `Owner` | string | Holder entity name |
| `WealthKogi` | int | Total wealth in base units |
| `OwnerCategory` | string | Physical, Virtual, or Unknown |

## Economic Timeline Entry

PSCustomObject built in `public/reporting/get-economictimeline.ps1` (lines 248-255). Array returned by `Get-EconomicTimeline`.

| Property | Type | Description |
|---|---|---|
| `Month` | string | Month identifier in `yyyy-MM` format |
| `TotalSupplyKogi` | int | Total supply in base units |
| `PhysicalSupplyKogi` | int | Physical supply in base units |
| `VirtualSupplyKogi` | int | Virtual supply in base units |
| `SupplyByDenomination` | hashtable | `{ DenomName = @{ Total; Physical; Virtual } }` |
| `TransferCount` | int | Number of transfers in this month |

## Materialization Report Object

PSCustomObject built in `public/reporting/get-materializationreport.ps1` (lines 206-215). Returned by `Get-MaterializationReport`.

| Property | Type | Description |
|---|---|---|
| `DenominationBreakdown` | object[] | Per-denomination physical/virtual split (see below) |
| `PlayerBreakdown` | object[] | Per-player physical holdings (see below) |
| `OrphanedPhysical` | object[] | Physical currency with inactive/removed owners (see below) |
| `Summary` | hashtable | `@{ TotalPhysical = int; TotalVirtual = int; OrphanedCount = int }` |

`DenominationBreakdown` entry (lines 123-129):

| Property | Type | Description |
|---|---|---|
| `Denomination` | string | Denomination name |
| `Total` | int | Total quantity |
| `Physical` | int | Postać-owned quantity |
| `Virtual` | int | NPC/Grupa/Gracz-owned quantity |
| `PhysicalPct` | double | Physical percentage (0-100) |

`PlayerBreakdown` entry (lines 164-169):

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Player name |
| `Characters` | string[] | Character names holding currency |
| `TotalPhysicalKogi` | int | Total physical wealth in base units |
| `PerDenomination` | hashtable | `{ DenomName = Quantity }` breakdown |

`OrphanedPhysical` entry (lines 184-191):

| Property | Type | Description |
|---|---|---|
| `Entity` | string | Currency entity name |
| `Owner` | string | Owner entity name |
| `OwnerStatus` | string | Owner's entity status |
| `Denomination` | string | Denomination name |
| `Quantity` | int | Currency quantity |
| `BaseValueKogi` | int | Value in base units |

## Location Graph Objects

PSCustomObjects built in `public/reporting/get-locationgraph.ps1`. Returned by `Get-LocationGraph`.

Edge object (lines 126-137):

| Property | Type | Description |
|---|---|---|
| `Source` | string | Source location name |
| `Target` | string | Target location name |
| `Type` | string | Containment, Door, Route, InferredHierarchy, Movement, or Teleport |
| `Weight` | int | Edge weight (incremented on repeated observations) |
| `Sources` | List[string] | Data source descriptions (session headers, entity tags) |
| `FirstSeen` | DateTime | Earliest observation date |
| `LastSeen` | DateTime | Most recent observation date |
| `PossiblyStale` | bool | Whether the edge may be outdated |
| `StaleReason` | string | Reason for staleness flag (or `$null`) |

Node object:

| Property | Type | Description |
|---|---|---|
| `Name` | string | Location name |
| `EntityMatch` | object | Resolved entity object (or `$null` for unresolved references) |
| `CN` | string | Hierarchical canonical name |
| `NerthusName` | string | RP override name |
| `Coordinates` | hashtable | `@{ X = int; Y = int }` (or `$null`) |
| `IsExterior` | bool | Whether the location is exterior (computed classification or coordinates fallback) |
| `InDegree` | int | Number of incoming edges |
| `OutDegree` | int | Number of outgoing edges |

Summary object:

| Property | Type | Description |
|---|---|---|
| `NodeCount` | int | Total location nodes |
| `EdgeCount` | int | Total edges |
| `ContainmentEdges` | int | Parent-child hierarchy edges |
| `DoorEdges` | int | Door connection edges |
| `RouteEdges` | int | Session-observed route edges |
| `MovementEdges` | int | Log-derived movement edges |
| `TeleportEdges` | int | Non-adjacent transitions |
| `InferredEdges` | int | Hierarchy-inferred edges |
| `ResolvedNodes` | int | Nodes matched to entities |
| `UnresolvedNodes` | int | Nodes without entity match |
| `ExteriorNodes` | int | Outdoor locations |
| `InteriorNodes` | int | Indoor locations |
| `PossiblyStaleEdges` | int | Potentially outdated edges |

## Session Graph Objects

PSCustomObjects built in `public/reporting/get-sessiongraph.ps1` and `private/session-graphhelpers.ps1`. Returned by `Get-SessionGraph`.

Participant record — built by `ConvertTo-ParticipantRecord` in `private/session-graphhelpers.ps1` (lines 167-173):

| Property | Type | Description |
|---|---|---|
| `Name` | string | Entity name |
| `Type` | string | Entity type (Postać, NPC, Grupa, Lokacja, etc.) |
| `Tier` | int | Participation tier: 0 (direct), 1 (mentioned), 2 (inferred) |
| `Source` | string | How participation was detected |
| `Weight` | decimal | Participation weight |

Summary object — returned by `Get-SessionGraph -Mode Summary` (lines 134-141):

| Property | Type | Description |
|---|---|---|
| `TotalSessions` | int | Total sessions in graph |
| `TotalParticipants` | int | Total unique participants |
| `FormatBreakdown` | PSCustomObject | Dynamic properties: Gen1, Gen2, Gen3, Gen4 (each an int count) |
| `Tier0Count` | int | Direct participants |
| `Tier1Count` | int | Mentioned participants |
| `Tier2Count` | int | Inferred participants |

EntityTimeline entry — returned by `Get-SessionGraph -Mode EntityTimeline` (lines 174-181):

| Property | Type | Description |
|---|---|---|
| `Session` | string | Session header |
| `Name` | string | Entity name |
| `Type` | string | Entity type |
| `Tier` | int | Participation tier |
| `Source` | string | Detection source |
| `Weight` | decimal | Participation weight |

Sessions mode entry — returned by `Get-SessionGraph -Mode Sessions` (lines 214-223):

| Property | Type | Description |
|---|---|---|
| `Header` | string | Session header |
| `Date` | DateTime | Session date |
| `Format` | string | Session format |
| `EntityTier` | int | Target entity's participation tier |
| `EntitySource` | string | Target entity's detection source |
| `EntityWeight` | decimal | Target entity's weight |
| `Participants` | hashtable[] | All participant records for the session |
| `FilePaths` | string[] | Source file paths |

FilePathInvolvement — returned by `Get-FilePathInvolvement` in `private/session-graphhelpers.ps1` (lines 75-119):

| Property | Type | Description |
|---|---|---|
| `Category` | string | Player, NPC, Location, Thread, or Org |
| `Name` | string | Entity name |
| `Type` | string | Entity type |

## Log Objects

C# types in `lib/LogParser.cs` and PSCustomObjects in `private/parse-logcontent.ps1`.

`Robot.LogParser.ParseResult` — container for parsed log file:

| Property | Type | Description |
|---|---|---|
| `Format` | string | ChatLog or Prose |
| `Lines` | LogLine[] | Parsed log lines |
| `LocationSegments` | LocationSegment[] | Location boundary markers |

`Robot.LogParser.LogLine` (struct) — single parsed log line:

| Property | Type | Description |
|---|---|---|
| `Index` | int | Line sequence number |
| `Time` | string | Timestamp text |
| `Channel` | string | Chat channel name |
| `Speaker` | string | Speaker name |
| `Text` | string | Message text |
| `Segment` | int | Index into LocationSegments array |

`Robot.LogParser.LocationSegment` — location boundary in log:

| Property | Type | Description |
|---|---|---|
| `Index` | int | Segment sequence number |
| `Raw` | string | Raw location text from log |
| `StartLine` | int | First line index in this segment |
| `EndLine` | int | Last line index in this segment |
| `Resolved` | string | Resolved entity name (set by PowerShell after name resolution) |
| `Stage` | string | Resolution stage (set by PowerShell after name resolution) |

## Markdown Parser Objects

C# types in `lib/MarkdownScanner.cs`. Returned by `Robot.MarkdownScanner.Scan()`, consumed by `Get-Markdown`.

`Robot.MarkdownScanner.ScanResult` — complete parsed file:

| Property | Type | Description |
|---|---|---|
| `Headers` | HeaderEntry[] | All Markdown headers |
| `Sections` | SectionEntry[] | Content between headers |
| `Lists` | ListEntry[] | All list items (flat array) |
| `Links` | LinkEntry[] | All links and URLs |

`Robot.MarkdownScanner.HeaderEntry` (struct):

| Property | Type | Description |
|---|---|---|
| `Level` | int | Header depth (1-6) |
| `Text` | string | Header text (without `#` prefix) |
| `ParentIndex` | int | Index of parent header (-1 = no parent) |
| `LineNumber` | int | Source line number |

`Robot.MarkdownScanner.SectionEntry`:

| Property | Type | Description |
|---|---|---|
| `HeaderIndex` | int | Index into Headers array (-1 = root section) |
| `Content` | string | Section body text |
| `ListStartIndex` | int | Start index into Lists array |
| `ListCount` | int | Number of list items in this section |

`Robot.MarkdownScanner.ListEntry`:

| Property | Type | Description |
|---|---|---|
| `Type` | string | Bullet or Numbered |
| `Text` | string | List item text |
| `Indent` | int | Indentation level |
| `ParentIndex` | int | Index of parent list item (-1 = no parent) |
| `LocalIndex` | int | Index within section's list items (set by PowerShell layer) |
| `SectionHeaderIndex` | int | Owning section's header index (-1 = root section) |

`Robot.MarkdownScanner.LinkEntry` (struct):

| Property | Type | Description |
|---|---|---|
| `Type` | string | MarkdownLink or PlainUrl |
| `Text` | string | Link display text (`$null` for PlainUrl) |
| `Url` | string | Link URL |

## Auditing Report Objects

PSCustomObjects returned by reporting functions in `public/reporting/`. See [AUDITING.md](AUDITING.md) for behavioral documentation.

`Get-EntityHistory` entry — built in `public/reporting/get-entityhistory.ps1` (lines 118-123):

| Property | Type | Description |
|---|---|---|
| `Date` | DateTime | Change start date |
| `DateEnd` | DateTime | Change end date |
| `Property` | string | Property display name |
| `Value` | string | Property value |

`Get-ChangeLog` entry — built in `public/reporting/get-changelog.ps1` (lines 83-90):

| Property | Type | Description |
|---|---|---|
| `Date` | DateTime | Session date |
| `SessionTitle` | string | Session title |
| `Narrator` | object | Narrator result |
| `EntityName` | string | Changed entity name |
| `Property` | string | Changed tag name |
| `Value` | string | New tag value |

`Get-TransactionLedger` entry — built in `public/reporting/get-transactionledger.ps1` (lines 103-117):

| Property | Type | Description |
|---|---|---|
| `Date` | DateTime | Session date |
| `SessionTitle` | string | Session title |
| `Narrator` | object | Narrator result |
| `Amount` | int | Transfer amount |
| `Denomination` | string | Denomination name |
| `Source` | string | Source entity |
| `Destination` | string | Destination entity |

`Get-PUAssignmentLog` entry — built in `public/reporting/get-puassignmentlog.ps1` (lines 86-91):

| Property | Type | Description |
|---|---|---|
| `ProcessedAt` | DateTime | Processing timestamp |
| `Timezone` | string | Timezone identifier |
| `SessionCount` | int | Number of sessions in this batch |
| `Sessions` | object[] | Array of PULogSession objects |

`PULogSession` — nested in PU assignment log (lines 127-132):

| Property | Type | Description |
|---|---|---|
| `Header` | string | Session header text |
| `Date` | DateTime | Session date |
| `Title` | string | Session title |
| `Narrator` | string | Narrator name |

`Get-NotificationLog` entry — built in `public/reporting/get-notificationlog.ps1` (lines 98-107):

| Property | Type | Description |
|---|---|---|
| `Date` | DateTime | Session date |
| `SessionTitle` | string | Session title |
| `Narrator` | object | Narrator result |
| `Directive` | string | Targeting directive: Grupa, Lokacja, or Direct |
| `TargetName` | string | Target entity name |
| `Message` | string | Intel message text |
| `RecipientCount` | int | Number of recipients |
| `Recipients` | string[] | Recipient names |

## Entity Write Helper Objects

Hashtables returned by internal write helpers in `private/entity-writehelpers.ps1`. See [ENTITY-WRITES.md](ENTITY-WRITES.md) for behavioral documentation.

`Find-EntitySection` result (lines 98-104):

| Property | Type | Description |
|---|---|---|
| `HeaderIdx` | int | Line index of the `## Type` section header |
| `StartIdx` | int | First content line index |
| `EndIdx` | int | Line index past last content line |
| `HeaderText` | string | Raw header text |
| `EntityType` | string | Normalized entity type |

`Find-EntityBullet` result (lines 144-149):

| Property | Type | Description |
|---|---|---|
| `BulletIdx` | int | Line index of the `* EntityName` bullet |
| `ChildrenStartIdx` | int | First child tag line index |
| `ChildrenEndIdx` | int | Line index past last child tag |
| `EntityName` | string | Entity name from the bullet text |

`Find-EntityTag` result (lines 173-177, or `$null` if not found):

| Property | Type | Description |
|---|---|---|
| `TagIdx` | int | Line index of the tag |
| `Tag` | string | Matched tag name |
| `Value` | string | Tag value text |

`Resolve-EntityTarget` result (lines 289-297):

| Property | Type | Description |
|---|---|---|
| `Lines` | List[string] | File content lines (mutable, for in-place editing) |
| `NL` | string | Detected newline style |
| `BulletIdx` | int | Entity bullet line index |
| `ChildrenStart` | int | First child tag line index |
| `ChildrenEnd` | int | Line index past last child tag |
| `FilePath` | string | Entity file path |
| `Created` | bool | Whether the entity bullet was newly created |

`Read-EntityFile` result (lines 245-248):

| Property | Type | Description |
|---|---|---|
| `Lines` | List[string] | File content lines |
| `NL` | string | Detected newline style |

## CRUD Return Objects

PSCustomObjects returned by public create commands. All CRUD commands support `-WhatIf`/`-Confirm`.

`New-Entity` result — built in `public/entity/new-entity.ps1` (lines 94-100):

| Property | Type | Description |
|---|---|---|
| `Name` | string | Created entity name |
| `Type` | string | Entity type |
| `EntitiesFile` | string | File where the entity was written |
| `Tags` | hashtable | Effective tag values |
| `Created` | bool | Always `$true` |

`New-Player` result — built in `public/player/new-player.ps1` (lines 135-143):

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Player name |
| `MargonemID` | string | Margonem game ID |
| `PRFWebhook` | string | Discord webhook URL |
| `Triggers` | string[] | Restricted topics |
| `EntitiesFile` | string | Entities file path |
| `CharacterName` | string | First character name (or `$null`) |
| `CharacterFile` | string | Character file path (or `$null`) |

`New-PlayerCharacter` result — built in `public/player/new-playercharacter.ps1` (lines 236-242):

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Parent player name |
| `CharacterName` | string | Character name |
| `PUStart` | decimal | Starting PU value |
| `EntitiesFile` | string | Entities file path |
| `CharacterFile` | string | Character file path (or `$null` with `-NoCharacterFile`) |
| `PlayerCreated` | bool | Whether a new Player entity was also created |

`New-CurrencyEntity` result — built in `public/currency/new-currencyentity.ps1` (lines 104-110):

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Auto-generated currency entity name |
| `Denomination` | string | Canonical denomination name |
| `DenomShort` | string | Short denomination name |
| `Owner` | string | Owner entity name |
| `Amount` | int | Initial amount |
| `EntitiesFile` | string | Entities file path |

## Name Resolution Objects

Structures returned by name resolution functions. See [NAME-RESOLUTION.md](NAME-RESOLUTION.md) for behavioral documentation.

`Get-NameIndex` returns a hashtable with three keys:

| Key | Type | Description |
|---|---|---|
| `Index` | Dictionary[string, object] | Token -> IndexEntry lookup (case-insensitive) |
| `StemIndex` | Dictionary[string, List[string]] | Declension stem -> list of token keys |
| `BKTree` | object | BK-tree root node (Robot.BKTree or PowerShell hashtable fallback) |

Index entry (value in `Index` dictionary):

| Property | Type | Description |
|---|---|---|
| `Owner` | object | Resolved entity or player object |
| `OwnerType` | string | Player, NPC, Grupa, Lokacja, Mapa, Gracz, Postać, or Przedmiot |
| `Source` | string | Registration source |
| `Priority` | int | Resolution priority (lower = higher priority) |
| `Ambiguous` | bool | Whether the token maps to multiple owners |

## Currency Entities Filtered Object

PSCustomObject returned by `Get-CurrencyEntitiesFiltered` in `private/currency-helpers.ps1`. Used internally by reporting and reconciliation functions.

| Property | Type | Description |
|---|---|---|
| `Entity` | object | Original Robot.Entity object |
| `Denomination` | object | Resolved denomination definition |
| `Owner` | string | Entity owner |
| `Location` | string | Entity location |
| `Quantity` | int | Parsed integer quantity (0 if missing) |
| `Status` | string | Entity status (Aktywny default) |
| `OwnerCategory` | string | Physical, Virtual, or Unknown (only with `-EntityLookup`) |

## Item Entity Object

Returned by `Get-ItemEntity`. Enriched Przedmiot entity with owner classification and currency identification.

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Entity display name |
| `Owner` | string | Owner entity name (from `@należy_do`) |
| `OwnerType` | string | Physical, Virtual, or Unknown (resolved from entity type) |
| `Location` | string | Entity location (from `@lokacja`) |
| `Quantity` | int | Parsed `@ilość` value (defaults to 1) |
| `Status` | string | Entity status (Aktywny default) |
| `IsCurrency` | bool | Whether this item matches a currency denomination |
| `Denomination` | string | Resolved denomination name (null if not currency) |
| `LastChangeDate` | datetime? | Most recent ValidFrom across owner/location/status/quantity histories |

## Location Entity Object

Returned by `Get-LocationEntity` in `public/location/get-locationentity.ps1`. Enriched Lokacja (or Mapa with `-IncludeMaps`) entity with hierarchy, door connections, and map metadata.

| Property | Type | Description |
|---|---|---|
| `Entity` | object | Original Robot.Entity object from `Get-EntityState` |
| `EntityName` | string | Entity display name |
| `Type` | string | Entity type: Lokacja or Mapa |
| `Parent` | string | Parent location name (from `@lokacja`) |
| `Children` | object[] | Child location/map entities |
| `ChildCount` | int | Number of children |
| `DoorTargets` | object[] | Resolved door connection entities (or `@{ Name; Resolved = $false }` stubs) |
| `DoorCount` | int | Number of door connections |
| `IsExterior` | bool | Whether the entity is exterior (computed from entity `IsExterior` or coordinates fallback) |
| `Coordinates` | hashtable | `@{ X = int; Y = int }` (or `$null`) |
| `HierarchicalPath` | string | Canonical name (CN) from entity state — `Lokacja/Parent/.../Name` |
| `NerthusName` | string | RP override name (Nerthus server name for a Margonem location) |
| `EntityCount` | int | Count of non-location entities at this location |
| `Status` | string | Entity status (Aktywny default) |
| `MapData` | object | Mapa-specific metadata (only for `Type = 'Mapa'`, else `$null`) |
| `ExteriorParent` | string | Name of the nearest exterior ancestor (or `$null` for exteriors/no ancestor) |
| `QualifiedPath` | string | `"ExteriorAncestor/Name"` path (or `$null`) |

MapData subobject (for Mapa entities, extracted from `Entity.Overrides`):

| Property | Type | Description |
|---|---|---|
| `Slug` | string | URL-safe slug (`@slug` override) |
| `Url` | string | CDN map image URL (`@url` override) |
| `UrlNerthus` | string | Nerthus map image URL (`@url_nerthus` override) |
| `Dimensions` | string | Tile dimensions (`@wymiary` override) |

## Resolve-Entity Result

Returned by `Resolve-Entity`. Passes through original `Robot.Entity` objects — no enrichment or projection. Filter parameters are AND-combined: Owner, Location, Group, Type, Status, Name (substring).

## Dormancy Report Object

Returned by `Get-DormancyReport`. One entry per dormant entity, sorted by `DaysDormant` descending.

| Property | Type | Description |
|---|---|---|
| `Name` | string | Entity name |
| `Type` | string | Entity type |
| `Status` | string | Entity status (null treated as Aktywny) |
| `LastActivity` | datetime? | Most recent activity date (null = no history) |
| `DaysDormant` | int | Days since last activity |
| `CreatedOn` | datetime? | Earliest ValidFrom across all histories |
| `LastSource` | string | Activity source: PropertyChange, SessionMention, or Creation |

Activity sources checked: all 9 history lists (ValidFrom scan) + session graph index `_index.json` (participant dates). Entities with `Status = Usunięty` excluded by default.

## Session Frequency Trend Object

Returned by `Get-SessionFrequencyTrend`. One entry per calendar month with sessions.

| Property | Type | Description |
|---|---|---|
| `Month` | string | Calendar month in `yyyy-MM` format |
| `SessionCount` | int | Number of sessions in this month |
| `NarratorCount` | int | Number of unique narrators |
| `UniqueNarrators` | string[] | Deduplicated narrator names |
| `FormatBreakdown` | hashtable | Session counts per format: Gen1, Gen2, Gen3, Gen4 |

Sessions with null Date are skipped. Narrator names extracted from `Session.Narrator.Name` (object) or string value.

## Entity Delta Object

Returned by `Get-EntityDelta`. One entry per changed property between two date snapshots.

| Property | Type | Description |
|---|---|---|
| `Property` | string | Polish display name: Lokacja, Właściciel, Typ, Status, Ilość, NazwaNerthus, Grupy, Drzwi |
| `Before` | object | Value at FromDate (scalar or string[] for multi-valued) |
| `After` | object | Value at ToDate (scalar or string[] for multi-valued) |

Scalar comparison uses `OrdinalIgnoreCase` with null→empty normalization. Multi-valued comparison uses `HashSet[string]` symmetric diff. Entity resolution supports primary name and alias (Names collection) matching.

## Testing

| Test file | Structure coverage |
|---|---|
| `tests/get-entity.Tests.ps1` | Entity object properties, temporal histories, Names set |
| `tests/get-entitystate.Tests.ps1` | Entity state merge, Transfer expansion, QuantityHistory |
| `tests/get-session.Tests.ps1` | Session object, PU/Changes/Transfers/Intel arrays, deduplication |
| `tests/get-player.Tests.ps1` | Player and Character objects, entity-only stubs |
| `tests/get-playercharacter.Tests.ps1` | PlayerCharacter three-layer merge, Reputation, DescribedSessions |
| `tests/charfile-helpers.Tests.ps1` | CharacterFile object, section parsing, Reputation tiers |
| `tests/currency-helpers.Tests.ps1` | Denomination constants, CurrencyEntitiesFiltered |
| `tests/get-currencyentity.Tests.ps1` | CurrencyEntity object |
| `tests/get-currencyreport.Tests.ps1` | CurrencyReport object |
| `tests/test-currencyreconciliation.Tests.ps1` | Reconciliation result and warnings |
| `tests/get-economicsnapshot.Tests.ps1` | EconomicSnapshot, TopHolder |
| `tests/get-economictimeline.Tests.ps1` | EconomicTimelineEntry |
| `tests/get-materializationreport.Tests.ps1` | MaterializationReport and sub-objects |
| `tests/get-sessiongraph.Tests.ps1` | Participant record, Summary, EntityTimeline |
| `tests/get-locationgraph.Tests.ps1` | Edge, Node, Summary objects |
| `tests/get-markdown.Tests.ps1` | ScanResult, HeaderEntry, SectionEntry, ListEntry, LinkEntry |
| `tests/parse-logcontent.Tests.ps1` | ParseResult, LogLine, LocationSegment |
| `tests/resolve-name.Tests.ps1` | NameIndex, IndexEntry, BK-tree results |
| `tests/get-itementity.Tests.ps1` | ItemEntity object, owner type, currency exclusion |
| `tests/resolve-entity.Tests.ps1` | Resolve-Entity filtering, status gates |
| `tests/get-locationentity.Tests.ps1` | LocationEntity object, children/doors enrichment, MapData, filters |
| `tests/new-mapentity.Tests.ps1` | MapEntity creation, slug uniqueness, dimensions validation, parent check |
| `tests/get-dormancyreport.Tests.ps1` | DormancyReport object, threshold filtering, LastSource |
| `tests/get-sessionfrequencytrend.Tests.ps1` | SessionFrequencyTrend object, narrator dedup, format breakdown |
| `tests/get-entitydelta.Tests.ps1` | EntityDelta object, scalar/multi-valued diffs, alias resolution |

## Related Documents

- [MODEL.md](MODEL.md) — Repository layout, data flow, merge rules, cache architecture
- [ENTITIES.md](ENTITIES.md) — Entity parsing, tags, temporal scoping, multi-file merge
- [SESSIONS.md](SESSIONS.md) — Session parsing, format detection, metadata extraction
- [CHARFILE.md](CHARFILE.md) — Character file parsing and section management
- [ENTITY-WRITES.md](ENTITY-WRITES.md) — Write operations on entity files
- [CURRENCY.md](CURRENCY.md) — Currency subsystem and denomination handling
- [ECONOMY.md](ECONOMY.md) — Economic analysis (snapshot, timeline, materialization)
- [SESSION-GRAPH.md](SESSION-GRAPH.md) — Session participation graph
- [LOCATION-GRAPH.md](LOCATION-GRAPH.md) — Location connectivity graph
- [LOGS.md](LOGS.md) — Log parsing pipeline
- [PARSER.md](PARSER.md) — Markdown parsing internals
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) — Name resolution pipeline
- [AUDITING.md](AUDITING.md) — Audit and reporting functions
- [PU.md](PU.md) — PU assignment structures

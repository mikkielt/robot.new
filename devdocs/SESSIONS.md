# Session Pipeline - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the session subsystem: `Get-Session` (extraction, format detection, deduplication, Intel resolution), `Set-Session` (modification, format upgrade), `New-Session` (Gen4 generation), and their private helpers across four files: `session-parsehelpers.ps1`, `session-decomposehelpers.ps1`, `session-intelhelpers.ps1`, and `format-sessionblock.ps1`.

**Not covered**: PU computation from session data - see [PU.md](PU.md). Entity state merging from session Zmiany - see [ENTITIES.md](ENTITIES.md).

---

## 2. Architecture Overview

```
Get-Session (read path)
    ├── Get-Markdown (batch file parsing)
    ├── Get-Entity (entity data for resolution)
    ├── Get-Player (player data)
    ├── Get-NameIndex (token index for mentions/intel)
    ├── Resolve-Narrator (narrator name resolution)
    ├── session-parsehelpers.ps1
    │     ├── Get-SessionTitle (strip date/narrator from header)
    │     ├── Get-SessionLocations (format-specific location extraction)
    │     ├── Get-SessionListMetadata (PU, Logi, Zmiany, Intel, Transfer, Narrator, Data)
    │     └── Get-SessionPlainTextLogs (Gen1/2 fallback)
    ├── Format detection (Gen1–Gen4 heuristics)
    ├── Cross-file deduplication (Merge-SessionGroup)
    ├── session-intelhelpers.ps1
    │     ├── Resolve-IntelTargets (Grupa/, Lokacja/, Direct fan-out)
    │     ├── Resolve-EntityWebhook (webhook priority chain)
    │     ├── Test-LocationMatch (slash-separated path matching)
    │     └── Get-SessionMentions (5-phase body text extraction)
    └── Intel target resolution

Set-Session (write path)
    ├── session-decomposehelpers.ps1
    │     ├── Find-SessionInFile (section boundary detection)
    │     ├── Split-SessionSection (decompose into meta/preserved/body)
    │     ├── ConvertTo-Gen4FromRawBlock (Gen3 -> Gen4 tag rename)
    │     ├── ConvertFrom-ItalicLocation (Gen2 italic -> Gen4)
    │     ├── ConvertFrom-PlainTextLog (Gen1/2 plain -> Gen4)
    │     └── Get-FormatFromSplit (derive format from MetaBlocks)
    └── format-sessionblock.ps1 (Gen4 rendering)

New-Session (creation path)
    └── format-sessionblock.ps1
          ├── ConvertTo-Gen4MetadataBlock (single block)
          └── ConvertTo-SessionMetadata (all blocks, canonical order)
```

---

## 3. Format Generations

| Gen | Era | Location format | Log format | Metadata blocks | Detection heuristic |
|---|---|---|---|---|---|
| Gen1 | START–2022 | None | `Logi: https://…` plain text | None | Fallback (no other match) |
| Gen2 | 2022–2023 | `*Lokalizacja: A, B*` (italic) | `Logi: https://…` plain text | None | First non-empty line starts with `*Lokalizacj` |
| Gen3 | 2024–2026 | `- Lokalizacje:` list item | `- Logi:` list item | `- PU:`, `- Zmiany:`, `- Efekty:` | Root list item with `pu` prefix (no `@`) |
| Gen4 | 2026+ | `- @Lokacje:` list item | `- @Logi:` list item | `- @Narrator:`, `- @Data:`, `- @PU:`, `- @Zmiany:`, `- @Intel:` | Root list item starting with `@` + letter |

All four formats remain parseable. `Get-Session` auto-detects and normalizes transparently.

### 3.1 Format Detection (`Get-SessionFormat`)

Detection order (per-section heuristic):
1. `$FirstNonEmptyLine` starts with `*Lokalizacj` -> **Gen2**
2. Root list items (`$LI.Indent -eq 0`):
   - Text starts with `@` + letter -> **Gen4**
   - Text starts with `pu` followed by `:` or space -> **Gen3**
3. Fallback -> **Gen1**

---

## 4. `Get-Session` - Extraction Pipeline

### 4.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `File` | string[] | Specific files to scan |
| `Directory` | string | Directory to scan recursively |
| `MinDate` / `MaxDate` | datetime | Date range filter |
| `ExcludeDirectory` | string[] | Directories to exclude from scanning |
| `IncludeContent` | switch | Include raw section content in output |
| `IncludeMentions` | switch | Extract entity mentions from body text |
| `IncludeLogs` | switch | Fetch and parse session logs (attaches `LogData` property) |
| `IncludeFailed` | switch | Include sessions with broken date headers |
| `Entities` | object[] | Pre-fetched entity list from `Get-Entity` (avoids redundant fetch) |
| `Players` | object[] | Pre-fetched player list from `Get-Player` (avoids redundant fetch) |
| `NameIndex` | hashtable | Pre-built name index from `Get-NameIndex` (avoids redundant BK-tree rebuild) |
| `ProgressCallback` | scriptblock | Optional callback for CLI progress reporting (receives `Current`, `Total`, `ItemDetail`) |
| `Quiet` | switch | Suppress warning output to stderr |

### 4.2 Dependency Pre-Fetching

`Get-Session` batch-loads all dependencies upfront, but accepts pre-fetched instances via `-Entities`, `-Players`, and `-NameIndex` parameters to avoid redundant computation when the caller already has them:

```powershell
$Entities = Get-Entity                                    # or from -Entities parameter
$Players  = Get-Player -Entities $Entities                # or from -Players parameter
$Index    = Get-NameIndex -Players $Players -Entities $Entities  # or from -NameIndex parameter
$Docs     = Get-Markdown -File $FilesToProcess            # or -Directory
```

### 4.2.1 Pre-Built Entity Indices for Intel Resolution

After loading entities, `Get-Session` pre-builds two hashtable indices for O(1) Intel target lookup, replacing the previous O(E) linear scans per directive:

```powershell
$EntityByGroup    = @{}   # GroupName -> List[{ Entity, History }]
$EntityByLocation = @{}   # LocationName -> List[{ Entity, History }]
```

Each entity's `GroupHistory` and `LocationHistory` collections are iterated once to populate these indices. `Resolve-IntelTargets` receives them as mandatory `-EntityByGroup` and `-EntityByLocation` parameters (see section 6.1).

### 4.2.2 Per-Section Parent-Children Index

For each session section, `Get-Session` builds a `$SectionChildrenOf` hashtable mapping parent list item identity hashes to their child list items:

```powershell
$SectionChildrenOf = @{}
foreach ($LI in $Section.Lists) {
    if ($null -ne $LI.ParentListItem) {
        $ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI.ParentListItem)
        $SectionChildrenOf[$ParentId] = List[object]  # children
    }
}
```

This index is built once per section and shared by `Get-SessionLocations`, `Get-SessionListMetadata`, and `Get-SessionMentions` via their `-ChildrenOf` parameter, replacing O(L) inner scans with O(1) hashtable lookups.

### 4.2.3 Progress Reporting

When a `-ProgressCallback` scriptblock is provided, `Get-Session` invokes it during the file processing loop. The callback is called every 5 files and on the final file, receiving `(Current, Total, ItemDetail)` arguments. This integrates with the CLI progress UI.

### 4.2.4 Date Caching in Pre-Filter Pass

`Get-Session` performs a single combined pass over `$SessionSections` that pre-filters, caches date regex matches, and builds the parseable sections list. This merges what was previously two separate passes:

1. Date regex matches are cached in `$CachedDateMatches` (Dictionary keyed by section index)
2. Parsed dates are cached in `$CachedDateParsed` for reuse by `ConvertFrom-SessionHeader`
3. A `$HasCandidateSession` flag enables early file skip when no sections fall within the date range
4. `$ParseableIndices` (HashSet) tracks which sections have valid dates for narrator result alignment

### 4.3 Date Parsing (`ConvertFrom-SessionHeader`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Header` | string | Yes | Raw header text |
| `DateRegex` | regex | Yes | Precompiled date extraction pattern |
| `Match` | object | No | Pre-matched regex result to avoid redundant matching |
| `ParsedDate` | datetime | No | Pre-parsed date to avoid redundant `TryParseExact` |

Parses `### YYYY-MM-DD` headers via `ConvertTo-SessionDate`. Accepts optional `-Match` and `-ParsedDate` parameters to reuse values cached during the pre-filter pass (see section 4.2.4), avoiding redundant regex matching and date parsing.

Supports date ranges: `2022-12-21/22` -> `Date = Dec 21`, `DateEnd = Dec 22`. The `/DD` suffix must be same month/year.

### 4.4 Title Extraction (`Get-SessionTitle`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Header` | string | Yes | Raw header text (after `### ` prefix) |
| `DateInfo` | object | No | Hashtable from `ConvertFrom-SessionHeader` with `DateStr` and `EndDayStr` |

Strips the date portion (10 characters for `yyyy-MM-dd`, plus `/DD` suffix length if present) and the trailing narrator segment (after last comma) from the header text. Returns the session title. If `$DateInfo` is `$null`, returns the header unchanged.

### 4.5 Location Extraction (`Get-SessionLocations`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Format` | string | Yes | Session format generation (`Gen1`–`Gen4`) |
| `FirstNonEmptyLine` | string | Yes | First non-empty content line of the section |
| `SectionLists` | object | Yes | Parsed list items from the Markdown section |
| `LocItalicRegex` | regex | Yes | Precompiled Gen2 italic location pattern |
| `Index` | Dictionary[string, object] | No | Name index for entity resolution |
| `ChildrenOf` | hashtable | Yes | Pre-built parent-to-children index (see section 4.2.2) |

Children of each root list item are resolved via `$ChildrenOf[$ParentId]` using identity hash keys, providing O(1) lookup instead of O(L) inner scans.

Three strategies, tried in order:

1. **Entity resolution** (Gen3/Gen4): For each root list item, check if all children resolve to `Lokacja` entities via the name index. If `ResolvedLocCount > 0` and `ResolvedNonLocCount == 0`, use those children as locations.
2. **Tag-based fallback** (Gen3/Gen4): Look for root list items matching `Lokalizacj*` or `Lokacj*`. Leading `@` stripped. If children exist, use them; otherwise split inline CSV after the colon.
3. **Italic extraction** (Gen2): Regex on `*Lokalizacja: A, B*` pattern, comma-split.

Returns `List[string]`.

#### Route Edges

Location values may contain `->` separators indicating movement routes (e.g., `Steadwick -> Przełęcz Gryfów -> Zamek Gryfów`). `Get-NamedLocationReport` splits these and extracts **RouteEdges** — ordered pairs of consecutive segments — preserving traversal direction. The report output is `[PSCustomObject]@{ Locations; RouteEdges }` where `RouteEdges` is `@{ Source; Target; SessionDate; Header; FilePath }`.

### 4.6 Metadata Extraction (`Get-SessionListMetadata`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `SectionLists` | object | Yes | Parsed list items from the Markdown section |
| `PURegex` | regex | Yes | Precompiled `Character: Value` pattern |
| `UrlRegex` | regex | Yes | Precompiled URL extraction pattern |
| `ChildrenOf` | hashtable | Yes | Pre-built parent-to-children index (see section 4.2.2) |

Children and grandchildren of each list item are resolved via `$ChildrenOf[$ListItemId]` using identity hash keys, providing O(1) lookup. This is used for PU children, Logi children, Zmiany entity children and their tag grandchildren, Intel children, Narrator children, and Data children.

Parses structured list items for Gen3/Gen4 sessions. Leading `@` is stripped via:

```powershell
$MatchText = if ($LowerText.StartsWith('@')) { $LowerText.Substring(1) } else { $LowerText }
```

This enables unified parsing for both `- PU:` and `- @PU:`.

Extracted fields:
- **Narrator**: Canonical narrator name(s) under `narrator` tag, used as override (see §4.8)
- **PU**: `Character: Value` pairs (comma -> period decimal normalization)
- **Logs**: Child URLs or local file paths under `logi` tag; entries starting with `res/logs/` are accepted alongside `https://...` URLs. Also checks inline URL on root line
- **Changes (Zmiany)**: Entity names at 4-space indent, `@tag: value` at 8-space indent
- **Intel**: `RawTarget: Message` pairs under `intel` tag
- **Transfers**: `@Transfer: {amount} {denomination}, {source} -> {destination}` inline on root line
- **DateOverride**: Inline `@Data: YYYY-MM-DD` value or first child of `@Data:` block

Returns hashtable with keys: `Logs`, `PU`, `Changes`, `Intel`, `Transfers`, `Narrators`, `DateOverride`.

### 4.7 Plain-Text Log Fallback (`Get-SessionPlainTextLogs`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `ContentLines` | string[] | Yes | Raw content lines of the session section |
| `LogiLineRegex` | regex | Yes | Precompiled `Logi: <url>` pattern |

Applied when list-based `$Logs.Count -eq 0`. Scans raw content lines for `Logi: <url>` patterns (Gen1/Gen2). Returns `List[string]` of URLs.

### 4.8 @Narrator Override

When a `- @Narrator:` block is present in session metadata, it completely replaces header-based narrator resolution. The override takes precedence over any narrator segment parsed from the `### date, title, narrator` header.

Behavior:
- The canonical narrator name(s) from the `@Narrator` block are used directly - no fuzzy resolution is applied.
- `RawText` from the original header is preserved in the session object for round-trip fidelity.
- If the `@Narrator` block is absent, standard header-based resolution via `Resolve-Narrator` applies as before.

This mechanism supports narrator normalization during migration: the `@Narrator` block provides a verified canonical name, while the original header text remains untouched.

### 4.9 @Data Override

When a `- @Data:` tag is present in session metadata, it overrides the date parsed from the session header. This rescues sessions with malformed header dates (e.g., `2024-07-014`) that cannot have their headers changed because headers are unique identifiers.

Format (inline):
```markdown
### 2024-07-014, Oblężenie Steadwick, Solmyr

- @Data: 2024-07-14
```

Behavior:
- The date value must be in `YYYY-MM-DD` format. Invalid values are silently ignored.
- When present, `@Data` replaces the header-parsed date in the session object's `Date` field.
- If the header has no valid date at all, `@Data` provides the date and prevents the session from being recorded as failed.
- `@Data` is excluded from mention detection.
- In `Set-Session`, use `-DateOverride '2024-07-14'` to write the `@Data` block.
- Example: `Set-Session -DateOverride '2024-07-14' -File 'Postaci/Gracze/Crag Hack.md'`

---

## 5. Session Deduplication (`Merge-SessionGroup`)

Sessions with identical headers across multiple files represent the same session.

### 5.1 Grouping

Sessions are grouped using an O(1) `Dictionary[string, List[session]]` keyed by exact Header text with `StringComparer.Ordinal`:

```powershell
$SessionsByHeader = [Dictionary[string, List[object]]]::new([StringComparer]::Ordinal)
```

### 5.2 Primary Selection

The instance with the richest metadata is selected as primary, scored by field count (locations, logs, PU entries, changes, intel).

### 5.3 Array Field Merging

| Field | Strategy |
|---|---|
| Locations | `HashSet` union |
| Logs | `HashSet` union |
| PU | Deduped by `Character|Value` composite key |
| Intel | Deduped by `RawTarget|Message` composite key |

### 5.4 Output Markers

Merged sessions carry `IsMerged = $true`, `DuplicateCount`, and `FilePaths[]`.

---

## 6. Intel Resolution (`Resolve-IntelTargets`)

### 6.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `RawIntel` | List[object] | Yes | Raw intel entries (RawTarget + Message) from `Get-SessionListMetadata` |
| `SessionDate` | datetime | Yes | Session date for temporal activity checks |
| `Entities` | object[] | Yes | All entities from `Get-Entity` |
| `Index` | Dictionary[string, object] | Yes | Name index for resolution |
| `StemIndex` | Dictionary[string, List[string]] | Yes | Stem index for declension matching |
| `Players` | object[] | Yes | All players from `Get-Player` |
| `ResolveCache` | hashtable | Yes | Shared resolution cache |
| `EntityByGroup` | hashtable | Yes | Pre-built group membership index: `GroupName -> List[{ Entity, History }]` (see section 4.2.1) |
| `EntityByLocation` | hashtable | Yes | Pre-built location index: `LocationName -> List[{ Entity, History }]` (see section 4.2.1) |

### 6.2 Targeting Directives

| Directive | Syntax | Fan-out strategy |
|---|---|---|
| `Grupa/` | `Grupa/OrgName` | Target org + all entities with `@grupa` membership matching at session date (via pre-built `$EntityByGroup` index) |
| `Lokacja/` | `Lokacja/LocName` | BFS through location tree via `@lokacja` (via pre-built `$EntityByLocation` index) + non-location entities within the tree |
| Direct | `Name` or `Name1, Name2` | Comma-split, resolved individually |

The `Grupa/` directive builds a `HashSet` of all known names for the resolved group (including aliases via `.Names`), then iterates `$EntityByGroup` entries for each name to find temporally active members. The `Lokacja/` directive uses a BFS `Queue` seeded with the resolved location name, expanding through `$EntityByLocation` to discover child locations and non-location entities within the tree.

### 6.3 Resolution Stages

Uses stages 1/2/2b of name resolution (exact -> declension -> stem alternation). **No fuzzy matching** (stage 3 skipped for Intel).

### 6.4 `Test-LocationMatch`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `LocationValue` | string | Yes | Entity's `@lokacja` tag value (may contain `/` path separators) |
| `LocationSet` | HashSet[string] | Yes | Set of target location names (OrdinalIgnoreCase) |

Handles slash-separated path values (e.g. `Ithan/Ratusz Ithan`) by splitting on `/` and checking each segment against the location set. Returns `$true` if any segment matches. Used by the `Lokacja/` directive to identify non-location entities within a location tree.

### 6.5 Webhook Resolution (`Resolve-EntityWebhook`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Entity` | object | Yes | Entity object to resolve webhook for |
| `Players` | object[] | Yes | All players from `Get-Player` |

Priority chain:
1. Entity's own `@prfwebhook` override (last value, must start with `https://discord.com/api/webhooks/`)
2. For `Postać` or `Gracz` entities: owning Player's `PRFWebhook`
3. For objects with a `PRFWebhook` property (Player objects from `Resolve-Name`): use directly
4. `$null` if none available

---

## 7. Mention Extraction (`Get-SessionMentions`)

### 7.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Content` | string | Yes | Raw section content text |
| `SectionLists` | object | Yes | Parsed list items from the Markdown section |
| `Format` | string | Yes | Session format generation |
| `FirstNonEmptyLine` | string | Yes | First non-empty content line |
| `Index` | Dictionary[string, object] | Yes | Name index |
| `StemIndex` | Dictionary[string, List[string]] | Yes | Stem index for declension matching |
| `ResolveCache` | hashtable | Yes | Shared resolution cache |
| `ChildrenOf` | hashtable | Yes | Pre-built parent-to-children index (see section 4.2.2) |
| `ContentLines` | string[] | No | Pre-split content lines (avoids redundant `Split` when caller already has them) |

### 7.2 Five-Phase Pipeline

Enabled via `-IncludeMentions` switch.

1. **Exclude metadata list items** recursively — builds a `HashSet[int]` of excluded list item identity hashes. Root items matching `narrator`, `pu`, `logi`, `lokalizacj*`, `lokacj*`, `zmiany`, `intel`, or `data` tags are excluded. Single-pass DFS propagation via the shared `$ChildrenOf` index marks all descendants using a stack.
2. **Collect scannable text** (dual-source):
   - Source A: Non-excluded list item `.Text` values
   - Source B: Paragraph (non-list) content lines, excluding list-like lines, Gen2 italic locations, and `Logi:` plain-text lines
3. **Tokenize** via Markdown link extraction, formatting strip (`**`, `*`, `__`, `_`), and punctuation-split. Minimum token length: 3 characters.
4. **Resolve** unique tokens via stages 1/2/2b (no fuzzy matching — `-NoFuzzy` flag). Tokens are deduplicated into a `HashSet[string]` (OrdinalIgnoreCase) before resolution to avoid redundant `Resolve-Name` calls. Typical session: ~150 tokens but only ~50 unique, saving ~3x function call overhead.
5. **Deduplicate** into `Dictionary[string, object]` keyed by entity name (OrdinalIgnoreCase), build output objects

---

## 8. `Set-Session` - Modification Pipeline

### 8.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| Pipeline input | session object | From `Get-Session` |
| `Date` / `File` | explicit | Alternative to pipeline input |
| `Locations`, `PU`, `Logs`, `Changes`, `Intel`, `Content` | various | New values (full-replace semantics) |
| `DateOverride` | string | Write `@Data:` override block with given date |
| `Properties` | hashtable | Alternative to individual parameters |
| `UpgradeFormat` | switch | Convert Gen2/Gen3 -> Gen4 |

### 8.2 Section Discovery (`Find-SessionInFile`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Lines` | string[] | Yes | All lines of the file |
| `TargetHeader` | string | No | Exact header text to match (Ordinal comparison) |
| `TargetDate` | datetime | No | Date to match via regex |

Linear scan for `### ` headers. Extracts header text via `Substring(4).Trim()` (strips both leading and trailing whitespace). When `TargetHeader` is specified, matches by exact string. When `TargetDate` is specified, matches by date regex extraction. Section end = next `### ` header or EOF.

Returns `List[object]` of match objects with `HeaderLineIdx`, `SectionStartIdx`, `SectionEndIdx`, `HeaderText`.

### 8.3 Section Decomposition (`Split-SessionSection`)

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Lines` | string[] | Yes | Section content lines (between header and next header) |

State machine classifies content into:

| Category | Tags | Canonical Key | Handling |
|---|---|---|---|
| Meta blocks | `narrator`, `data`, `pu`, `logi`, `lokalizacje`, `lokacje`, `zmiany`, `intel` | `narrator`, `data`, `pu`, `logs`, `locations`, `changes`, `intel` | Replaceable by parameters or upgradeable |
| Preserved blocks | `objaśnienia`, `efekty`, `komunikaty`, `straty`, `nagrody` | Lowercase tag name | Written back unchanged |
| Body lines | Everything else | — | Replaceable via `-Content` |
| Legacy: italic locations | `*Lokalizacj*` line | `locations-italic` | Captured, converted during upgrade |
| Legacy: plain text logs | `Logi: https://...` line | `logs-plain` | Captured (multiple accumulated), converted during upgrade |

Leading `@` on tags is stripped before classification. Code fence toggle prevents false classification inside code blocks.

Returns hashtable with keys: `MetaBlocks` ([ordered] dict), `PreservedBlocks` (List of Tag+Lines), `BodyLines` (string[]).

### 8.4 `Get-FormatFromSplit`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `MetaBlocks` | OrderedDictionary | Yes | MetaBlocks from `Split-SessionSection` output |

Derives the session format generation from the decomposition result:
1. Empty `MetaBlocks` -> `Gen1`
2. Contains `locations-italic` key -> `Gen2`
3. First structured key's root line starts with `- @` -> `Gen4`, otherwise `Gen3`
4. Contains only `logs-plain` -> `Gen1`

### 8.5 Metadata Replacement

**Full-replace semantics** (not merge):
- `$null` (or omit) -> leave unchanged
- `@()` (empty array) -> clear the block
- Non-empty value -> replace entirely

### 8.6 Format Upgrade Conversions

| Source | Converter | Output |
|---|---|---|
| Gen3 list blocks | `ConvertTo-Gen4FromRawBlock` | Rename root tag, normalize to 4-space indent multiples |
| Gen2 italic locations | `ConvertFrom-ItalicLocation` | `- @Lokacje:` with expanded children |
| Gen1/2 plain text logs | `ConvertFrom-PlainTextLog` | `- @Logi:` with child URLs |

#### `ConvertTo-Gen4FromRawBlock`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Tag` | string | Yes | Canonical key from `Split-SessionSection` (e.g. `locations`, `pu`) |
| `Lines` | string[] | Yes | Raw block lines (root + children) |
| `NL` | string | Yes | Newline string for output |
| `LogDirectory` | string | No | Directory for log URL localization (when provided, log URLs with locally cached files are replaced with `res/logs/` paths via `Resolve-LogUrlToLocalPath`) |

Maps canonical keys to Gen4 tag names: `narrator`->`Narrator`, `data`->`Data`, `locations`->`Lokacje`, `logs`->`Logi`, `pu`->`PU`, `changes`->`Zmiany`, `intel`->`Intel`. Detects indent base from first meaningful child and normalizes to 4-space multiples. Inline CSV values on root lines are expanded to nested 4-space indented children. When `$Tag -eq 'logs'` and `$LogDirectory` is provided, each child URL is passed through `Resolve-LogUrlToLocalPath` to replace URLs with local paths when the cached file exists.

#### `ConvertFrom-ItalicLocation`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Line` | string | Yes | Gen2 italic location line (e.g. `*Lokalizacja: A, B*`) |
| `NL` | string | Yes | Newline string for output |

Extracts locations from `*Lokalizacj[ae]?:\s*(.+?)\*` regex, comma-splits, and delegates to `ConvertTo-Gen4MetadataBlock -Tag 'Lokacje'`. Returns `$null` if regex does not match or no items extracted.

#### `ConvertFrom-PlainTextLog`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Lines` | string[] | Yes | Gen1/2 plain text log lines (e.g. `Logi: https://...`) |
| `NL` | string | Yes | Newline string for output |
| `LogDirectory` | string | No | Directory for log URL localization (same semantics as `ConvertTo-Gen4FromRawBlock`) |

Extracts URLs via `(https?://\S+)` regex, passes each through `Resolve-LogUrlToLocalPath` when `$LogDirectory` is provided, and delegates to `ConvertTo-Gen4MetadataBlock -Tag 'Logi'`. Returns `$null` if no URLs extracted.

#### `Resolve-LogUrlToLocalPath`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Url` | string | Yes | Log URL to resolve |
| `LogDirectory` | string | No | Directory containing locally cached log files |

Returns the original URL unchanged if `$LogDirectory` is empty or the URL does not start with `http`. Otherwise normalizes the URL via `Normalize-LogUrl`, converts to a filename via `ConvertTo-LogFileName`, checks if the file exists in `$LogDirectory`, and returns `res/logs/$FileName` if found. Used during format upgrade to localize log URLs that have been downloaded by migration Phase 4.

---

## 9. `New-Session` - Gen4 Generation

### 9.1 Header Construction

Format: `### yyyy-MM-dd[/dd], Title, Narrator`

Optional `DateEnd` appended as `/dd` suffix (validated: same month/year, > Date).

### 9.2 Metadata Assembly

Delegates to `ConvertTo-SessionMetadata` which calls `ConvertTo-Gen4MetadataBlock` per field.

**Canonical block order**: `@Narrator` -> `@Data` -> `@Lokacje` -> `@Logi` -> `@PU` -> `@Zmiany` -> `@Intel`

Note: `@Transfer` is not rendered by `ConvertTo-SessionMetadata` — it is a read-only parsed field from `Get-SessionListMetadata`, not a writable metadata block.

Returns a string - does **not** write to disk.

---

## 10. File Map

### 10.1 Session Helper Files

| File | Functions |
|---|---|
| `public/session/get-session.ps1` | `Get-Session`, `Get-SessionFormat`, `ConvertFrom-SessionHeader`, `Merge-SessionGroup` |
| `public/session/set-session.ps1` | `Set-Session` |
| `public/session/new-session.ps1` | `New-Session` |
| `private/session-parsehelpers.ps1` | `Get-SessionTitle`, `Get-SessionLocations`, `Get-SessionListMetadata`, `Get-SessionPlainTextLogs` |
| `private/session-decomposehelpers.ps1` | `Find-SessionInFile`, `Split-SessionSection`, `ConvertTo-Gen4FromRawBlock`, `ConvertFrom-ItalicLocation`, `ConvertFrom-PlainTextLog`, `Resolve-LogUrlToLocalPath`, `Get-FormatFromSplit` |
| `private/session-intelhelpers.ps1` | `Resolve-EntityWebhook`, `Test-LocationMatch`, `Resolve-IntelTargets`, `Get-SessionMentions` |
| `private/format-sessionblock.ps1` | `ConvertTo-Gen4MetadataBlock`, `ConvertTo-SessionMetadata` |

### 10.2 Shared Rendering (`private/format-sessionblock.ps1`)

| Function | Purpose |
|---|---|
| `ConvertTo-Gen4MetadataBlock` | Renders a single `@`-prefixed block (switch dispatch by tag) |
| `ConvertTo-SessionMetadata` | Renders all blocks in canonical order, joined with newlines |

### 10.3 Rendering Rules

| Tag | Item format |
|---|---|
| `@Narrator` | `    - NarratorName` (4-space indent) |
| `@Data` | `- @Data: YYYY-MM-DD` (inline, single value) |
| `@Lokacje` | `    - LocationName` (4-space indent) |
| `@Logi` | `    - URL` (4-space indent) |
| `@PU` | `    - Character: Value` (decimal with `InvariantCulture`) |
| `@Zmiany` | `    - EntityName` (4-space) -> `        - @tag: value` (8-space) |
| `@Intel` | `    - RawTarget: Message` (4-space) |

Returns `$null` if items are empty/null - caller must check before including in output.

---

## 11. Edge Cases

| Scenario | Behavior |
|---|---|
| Date range `2022-12-21/22` | Parsed as `Date` + `DateEnd` (same month validated) |
| Session with broken date | Skipped normally; included with `-IncludeFailed` (carries `ParseError`) |
| Multiple sessions on same date in same file | Error with header list |
| Code blocks in session content | `InCodeBlock` toggle prevents false metadata detection |
| PU value with comma decimal | Normalized to period before parsing |
| `$null` PU value | Contributes 0 to computation; flagged by diagnostics |
| Entity mention in metadata block | Excluded from mention scanning |
| Intel target unresolvable | Warns to stderr, continues |
| Newline style (CRLF vs LF) | Detected and preserved on round-trip |
| Preserved blocks during upgrade | `Objaśnienia`, `Efekty`, etc. written back unchanged |
| Batch format upgrade (`-UpgradeFormat`) | Skips eager session graph refresh (caller rebuilds full graph afterward, avoiding O(n²) per-session updates) |
| Transfer with invalid amount | Skipped (amount must be positive integer) |
| Transfer missing source/destination | Skipped |
| Local log paths in `.Logs` | Sessions modified by migration Phase 5 may contain `res/logs/filename` entries instead of `https://...` URLs. Both formats are handled by `Get-SessionLog` and `Invoke-SessionLogFetch` |

### Session Object (`Get-Session`)

| Property | Type | Description |
|---|---|---|
| `FilePath` | string | Source file path |
| `FilePaths` | string[] | All source files (after dedup merge) |
| `Header` | string | Raw header text |
| `Date` | datetime | Session date |
| `DateEnd` | datetime | End date (for multi-day sessions) |
| `Title` | string | Session title (header minus date and narrator) |
| `Narrator` | object | Narrator info (see Narrator Subproperties below) |
| `Locations` | string[] | Session locations |
| `Logs` | string[] | Session log entries: URLs (`https://...`) or local file paths (`res/logs/...`) after migration Phase 5 URL localization |
| `PU` | object[] | PU awards (Character + Value) |
| `Format` | string | Detected format generation: Gen1, Gen2, Gen3, Gen4 |
| `IsMerged` | bool | Whether this session was deduplicated |
| `DuplicateCount` | int | Number of duplicates found |
| `Content` | string | Full section content (only with `-IncludeContent`) |
| `Changes` | object[] | Entity state overrides from `- Zmiany:` block |
| `Transfers` | object[] | Currency transfer directives from `- @Transfer:` lines (Amount, Denomination, Source, Destination) |
| `Mentions` | object[] | Deduplicated array of mention objects (only with `-IncludeMentions`) |
| `Intel` | object[] | Resolved `@Intel` entries with recipient webhooks |
| `LogData` | object | Parsed log data (only with `-IncludeLogs`, from `Get-SessionLog`) |
| `ParseError` | string | Error description (only with `-IncludeFailed`) |

### Narrator Subproperties (`Session.Narrator`)

| Property | Type | Description |
|---|---|---|
| `Narrators` | object[] | Array of narrator objects (Name, Player, Confidence) |
| `IsCouncil` | bool | Whether this is a "Rada" (council) session |
| `Confidence` | string | Overall resolution confidence: High, Medium, None |
| `RawText` | string | Raw narrator text from header |

### Mention Object (`Session.Mentions`)

| Property | Type | Description |
|---|---|---|
| `Name` | string | Entity's canonical display name (nominative form) |
| `Type` | string | Entity type: `Player`, `NPC`, `Grupa`, `Lokacja`, `Gracz`, `Postać` |
| `Owner` | object | Reference to the resolved owner object (Player or Entity) |

### Intel Object (`Session.Intel`)

| Property | Type | Description |
|---|---|---|
| `RawTarget` | string | Original target string from Markdown (e.g. `Grupa/Nocarze`, `Rion`) |
| `Message` | string | Intel message text |
| `Directive` | string | Parsed directive: `Grupa`, `Lokacja`, or `Direct` |
| `TargetName` | string | Resolved target name (after stripping prefix) |
| `Recipients` | object[] | Array of recipient objects with resolved webhooks |

### Recipient Object (`Intel.Recipients`)

| Property | Type | Description |
|---|---|---|
| `Name` | string | Recipient entity's canonical name |
| `Type` | string | Entity type |
| `Webhook` | string | Discord webhook URL, or `$null` if entity has no webhook |

### Change Object (`Session.Changes`)

| Property | Type | Description |
|---|---|---|
| `EntityName` | string | Raw entity name from the Zmiany block |
| `Tags` | object[] | Array of tag objects (Tag + Value) |

### Change Tag Object (`Change.Tags`)

| Property | Type | Description |
|---|---|---|
| `Tag` | string | Lowercase `@tag` name (e.g. `@lokacja`, `@grupa`) |
| `Value` | string | Raw value string (may include temporal range) |

### Transfer Object (`Session.Transfers`)

| Property | Type | Description |
|---|---|---|
| `Amount` | int | Transfer amount (positive integer) |
| `Denomination` | string | Currency denomination shorthand |
| `Source` | string | Source entity name |
| `Destination` | string | Destination entity name |

---

## 12. Precompiled Regex Patterns

### 12.1 Session Parse Helpers (`session-parsehelpers.ps1`)

| Variable | Scope | Pattern | Purpose |
|---|---|---|---|
| `$PUSectionPattern` | `$script:` | `^\s*[-\*]\s+@?[Pp][Uu]\s*:` | PU section header (for diagnostics, shared with `Test-SessionIntegrity`) |

### 12.2 Get-Session (`get-session.ps1`, local to function)

| Variable | Pattern | Purpose |
|---|---|---|
| `$DateRegex` | `$script:SessionDatePattern` (from `temporal-helpers.ps1`) | Session header date extraction |
| `$LocItalicRegex` | `\*Lokalizacj[ae]?:\s*(.+?)\*` | Gen2 italic location detection |
| `$PURegex` | `^(.+?):\s*([\d,\.]+)` | PU entry parsing |
| `$UrlRegex` | `(https?://\S+)` | URL extraction |
| `$LogiLineRegex` | `^Logi:\s*(https?://\S+)` | Gen1/2 plain text log detection |

### 12.3 Intel/Mention Helpers (`session-intelhelpers.ps1`)

| Variable | Scope | Pattern | Purpose |
|---|---|---|---|
| `$MentionListLineRegex` | `$script:` | `^\s*(\d+\.\|[-\*\+])\s+` | Detect list-item lines for Source B exclusion |
| `$MentionLogiPlainRegex` | `$script:` | `^Logi:\s*https?://` | Detect plain-text Logi lines for Source B exclusion |
| `$MentionMdLinkRegex` | `$script:` | `\[(.+?)\]\(.+?\)` | Extract Markdown link display text for tokenization |
| `$MentionPunctuationRegex` | `$script:` | Punctuation character class | Split tokens on punctuation boundaries |

### 12.4 Diagnostics (from other files, shared via module scope)

| Variable | Pattern | Purpose |
|---|---|---|
| `$PULikePattern` | `^\s+[-\*]\s+(.+?):\s*([\d,\.]+)\s*$` | PU-like child line (for diagnostics) |

---

## 13. Testing

| Test file | Coverage |
|---|---|
| `tests/get-session.Tests.ps1` | All format generations, date parsing, deduplication, metadata extraction, Intel, mentions |
| `tests/set-session.Tests.ps1` | Section decomposition, format upgrade, metadata replacement, preserved blocks |
| `tests/new-session.Tests.ps1` | Gen4 generation, header construction, round-trip compatibility |
| `tests/format-sessionblock.Tests.ps1` | Block rendering, canonical ordering, null handling |

Fixtures: `sessions-gen1.md`, `sessions-gen2.md`, `sessions-gen3.md`, `sessions-gen4.md`, `sessions-duplicate.md`, `sessions-zmiany.md`, `sessions-failed.md`.

---

## 14. Related Documents

- [PU.md](PU.md) - PU computation from session data
- [ENTITIES.md](ENTITIES.md) - Entity state merging from session Zmiany
- [CURRENCY.md](CURRENCY.md) - Currency tracking system (@Transfer processing, reconciliation)
- [LOGS.md](LOGS.md) - Session log pipeline (fetching, parsing, location analysis)
- [PARSER.md](PARSER.md) - Underlying Markdown parser
- [LOCATION-GRAPH.md](LOCATION-GRAPH.md) - Location graph (route edges from session metadata)
- [SESSION-GRAPH.md](SESSION-GRAPH.md) - Session participation graph (entity involvement tracking)
- [SESSION-INTEGRITY.md](SESSION-INTEGRITY.md) - Session content hashing and integrity checks
- [MIGRATION.md](MIGRATION.md) - §3 Session Format Transition

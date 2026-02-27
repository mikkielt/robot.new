# Session Pipeline — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the session subsystem: `Get-Session` (extraction, format detection, deduplication, Intel resolution), `Set-Session` (modification, format upgrade), `New-Session` (Gen4 generation), and `format-sessionblock.ps1` (shared rendering).

**Not covered**: PU computation from session data — see [PU.md](PU.md). Entity state merging from session Zmiany — see [ENTITIES.md](ENTITIES.md).

---

## 2. Architecture Overview

```
Get-Session (read path)
    ├── Get-Markdown (batch file parsing)
    ├── Get-Entity (entity data for resolution)
    ├── Get-Player (player data)
    ├── Get-NameIndex (token index for mentions/intel)
    ├── Resolve-Narrator (narrator name resolution)
    ├── Format detection (Gen1–Gen4 heuristics)
    ├── Metadata extraction (per-format strategies)
    ├── Cross-file deduplication (Merge-SessionGroup)
    └── Intel target resolution (Resolve-IntelTargets)

Set-Session (write path)
    ├── Find-SessionInFile (section boundary detection)
    ├── Split-SessionSection (decompose into meta/preserved/body)
    ├── format-sessionblock.ps1 (Gen4 rendering)
    └── Format upgrade converters (Gen2/3 → Gen4)

New-Session (creation path)
    └── format-sessionblock.ps1 (Gen4 rendering)
```

---

## 3. Format Generations

| Gen | Era | Location format | Log format | Metadata blocks | Detection heuristic |
|---|---|---|---|---|---|
| Gen1 | START–2022 | None | `Logi: https://…` plain text | None | Fallback (no other match) |
| Gen2 | 2022–2023 | `*Lokalizacja: A, B*` (italic) | `Logi: https://…` plain text | None | First non-empty line starts with `*Lokalizacj` |
| Gen3 | 2024–2026 | `- Lokalizacje:` list item | `- Logi:` list item | `- PU:`, `- Zmiany:`, `- Efekty:` | Root list item with `pu` prefix (no `@`) |
| Gen4 | 2026+ | `- @Lokacje:` list item | `- @Logi:` list item | `- @PU:`, `- @Zmiany:`, `- @Intel:` | Root list item starting with `@` + letter |

All four formats remain parseable. `Get-Session` auto-detects and normalizes transparently.

### 3.1 Format Detection (`Get-SessionFormat`)

Detection order (per-section heuristic):
1. `$FirstNonEmptyLine` starts with `*Lokalizacj` → **Gen2**
2. Root list items (`$LI.Indent -eq 0`):
   - Text starts with `@` + letter → **Gen4**
   - Text starts with `pu` followed by `:` or space → **Gen3**
3. Fallback → **Gen1**

---

## 4. `Get-Session` — Extraction Pipeline

### 4.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `File` | string[] | Specific files to scan |
| `Directory` | string | Directory to scan recursively |
| `MinDate` / `MaxDate` | datetime | Date range filter |
| `IncludeContent` | switch | Include raw section content in output |
| `IncludeMentions` | switch | Extract entity mentions from body text |
| `IncludeFailed` | switch | Include sessions with broken date headers |

### 4.2 Dependency Pre-Fetching

`Get-Session` batch-loads all dependencies upfront:

```powershell
$Entities = Get-Entity
$Players  = Get-Player -Entities $Entities
$Index    = Get-NameIndex -Players $Players -Entities $Entities
$Docs     = Get-Markdown -File $FilesToProcess  # or -Directory
```

### 4.3 Date Parsing (`ConvertFrom-SessionHeader`)

Parses `### YYYY-MM-DD` headers via `[datetime]::TryParseExact` with format `"yyyy-MM-dd"`.

Supports date ranges: `2022-12-21/22` → `Date = Dec 21`, `DateEnd = Dec 22`. The `/DD` suffix must be same month/year.

### 4.4 Title Extraction (`Get-SessionTitle`)

Strips the date prefix and trailing narrator segment (after last comma) from the header text.

### 4.5 Location Extraction (`Get-SessionLocations`)

Two strategies, tried in order:

1. **Entity resolution** (Gen3/Gen4): Check if all root list item children resolve to `Lokacja` entities via the name index. If yes, use those as locations.
2. **Tag-based fallback** (all formats): Look for root list items matching `Lokalizacj*` or `Lokacj*`. Leading `@` stripped.
3. **Italic extraction** (Gen2): Regex on `*Lokalizacja: A, B*` pattern.

### 4.6 Metadata Extraction (`Get-SessionListMetadata`)

Parses structured list items for Gen3/Gen4 sessions. Leading `@` is stripped via:

```powershell
$MatchText = if ($LowerText.StartsWith('@')) { $LowerText.Substring(1) } else { $LowerText }
```

This enables unified parsing for both `- PU:` and `- @PU:`.

Extracted fields:
- **PU**: `Character: Value` pairs (comma → period decimal normalization)
- **Logs**: Child URLs under `logi` tag
- **Changes (Zmiany)**: Entity names at 4-space indent, `@tag: value` at 8-space indent
- **Intel**: `RawTarget: Message` pairs under `intel` tag

### 4.7 Plain-Text Log Fallback (`Get-SessionPlainTextLogs`)

Applied when list-based `$Logs.Count -eq 0`. Scans raw content lines for `Logi: <url>` patterns (Gen1/Gen2).

---

## 5. Session Deduplication (`Merge-SessionGroup`)

Sessions with identical headers across multiple files represent the same session.

### 5.1 Grouping

```powershell
Dictionary[string, List[session]] grouped by exact Header text (Ordinal comparison)
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

### 6.1 Targeting Directives

| Directive | Syntax | Fan-out strategy |
|---|---|---|
| `Grupa/` | `Grupa/OrgName` | Target org + all entities with `@grupa` membership matching at session date |
| `Lokacja/` | `Lokacja/LocName` | BFS through location tree via `@lokacja` + non-location entities within the tree |
| Direct | `Name` or `Name1, Name2` | Comma-split, resolved individually |

### 6.2 Resolution Stages

Uses stages 1/2/2b of name resolution (exact → declension → stem alternation). **No fuzzy matching** (stage 3 skipped for Intel).

### 6.3 Webhook Resolution (`Resolve-EntityWebhook`)

Priority chain:
1. Entity's own `@prfwebhook` override
2. For `Postać (Gracz)` entities: owning Player's `PRFWebhook`
3. `$null` if neither available

---

## 7. Mention Extraction (`Get-SessionMentions`)

Enabled via `-IncludeMentions` switch. Five-phase pipeline:

1. **Exclude metadata list items** recursively (PU, Logi, Lokalizacje, Zmiany, Intel)
2. **Collect scannable text** from remaining list items + section content
3. **Tokenize** via regex word boundary splitting
4. **Resolve** each token via stages 1/2/2b (no fuzzy matching)
5. **Deduplicate** and build output objects

Cache pattern uses `[DBNull]::Value` sentinel for unresolvable tokens.

---

## 8. `Set-Session` — Modification Pipeline

### 8.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| Pipeline input | session object | From `Get-Session` |
| `Date` / `File` | explicit | Alternative to pipeline input |
| `Locations`, `PU`, `Logs`, `Changes`, `Intel`, `Content` | various | New values (full-replace semantics) |
| `Properties` | hashtable | Alternative to individual parameters |
| `UpgradeFormat` | switch | Convert Gen2/Gen3 → Gen4 |

### 8.2 Section Discovery (`Find-SessionInFile`)

Linear scan for `### ` headers with date regex matching. Section end = next `### ` header or EOF.

### 8.3 Section Decomposition (`Split-SessionSection`)

State machine classifies content into:

| Category | Tags | Handling |
|---|---|---|
| Meta blocks | `pu`, `logi`, `lokalizacje`, `lokacje`, `zmiany`, `intel` | Replaceable by parameters or upgradeable |
| Preserved blocks | `objaśnienia`, `efekty`, `komunikaty`, `straty`, `nagrody` | Written back unchanged |
| Body lines | Everything else | Replaceable via `-Content` |
| Legacy formats | Gen2 italic locations, Gen1/2 plain logs | Captured separately, converted during upgrade |

### 8.4 Metadata Replacement

**Full-replace semantics** (not merge):
- `$null` (or omit) → leave unchanged
- `@()` (empty array) → clear the block
- Non-empty value → replace entirely

### 8.5 Format Upgrade Conversions

| Source | Converter | Output |
|---|---|---|
| Gen3 list blocks | `ConvertTo-Gen4FromRawBlock` | Rename root tag, normalize to 4-space indent multiples |
| Gen2 italic locations | `ConvertFrom-ItalicLocation` | `- @Lokacje:` with expanded children |
| Gen1/2 plain text logs | `ConvertFrom-PlainTextLog` | `- @Logi:` with child URLs |

Inline CSV values on root lines are expanded to nested 4-space indented children during Gen3→Gen4 conversion.

---

## 9. `New-Session` — Gen4 Generation

### 9.1 Header Construction

Format: `### yyyy-MM-dd[/dd], Title, Narrator`

Optional `DateEnd` appended as `/dd` suffix (validated: same month/year, > Date).

### 9.2 Metadata Assembly

Delegates to `ConvertTo-SessionMetadata` which calls `ConvertTo-Gen4MetadataBlock` per field.

**Canonical block order**: `@Lokacje` → `@Logi` → `@PU` → `@Zmiany` → `@Transfer` → `@Intel`

Returns a string — does **not** write to disk.

---

## 10. Shared Rendering (`format-sessionblock.ps1`)

### 10.1 Functions

| Function | Purpose |
|---|---|
| `ConvertTo-Gen4MetadataBlock` | Renders a single `@`-prefixed block (switch dispatch by tag) |
| `ConvertTo-SessionMetadata` | Renders all blocks in canonical order, joined with blank lines |

### 10.2 Rendering Rules

| Tag | Item format |
|---|---|
| `@Lokacje` | `    - LocationName` (4-space indent) |
| `@Logi` | `    - URL` (4-space indent) |
| `@PU` | `    - Character: Value` (decimal with `InvariantCulture`) |
| `@Zmiany` | `    - EntityName` (4-space) → `        - @tag: value` (8-space) |
| `@Transfer` | `    - @Transfer: {amount} {denomination}, {source} -> {destination}` |
| `@Intel` | `    - RawTarget: Message` (4-space) |

Returns `$null` if items are empty/null — caller must check before including in output.

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
| `Logs` | string[] | Session log URLs |
| `PU` | object[] | PU awards (Character + Value) |
| `Format` | string | Detected format generation: Gen1, Gen2, Gen3, Gen4 |
| `IsMerged` | bool | Whether this session was deduplicated |
| `DuplicateCount` | int | Number of duplicates found |
| `Content` | string | Full section content (only with `-IncludeContent`) |
| `Changes` | object[] | Entity state overrides from `- Zmiany:` block |
| `Transfers` | object[] | Currency transfer directives from `- @Transfer:` lines (Amount, Denomination, Source, Destination) |
| `Mentions` | object[] | Deduplicated array of mention objects (only with `-IncludeMentions`) |
| `Intel` | object[] | Resolved `@Intel` entries with recipient webhooks |
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
| `Type` | string | Entity type: `Player`, `NPC`, `Organizacja`, `Lokacja`, `Gracz`, `Postać (Gracz)` |
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

---

## 12. Precompiled Regex Patterns

| Variable | Pattern | Purpose |
|---|---|---|
| `$DateRegex` | `yyyy-MM-dd` with optional `/DD` | Session header date extraction |
| `$LocItalicRegex` | `*Lokalizacja:...*` | Gen2 italic location detection |
| `$PURegex` | `Character: decimal` | PU entry parsing |
| `$UrlRegex` | `https?://...` | URL extraction |
| `$LogiLineRegex` | `Logi: <url>` | Gen1/2 plain text log detection |
| `$PUSectionPattern` | `^\s*[-\*]\s+@?[Pp][Uu]\s*:` | PU section header (for diagnostics) |
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

- [PU.md](PU.md) — PU computation from session data
- [ENTITIES.md](ENTITIES.md) — Entity state merging from session Zmiany
- [CURRENCY.md](CURRENCY.md) — Currency tracking system (@Transfer processing, reconciliation)
- [PARSER.md](PARSER.md) — Underlying Markdown parser
- [MIGRATION.md](MIGRATION.md) — §3 Session Format Transition

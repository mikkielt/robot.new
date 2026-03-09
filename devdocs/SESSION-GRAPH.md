# Session Participation Graph - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the session participation graph subsystem: three-tier entity involvement classification, persistent index storage, incremental updates, eager refresh, mention caching, and multi-mode query API.

| Function | File | Purpose |
|---|---|---|
| `Set-SessionGraph` | `public/workflow/set-sessiongraph.ps1` | Build/update persistent participation index |
| `Get-SessionGraph` | `public/reporting/get-sessiongraph.ps1` | Query API with 4 output modes |
| `Test-SessionGraphIntegrity` | `public/reporting/test-sessiongraphintegrity.ps1` | Validate index against repo state |
| `Get-EntitySessionProfile` | `public/reporting/get-entitysessionprofile.ps1` | Comprehensive entity participation profile |
| `Get-NarratorSessionProfile` | `public/reporting/get-narratorsessionprofile.ps1` | Narrator session statistics |
| `Compare-SessionParticipation` | `public/reporting/compare-sessionparticipation.ps1` | Multi-entity participation comparison |
| `Get-SessionGraphLeaderboard` | `public/reporting/get-sessiongraphleaderboard.ps1` | Entities ranked by session count |
| `Get-FilePathInvolvement` | `private/session-graphhelpers.ps1` | Classify file path -> entity category/type |
| `ConvertTo-ParticipantRecord` | `private/session-graphhelpers.ps1` | Merge three-tier involvement for a session |
| `Read-SessionGraphIndex` | `private/session-graphhelpers.ps1` | Load index from `_index.json` |
| `Write-SessionGraphIndex` | `private/session-graphhelpers.ps1` | Persist index to `_index.json` |
| `Read-SessionGraphMeta` | `private/session-graphhelpers.ps1` | Load metadata from `_meta.json` |
| `Write-SessionGraphMeta` | `private/session-graphhelpers.ps1` | Persist metadata |
| `Get-NameIndexVersion` | `private/session-graphhelpers.ps1` | SHA256 of sorted entity names |
| `ConvertFrom-GraphEntryDate` | `private/session-graphhelpers.ps1` | Parse date string from graph entry into `[datetime]` |
| `Test-GraphEntryDateInRange` | `private/session-graphhelpers.ps1` | Test whether a graph entry's date falls within a range |
| `Update-SessionGraphEntry` | `private/session-graphhelpers.ps1` | Recompute Tier 0+1 for a session, preserve Tier 2 |
| `Read-MentionCache` | `private/session-graphhelpers.ps1` | Load Tier 2 mention cache from `_mentions.json` |
| `Write-MentionCache` | `private/session-graphhelpers.ps1` | Persist mention cache |
| `Get-CachedMentions` | `private/session-graphhelpers.ps1` | Return cached mentions if cache key matches |

`Set-SessionGraph` is a write command (`SupportsShouldProcess`). `Get-SessionGraph` is read-only.

**Not covered**: Session parsing (`Get-Session`) -- see [SESSIONS.md](SESSIONS.md). Name resolution (`Resolve-Name`, `Get-NameIndex`) -- see [NAME-RESOLUTION.md](NAME-RESOLUTION.md). Session integrity hashing -- see [SESSION-INTEGRITY.md](SESSION-INTEGRITY.md).

---

## 2. Architecture Overview

```
private/session-graphhelpers.ps1       Graph helpers (non-Verb-Noun, dot-sourced)
├── Get-FilePathInvolvement            RelPath -> { Category, Name, Type }
├── ConvertTo-ParticipantRecord        Session -> participant[] (3-tier merge)
├── Read-SessionGraphIndex             _index.json -> hashtable
├── Write-SessionGraphIndex            hashtable -> _index.json
├── Read-SessionGraphMeta              _meta.json -> hashtable
├── Write-SessionGraphMeta             hashtable -> _meta.json
├── Get-NameIndexVersion               string[] -> SHA256 hash
├── ConvertFrom-GraphEntryDate         Entry -> [datetime] or $null
├── Test-GraphEntryDateInRange         Entry + bounds -> bool
├── Update-SessionGraphEntry           Session -> index entry (Tier 0+1 refresh)
├── Read-MentionCache                  _mentions.json -> hashtable
├── Write-MentionCache                 hashtable -> _mentions.json
└── Get-CachedMentions                 Header + keys -> mentions[] or $null

public/workflow/set-sessiongraph.ps1   Index writer (exported, SupportsShouldProcess)
└── dot-sources: session-graphhelpers.ps1, session-hashhelpers.ps1, admin-config.ps1

public/reporting/get-sessiongraph.ps1  Query API (exported, read-only)
└── dot-sources: session-graphhelpers.ps1, admin-config.ps1
```

### 2.1 Index Store Layout

The graph uses a single index file (not per-file sidecars like session-hashes) because sessions span multiple source files via `Merge-SessionGroup`:

```
.robot/res/session-graph/
├── _meta.json         Operational metadata (timestamps, name version, count, staleness)
├── _index.json        All sessions with their participant lists
└── _mentions.json     Tier 2 mention cache (keyed by NameIndexVersion + content hash)
```

---

## 3. Three-Tier Involvement Model

Entity involvement in a session is classified into three tiers of decreasing confidence:

| Tier | Signal | Available In | Weight? |
|---|---|---|---|
| **0 -- Filesystem** | Session `.md` file placed in entity's directory | All formats (Gen1-Gen4) | No (binary) |
| **1 -- Structured** | Entity appears in `@PU`, `@Zmiany`, `@Transfer`, or `@Intel` | Gen3+ only | Yes (PU value) |
| **2 -- Body Text** | Entity name found via `Get-SessionMentions` | All formats (with `-IncludeMentions`) | No (binary) |

### 3.1 Tier Coverage by Format Generation

| Format | Tier 0 (Filesystem) | Tier 1 (Structured) | Tier 2 (Body Text) |
|---|---|---|---|
| Gen1 (-2022) | Binary participation | Not available | Cached mentions |
| Gen2 (2022-2023) | Binary participation | Not available | Cached mentions |
| Gen3 (2024-2025) | Binary participation | PU weights, Zmiany, Transfer | Cached mentions |
| Gen4 (2026+) | Binary participation | All @-tags | Cached mentions |

### 3.2 Deduplication Rules

When the same entity appears at multiple tiers:
1. **Lowest tier number wins** (Tier 0 > Tier 1 > Tier 2 in confidence)
2. The winning tier's `Source` field is kept
3. If Tier 1 provides a `Weight`, it is preserved only if Tier 1 is the winner

---

## 4. `Get-FilePathInvolvement`

Maps a repo-relative file path (forward slashes) to an entity involvement record.

### 4.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `RelPath` | string | Yes | Repo-relative file path (forward slashes, e.g. `Postaci/Gracze/Xeron.md`) |

### 4.2 Classification Rules

Evaluated in order; first match wins. All comparisons use `OrdinalIgnoreCase`.

| Rule | Path Pattern | Category | Entity Type | Name Derivation |
|---|---|---|---|---|
| 1 | `Postaci/Gracze/*.md` | Player | Postac | Filename stem |
| 2 | `Postaci/NPC/**/*.md` | NPC | NPC | Filename stem |
| 3 | `Swiat gry/**/Sesje lokalne.md` | Location | Lokacja | Parent directory name |
| 4 | `Watki/*.md` | Thread | Watek | Filename stem |
| 5 | `Organizacje/**/*.md` | Org | Grupa | Filename stem |
| 6 | Everything else | -- | -- | -- |

Implementation notes:
- **Watek** is a graph-only classification; no corresponding entity type exists in `entities.md`
- **Grupa** maps the `Organizacje/` directory to the existing entity type
- Rule 1 checks for no further `/` after the `Postaci/Gracze/` prefix (flat directory)
- Rule 4 checks for no further `/` after `Watki/` (flat directory)
- Backslashes are normalized to forward slashes before matching

### 4.3 Output

Returns `[PSCustomObject]` with properties `Category`, `Name`, `Type`. Returns `$null` for unrecognized paths.

---

## 5. `ConvertTo-ParticipantRecord`

Merges all three tiers of involvement for a single session into a deduplicated participant list.

### 5.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Session` | object | Yes | Session object from `Get-Session` (must have `FilePaths`, `PU`, `Changes`, `Transfers`, `Intel`, `Mentions`) |

### 5.2 Algorithm

Three passes, each feeding into a `Dictionary[string, object]` keyed by entity name (`OrdinalIgnoreCase`):

```
Pass 1 (Tier 0): Session.FilePaths -> Get-FilePathInvolvement -> participant records
Pass 2 (Tier 1): Session.PU         -> Character/Value pairs (Source='PU', Weight=Value)
                  Session.Changes    -> EntityName entries (Source='Changes')
                  Session.Transfers  -> Source/Destination pairs (Source='Transfer')
                  Session.Intel      -> Recipient entries (Source='Intel')
Pass 3 (Tier 2): Session.Mentions   -> Name/Type pairs (Source='BodyText')
```

The `$MergeParticipant` scriptblock implements deduplication per section 3.2. When the same name appears at a lower tier, the entire record is replaced. Equal-tier entries with a non-null `Weight` preserve the weight.

### 5.3 Output

Returns `PSCustomObject[]`:

| Property | Type | Description |
|---|---|---|
| `Name` | string | Entity name |
| `Type` | string | Entity type (`Postac`, `NPC`, `Lokacja`, `Watek`, `Grupa`, or `$null` for unresolved) |
| `Tier` | int | Involvement tier (0, 1, or 2) |
| `Source` | string | Detection source (`FilePath`, `PU`, `Changes`, `Transfer`, `Intel`, `BodyText`) |
| `Weight` | decimal or `$null` | PU weight (only from Tier 1 PU entries) |

---

## 6. `Set-SessionGraph`

### 6.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Full` | switch | No | Rebuild entire index, clear Tier2Stale flag |
| `EagerOnly` | switch | No | Refresh only Tiers 0+1 for existing sessions (no mention resolution) |
| `Since` | string | No | Process sessions changed since this date (incremental) |
| `ExcludeDirectory` | string[] | No | Directories to exclude from session scanning |
| `Quiet` | switch | No | Suppress warning output to stderr |

Supports `ShouldProcess` (`ConfirmImpact = 'Low'`).

### 6.2 Three Modes

| Mode | Trigger | Tier 2 Handling | Mention Cache |
|---|---|---|---|
| **Full** | `-Full` switch | Rebuilt via `-IncludeMentions`; Tier2Stale cleared | Read/write `_mentions.json` |
| **Incremental** | Default (no switch) | Rebuilt for affected sessions only | Not used |
| **EagerOnly** | `-EagerOnly` switch | Preserved from existing index entries | Not used |

### 6.3 Algorithm

1. Load helpers via dot-sourcing (`session-graphhelpers.ps1`, `session-hashhelpers.ps1`, `admin-config.ps1`)
2. Resolve paths: `$Config.ResDir/session-graph/`
3. Read `_meta.json` for `LastIncrementalUpdate` and `NameIndexVersion`
4. **Determine scope**:
   - `-Full`: process all sessions
   - `-EagerOnly`: process only sessions that already exist in the index
   - Incremental: `Get-GitChangeLog -MinDate $LastIncrementalUpdate -NoPatch` -> changed `.md` files -> affected sessions (any session whose `FilePaths` overlaps a changed file)
   - Fallback: no stored timestamp or git fails -> full scan
5. Fetch sessions: `Get-Session` (with `-IncludeMentions` unless EagerOnly)
6. **NameIndex version check**: compute `Get-NameIndexVersion` from `Get-NameIndex` keys. If changed from stored and not EagerOnly -> force full rebuild (Tier 2 matches invalidated by name set change)
7. For each session:
   - EagerOnly: `Update-SessionGraphEntry` (preserves Tier 2, refreshes Tier 0+1)
   - Full/Incremental: `ConvertTo-ParticipantRecord` -> store in index. On full rebuild, check mention cache first to avoid redundant name resolution.
8. Incremental mode: load existing `_index.json`, replace only affected entries, preserve unaffected ones
9. Write `_index.json` and update `_meta.json` (both guarded by `ShouldProcess`)
10. Write `_mentions.json` if cache was updated during full rebuild

### 6.4 Output

| Property | Type | Description |
|---|---|---|
| `SessionsProcessed` | int | Number of sessions processed in this run |
| `ParticipantsFound` | int | Total participant records across all processed sessions |
| `Tier0Count` | int | Participants detected via filesystem placement |
| `Tier1Count` | int | Participants detected via structured metadata |
| `Tier2Count` | int | Participants detected via body text mentions |

Returns the zero-valued object when no sessions need processing.

---

## 7. `Get-SessionGraph`

### 7.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `EntityName` | string | No | Entity name to look up (required for Sessions, CoParticipants modes) |
| `EntityType` | string[] | No | Filter co-participants/timeline by entity type |
| `SessionHeader` | string | No | Session header to look up (required for EntityTimeline mode) |
| `MinDate` | datetime | No | Include only sessions on or after this date |
| `MaxDate` | datetime | No | Include only sessions on or before this date |
| `MinTier` | int | No | Maximum tier to include (default 2; 0=filesystem only, 1=+metadata, 2=+bodytext) |
| `Mode` | string | No | Output mode: `Sessions` (default), `CoParticipants`, `EntityTimeline`, `Summary` |
| `Quiet` | switch | No | Suppress warning output to stderr |

### 7.2 Output Modes

**Sessions** (default) -- requires `-EntityName`. Returns `PSCustomObject[]`:

| Property | Type | Description |
|---|---|---|
| `Header` | string | Full session header |
| `Date` | string | Session date (`yyyy-MM-dd`) |
| `Format` | string | Session format generation (`Gen1`-`Gen4`) |
| `EntityTier` | int | Tier at which the queried entity participates |
| `EntitySource` | string | Detection source for the queried entity |
| `EntityWeight` | decimal or `$null` | PU weight for the queried entity |
| `Participants` | hashtable[] | All participants in the session |
| `FilePaths` | string[] | Source file paths for the session |

**CoParticipants** -- requires `-EntityName`. Returns `PSCustomObject[]` sorted by `SharedSessions` descending:

| Property | Type | Description |
|---|---|---|
| `Name` | string | Co-participant entity name |
| `Type` | string | Entity type |
| `SharedSessions` | int | Number of sessions shared with the queried entity |

**EntityTimeline** -- requires `-SessionHeader`. Returns `PSCustomObject[]`:

| Property | Type | Description |
|---|---|---|
| `Session` | string | Session header |
| `Name` | string | Participant entity name |
| `Type` | string | Entity type |
| `Tier` | int | Involvement tier |
| `Source` | string | Detection source |
| `Weight` | decimal or `$null` | PU weight |

**Summary** -- no entity required. Returns a single `PSCustomObject`:

| Property | Type | Description |
|---|---|---|
| `TotalSessions` | int | Number of sessions in the filtered index |
| `TotalParticipants` | int | Total participant records (within tier threshold) |
| `FormatBreakdown` | PSCustomObject | Per-format session counts (e.g. `.Gen1 = 50`, `.Gen3 = 200`) |
| `Tier0Count` | int | Filesystem-detected participations |
| `Tier1Count` | int | Metadata-detected participations |
| `Tier2Count` | int | Body-text-detected participations |

---

## 8. Index Schema

### 8.1 `_meta.json`

| Field | Type | Default | Description |
|---|---|---|---|
| `Version` | int | `2` | Schema version |
| `LastFullUpdate` | string or `$null` | `$null` | Timestamp of last full build (`yyyy-MM-dd HH:mm:ss`) |
| `LastIncrementalUpdate` | string or `$null` | `$null` | Timestamp of last incremental update |
| `NameIndexVersion` | string or `$null` | `$null` | SHA256 of sorted entity name set |
| `SessionCount` | int | `0` | Number of sessions in the index |
| `Tier2Stale` | bool | `$false` | Whether Tier 2 matches are potentially invalid |
| `Tier2StaleReason` | string or `$null` | `$null` | Reason for staleness (e.g. name set changed) |
| `LastEagerRefresh` | string or `$null` | `$null` | Timestamp of last eager-only refresh |
| `EagerRefreshCount` | int | `0` | Number of eager refreshes since last full build |

Timestamps use non-ISO format `yyyy-MM-dd HH:mm:ss` to prevent `ConvertFrom-Json` auto-conversion. Read via `-AsHashtable`.

### 8.2 `_index.json`

Hashtable keyed by full session header string (e.g. `### 2024-06-15, Ucieczka z Erathii, Solmyr`). Each value:

| Field | Type | Description |
|---|---|---|
| `Date` | string | `yyyy-MM-dd` |
| `Format` | string | `Gen1`, `Gen2`, `Gen3`, or `Gen4` |
| `Participants` | hashtable[] | Array of participant records (Name, Type, Tier, Source, Weight) |
| `FilePaths` | string[] | Repo-relative source file paths |

Keys sorted alphabetically (`StringComparer.Ordinal`) for deterministic output. Serialized at `ConvertTo-Json -Depth 5`.

### 8.3 `_mentions.json`

Hashtable keyed by session header string. Each value:

| Field | Type | Description |
|---|---|---|
| `CacheKey` | string | `"{NameIndexVersion}:{ContentHash}"` composite key |
| `Mentions` | array | Cached mention records from `Get-SessionMentions` |

The cache key ensures that mentions are invalidated when either the entity name set changes (NameIndexVersion) or the session body content changes (ContentHash). Used only during full rebuilds.

---

## 9. Date Filtering Helpers

### 9.1 `ConvertFrom-GraphEntryDate`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Entry` | hashtable | Yes | Graph index entry (must have a `Date` key with `yyyy-MM-dd` value) |

Parses the `Date` string from a graph index entry into `[datetime]` via `TryParseExact`. Returns `$null` if the entry has no `Date` key or the value is not valid `yyyy-MM-dd`.

### 9.2 `Test-GraphEntryDateInRange`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Entry` | hashtable | Yes | Graph index entry |
| `MinDate` | Nullable[datetime] | No | Lower bound (inclusive) |
| `MaxDate` | Nullable[datetime] | No | Upper bound (inclusive) |

Tests whether a graph entry's parsed date falls within `[MinDate, MaxDate]`. Entries with unparseable or missing dates are excluded when any bound is set. Returns `$true` if in range. Used by `Get-SessionGraph` for all modes.

---

## 10. Eager Refresh (`Update-SessionGraphEntry`)

### 10.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `SessionHeader` | string | Yes | Session header string |
| `Session` | object | Yes | Session object from `Get-Session` |
| `Index` | hashtable | Yes | Graph index hashtable (mutated in-place) |

### 10.2 Algorithm

1. Collect existing Tier 2 entries for this session from the index (preserve mentions)
2. Build a session copy with `Mentions = @()` to suppress Tier 2 during recomputation
3. Call `ConvertTo-ParticipantRecord` on the copy to get fresh Tier 0+1 participants
4. Merge: fresh Tier 0+1 entries first, then preserved Tier 2 entries (only for names not already covered by Tier 0/1)
5. Write the updated index entry with merged participants, session date, format, and file paths

This function is used by `Set-SessionGraph -EagerOnly` to refresh structured metadata without the cost of full mention resolution. Tier 2 entries from a previous full build are preserved, maintaining coverage until the next full rebuild.

---

## 11. Mention Cache

### 11.1 `Read-MentionCache`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `CachePath` | string | Yes | Path to `_mentions.json` |

Loads the mention cache from disk. Returns empty hashtable on missing or corrupt file. Same error-handling pattern as `Read-SessionGraphIndex`.

### 11.2 `Write-MentionCache`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `CachePath` | string | Yes | Path to `_mentions.json` |
| `Cache` | hashtable | Yes | Cache hashtable to persist |

Creates parent directories as needed. Serialized at `ConvertTo-Json -Depth 5`.

### 11.3 `Get-CachedMentions`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `SessionHeader` | string | Yes | Session header to look up |
| `NameIndexVersion` | string | Yes | Current NameIndexVersion hash |
| `ContentHash` | string | Yes | Content hash of session body |
| `Cache` | hashtable | Yes | Mention cache hashtable |

Cache key = `"$NameIndexVersion:$ContentHash"`. Returns `$null` on miss. On hit, returns the cached mentions array (possibly empty `@()`). The composite key ensures invalidation when either the entity name set or session content changes.

---

## 12. `Get-NameIndexVersion`

### 12.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Names` | string[] | Yes | Array of entity names from the name index |

### 12.2 Algorithm

1. Sort names using `StringComparer.Ordinal`
2. Join with `|` separator
3. Compute SHA256 hash (reuses `Get-ContentHash` if loaded, otherwise inline computation)

Returns a 64-character lowercase hex string. Used by `Set-SessionGraph` to detect entity name set changes that would invalidate Tier 2 matches.

---

## 13. I/O Helpers

### 13.1 `Read-SessionGraphIndex` / `Write-SessionGraphIndex`

Follow the same pattern as `Read-SessionHashFile` / `Write-SessionHashFile` in `session-hashhelpers.ps1`:
- Read returns empty hashtable on missing or corrupt file
- Write creates parent directories as needed
- Write sorts keys via `StringComparer.Ordinal` before serialization
- Both use `.NET static I/O` with `$script:UTF8NoBOM` encoding

### 13.2 `Read-SessionGraphMeta` / `Write-SessionGraphMeta`

Follow the same pattern as `Read-SessionHashMeta` / `Write-SessionHashMeta`:
- Read returns defaults on missing file: `Version=2, SessionCount=0, timestamps=$null, NameIndexVersion=$null, Tier2Stale=$false, Tier2StaleReason=$null, LastEagerRefresh=$null, EagerRefreshCount=0`
- Read uses `ConvertFrom-Json -AsHashtable` to prevent timestamp auto-conversion
- Write creates parent directories as needed

---

## 14. Incremental Update Strategy

The incremental path in `Set-SessionGraph`:
1. Read `LastIncrementalUpdate` from `_meta.json`
2. `Get-GitChangeLog -MinDate $LastUpdate -NoPatch` -> list of changed `.md` file paths
3. For each session: if any path in its `FilePaths` array matches a changed file (OrdinalIgnoreCase) -> mark as affected
4. Load existing `_index.json`, replace only affected session entries, preserve unaffected ones
5. Write merged index

`NameIndexVersion` provides a safety net: if the entity name set changes (new entity added, entity renamed, alias changed), all Tier 2 body text matches are potentially invalidated, forcing a full rebuild regardless of incremental scope.

The **eager refresh** path (`-EagerOnly`) provides a lighter alternative: it refreshes Tier 0+1 for existing sessions without running mention resolution, and preserves existing Tier 2 entries. This is suitable for use after `Set-Session` writes where structured metadata has changed but body text has not.

---

## 15. Edge Cases

| Scenario | Behavior |
|---|---|
| Session with no `FilePaths` | Only Tier 1/2 participants are produced |
| File path not matching any classification rule | Silently skipped (`Get-FilePathInvolvement` returns `$null`) |
| PU entry with `$null` Value | Participant created with `Weight = $null` |
| Entity name is empty or whitespace | Skipped by `$MergeParticipant` guard |
| Merged session (via `Merge-SessionGroup`) | Graph sees the merged result -- `FilePaths`, `PU`, `Changes`, `Mentions` are already deduplicated |
| `Get-SessionGraph` called with no index file | Returns `@()` with a warning, never throws |
| `Get-SessionGraph` EntityTimeline without `-SessionHeader` | Returns `@()` with a warning |
| `Get-SessionGraph` Sessions/CoParticipants without `-EntityName` | Returns `@()` with a warning |
| `Set-SessionGraph -WhatIf` | No files written; `ShouldProcess` guards `_index.json`, `_meta.json`, and `_mentions.json` writes |
| Git changelog fails in incremental mode | Falls back to full scan with a warning |
| Incremental mode with no stored timestamp | Falls back to full scan |
| EagerOnly with empty index | Only sessions already in index are processed (none if empty) |
| Mention cache miss during full rebuild | Resolved mentions are computed and stored in cache for next time |
| Graph entry with unparseable date | Excluded from date-filtered queries |

---

## 16. Testing

Test file: `tests/set-sessiongraph.Tests.ps1` (31 tests, Pattern B)

| Describe Block | Tests | Coverage |
|---|---|---|
| `Get-FilePathInvolvement` | 12 | All 5 categories + unknown, backslash normalization, spaces in names |
| `ConvertTo-ParticipantRecord` | 9 | Per-tier extraction, dedup priority, weight preservation, tier upgrade |
| `Get-NameIndexVersion` | 4 | Consistency, order independence, change detection, hex format |
| Session Graph Index I/O | 6 | Read/Write round-trip, missing file defaults, parent directory creation |

Test file: `tests/get-sessiongraph.Tests.ps1` (20 tests, Pattern B with mocked `Get-AdminConfig`)

| Describe Block | Tests | Coverage |
|---|---|---|
| Missing index | 1 | Returns empty array when index file absent |
| Sessions mode | 7 | Entity filter, date range, MinTier filter, detail field verification |
| CoParticipants mode | 3 | Shared session counts, self-exclusion, tier filter on co-participants |
| EntityTimeline mode | 4 | Participant listing, missing session, tier filter, missing parameter |
| Summary mode | 3 | Global stats, format generation breakdown, date range |
| Tier coverage by format | 2 | Gen1 has Tier 0+2 only, Gen3 has Tier 0+1+2 |

Fixture data: in-memory hashtable with 5 sessions (1x Gen1, 1x Gen2, 2x Gen3, 1x Gen4) covering all tier combinations.

---

## 17. Related Documents

- [SESSIONS.md](SESSIONS.md) -- Session parsing, format generations, `Merge-SessionGroup`
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) -- Name index, fuzzy matching, mention extraction
- [SESSION-INTEGRITY.md](SESSION-INTEGRITY.md) -- Content hashing (similar architecture pattern)
- [LOCATION-GRAPH.md](LOCATION-GRAPH.md) -- Edge accumulation pattern reused in CoParticipants mode

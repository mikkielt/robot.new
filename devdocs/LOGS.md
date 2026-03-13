# Session Log Pipeline - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the session log subsystem: `Get-SessionLog` (fetch, parse, cross-reference), `Invoke-SessionLogFetch` (mass fetch workflow), `Get-NamedLogLocationReport` (location resolution analysis), and their private helpers in `log-fetchhelpers.ps1` and `parse-logcontent.ps1`.

| Function | File | Purpose |
|---|---|---|
| `Get-SessionLog` | `public/session/get-sessionlog.ps1` | Core pipeline: fetch, parse, cross-reference |
| `Invoke-SessionLogFetch` | `public/workflow/invoke-sessionlogfetch.ps1` | Mass fetch with error handling |
| `Get-NamedLogLocationReport` | `public/reporting/get-namedloglocationreport.ps1` | Location resolution analysis |
| `Resolve-LogUrlToLocalPath` | `private/session-decomposehelpers.ps1` | URL-to-local-path resolution for cached log files |
| `Normalize-LogUrl` | `private/log-fetchhelpers.ps1` | Pastebin URL normalization, http->https |
| `ConvertTo-LogFileName` | `private/log-fetchhelpers.ps1` | URL to filesystem-safe filename |
| `Get-LogHttpClient` | `private/log-fetchhelpers.ps1` | Lazily-initialized shared HttpClient |
| `Invoke-LogFetch` | `private/log-fetchhelpers.ps1` | Single URL fetch with disk cache |
| `Invoke-LogBatchFetch` | `private/log-fetchhelpers.ps1` | Sequential batch fetch with throttle |
| `Get-LogFormat` | `private/parse-logcontent.ps1` | Detect ChatLog vs Prose from content |
| `ConvertFrom-ChatLogContent` | `private/parse-logcontent.ps1` | Parse ChatLog format |
| `ConvertFrom-ProseContent` | `private/parse-logcontent.ps1` | Parse Prose format |
| `ConvertFrom-LogContent` | `private/parse-logcontent.ps1` | Dispatcher: detect format, route to parser |

**Shared dependency**: `private/string-helpers.ps1` provides `Get-LevenshteinDistance`, used by the location report's near-match detection.

**Not covered**: How session objects are produced - see [SESSIONS.md](SESSIONS.md). Name resolution internals - see [NAME-RESOLUTION.md](NAME-RESOLUTION.md).

---

## 2. Architecture Overview

```
Get-Session --> session objects with .Logs (URLs or local paths)
                    |
                    v
              Get-SessionLog
                +-- log-fetchhelpers.ps1
                |     +-- Normalize-LogUrl (pastebin URL normalization, http->https)
                |     +-- ConvertTo-LogFileName (URL -> cache filename)
                |     +-- Get-LogHttpClient (shared HttpClient, 30s timeout)
                |     +-- Invoke-LogFetch (single fetch with disk cache)
                |     +-- Invoke-LogBatchFetch (sequential batch with throttle)
                +-- parse-logcontent.ps1
                |     +-- Get-LogFormat (ChatLog vs Prose detection)
                |     +-- ConvertFrom-LogContent (dispatcher)
                |     +-- ConvertFrom-ChatLogContent (timestamped chat parser)
                |     +-- ConvertFrom-ProseContent (narrative parser)
                +-- Resolve-Name (optional speaker/location resolution)
                    |
                    v
              { Logs: [{ Url, Format, Lines[], LocationSegments[], Speakers[], Channels }] }
                    |
                    v
              Get-NamedLogLocationReport (location resolution quality analysis)
```

`Invoke-SessionLogFetch` handles mass fetching with CDN-safe throttling and persistent failure tracking. `Get-SessionLog` consumes the fetched files from disk.

---

## 3. Log Formats

Two formats are supported, auto-detected by `Get-LogFormat`:

### 3.1 ChatLog

Timestamped chat lines with channel tags. Source: game engine copy-paste.

```
 Domostwo
[13:22] [Lokalny] Rozleglo sie pukanie do drzwi.
[13:22] [Lokalny] Lord Haart ledwo co usiadl i znowu ktos zawraca glowe.
[13:22] [Lokalny] Lord Haart: Prosze!
```

**Detection**: Scans first ~30 non-empty lines for `^\[\d{2}:\d{2}\]` pattern. If >=2 matches: ChatLog.

**Location headers**: Non-empty lines that do NOT match `^\[\d{2}:\d{2}\]` and are not continuation text from a preceding timestamp line. Leading/trailing whitespace is stripped. These split the log into LocationSegments.

**Line parsing**:
- Pattern: `^\[(\d{2}:\d{2})\]\s*\[([^\]]+)\]\s*(.*)`
- Extracts: `Time`, `Channel` (Lokalny/Prywatny/Grupowy/Szept), `Speaker`, `Text`
- Speaker detection: `Speaker: text` or `*narration*` (null speaker)
- Speaker-only: `Speaker:` with no text after colon
- Continuation lines: timestamp line with no inline text after channel tag, followed by content on the next non-empty line (joined to that chat line's timestamp and channel)

### 3.2 Prose

Plain narrative without timestamps. Source: manually written session summaries.

```
Karczma pod Lisciem Debu

Narrator: Wieczor byl ciepły i wilgotny.
Jenova: Slyszalam o bandytach na trakcie.
```

**Detection**: Fallback when ChatLog detection fails.

**Location headers**: Short lines (<=60 chars) after an empty line, no `Speaker:` pattern, no leading `*`. Heuristic: `$PreviousWasEmpty` flag, with start of content treated as "after empty line".

**Line parsing**: `Speaker: text` pattern. Lines without speakers have null Speaker. Both ChatLog and Prose parsers produce uniform line objects with `Time` and `Channel` fields (set to `$null` in Prose).

---

## 4. Fetch Helpers (`private/log-fetchhelpers.ps1`)

### 4.1 `Normalize-LogUrl`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Url` | string | Yes | Raw or normalized URL to normalize |

Normalization rules:

```
pastebin.com/wqhtQ5Wq      -> https://pastebin.com/raw/wqhtQ5Wq
pastebin.com/raw/wqhtQ5Wq   -> https://pastebin.com/raw/wqhtQ5Wq  (unchanged)
http://example.com/log.txt  -> https://example.com/log.txt
```

Uses two precompiled regex patterns:
- `$script:PastebinUrlPattern`: matches non-raw pastebin URLs (`^https?://(?:www\.)?pastebin\.com/(?!raw/)([A-Za-z0-9]+)/?$`)
- `$script:PastebinRawPattern`: matches raw pastebin URLs (`^https?://(?:www\.)?pastebin\.com/raw/([A-Za-z0-9]+)/?$`)

Trims whitespace and trailing slashes before matching.

### 4.2 `ConvertTo-LogFileName`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `NormalizedUrl` | string | Yes | Normalized URL to convert to filename |

Strips protocol prefix (`https://` or `http://`), removes all non-alphanumeric characters via `$script:UrlUnsafeChars`:

```
https://pastebin.com/raw/wqhtQ5Wq -> pastebincomrawwqhtQ5Wq
```

Files are stored in `res/logs/` (resolved via `Get-AdminConfig` ResDir).

### 4.3 `Get-LogHttpClient`

No parameters. Returns the lazily-initialized shared `[System.Net.Http.HttpClient]` instance stored in `$script:LogHttpClient`. The client has:
- 30-second timeout (`TimeSpan.FromSeconds(30)`)
- Custom User-Agent header: `Robot-PowerShell/1.0`

Reused across all calls within the same module session.

### 4.4 `Invoke-LogFetch`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Url` | string | Yes | URL to fetch |
| `LogDirectory` | string | Yes | Directory for cached log files |
| `RetryFailed` | switch | No | Re-attempt URLs with existing `.failed` markers |

Fetch logic:
1. Normalize URL, compute filename and file path
2. **Cache hit**: File exists at `res/logs/{filename}` -> read from disk via `[System.IO.File]::ReadAllText`, return content
3. **Failed marker**: `res/logs/{filename}.failed` exists -> return `$null` (unless `-RetryFailed`)
4. **Fresh fetch**: HTTP GET via shared `HttpClient`, write to disk on success, remove `.failed` marker if present, return content
5. On non-success HTTP response or network error: warn to stderr, return `$null`

Caller is responsible for writing `.failed` markers on permanent failure (done by `Invoke-SessionLogFetch`).

### 4.5 `Invoke-LogBatchFetch`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Urls` | string[] | Yes | Array of URLs to fetch |
| `LogDirectory` | string | Yes | Directory for cached log files |
| `DelayMs` | int | No | Throttle delay in milliseconds between HTTP requests (default 500) |
| `RetryFailed` | switch | No | Re-attempt URLs with existing `.failed` markers |

Deduplicates URLs via `HashSet[string]` (OrdinalIgnoreCase) after normalization. Fetches each sequentially via `Invoke-LogFetch`. Only actual HTTP requests (not cache hits) incur the throttle delay. Reports progress via `Write-Progress`.

Returns a hashtable mapping normalized URLs to their text content. URLs that fail are mapped to `$null`.

### 4.6 `Resolve-LogUrlToLocalPath`

File: `private/session-decomposehelpers.ps1`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Url` | string | Yes | URL or path to resolve |
| `LogDirectory` | string | Yes | Directory containing cached log files (typically `res/logs/` resolved via `Get-AdminConfig`) |

Replaces a log URL with a local `res/logs/` path if the corresponding cached file exists on disk. Used during migration Phase 5 (`-UpgradeFormat`) and by `ConvertTo-Gen4FromRawBlock` / `ConvertFrom-PlainTextLog` to localize log references in session metadata.

Resolution logic:
1. If `$LogDirectory` is empty or `$null`, returns the original `$Url` unchanged.
2. If `$Url` does not start with `http` (already a local path), returns it unchanged.
3. Normalizes the URL via `Normalize-LogUrl`, converts to a cache filename via `ConvertTo-LogFileName`, and checks if the file exists at `$LogDirectory/$FileName`.
4. If the file exists, returns `res/logs/$FileName`. Otherwise returns the original `$Url`.

---

## 5. Content Parser (`private/parse-logcontent.ps1`)

### 5.1 `Get-LogFormat`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Content` | string | Yes | Raw log content string |

Scans the first ~30 non-empty lines for the `^\[\d{2}:\d{2}\]` timestamp pattern (via `$script:FormatDetectPattern`). Returns `'ChatLog'` if 2+ matches found, otherwise `'Prose'`.

### 5.2 `ConvertFrom-ChatLogContent`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Content` | string | Yes | Raw ChatLog content string |

Parses content line by line using a state machine with a `$PendingTimestamp` variable for handling continuation lines. Returns `PSCustomObject` with `Format`, `Lines`, `LocationSegments`.

### 5.3 `ConvertFrom-ProseContent`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Content` | string | Yes | Raw Prose content string |

Parses narrative lines using a `$PreviousWasEmpty` flag to detect location headers. Returns `PSCustomObject` with `Format`, `Lines`, `LocationSegments`.

### 5.4 `ConvertFrom-LogContent`

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Content` | string | Yes | Raw log content string to parse |

Dispatcher: calls `Get-LogFormat` to detect format, then routes to `ConvertFrom-ChatLogContent` or `ConvertFrom-ProseContent`. Returns the same cross-referenced structure regardless of format.

### 5.5 Precompiled Regex Patterns

| Variable | Pattern | Purpose |
|---|---|---|
| `$script:TimestampPattern` | `^\[(\d{2}:\d{2})\]\s*` | Timestamp prefix extraction |
| `$script:ChannelPattern` | `^\[([^\]]+)\]\s*` | Channel tag extraction |
| `$script:SpeakerPattern` | `^([^:]+?):\s+(.*)$` | Speaker + text extraction |
| `$script:SpeakerOnlyPattern` | `^([^:]+?):\s*$` | Speaker-only (no text) |
| `$script:FormatDetectPattern` | `^\[\d{2}:\d{2}\]` | Format detection |

### 5.6 Output Schema

All parsers return:

```powershell
@{
    Format           = 'ChatLog' | 'Prose'
    Lines            = @(
        @{ Index; Time; Channel; Speaker; Text; Segment }
    )
    LocationSegments = @(
        @{ Index; Raw; StartLine; EndLine }
    )
}
```

- `Lines[].Index`: Zero-based sequential line number
- `Lines[].Time`: Timestamp string (`HH:MM`) for ChatLog, `$null` for Prose
- `Lines[].Channel`: Channel tag string for ChatLog, `$null` for Prose
- `Lines[].Segment`: Which LocationSegment this line belongs to (by index, -1 if before first segment)
- `LocationSegments[].StartLine` / `.EndLine`: Line index range for cross-referencing. `EndLine` for the last segment extends to the final line.

---

## 6. `Get-SessionLog` - Core Pipeline

### 6.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Session` | PSObject[] | No | Session objects (pipeline input). Must have `.Logs` array |
| `Index` | hashtable | No | Name index from `Get-NameIndex` (enables resolution) |
| `Cache` | hashtable | No | Shared resolution cache for `Resolve-Name` |
| `LogDirectory` | string | No | Override for `res/logs/` path |
| `DelayMs` | int | No | Throttle between HTTP requests (default 500ms) |
| `SkipFetch` | switch | No | Read only from disk, no HTTP requests |

When `.Logs` contains local file paths (non-HTTP entries such as `res/logs/filename`), they are read directly from disk via `[System.IO.File]::ReadAllText()` without HTTP requests. Mixed URLs and local paths in the same session are fully supported — URLs go through `Invoke-LogBatchFetch` while local paths are resolved against `Get-RepoRoot`'s `.robot/` directory and merged into the fetched content dictionary before parsing.

### 6.2 Pipeline Architecture

Uses **collect-then-emit** pattern:

1. `begin` block: initialize `$CollectedSessions` list
2. `process` block: collect all sessions into the list
3. `end` block:
   - Collect all log URLs across all sessions
   - Deduplicate and batch-fetch (via `Invoke-LogBatchFetch`) or read from disk with `-SkipFetch`
   - Parse each log via `ConvertFrom-LogContent`, build cross-referenced output
   - Emit one result per session that has parseable logs

This ensures each unique URL is fetched/parsed only once, even when shared across sessions.

### 6.3 Speaker Resolution

When `-Index` is provided, each speaker's raw name is resolved via `Resolve-Name` using the Index's `Index`, `StemIndex`, and `BKTree` sub-hashtables. The `Cache` parameter enables cross-session resolution caching.

### 6.4 Location Segment Resolution

When `-Index` is provided, each `LocationSegment.Raw` value is resolved via `Resolve-Name`. `Resolved` and `Stage` NoteProperties are added to the segment objects.

### 6.5 Output Schema

Per session, emits:

```powershell
[PSCustomObject]@{
    Logs = @(
        [PSCustomObject]@{
            Url              = 'https://pastebin.com/raw/...'
            Format           = 'ChatLog' | 'Prose'
            Lines            = @(...)       # Parsed lines with Index, Speaker, etc.
            LocationSegments = @(...)       # With optional Resolved/Stage if Index provided
            Speakers         = @(           # Aggregated speaker list
                @{ Raw; Resolved; Stage; Lines = [int[]]; LineCount }
            )
            Channels         = @(           # ChatLog only, $null for Prose
                @{ Name; Lines = [int[]]; LineCount }
            ) | $null
        }
    )
}
```

- `Speakers[].Lines`: Array of line indices where this speaker appears
- `Speakers[].Resolved`: Canonical entity name (or `$null` if unresolved)
- `Speakers[].Stage`: Resolution stage (or `$null`)
- `Channels[].Lines`: Array of line indices in this channel
- When `-Index` is provided, `LocationSegments[].Resolved` and `LocationSegments[].Stage` are populated via `Resolve-Name`

### 6.6 `-IncludeLogs` Integration

`Get-Session -IncludeLogs` internally calls `Get-SessionLog` and attaches a `LogData` property to each session object that has log URLs. This enables single-pipeline workflows:

```powershell
$Sessions = Get-Session -IncludeLogs -MinDate "2024-01-01"
$Sessions[0].LogData.Logs[0].Speakers  # speaker list from first log
```

---

## 7. `Invoke-SessionLogFetch` - Mass Fetch Workflow

### 7.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Session` | PSObject[] | No | Sessions to fetch logs for (pipeline input) |
| `MinDate` / `MaxDate` | datetime | No | Fetch sessions from `Get-Session` if `-Session` not piped |
| `DelayMs` | int | No | Throttle between HTTP requests (default 500ms) |
| `MaxRetries` | int | No | Max retry attempts per URL (default 2) |
| `RetryDelayMs` | int | No | Initial delay for exponential backoff (default 2000ms) |
| `RetryFailed` | switch | No | Retry URLs with existing `.failed` markers |
| `LogDirectory` | string | No | Override for `res/logs/` path |
| `Quiet` | switch | No | Suppress warning output to stderr |

Supports `ShouldProcess`.

### 7.2 Pipeline Architecture

Uses **collect-then-emit** pattern like `Get-SessionLog`:

1. `begin` block: initialize collection, save/set `$SuppressWarnings`
2. `process` block: collect sessions
3. `end` block:
   - If no sessions piped, fetch via `Get-Session` using MinDate/MaxDate
   - Collect and deduplicate all log URLs (via `HashSet`)
   - Partition into cached, failed/skipped, and pending
   - Fetch pending URLs with retry logic

### 7.3 Error Handling

| HTTP Status | Action |
|---|---|
| 2xx (Success) | Write to disk, remove `.failed` marker if present |
| 429 (Rate Limited) | Exponential backoff retry (`RetryDelayMs * 2^attempt`) |
| 404 (Not Found) | Write `.failed` marker, no retry |
| 5xx (Server Error) | Retry up to `MaxRetries`, then `.failed` marker |
| Network timeout | Retry up to `MaxRetries` |
| Other error codes | Write `.failed` marker, no retry |

Failed markers contain: URL, error description, HTTP status code, UTC timestamp (ISO 8601 format).

### 7.4 Output

Returns a summary `PSCustomObject`:

```powershell
@{
    Total      = 150    # Unique URLs across all sessions
    Fetched    = 45     # Successfully fetched this run
    Cached     = 100    # Already on disk
    Failed     = 3      # Failed this run
    Skipped    = 2      # Had .failed markers, not retried
    FailedUrls = @(...) # URLs that failed (string[])
}
```

### 7.5 `-WhatIf` Support

With `-WhatIf`, partitions URLs into cached/skipped/pending but performs no HTTP requests. Reports what would be fetched. Returns the summary with `Fetched = 0`.

---

## 8. `Get-NamedLogLocationReport` - Location Analysis

### 8.1 Parameters

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `SessionLog` | PSObject[] | No | Output from `Get-SessionLog` (pipeline input) |
| `Session` | PSObject[] | No | Corresponding session objects for `@Lokalizacje` cross-reference |
| `Index` | hashtable | Yes | Name index from `Get-NameIndex` |
| `Cache` | hashtable | No | Shared resolution cache |
| `MaxNearMatches` | int | No | Max near-match candidates for unresolved locations (default 3) |

### 8.2 Analysis Steps

For each LocationSegment in each parsed log:

1. **Resolve** via `Resolve-Name` (all 4 stages: exact, declension, stem alternation, fuzzy)
2. **Cross-reference** against the source session's `@Lokalizacje` metadata
3. **Near-match detection** for unresolved locations: Levenshtein distance against all `Lokacja` entities in the index, threshold `floor(length / 3)`

### 8.3 Output Schema

```powershell
@{
    SessionTitle = 'Test Session'
    SessionDate  = [datetime]
    Locations    = @(
        @{
            Raw           = 'Opuszczony dom'      # Original header from log
            Resolved      = 'Wieza Obserwacyjna'   # Canonical entity name (or $null)
            Stage         = $null                   # Resolution stage (future use)
            InSessionMeta = $false                  # Present in session @Lokalizacje?
            NearMatches   = @(                      # Close entities if unresolved
                @{ Name = 'Wieza Obserwacyjna'; Distance = 5 }
            )
            LogUrl        = 'https://...'
            StartLine     = 0
            EndLine       = 15
        }
    )
    Transitions  = @(                               # Movement edges from consecutive segments
        @{
            Source       = 'Wieza Obserwacyjna'     # Resolved (or Raw if unresolved)
            Target       = 'Steadwick'
            SourceRaw    = 'Opuszczony dom'
            TargetRaw    = 'Steadwick'
            LogUrl       = 'https://...'
            SessionTitle = 'Test Session'
            SessionDate  = [datetime]
        }
    )
    Summary = @{
        Total           = 3
        Resolved        = 2
        Unresolved      = 1
        InMeta          = 2
        NotInMeta       = 1
        TransitionCount = 1
    }
}
```

---

## 9. CLI Integration

Two CLI entries under the "Logi" section:

| Registry Key | Mode | Function | Role |
|---|---|---|---|
| `fetch-logs` | Workflow | `Invoke-FetchLogsWorkflow` | K (Coordinator) |
| `log-location-report` | Workflow | `Invoke-LogLocationReportWorkflow` | N (Narrator) |

### `Invoke-FetchLogsWorkflow`

Date range wizard -> count sessions -> confirm -> `Invoke-SessionLogFetch` -> summary display.

### `Invoke-LogLocationReportWorkflow`

Date range -> `Get-Session | Get-SessionLog -SkipFetch` -> `Get-NamedLogLocationReport` -> table view with drill-down detail cards for unresolved locations.

---

## 10. File Map

| File | Layer | Purpose |
|---|---|---|
| `private/log-fetchhelpers.ps1` | Private | URL normalization, disk cache, HTTP fetch (5 functions) |
| `private/session-decomposehelpers.ps1` | Private | `Resolve-LogUrlToLocalPath` — URL-to-local-path resolution for log localization |
| `private/parse-logcontent.ps1` | Private | Format detection, ChatLog/Prose parsers (4 functions) |
| `public/session/get-sessionlog.ps1` | Public | Core pipeline: fetch, parse, cross-reference |
| `public/workflow/invoke-sessionlogfetch.ps1` | Public | Mass fetch with error handling |
| `public/reporting/get-namedloglocationreport.ps1` | Public | Location resolution analysis |
| `private/cli/cli-registry.ps1` | Private | CLI menu entries (fetch-logs, log-location-report) |
| `private/cli/cli-wf-reporting.ps1` | Private | CLI workflow functions |
| `tests/get-sessionlog.Tests.ps1` | Tests | 38 tests: URL, parsing, pipeline |
| `tests/get-namedloglocationreport.Tests.ps1` | Tests | 9 tests: resolution report |
| `tests/invoke-sessionlogfetch.Tests.ps1` | Tests | 3 tests: mass fetch workflow |
| `tests/fixtures/log-chatlog.txt` | Fixture | ChatLog format sample |
| `tests/fixtures/log-prose.txt` | Fixture | Prose format sample |

---

## 11. Related Documents

- [SESSIONS.md](SESSIONS.md) - Session parsing pipeline (produces `.Logs` URLs consumed by this subsystem)
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) - Name resolution used for speaker and location matching
- [LOCATION-GRAPH.md](LOCATION-GRAPH.md) - Location graph (transition edges from log location segments)
- [DISCORD.md](DISCORD.md) - Discord messaging (separate notification subsystem)

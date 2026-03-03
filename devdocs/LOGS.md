# Session Log Pipeline - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the session log subsystem: `Get-SessionLog` (fetch, parse, cross-reference), `Invoke-SessionLogFetch` (mass fetch workflow), `Get-NamedLogLocationReport` (location resolution analysis), and their private helpers.

**Shared dependency**: `private/string-helpers.ps1` provides `Get-LevenshteinDistance`, used by the location report's near-match detection.

**Not covered**: How session objects are produced - see [SESSIONS.md](SESSIONS.md). Name resolution internals - see [NAME-RESOLUTION.md](NAME-RESOLUTION.md).

---

## 2. Architecture Overview

```
Get-Session ──> session objects with .Logs URLs
                    │
                    ▼
              Get-SessionLog
                ├── log-fetchhelpers.ps1
                │     ├── Normalize-LogUrl (pastebin URL normalization, http→https)
                │     ├── ConvertTo-LogFileName (URL → cache filename)
                │     ├── Invoke-LogFetch (single fetch with disk cache)
                │     └── Invoke-LogBatchFetch (sequential batch with throttle)
                ├── parse-logcontent.ps1 (format detection, ChatLog/Prose parsers)
                └── Resolve-Name (optional speaker/location resolution)
                    │
                    ▼
              { Logs: [{ Url, Format, Lines[], LocationSegments[], Speakers[], Channels }] }
                    │
                    ▼
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
[13:22] [Lokalny] Rozległo się pukanie do drzwi.
[13:22] [Lokalny] Lord Haart ledwo co usiadł i znowu ktoś zawraca głowę.                                                 
[13:22] [Lokalny] Lord Haart: Proszę!  
```

**Detection**: Scans first ~20 non-empty lines for `^\[\d{2}:\d{2}\]` pattern. If >=2 matches: ChatLog.

**Location headers**: Non-empty lines that do NOT match `^\[\d{2}:\d{2}\]`. Leading/trailing whitespace is stripped. These split the log into LocationSegments.

**Line parsing**:
- Pattern: `^\[(\d{2}:\d{2})\]\s*\[([^\]]+)\]\s*(.*)`
- Extracts: `Time`, `Channel` (Lokalny/Prywatny/Grupowy/Szept), `Speaker`, `Text`
- Speaker detection: `Speaker: text` or `*narration*` (null speaker)
- Continuation lines: timestamp line with no inline text, followed by content on the next line

### 3.2 Prose

Plain narrative without timestamps. Source: manually written session summaries.

```
Karczma pod Liściem Dębu

Narrator: Wieczór był ciepły i wilgotny.
Elara: Słyszałam o bandytach na trakcie.
```

**Detection**: Fallback when ChatLog detection fails.

**Location headers**: Short lines (<=60 chars) after an empty line, no `Speaker:` pattern, no leading `*`.

**Line parsing**: `Speaker: text` pattern. Lines without speakers have null Speaker.

---

## 4. Fetch Helpers (`private/log-fetchhelpers.ps1`)

### 4.1 Functions

| Function | Purpose |
|---|---|
| `Normalize-LogUrl` | Pastebin URL normalization to `/raw/` variant, http->https |
| `ConvertTo-LogFileName` | URL to filesystem-safe filename (strip protocol, remove non-alphanumeric) |
| `Get-LogHttpClient` | Lazily-initialized shared `HttpClient` with 30s timeout |
| `Invoke-LogFetch` | Single URL fetch with disk cache in `res/logs/` |
| `Invoke-LogBatchFetch` | Sequential batch fetch with deduplication and CDN throttle |

### 4.2 URL Normalization

```
pastebin.com/wqhtQ5Wq      → https://pastebin.com/raw/wqhtQ5Wq
pastebin.com/raw/wqhtQ5Wq   → https://pastebin.com/raw/wqhtQ5Wq  (unchanged)
http://example.com/log.txt  → https://example.com/log.txt
```

### 4.3 Filename Generation

Strips protocol prefix, removes all non-alphanumeric characters:

```
https://pastebin.com/raw/wqhtQ5Wq → pastebincomrawwqhtQ5Wq
```

Files are stored in `res/logs/` (resolved via `Get-AdminConfig` ResDir).

### 4.4 Cache and Failure Tracking

- **Cache hit**: File exists at `res/logs/{filename}` -> read from disk, no HTTP
- **Failed marker**: `res/logs/{filename}.failed` exists -> skip (unless `-RetryFailed`)
- **Fresh fetch**: HTTP GET, write to disk on success, return content

Failed markers contain: URL, error description, HTTP status code, UTC timestamp.

---

## 5. Content Parser (`private/parse-logcontent.ps1`)

### 5.1 Functions

| Function | Purpose |
|---|---|
| `Get-LogFormat` | Detect ChatLog vs Prose from content |
| `ConvertFrom-ChatLogContent` | Parse ChatLog format into structured objects |
| `ConvertFrom-ProseContent` | Parse Prose format into structured objects |
| `ConvertFrom-LogContent` | Dispatcher: detect format, route to parser |

### 5.2 Output Schema

All parsers return:

```powershell
@{
    Format           = 'ChatLog' | 'Prose'
    Lines            = @(
        @{ Index; Time; Channel; Speaker; Text; Segment }  # ChatLog
        @{ Index; Speaker; Text; Segment }                  # Prose
    )
    LocationSegments = @(
        @{ Raw; Index; StartLine; EndLine }
    )
}
```

- `Lines[].Index`: Zero-based sequential line number
- `Lines[].Segment`: Which LocationSegment this line belongs to (by index)
- `LocationSegments[].StartLine` / `.EndLine`: Line index range for cross-referencing

---

## 6. `Get-SessionLog` - Core Pipeline

### 6.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Session` | PSObject[] | Session objects (pipeline input). Must have `.Logs` URL array |
| `Index` | hashtable | Name index from `Get-NameIndex` (optional, enables resolution) |
| `Cache` | hashtable | Shared resolution cache for `Resolve-Name` |
| `LogDirectory` | string | Override for `res/logs/` path |
| `DelayMs` | int | Throttle between HTTP requests (default 500ms) |
| `SkipFetch` | switch | Read only from disk, no HTTP requests |

### 6.2 Pipeline Architecture

Uses **collect-then-emit** pattern:

1. `process` block: collect all sessions into a list
2. `end` block:
   - Collect all log URLs across all sessions
   - Deduplicate and batch-fetch (or read from disk with `-SkipFetch`)
   - Parse each log, build cross-referenced output
   - Emit one result per session

This ensures each unique URL is fetched/parsed only once, even when shared across sessions.

### 6.3 Output Schema

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
            Channels         = @(           # ChatLog only, null for Prose
                @{ Name; Lines = [int[]]; LineCount }
            ) | $null
        }
    )
}
```

- `Speakers[].Lines`: Array of line indices where this speaker appears
- `Channels[].Lines`: Array of line indices in this channel
- When `-Index` is provided, `Speakers[].Resolved` and `LocationSegments[].Resolved` are populated via `Resolve-Name`

### 6.4 `-IncludeLogs` Integration

`Get-Session -IncludeLogs` internally calls `Get-SessionLog` and attaches a `LogData` property to each session object that has log URLs. This enables single-pipeline workflows:

```powershell
$Sessions = Get-Session -IncludeLogs -MinDate "2024-01-01"
$Sessions[0].LogData.Logs[0].Speakers  # speaker list from first log
```

---

## 7. `Invoke-SessionLogFetch` - Mass Fetch Workflow

### 7.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Session` | PSObject[] | Sessions to fetch logs for (pipeline input) |
| `MinDate` / `MaxDate` | datetime | Fetch sessions from `Get-Session` if `-Session` not piped |
| `DelayMs` | int | Throttle between HTTP requests (default 500ms) |
| `MaxRetries` | int | Max retry attempts per URL (default 3) |
| `RetryDelayMs` | int | Base delay for exponential backoff (default 2000ms) |
| `RetryFailed` | switch | Retry URLs with existing `.failed` markers |
| `LogDirectory` | string | Override for `res/logs/` path |

### 7.2 Error Handling

| HTTP Status | Action |
|---|---|
| 429 (Rate Limited) | Exponential backoff retry (`RetryDelayMs * 2^attempt`) |
| 404 (Not Found) | Write `.failed` marker, no retry |
| 5xx (Server Error) | Retry up to `MaxRetries`, then `.failed` marker |
| Network timeout | Retry up to `MaxRetries` |

### 7.3 Output

Returns a summary hashtable:

```powershell
@{
    Total      = 150    # Unique URLs across all sessions
    Fetched    = 45     # Successfully fetched this run
    Cached     = 100    # Already on disk
    Failed     = 3      # Failed this run
    Skipped    = 2      # Had .failed markers, not retried
    FailedUrls = @(...) # URLs that failed
}
```

### 7.4 `-WhatIf` Support

With `-WhatIf`, partitions URLs into cached/skipped/pending but performs no HTTP requests. Reports what would be fetched.

---

## 8. `Get-NamedLogLocationReport` - Location Analysis

### 8.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `SessionLog` | PSObject[] | Output from `Get-SessionLog` (pipeline input) |
| `Session` | PSObject[] | Corresponding session objects for `@Lokalizacje` cross-reference |
| `Index` | hashtable | Name index from `Get-NameIndex` (required) |
| `Cache` | hashtable | Shared resolution cache |
| `MaxNearMatches` | int | Max near-match candidates for unresolved locations (default 3) |

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
            Resolved      = 'Dom Radneraka'        # Canonical entity name (or $null)
            Stage         = $null                   # Resolution stage (future use)
            InSessionMeta = $false                  # Present in session @Lokalizacje?
            NearMatches   = @(                      # Close entities if unresolved
                @{ Name = 'Dom Radneraka'; Distance = 5 }
            )
            LogUrl        = 'https://...'
            StartLine     = 0
            EndLine       = 15
        }
    )
    Summary = @{
        Total      = 3
        Resolved   = 2
        Unresolved = 1
        InMeta     = 2
        NotInMeta  = 1
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
| `private/log-fetchhelpers.ps1` | Private | URL normalization, disk cache, HTTP fetch |
| `private/parse-logcontent.ps1` | Private | Format detection, ChatLog/Prose parsers |
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
- [DISCORD.md](DISCORD.md) - Discord messaging (separate notification subsystem)

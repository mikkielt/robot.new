# Session Log Pipeline - Technical Reference

## Scope

The session log subsystem comprises `Get-SessionLog` (fetch, parse, cross-reference), `Invoke-SessionLogFetch` (mass fetch workflow), `Get-NamedLogLocationReport` (location resolution analysis), and their private helpers in `log-fetchhelpers.ps1` and `parse-logcontent.ps1`.

| Function | File | Purpose |
|---|---|---|
| `Get-SessionLog` | `public/session/get-sessionlog.ps1` | Core pipeline: fetch, parse, cross-reference |
| `Invoke-SessionLogFetch` | `public/workflow/invoke-sessionlogfetch.ps1` | Mass fetch with error handling |
| `Get-NamedLogLocationReport` | `public/reporting/get-namedloglocationreport.ps1` | Location resolution analysis |
| `New-ResolvedLogObject` | `private/parse-logcontent.ps1` | Builds the cross-referenced per-log object (Speakers/Channels/LocationSegments/Mentions) from a parse result. Shared by `Get-SessionLog` and `Invoke-ApiParseLogEnriched`. |
| `Resolve-MessageMentions` | `private/parse-logcontent.ps1` | Extracts in-message entity mentions via Capitalized n-gram tokenization and `Resolve-Name -NoFuzzy` (Stages 1+2 only). |
| `Resolve-LogUrlToLocalPath` | `private/session-decomposehelpers.ps1` | URL-to-local-path resolution for cached log files |
| `Normalize-LogUrl` | `private/log-fetchhelpers.ps1` | Pastebin URL normalization, http->https |
| `ConvertTo-LogFileName` | `private/log-fetchhelpers.ps1` | URL to filesystem-safe filename |
| `Get-LogHttpClient` | `private/log-fetchhelpers.ps1` | Lazily-initialized shared HttpClient |
| `Invoke-LogFetch` | `private/log-fetchhelpers.ps1` | Single URL fetch with disk cache |
| `Invoke-LogBatchFetch` | `private/log-fetchhelpers.ps1` | Sequential batch fetch with throttle |
| `Get-LogFormat` | `private/parse-logcontent.ps1` | Detect ChatLog vs Prose from content |
| `Complete-LocationSegmentBoundaries` | `private/parse-logcontent.ps1` | Compute EndLine for each LocationSegment |
| `ConvertFrom-ChatLogContent` | `private/parse-logcontent.ps1` | Parse ChatLog format |
| `ConvertFrom-ProseContent` | `private/parse-logcontent.ps1` | Parse Prose format |
| `ConvertFrom-LogContent` | `private/parse-logcontent.ps1` | Dispatcher: detect format, route to parser |

Shared dependency: `private/string-helpers.ps1` provides `Get-LevenshteinDistance`, used by the location report's near-match detection.

How session objects are produced is documented in [SESSIONS.md](SESSIONS.md). Name resolution internals are documented in [NAME-RESOLUTION.md](NAME-RESOLUTION.md).

## Architecture Overview

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
                |     +-- Complete-LocationSegmentBoundaries (segment EndLine computation)
                +-- Resolve-Name (optional speaker/location resolution)
                    |
                    v
              { Logs: [{ Url, Format, Lines[], LocationSegments[], Speakers[], Channels }] }
                    |
                    v
              Get-NamedLogLocationReport (location resolution quality analysis)
```

`Invoke-SessionLogFetch` handles mass fetching with CDN-safe throttling and persistent failure tracking. `Get-SessionLog` consumes the fetched files from disk.

## Log Formats

Two formats are supported, auto-detected by `Get-LogFormat`.

ChatLog is timestamped chat lines with channel tags, sourced from game engine copy-paste:

```
 Domostwo
[13:22] [Lokalny] Rozleglo sie pukanie do drzwi.
[13:22] [Lokalny] Lord Haart ledwo co usiadl i znowu ktos zawraca glowe.
[13:22] [Lokalny] Lord Haart: Prosze!
```

Detection scans the first ~30 non-empty lines for `^\[\d{2}:\d{2}\]` pattern. If >=2 matches: ChatLog. Location headers are non-empty lines that do not match the timestamp pattern and are not continuation text from a preceding timestamp line. Leading/trailing whitespace is stripped. These split the log into LocationSegments. Line parsing uses the pattern `^\[(\d{2}:\d{2})\]\s*\[([^\]]+)\]\s*(.*)`, extracting `Time`, `Channel` (Lokalny/Prywatny/Grupowy/Szept), `Speaker`, and `Text`. Speaker detection handles `Speaker: text` or `*narration*` (null speaker), speaker-only lines (`Speaker:` with no text after colon), and continuation lines (timestamp line with no inline text after channel tag, followed by content on the next non-empty line).

Prose is plain narrative without timestamps, sourced from manually written session summaries:

```
Karczma pod Lisciem Debu

Narrator: Wieczor byl ciepły i wilgotny.
Jenova: Slyszalam o bandytach na trakcie.
```

Detection: fallback when ChatLog detection fails. Location headers are short lines (<=60 chars) after an empty line, with no `Speaker:` pattern and no leading `*`. The heuristic uses a `$PreviousWasEmpty` flag, with start of content treated as "after empty line". Line parsing uses the `Speaker: text` pattern. Lines without speakers have null Speaker. Both ChatLog and Prose parsers produce uniform line objects with `Time` and `Channel` fields (set to `$null` in Prose).

## Fetch Helpers

Source: `private/log-fetchhelpers.ps1`.

`Normalize-LogUrl` takes a `Url` (string, mandatory) and applies normalization rules:

```
pastebin.com/wqhtQ5Wq      -> https://pastebin.com/raw/wqhtQ5Wq
pastebin.com/raw/wqhtQ5Wq   -> https://pastebin.com/raw/wqhtQ5Wq  (unchanged)
http://example.com/log.txt  -> https://example.com/log.txt
```

Uses two precompiled regex patterns: `$script:PastebinUrlPattern` matches non-raw pastebin URLs (`^https?://(?:www\.)?pastebin\.com/(?!raw/)([A-Za-z0-9]+)/?$`); `$script:PastebinRawPattern` matches raw pastebin URLs (`^https?://(?:www\.)?pastebin\.com/raw/([A-Za-z0-9]+)/?$`). Trims whitespace and trailing slashes before matching.

`ConvertTo-LogFileName` takes a `NormalizedUrl` (string, mandatory). Strips protocol prefix (`https://` or `http://`), removes all non-alphanumeric characters via `$script:UrlUnsafeChars`: `https://pastebin.com/raw/wqhtQ5Wq` becomes `pastebincomrawwqhtQ5Wq`. Files are stored in `res/logs/` (resolved via `Get-AdminConfig` ResDir).

`Get-LogHttpClient` takes no parameters. Returns the lazily-initialized shared `[System.Net.Http.HttpClient]` instance stored in `$script:LogHttpClient`. The client has a 30-second timeout (`TimeSpan.FromSeconds(30)`) and custom User-Agent header: `Robot-PowerShell/1.0`. Reused across all calls within the same module session.

`Invoke-LogFetch` takes `Url` (string, mandatory), `LogDirectory` (string, mandatory), and optional `RetryFailed` (switch). Fetch logic: (1) Normalize URL, compute filename and file path. (2) Cache hit — file exists at `res/logs/{filename}`, read from disk via `[System.IO.File]::ReadAllText`, return content. (3) Failed marker — `res/logs/{filename}.failed` exists, return `$null` (unless `-RetryFailed`). (4) Fresh fetch — HTTP GET via shared `HttpClient`, write to disk on success, remove `.failed` marker if present, return content. (5) On non-success HTTP response: warn to stderr; for 4xx client errors (status 400-499), write a `.failed` marker containing the status code and URL to prevent redundant retries on subsequent calls; return `$null`. (6) On network error: warn to stderr, return `$null`. `Invoke-SessionLogFetch` handles additional `.failed` marker logic for server errors and retries.

`Invoke-LogBatchFetch` takes `Urls` (string[], mandatory), `LogDirectory` (string, mandatory), optional `DelayMs` (int, default 500), and optional `RetryFailed` (switch). Deduplicates URLs via `HashSet[string]` (OrdinalIgnoreCase) after normalization. Fetches each sequentially via `Invoke-LogFetch`. The throttle delay applies only to successful HTTP fetches (not cache hits or failed requests). Reports progress via `Write-Progress`. Returns a hashtable mapping normalized URLs to their text content. URLs that fail are mapped to `$null`.

`Resolve-LogUrlToLocalPath` (in `private/session-decomposehelpers.ps1`) takes `Url` (string, mandatory) and `LogDirectory` (string, mandatory). Replaces a log URL with a local `res/logs/` path if the corresponding cached file exists on disk. Used during migration Phase 5 (`-UpgradeFormat`) and by `ConvertTo-Gen4FromRawBlock` / `ConvertFrom-PlainTextLog` to localize log references in session metadata. Resolution logic: (1) If `$LogDirectory` is empty or `$null`, returns the original `$Url` unchanged. (2) If `$Url` does not start with `http` (already a local path), returns it unchanged. (3) Normalizes the URL via `Normalize-LogUrl`, converts to a cache filename via `ConvertTo-LogFileName`, and checks if the file exists at `$LogDirectory/$FileName`. (4) If the file exists, returns `res/logs/$FileName`. Otherwise returns the original `$Url`.

## Content Parser

Source: `private/parse-logcontent.ps1`.

`Complete-LocationSegmentBoundaries` takes `Segments` (List[PSCustomObject], mandatory) and `TotalLineCount` (int, mandatory). Sets the `EndLine` property on each segment: for non-last segments, `EndLine` is set to the next segment's `StartLine - 1`; for the last segment, `EndLine` is set to `TotalLineCount - 1`. Called by both `ConvertFrom-ChatLogContent` and `ConvertFrom-ProseContent` after building their segment lists, replacing previously duplicated inline boundary computation.

`Get-LogFormat` takes `Content` (string, mandatory). Scans the first ~30 non-empty lines for the `^\[\d{2}:\d{2}\]` timestamp pattern (via `$script:FormatDetectPattern`). Returns `'ChatLog'` if 2+ matches found, otherwise `'Prose'`.

`ConvertFrom-ChatLogContent` takes `Content` (string, mandatory). Parses content line by line using a state machine with a `$PendingTimestamp` variable for handling continuation lines. Returns `PSCustomObject` with `Format`, `Lines`, `LocationSegments`.

`ConvertFrom-ProseContent` takes `Content` (string, mandatory). Parses narrative lines using a `$PreviousWasEmpty` flag to detect location headers. Returns `PSCustomObject` with `Format`, `Lines`, `LocationSegments`.

`ConvertFrom-LogContent` takes `Content` (string, mandatory). Dispatcher: calls `Get-LogFormat` to detect format, then routes to `ConvertFrom-ChatLogContent` or `ConvertFrom-ProseContent`. Returns the same cross-referenced structure regardless of format.

Precompiled regex patterns:

| Variable | Pattern | Purpose |
|---|---|---|
| `$script:TimestampPattern` | `^\[(\d{2}:\d{2})\]\s*` | Timestamp prefix extraction |
| `$script:ChannelPattern` | `^\[([^\]]+)\]\s*` | Channel tag extraction |
| `$script:SpeakerPattern` | `^([^:]+?):\s+(.*)$` | Speaker + text extraction |
| `$script:SpeakerOnlyPattern` | `^([^:]+?):\s*$` | Speaker-only (no text) |
| `$script:FormatDetectPattern` | `^\[\d{2}:\d{2}\]` | Format detection |

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

`Lines[].Index` is a zero-based sequential line number. `Lines[].Time` is a timestamp string (`HH:MM`) for ChatLog, `$null` for Prose. `Lines[].Channel` is a channel tag string for ChatLog, `$null` for Prose. `Lines[].Segment` indicates which LocationSegment this line belongs to (by index, -1 if before first segment). `LocationSegments[].StartLine` / `.EndLine` define a line index range for cross-referencing. `EndLine` for the last segment extends to the final line.

## Compiled C# Parser — Robot.LogParser

Source: `lib/LogParser.cs`. A compiled C# log content parser for ChatLog and Prose formats. It applies 3-5 precompiled regex operations per line in a single native pass with struct array output (`LogLine[]`), minimizing GC pressure on the hot path.

Two format parsers are implemented. ChatLog handles `[HH:MM]` timestamped lines with optional `[Channel]` tags. Uses a pending-timestamp state machine -- a timestamp line with no content after the channel tag is held pending until the next line resolves it (continuation text, empty line, or next timestamp). Prose handles freeform text with location headers detected by heuristic (short line <= 60 chars after empty line, no `Speaker:` pattern).

Format detection scans the first ~30 non-empty lines; 2+ timestamp matches selects ChatLog, otherwise Prose.

Output types:

| Type | Kind | Purpose |
|---|---|---|
| `ParseResult` | class | Container: `Format`, `Lines` (`LogLine[]`), `LocationSegments` (`LocationSegment[]`) |
| `LogLine` | struct | Per-line data: `Index`, `Time`, `Channel`, `Speaker`, `Text`, `Segment` |
| `LocationSegment` | class | Per-segment data: `Index`, `Raw`, `StartLine`, `EndLine`, `Resolved`, `Stage` |

`LocationSegment` is a class (not struct) because PowerShell consumers set `Resolved`/`Stage` properties after name resolution in `Get-SessionLog`; value-type boxing would lose mutations on array elements.

Both `LogLine` and `LocationSegment` expose their state as public **fields** (not properties). The REST API's `Robot.ApiSerializer` reflects public fields alongside public properties in its dispatcher, so `POST /logs/parse` emits these types as structured JSON objects rather than CLR type-name strings. Property-name precedence on collision keeps the wire format stable if a property is later added.

Consumers: `Parse-LogContent` (`private/parse-logcontent.ps1`) dispatches to `Robot.LogParser` when the type is available, falls back to the PowerShell parsers otherwise. Also consumed by `Get-SessionLog` (`public/session/get-sessionlog.ps1`).

## Get-SessionLog — Core Pipeline

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Session` | PSObject[] | No | Session objects (pipeline input). Must have `.Logs` array |
| `Index` | hashtable | No | Name index from `Get-NameIndex` (enables resolution) |
| `Cache` | hashtable | No | Shared resolution cache for `Resolve-Name` |
| `LogDirectory` | string | No | Override for `res/logs/` path |
| `DelayMs` | int | No | Throttle between HTTP requests (default 500ms) |
| `SkipFetch` | switch | No | Read only from disk, no HTTP requests |
| `SkipMentions` | switch | No | Skip in-message mention extraction (Mentions/MentionsByLine remain null) |

When `.Logs` contains local file paths (non-HTTP entries such as `res/logs/filename`), they are read directly from disk via `[System.IO.File]::ReadAllText()` without HTTP requests. Mixed URLs and local paths in the same session are fully supported -- URLs go through `Invoke-LogBatchFetch` while local paths are resolved against `Get-RepoRoot`'s `.robot.local/` directory and merged into the fetched content dictionary before parsing.

Uses collect-then-emit pattern: (1) `begin` block initializes `$CollectedSessions` list. (2) `process` block collects all sessions into the list. (3) `end` block collects all log URLs across all sessions, deduplicates and batch-fetches (via `Invoke-LogBatchFetch`) or reads from disk with `-SkipFetch`, parses each log via `ConvertFrom-LogContent`, builds cross-referenced output, emits one result per session that has parseable logs. This ensures each unique URL is fetched/parsed only once, even when shared across sessions.

When `-Index` is provided, each speaker's raw name is resolved via `Resolve-Name` using the Index's `Index`, `StemIndex`, and `BKTree` sub-hashtables. The `Cache` parameter enables cross-session resolution caching.

When `-Index` is provided, each `LocationSegment.Raw` value is resolved via `Resolve-Name`. `Resolved` and `Stage` NoteProperties are added to the segment objects.

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
            Mentions         = @(           # In-message entity mentions (only when -Index provided)
                @{ Resolved; Type; Lines = [int[]]; LineCount }
            ) | $null
            MentionsByLine   = @{           # Per-line mention lookup keyed by Line.Index
                LineIndex = @( @{ Raw; Resolved; Stage; Type; Offset; Length } )
            } | $null
        }
    )
}
```

`Speakers[].Lines` is an array of line indices where this speaker appears. `Speakers[].Resolved` is the canonical entity name (or `$null` if unresolved). `Speakers[].Stage` is the resolution stage (or `$null`). `Channels[].Lines` is an array of line indices in this channel. When `-Index` is provided, `LocationSegments[].Resolved` and `LocationSegments[].Stage` are populated via `Resolve-Name`.

### Message-Body Mention Extraction

When `-Index` is provided and `-SkipMentions` is not set, `Get-SessionLog` runs `Resolve-MessageMentions` over every non-empty `Line.Text`. The tokenizer extracts Capitalized Unicode words (`\p{Lu}[\p{L}\p{M}]*`), splits the text on sentence boundaries (`[.!?]+`) so n-gram windows cannot span unrelated clauses, then attempts 3-gram → 2-gram → 1-gram contiguous lookups (longest-match-wins). Each candidate is resolved via `Resolve-Name -NoFuzzy` — fuzzy matching is intentionally **disabled** inside narrative text because the false-positive rate on Polish prose is unacceptable (`karczmie` would fuzzy-match unrelated tokens). Stages 1 (exact index) and 2 (declension stem) are sufficient.

The aggregated `Mentions[]` array mirrors the `Speakers[]` shape: one entry per distinct resolved entity with the list of line indices where it was mentioned. The parallel `MentionsByLine` hashtable preserves per-line attribution with `Offset` and `Length` so consumers can highlight the matched substring. Mentions live in a parallel hashtable rather than on `Lines[]` because the compiled `Robot.LogParser.LogLine` is a struct and `Add-Member` would not persist across array access.

`New-ResolvedLogObject` (private helper in `parse-logcontent.ps1`) wraps the entire Speakers + Channels + LocationSegments + Mentions build step. Both `Get-SessionLog` and the `POST /logs/parse` API handler (`Invoke-ApiParseLogEnriched`) call it so the URL-fetch path and inline-content path produce byte-identical shapes.

`Get-Session -IncludeLogs` internally calls `Get-SessionLog` and attaches a `LogData` property to each session object that has log URLs. This enables single-pipeline workflows:

```powershell
$Sessions = Get-Session -IncludeLogs -MinDate "2024-01-01"
$Sessions[0].LogData.Logs[0].Speakers  # speaker list from first log
```

## Invoke-SessionLogFetch — Mass Fetch Workflow

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

Uses collect-then-emit pattern like `Get-SessionLog`: (1) `begin` block initializes collection, saves/sets `$SuppressWarnings`. (2) `process` block collects sessions. (3) `end` block — if no sessions piped, fetches via `Get-Session` using MinDate/MaxDate; collects and deduplicates all log URLs (via `HashSet`); partitions into cached, failed/skipped, and pending; fetches pending URLs with retry logic.

Error handling:

| HTTP Status | Action |
|---|---|
| 2xx (Success) | Write to disk, remove `.failed` marker if present |
| 429 (Rate Limited) | Exponential backoff retry (`RetryDelayMs * 2^attempt`) |
| 404 (Not Found) | Write `.failed` marker, no retry |
| 5xx (Server Error) | Retry up to `MaxRetries`, then `.failed` marker |
| Network timeout | Retry up to `MaxRetries` |
| Other error codes | Write `.failed` marker, no retry |

Failed markers contain: URL, error description, HTTP status code, UTC timestamp (ISO 8601 format).

Output:

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

With `-WhatIf`, partitions URLs into cached/skipped/pending but performs no HTTP requests. Reports what would be fetched. Returns the summary with `Fetched = 0`.

## Get-NamedLogLocationReport — Location Analysis

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `SessionLog` | PSObject[] | No | Output from `Get-SessionLog` (pipeline input) |
| `Session` | PSObject[] | No | Corresponding session objects for `@Lokalizacje` cross-reference |
| `Index` | hashtable | Yes | Name index from `Get-NameIndex` |
| `Cache` | hashtable | No | Shared resolution cache |
| `MaxNearMatches` | int | No | Max near-match candidates for unresolved locations (default 3) |

For each LocationSegment in each parsed log: (1) Resolve via `Resolve-Name` (all 4 stages: exact, declension, stem alternation, fuzzy). (2) Cross-reference against the source session's `@Lokalizacje` metadata. (3) Near-match detection for unresolved locations: Levenshtein distance against all `Lokacja` entities in the index, threshold `floor(length / 3)`.

Output:

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

## CLI Integration

Two CLI entries under the "Logi" section:

| Registry Key | Mode | Function | Role |
|---|---|---|---|
| `fetch-logs` | Workflow | `Invoke-FetchLogsWorkflow` | K (Coordinator) |
| `log-location-report` | Workflow | `Invoke-LogLocationReportWorkflow` | N (Narrator) |

`Invoke-FetchLogsWorkflow` performs: date range wizard, count sessions, confirm, `Invoke-SessionLogFetch`, summary display.

`Invoke-LogLocationReportWorkflow` performs: date range, `Get-Session | Get-SessionLog -SkipFetch`, `Get-NamedLogLocationReport`, table view with drill-down detail cards for unresolved locations.

## File Map

| File | Layer | Purpose |
|---|---|---|
| `private/log-fetchhelpers.ps1` | Private | URL normalization, disk cache, HTTP fetch (5 functions) |
| `private/session-decomposehelpers.ps1` | Private | `Resolve-LogUrlToLocalPath` -- URL-to-local-path resolution for log localization |
| `private/parse-logcontent.ps1` | Private | Format detection, ChatLog/Prose parsers, segment boundary helper (5 functions) |
| `lib/LogParser.cs` | Compiled C# | `Robot.LogParser` -- native ChatLog/Prose parser with struct array output |
| `public/session/get-sessionlog.ps1` | Public | Core pipeline: fetch, parse, cross-reference |
| `public/workflow/invoke-sessionlogfetch.ps1` | Public | Mass fetch with error handling |
| `public/reporting/get-namedloglocationreport.ps1` | Public | Location resolution analysis |
| `private/cli/cli-registry.ps1` | Private | CLI menu entries (fetch-logs, log-location-report) |
| `private/cli/cli-wf-reporting.ps1` | Private | CLI workflow functions |
| `tests/get-sessionlog.Tests.ps1` | Tests | 38 tests: URL, parsing, pipeline |
| `tests/get-namedloglocationreport.Tests.ps1` | Tests | 14 tests: resolution report |
| `tests/invoke-sessionlogfetch.Tests.ps1` | Tests | 3 tests: mass fetch workflow |
| `tests/fixtures/log-chatlog.txt` | Fixture | ChatLog format sample |
| `tests/fixtures/log-chatlog-avlee.txt` | Fixture | ChatLog format sample (Avlee) |
| `tests/fixtures/log-chatlog-route.txt` | Fixture | ChatLog format sample (route) |
| `tests/fixtures/log-prose.txt` | Fixture | Prose format sample |
| `tests/fixtures/log-prose-dungeon.txt` | Fixture | Prose format sample (dungeon) |

## Related Documents

- [SESSIONS.md](SESSIONS.md) -- Session parsing pipeline (produces `.Logs` URLs consumed by this subsystem)
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) -- Name resolution used for speaker and location matching
- [LOCATION-GRAPH.md](LOCATION-GRAPH.md) -- Location graph (transition edges from log location segments)
- [DISCORD.md](DISCORD.md) -- Discord messaging (separate notification subsystem)

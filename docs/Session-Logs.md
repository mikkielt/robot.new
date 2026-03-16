# Session Logs

## Overview

Session logs (transcripts) are linked from session entries, fetched and cached locally, and optionally analyzed for location data quality. Narrators include log links in sessions, the system fetches and caches them, and Coordinators can run analysis tools against the cached content.

## Actors and Responsibilities

The Narrator includes log URL(s) in the session's `@Logi` metadata block after each session and ensures URLs point to publicly accessible text (e.g., Pastebin).

The Coordinator triggers batch log fetching before analysis runs, reviews location analysis reports to identify data quality issues, and retries failed fetches when transient errors are resolved.

## Including Log URLs

Add one or more log links under the `@Logi` block in the session entry:

```markdown
### 2025-06-15, Session Title, Narrator
- @Logi:
    - https://pastebin.com/wqhtQ5Wq
    - https://pastebin.com/abc123
```

- Each URL should point to a raw text transcript of the session
- Multiple logs per session are supported (e.g., one per location change)
- The system normalizes Pastebin URLs automatically (short form and `/raw/` form are both accepted)

## Supported Log Formats

The system auto-detects two transcript formats:

| Format | Source | Example |
|---|---|---|
| ChatLog | Game engine copy-paste with timestamps and channels | `[13:22] [Lokalny] Lord Haart: Proszę!` |
| Prose | Manually written narrative summary | `Lord Haart: Otworzył drzwi z westchnieniem.` |

Both formats support location headers — standalone short lines (without timestamps or speaker patterns) that divide the log into location segments. These headers are used for location analysis.

## Log Caching

When logs are fetched, they are cached on disk. The first fetch downloads the log and saves it locally. Subsequent access uses the cached version with no network request. Failed fetches create a failure marker so the URL is skipped in future runs (unless retry is explicitly requested).

This means the batch fetch only needs to run once per new set of sessions. Previously fetched logs are always available offline.

## Batch Fetching

The Coordinator can fetch all logs for a date range at once. The process collects all unique log URLs from sessions in the specified period, skips URLs that are already cached, fetches remaining URLs with automatic throttling to avoid rate limits, and reports a summary of how many were fetched, cached, or failed.

Failed URLs are tracked individually. The Coordinator can retry only the failed ones in a subsequent run.

## Location Analysis

The location analysis tool cross-references log transcript headers with registered world locations to find resolved locations (log headers that match a known location name), unresolved locations (headers that could not be matched, indicating potential data quality issues), and near matches (close but inexact matches that suggest typos or missing aliases).

This helps Narrators and Coordinators ensure that location names in transcripts are consistent with the entity registry.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Log URL returns 404 | Marked as failed, skipped in future runs | Fix the URL in the session entry; retry with the failed-retry option |
| Rate limited (429) | Automatic retry with exponential backoff | Usually self-resolving; increase throttle delay if persistent |
| Server error (5xx) | Retried up to the configured limit, then marked as failed | Retry later when the server is available |
| Pastebin short URL | Automatically normalized to raw format | No action needed |
| Log format not detected | Falls back to Prose format | No action needed; all content is still parsed |
| Location header not recognized | Appears as "unresolved" in the analysis report | Add an alias to the location entity, or verify the header text |

## Related Documents

- [Sessions.md](Sessions.md) — How to write session entries with log URLs
- [Location-Graph.md](Location-Graph.md) — Location graph and movement analysis
- [Troubleshooting.md](Troubleshooting.md) — General data quality diagnostics

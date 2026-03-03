# Session Logs

## Purpose

This guide explains how session logs (transcripts) are managed: how narrators include log links in sessions, how the system fetches and caches them, and how coordinators can analyze log content for location data quality.

## Scope

**What is included:**

- How to include log URLs in session entries
- How logs are fetched and cached locally
- How to use mass-fetch and location analysis tools
- Supported log formats and their differences

**What is excluded:**

- How to write session entries (see [Sessions.md](Sessions.md))
- PU processing (see [PU.md](PU.md))

## Actors and Responsibilities

### Narrator

- Includes log URL(s) in the session's `@Logi` metadata block after each session
- Ensures URLs point to publicly accessible text (e.g., Pastebin)

### Coordinator

- Triggers batch log fetching before analysis runs
- Reviews location analysis reports to identify data quality issues
- Retries failed fetches when transient errors are resolved

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
| **ChatLog** | Game engine copy-paste with timestamps and channels | `[13:22] [Lokalny] Lord Haart: Proszę!` |
| **Prose** | Manually written narrative summary | `Lord Haart: Otworzył drzwi z westchnieniem.` |

Both formats support **location headers** — standalone short lines (without timestamps or speaker patterns) that divide the log into location segments. These headers are used for location analysis.

## Log Caching

When logs are fetched, they are cached on disk:

- **First fetch**: The log is downloaded and saved locally
- **Subsequent access**: The cached version is used, no network request
- **Failed fetches**: A failure marker is created so the URL is skipped in future runs (unless retry is explicitly requested)

This means the batch fetch only needs to run once per new set of sessions. Previously fetched logs are always available offline.

## Batch Fetching

The coordinator can fetch all logs for a date range at once. The process:

1. Collects all unique log URLs from sessions in the specified period
2. Skips URLs that are already cached
3. Fetches remaining URLs with automatic throttling to avoid rate limits
4. Reports a summary: how many were fetched, cached, or failed

Failed URLs are tracked individually. The coordinator can retry only the failed ones in a subsequent run.

## Location Analysis

The location analysis tool cross-references log transcript headers with registered world locations to find:

- **Resolved locations** — log headers that match a known location name
- **Unresolved locations** — headers that could not be matched (potential data quality issues)
- **Near matches** — close but not exact matches that suggest typos or missing aliases

This helps narrators and coordinators ensure that location names in transcripts are consistent with the entity registry.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Log URL returns 404** | Marked as failed, skipped in future runs | Fix the URL in the session entry; retry with the failed-retry option |
| **Rate limited (429)** | Automatic retry with exponential backoff | Usually self-resolving; increase throttle delay if persistent |
| **Server error (5xx)** | Retried up to the configured limit, then marked as failed | Retry later when the server is available |
| **Pastebin short URL** | Automatically normalized to raw format | No action needed |
| **Log format not detected** | Falls back to Prose format | No action needed; all content is still parsed |
| **Location header not recognized** | Appears as "unresolved" in the analysis report | Add an alias to the location entity, or verify the header text |

## Related Documents

- [Sessions.md](Sessions.md) - How to write session entries with log URLs
- [Location-Graph.md](Location-Graph.md) - Location graph and movement analysis
- [Troubleshooting.md](Troubleshooting.md) - General data quality diagnostics

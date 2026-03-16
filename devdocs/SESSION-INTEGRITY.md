# Session Integrity Checking

## Scope

The session integrity subsystem provides SHA256 content hashing for Markdown file headers, hash storage in JSON sidecar files, and multi-check validation for detecting content tampering, format anomalies, and PU manipulation.

| Function | File | Purpose |
|---|---|---|
| `Set-SessionHash` | `public/workflow/set-sessionhash.ps1` | Compute and persist header hashes |
| `Test-SessionIntegrity` | `public/reporting/test-sessionintegrity.ps1` | Validate current content against stored hashes |
| `Get-ContentHash` | `private/session-hashhelpers.ps1` | SHA256 of whitespace-stripped content |
| `Get-FileHeaderHashes` | `private/session-hashhelpers.ps1` | Hash map for all headers in a parsed Markdown file |
| `Read-SessionHashFile` | `private/session-hashhelpers.ps1` | Load stored hashes from JSON sidecar |
| `Write-SessionHashFile` | `private/session-hashhelpers.ps1` | Persist hash map to JSON sidecar |
| `Read-SessionHashMeta` | `private/session-hashhelpers.ps1` | Load operational metadata (`_meta.json`) |
| `Write-SessionHashMeta` | `private/session-hashhelpers.ps1` | Persist operational metadata |
| `Get-HashableFiles` | `private/session-hashhelpers.ps1` | Enumerate `.md` files respecting exclusion rules |
| `Get-RelativeHashPath` | `private/session-hashhelpers.ps1` | Repo-relative path with forward slashes |

`Set-SessionHash` is a write command (`SupportsShouldProcess`). `Test-SessionIntegrity` is read-only.

PU assignment logic (`Invoke-PlayerCharacterPUAssignment`) is documented in [PU.md](PU.md). Session parsing (`Get-Session`) is documented in [SESSIONS.md](SESSIONS.md).

---

## Architecture Overview

```
private/session-hashhelpers.ps1       Hashing primitives (non-Verb-Noun, dot-sourced)
├── Get-ContentHash                   SHA256(whitespace-strip(content))
├── Get-FileHeaderHashes              Markdown result -> Dict[header, hash]
├── Read-SessionHashFile              JSON sidecar -> Dict[header, hash]
├── Write-SessionHashFile             Dict[header, hash] -> JSON sidecar
├── Read-SessionHashMeta              _meta.json -> hashtable
├── Write-SessionHashMeta             hashtable -> _meta.json
├── Get-HashableFiles                 RepoRoot -> List[filePath] (exclusion-filtered)
└── Get-RelativeHashPath              Absolute path -> repo-relative forward-slash path

public/workflow/set-sessionhash.ps1   Hash writer (exported, SupportsShouldProcess)
└── dot-sources: session-hashhelpers.ps1, admin-config.ps1

public/reporting/test-sessionintegrity.ps1   Integrity validator (exported, read-only)
└── dot-sources: session-hashhelpers.ps1, admin-config.ps1
```

Hashes are stored as JSON sidecar files under `{ResDir}/session-hashes/`, mirroring the repository's directory structure:

```
.robot/res/session-hashes/
├── _meta.json                    Operational metadata (timestamps, version)
├── Archiwum/
│   ├── sesje-2024.md.json        Hashes for Archiwum/sesje-2024.md
│   └── sesje-2025.md.json
├── Postaci/
│   └── losy-npcs.md.json
└── top-level-file.md.json
```

Each `.json` sidecar contains an object where keys are full header lines (e.g., `### 2024-06-15, Title, Narrator`) and values are 64-character lowercase hex SHA256 hashes.

The hash algorithm: (1) Concatenate the full header line with a newline and the section body text (until next header or EOF). (2) Strip ALL whitespace characters (spaces, tabs, CR, LF) using precompiled `\s+` regex. (3) Encode the result as UTF-8 (no BOM). (4) Compute SHA256 and return as lowercase 64-character hex string. This normalization ensures formatting-only changes (extra blank lines, trailing spaces, CRLF/LF conversion) do not cause false positives, while genuine content changes are always detected.

---

## Get-ContentHash

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Content` | string | Yes | Raw content to hash (header + body), `[AllowEmptyString()]` |

Algorithm: (1) Strip all whitespace: `$script:WSPattern.Replace($Content, '')`. (2) Encode to UTF-8 bytes (no BOM): `$script:UTF8NoBOM.GetBytes($Stripped)`. (3) Compute SHA256: `[System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)`. (4) Format as lowercase hex: `[System.BitConverter]::ToString($HashBytes).Replace('-', '').ToLowerInvariant()`. (5) Dispose SHA256 instance in `finally` block.

Returns a `[string]` -- 64-character lowercase hex SHA256 hash.

---

## Compiled C# Hasher — Robot.ContentHasher

Source: `lib/ContentHasher.cs`. A compiled C# SHA256 content hasher with zero-allocation inner loop. It fuses whitespace stripping and UTF-8 encoding into a single pass, renting the byte buffer from `ArrayPool<byte>` to avoid per-call GC pressure.

Methods:

| Method | Signature | Description |
|---|---|---|
| `Hash` | `static string Hash(string content)` | Compute SHA256 of whitespace-stripped content. Returns lowercase 64-char hex string. Empty/whitespace-only content returns the SHA256 of an empty byte array (stable sentinel value). |
| `HashSections` | `static string[] HashSections(string[] headers, string[] bodies)` | Batch header+body pairs for sidecar file generation. Concatenates each header+newline+body, then hashes. Returns parallel string array of hashes. |

The static `SHA256` instance is guarded by `lock` -- safe for `RunspacePool` parallel Markdown parsing in `Get-Markdown`.

`char.IsWhiteSpace` matches the same set as .NET regex `\s` (tabs, spaces, CR, LF, form feeds, non-breaking spaces, etc.), ensuring hash stability across line-ending normalization and compatibility with the PowerShell `Get-ContentHash` implementation.

Consumers: `Get-SessionContentHash` (`private/session-hashhelpers.ps1`) dispatches to `Robot.ContentHasher.Hash` when the type is available, falls back to the PowerShell `Get-ContentHash` otherwise. Also consumed by `Save-SessionHashSidecar` (`private/session-hashhelpers.ps1`).

---

## Get-FileHeaderHashes

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `MarkdownResult` | object | Yes | Parsed result from `Get-Markdown` (has `.Sections` with `.Header` and `.Content`) |

Algorithm: (1) Create `Dictionary[string, string]` with `OrdinalIgnoreCase` comparer. (2) Iterate over `$MarkdownResult.Sections`. (3) Skip sections where `.Header` is `$null`. (4) Reconstruct full header line: `('#' * Level) + ' ' + Text`. (5) Build full content: header line + `\n` + section body. (6) Compute hash via `Get-ContentHash`. (7) Store in dictionary: `$Hashes[$HeaderLine] = $Hash`.

Returns `Dictionary[string, string]` -- keys are full header lines, values are SHA256 hashes. Empty dictionary if no headers found.

---

## Read-SessionHashFile / Write-SessionHashFile

Read parameters:

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `JsonPath` | string | Yes | Path to the `.json` hash sidecar file |

Read algorithm: (1) Return empty `Dictionary[string, string]` (OrdinalIgnoreCase) if file does not exist. (2) Read file via `[System.IO.File]::ReadAllText` with UTF-8 no BOM. (3) Parse JSON via `ConvertFrom-Json`. (4) Copy all properties into dictionary. (5) On parse failure: warn to stderr, return empty dictionary.

Write parameters:

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `JsonPath` | string | Yes | Path to the `.json` hash sidecar file |
| `Hashes` | Dictionary[string, string] | Yes | Header-to-hash dictionary |

Write algorithm: (1) Create parent directories if needed. (2) Sort keys using `StringComparer.Ordinal` for deterministic output. (3) Build `[ordered]@{}` from sorted keys. (4) Serialize via `ConvertTo-Json -Depth 1`. (5) Write via `[System.IO.File]::WriteAllText` with UTF-8 no BOM.

---

## Read-SessionHashMeta / Write-SessionHashMeta

Metadata schema:

| Key | Type | Default | Description |
|---|---|---|---|
| `LastFullUpdate` | string (nullable) | `$null` | Timestamp of last `-Full` run (`yyyy-MM-dd HH:mm:ss`) |
| `LastIncrementalUpdate` | string (nullable) | `$null` | Timestamp of last incremental run |
| `Version` | int | `1` | Schema version for forward compatibility |

Timestamps use `yyyy-MM-dd HH:mm:ss` format (not ISO 8601) to prevent `ConvertFrom-Json` from auto-converting strings to `DateTime` objects.

Read algorithm: (1) Return defaults if file does not exist. (2) Read and parse with `ConvertFrom-Json -AsHashtable`. (3) Merge parsed values into defaults (preserving defaults for missing keys). (4) On failure: warn to stderr, return defaults.

---

## Get-HashableFiles

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `RepoRoot` | string | Yes | Root directory of the lore repository |
| `ExcludeDirectory` | string[] | No | Additional directories to exclude |

Exclusion rules:

| Rule | Mechanism |
|---|---|
| Dot directories (`.git/`, `.robot/`, `.robot.new/`) | Component scan: any directory starting with `.` |
| `Nerthus/` subdirectory | Component scan: case-insensitive match on `Nerthus` |
| User-specified directories | Absolute prefix matching via `$ExcludePrefixes` |

Algorithm: (1) Resolve symlinks via `[System.IO.Path]::GetFullPath` (handles macOS `/var` -> `/private/var`). (2) Enumerate all `*.md` files recursively via `[System.IO.Directory]::GetFiles`. (3) For each file, compute relative path from repo root. (4) Split into directory components; skip if any component starts with `.` or equals `Nerthus` (case-insensitive). (5) Check against user-specified exclusion prefixes. (6) Collect surviving paths into result list.

Returns `List[string]` -- absolute paths to hashable `.md` files.

---

## Get-RelativeHashPath

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `FilePath` | string | Yes | Absolute file path |
| `RepoRoot` | string | Yes | Repository root directory |

Algorithm: (1) Resolve both paths via `GetFullPath`. (2) If file is under repo root: strip root prefix, replace `\` with `/`. (3) If file is outside repo root: return full path with `/` separators.

---

## Set-SessionHash

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Full` | switch | No | Recompute hashes for all files (not just changed) |
| `File` | string[] | No | Limit to specific file path(s) |
| `Since` | string | No | Only process files changed since this date |
| `ExcludeDirectory` | string[] | No | Directories to exclude from scanning |
| `Quiet` | switch | No | Suppress warning output to stderr |

File selection logic:

```
$File specified?
  +-- Yes -> use explicit file list (resolve relative to RepoRoot if needed)
  +-- No -> $Full?
       +-- Yes -> Get-HashableFiles (all eligible .md files)
       +-- No  -> Incremental mode:
            +-- $Since or _meta.json LastIncrementalUpdate -> Get-GitChangeLog
            +-- Filter to hashable files (intersection with Get-HashableFiles)
            +-- Fallback to full scan if no timestamp or git fails
```

Algorithm: (1) Dot-source `session-hashhelpers.ps1` and `admin-config.ps1` if not already loaded. (2) Resolve `RepoRoot`, `HashDir`, `MetaPath` from `Get-AdminConfig`. (3) Determine files to process (see file selection logic above). (4) Batch-parse all files via `Get-Markdown -File @($FilesToProcess)`. (5) For each parsed result: compute relative path to JSON sidecar path, compute current hashes via `Get-FileHeaderHashes`, load existing hashes via `Read-SessionHashFile`, count new vs updated hashes, write updated hashes via `Write-SessionHashFile` (respects `ShouldProcess`). (6) Update `_meta.json` timestamps (full run sets both `LastFullUpdate` and `LastIncrementalUpdate`; incremental sets only `LastIncrementalUpdate`).

Output:

| Property | Type | Description |
|---|---|---|
| `FilesProcessed` | int | Number of files written |
| `HashesComputed` | int | Total headers hashed across all files |
| `HashesUpdated` | int | Headers where hash changed from stored value |
| `HashesNew` | int | Headers not previously in hash store |

---

## Test-SessionIntegrity

| Parameter | Type | Mandatory | Description |
|---|---|---|---|
| `Full` | switch | No | Check all files (not just recently changed) |
| `File` | string[] | No | Limit validation to specific file path(s) |
| `Since` | string | No | Check only files changed since this date |
| `ExcludeDirectory` | string[] | No | Directories to exclude from scanning |
| `ProgressCallback` | scriptblock | No | Optional callback for CLI progress reporting (receives `Current`, `Total`, `ItemDetail`) |
| `Quiet` | switch | No | Suppress warning output to stderr |

File selection logic is identical to `Set-SessionHash`.

Validation checks:

| # | Check | Severity | Condition |
|---|---|---|---|
| 1 | Modified Sessions | High | Content hash differs from stored hash |
| 2 | Deleted Sessions | High | Header in hash store but not in current file |
| 3 | New Sessions | Medium | Header in file but not in hash store |
| 4 | Missing Hash Files | Medium | `.md` file has no corresponding `.json` sidecar |
| 5 | Malformed Headers | Medium | Level-3 header fails date parsing |
| 6 | PU-Affected Sessions | Critical | Modified session contains `@PU:` data |
| 7 | Duplicate PU Markers | Critical | Modified session has 2+ `@PU:` section markers |
| 8 | Format Anomalies | Low | Date-like line without `###` header prefix |
| 9 | Future-Dated Sessions | Medium | Session header date is after today |

Algorithm: (1) Dot-source helpers (same as `Set-SessionHash`). (2) Resolve config and determine files to check (same file selection logic). (3) Batch-parse all files via `Get-Markdown` and index results in a `Dictionary[string, object]` keyed by file path (OrdinalIgnoreCase) for O(1) lookup. (4) For each file: report progress via `$ProgressCallback` (every 5 files and on the final file, receiving `Current`, `Total`, `ItemDetail` arguments); compute relative path to JSON sidecar path; if no hash file exists (Check 4), record as missing, then still scan for malformed headers (Check 5), future dates (Check 9), and format anomalies (Check 8); if hash file exists, compute current hashes via `Get-FileHeaderHashes`, load stored hashes via `Read-SessionHashFile`, compare (hash mismatch triggers Check 1; if modified section contains `@PU:` triggers Check 6; if 2+ PU markers triggers Check 7; headers only in stored trigger Check 2; headers only in current trigger Check 3), scan level-3 headers for date validity (Check 5) and future dates (Check 9), section-based scan for format anomalies (Check 8).

Precompiled regex patterns:

| Variable | Pattern | Purpose |
|---|---|---|
| `$script:PUSectionPattern` | `^\s*[-\*]\s+@?[Pp][Uu]\s*:` | Detect `@PU:` or `PU:` section markers (canonical: `session-parsehelpers.ps1`) |
| `$script:DateLineLikePattern` | `^\d{4}-\d{2}-\d{2}` | Detect date-like lines for format anomaly check |
| `$script:SessionDatePattern` | `\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b` | Extract and validate dates from headers (canonical: `temporal-helpers.ps1`) |

Format anomaly detection uses parsed section data (from `Get-Markdown`). For each section, the `Content` string is split on newline characters and scanned with line numbers computed from `Section.Header.LineNumber`. The scan skips lines inside code blocks (backtick-triple toggle), lines starting with whitespace, `-`, `*`, or tab (list items, metadata), and lines starting with `### ` (valid headers). Only bare date-like lines at column 0 without `### ` prefix are flagged. This approach eliminates redundant file I/O -- the parser output already contains all the content needed for anomaly detection.

Output:

| Property | Type | Description |
|---|---|---|
| `OK` | bool | `$true` if all checks pass (all arrays empty) |
| `ModifiedSessions` | object[] | Hash mismatches (`.FilePath`, `.RelativePath`, `.Header`, `.Issue`, `.StoredHash`, `.CurrentHash`, `.HasPU`) |
| `DeletedSessions` | object[] | Stored headers missing from file (same schema as Modified) |
| `NewSessions` | object[] | File headers not in hash store (same schema as Modified) |
| `MissingHashFiles` | string[] | Relative paths of `.md` files without `.json` sidecars |
| `MalformedHeaders` | object[] | Invalid headers (`.FilePath`, `.RelativePath`, `.Header`, `.Issue`) |
| `PUAffectedSessions` | object[] | Modified sessions with PU data (same schema as Modified, `.HasPU` = `$true`) |
| `DuplicatePUMarkers` | object[] | Sessions with 2+ PU markers (`.PUMarkerCount` added) |
| `FormatAnomalies` | object[] | Date-like lines without `###` (`.FilePath`, `.RelativePath`, `.LineNumber`, `.Line`, `.Issue`) |
| `FutureDatedSessions` | object[] | Future-dated headers (`.FilePath`, `.RelativePath`, `.Header`, `.Date`, `.Issue`) |

---

## Common Patterns

Module-level data:

| Variable | File | Purpose |
|---|---|---|
| `$script:WSPattern` | `session-hashhelpers.ps1` | Precompiled `\s+` regex for whitespace stripping |
| `$script:UTF8NoBOM` | `session-hashhelpers.ps1` | Shared `UTF8Encoding($false)` instance |
| `$script:PUSectionPattern` | `session-parsehelpers.ps1` | Precompiled PU section marker pattern (shared) |
| `$script:DateLineLikePattern` | `test-sessionintegrity.ps1` | Precompiled date-like line pattern |
| `$script:SessionDatePattern` | `temporal-helpers.ps1` | Precompiled date extraction pattern (shared) |

Both `Set-SessionHash` and `Test-SessionIntegrity` guard-load helpers:

```powershell
if (-not (Get-Command 'Get-ContentHash' -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot/../../private/session-hashhelpers.ps1"
}
```

This avoids re-loading when the module has already sourced the helpers.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Corrupt JSON sidecar | `Read-SessionHashFile` warns to stderr, returns empty dictionary |
| Corrupt `_meta.json` | `Read-SessionHashMeta` warns to stderr, returns defaults |
| File outside repo root | `Get-RelativeHashPath` returns full path with forward slashes |
| Empty `.md` file (no headers) | `Get-FileHeaderHashes` returns empty dictionary; no hashes stored |
| macOS symlink `/var` -> `/private/var` | `GetFullPath` resolves before prefix comparison |
| Git changelog unavailable | Falls back to full scan with warning |
| No previous incremental timestamp | Falls back to full scan |
| `Set-SessionHash -WhatIf` | Computes hashes but writes no files or metadata |
| Date-like line inside code block | Format anomaly scanner respects backtick-triple toggle |
| Date-like line inside list item | Skipped by leading-character check (`-`, `*`, space, tab) |
| Level-3 header without valid date | Flagged as malformed; hash store comparison skipped |
| Session date in the future | Flagged even if no hash file exists |

---

## Testing

Test file: `tests/test-sessionintegrity.Tests.ps1`

| Describe Block | Coverage |
|---|---|
| `Get-ContentHash` | Hex format, whitespace normalization, different content, empty input |
| `Get-FileHeaderHashes` | Header extraction, empty file, case-insensitive keys |
| `Read-SessionHashFile / Write-SessionHashFile` | Round-trip, missing file, nested directories, sorted keys, corrupt JSON |
| `Read-SessionHashMeta / Write-SessionHashMeta` | Missing file defaults, round-trip |
| `Get-HashableFiles` | Content dirs, dot exclusion, Nerthus exclusion, user exclusion |
| `Get-RelativeHashPath` | Relative path, outside-repo path |
| `Set-SessionHash` | File mode, WhatIf, second-run counting |
| `Test-SessionIntegrity` | Clean state, modified, deleted, new, missing hash, malformed, PU-affected, duplicate PU, format anomaly, future-dated, output structure |

Fixtures located in `tests/fixtures/sessions-integrity/`:

| File | Purpose |
|---|---|
| `base.md` | Baseline: 3 valid sessions (2 with PU, 1 without) |
| `modified.md` | First session altered (content + PU value changed: Xeron 0,3 -> 0,8) |
| `malformed.md` | Headers with `invalid-date` and impossible month `2024-13-01` |
| `duplicate-pu.md` | Single session with two `@PU:` blocks |
| `format-anomaly.md` | Date-like line missing `###` prefix |
| `future-dated.md` | Session dated `2099-01-01` |

Loading pattern: A (exported functions) + B (dot-source internal helpers).

---

## Related Documents

- [SESSIONS.md](SESSIONS.md) -- session parsing pipeline and format generations
- [PU.md](PU.md) -- PU assignment algorithm (uses same `@PU:` pattern)
- [CONFIG-STATE.md](CONFIG-STATE.md) -- `Get-AdminConfig` and `ResDir` resolution
- [GIT.md](GIT.md) -- `Get-GitChangeLog` used for incremental mode
- [PARSER.md](PARSER.md) -- `Get-Markdown` output structure consumed by `Get-FileHeaderHashes`
- [SESSION-GRAPH.md](SESSION-GRAPH.md) -- session participation graph (reuses `Get-ContentHash`)

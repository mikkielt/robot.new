# Markdown Parser Internals - Technical Reference

---

## Scope

This document covers the Markdown parsing subsystem: `Get-Markdown` (orchestration and parallelism) and `private/parse-markdownfile.ps1` (single-file parser). These are the foundational data extraction layer -- all other functions consume their output.

How parsed output is consumed by `Get-Player`, `Get-Entity`, `Get-Session`, etc. is documented in the respective subsystem articles.

---

## Two-File Architecture

```
Get-Markdown (public/get-markdown.ps1)          # public/ root
    |
    +-- Sequential path (<=4 files): & $ParseFileScript $FilePath
    |
    +-- Parallel path (>4 files): RunspacePool workers
            |
            +-- private/parse-markdownfile.ps1 (self-contained script)
```

The split exists because RunspacePool workers do not share module scope. The parser script is loaded as a string (`[System.IO.File]::ReadAllText`) and passed to each worker via `AddScript()`, making it fully self-contained with no external dependencies.

---

## Compiled C# Types

Two compiled C# types in the `Robot` namespace provide native-speed parsing and disk cache persistence for the Markdown subsystem. Both are loaded via `Add-Type` with `PSTypeName` guards (see the Compiled C# Types section in [SYNTAX.md](SYNTAX.md)).

`Robot.MarkdownScanner` (`lib/MarkdownScanner.cs`) is a compiled Markdown line scanner that replaces the interpreted PowerShell line-scan loop with native code. Called by `private/parse-markdownfile.ps1` as the primary parse path; `public/get-markdown.ps1` pre-loads the type before RunspacePool workers start to ensure availability in all runspaces.

It accepts a `string[]` of file lines and produces a `ScanResult` containing four flat arrays -- `HeaderEntry[]`, `SectionEntry[]`, `ListEntry[]`, `LinkEntry[]`. The algorithm is a single-pass line scanner applying 6 precompiled regex patterns per line (CodeFence, MdLink, PlainUrl, Header, ListItem, MarkerNum), identical in logic to the interpreted parser described in the Single-File Parser section.

The scanner stores parent relationships as integer indices into the flat arrays (`ParentIndex = -1` means no parent). The PowerShell integration layer in `parse-markdownfile.ps1` reconstructs object references from these indices after scanning.

Output types:

| Type | Kind | Properties |
|---|---|---|
| `ScanResult` | class | `Headers`, `Sections`, `Lists`, `Links` (typed arrays) |
| `HeaderEntry` | struct | `Level` (int), `Text` (string), `ParentIndex` (int), `LineNumber` (int) |
| `SectionEntry` | struct | `HeaderIndex` (int), `Content` (string), `ListStartIndex` (int), `ListCount` (int) |
| `ListEntry` | class | `Type` (string), `Text` (string), `Indent` (int), `ParentIndex` (int), `LocalIndex` (int), `SectionHeaderIndex` (int) |
| `LinkEntry` | struct | `Type` (string), `Text` (string), `Url` (string) |

`ListEntry` is intentionally a class (not struct) so the PowerShell layer can mutate `LocalIndex` and convert `ParentIndex` from global to section-local without value-type boxing issues. `HeaderEntry`, `SectionEntry`, and `LinkEntry` are structs.

Key API: `MarkdownScanner.Parse(string[] lines)` -- static, stateless, thread-safe.

Consumers: `private/parse-markdownfile.ps1` (primary scanner call), `public/get-markdown.ps1` (type pre-loading for RunspacePool workers).

`Robot.ParseCacheHelper` (`lib/ParseCacheHelper.cs`) is a disk sidecar persistence layer for `MarkdownScanner.ScanResult` objects. Enables cross-session and cross-process cache reuse without re-parsing Markdown files. Called by `public/get-markdown.ps1` (6 call sites for the disk cache tier) and `Robot.PowerShell.psm1` (cache clear on module reload).

It serializes and deserializes `ScanResult` to/from JSON cache files on disk. The cache directory lives at `{RepoRoot}/.robot.local/.cache/markdown/`. Each parsed Markdown file gets a corresponding `.json` sidecar in the cache directory, populated lazily on first parse and checked before re-parsing on subsequent loads.

Serialization uses hand-rolled `StringBuilder` serialization with compact single-character JSON keys to minimize disk footprint and parse time:

| Entry type | Key mapping |
|---|---|
| `HeaderEntry` | `L` = Level, `T` = Text, `P` = ParentIndex, `N` = LineNumber |
| `SectionEntry` | `H` = HeaderIndex, `C` = Content, `LS` = ListStartIndex, `LC` = ListCount |
| `ListEntry` | `Y` = Type, `T` = Text, `I` = Indent, `P` = ParentIndex, `S` = SectionHeaderIndex |
| `LinkEntry` | `Y` = Type, `T` = Text, `U` = Url |

Polish diacritics are written unescaped for human readability; only ASCII control characters and JSON-special characters are escaped via a manual escape loop.

The `CacheVersion` constant (currently `1`) is stored in `meta.json`. Mismatched versions invalidate the entire cache tier, forcing a full re-parse. Bump `CacheVersion` when the `ScanResult` schema changes.

Public methods:

| Method | Description |
|---|---|
| `SerializeScanResult(ScanResult)` | Returns compact JSON string; `"null"` for null input |
| `DeserializeScanResult(string)` | Returns `ScanResult` or `null` on invalid/corrupt input |
| `WriteScanResultToFile(string, ScanResult)` | Writes JSON to path; creates parent directories as needed; UTF-8 no BOM |
| `ReadScanResultFromFile(string)` | Returns `ScanResult` or `null` if missing/corrupt |
| `WriteMetaFile(string, IDictionary)` | Writes meta/index dictionary via `Robot.JsonHelper.WriteSortedJson` for deterministic key ordering |
| `ReadMetaFile(string)` | Returns case-insensitive `Hashtable`; empty on missing/corrupt file |
| `DeleteCacheDirectory(string)` | Deletes entire `.robot.local/.cache` directory tree; best-effort on locked files |

All methods are static and stateless. File I/O is not locked -- callers must ensure no concurrent writes to the same path. All written files use UTF-8 no BOM encoding.

Consumers: `public/get-markdown.ps1` (6 call sites for disk cache read/write/invalidation), `Robot.PowerShell.psm1` (2 call sites for cache clear on module reload).

---

## Orchestration (`Get-Markdown`)

Parameters:

| Parameter | Type | Description |
|---|---|---|
| `File` | string[] | Specific file paths to parse |
| `Directory` | string | Recursive directory scan (defaults to repo root) |

File collection: `-File` validates each path via `[System.IO.File]::Exists()`. `-Directory` uses `[System.IO.Directory]::GetFiles($Dir, "*.md", AllDirectories)` plus a second pass for `*.markdown`.

Parallelism:

| Condition | Strategy | Rationale |
|---|---|---|
| <= 4 files | Sequential (`& $ParseFileScript`) | RunspacePool setup overhead ~50ms not justified |
| > 4 files | RunspacePool with `ProcessorCount` threads | Significant speedup for `Get-Session` scanning dozens of files |

Module-level variables:

```powershell
$ParallelThreshold = 4
$MaxThreads = [Math]::Min($FileCount, [Environment]::ProcessorCount)
```

Worker management:
1. Create `RunspacePool` with `[1, $MaxThreads]` bounds
2. For each file: create `PowerShell` instance -> `AddScript($ParseFileScriptStr)` -> `AddArgument($FilePath)` -> `BeginInvoke()`
3. Track jobs as `[PSCustomObject]@{ PS; Handle }`
4. Collect results via `EndInvoke()` (blocking)
5. Explicit `Dispose()` on each `PowerShell` instance and the pool

Return convention: single file via `-File` with one path returns the parsed object directly (unwrapped). Multiple files or `-Directory` returns `List[object]`.

---

## Single-File Parser (`private/parse-markdownfile.ps1`)

Script-scope variables:

| Variable | Type | Description |
|---|---|---|
| `$MdLinkPattern` | `[regex]` | `'\[(.+?)\]\((.+?)\)'` - Markdown link capture |
| `$PlainUrlPattern` | `[regex]` | `'https?:\/\/[^\s\)\]]+'` - Plain URL pattern |
| `$CodeFencePattern` | `[regex]` | `` '^```' `` - Code fence detection |
| `$HeaderPattern` | `[regex]` | `'^(#+)\s*(.+)$'` - Header level and text capture |
| `$ListItemPattern` | `[regex]` | `'^(\s*)(\d+\.\|[-\*\+])\s+(.+)$'` - List item with indent/marker/text capture |
| `$MarkerNumPattern` | `[regex]` | `'^\d+\.'` - Numbered list marker detection |
| `$HeaderStack` | `Stack[object]` | Maintains header hierarchy |
| `$ListStack` | `Stack[object]` | Maintains list item nesting |
| `$InCodeBlock` | `bool` | Fenced code block toggle |

All six regex patterns are precompiled once at script scope (outside the line-scan loop). This avoids per-line regex compilation overhead, which is significant when parsing thousands of lines across dozens of files.

The parser reads all lines via `[System.IO.File]::ReadAllLines()` and processes them in a single pass with 1-based line numbering. Each line is trimmed on the right only (`TrimEnd()`) to preserve leading whitespace needed for indent detection. The scan handles five concerns simultaneously using precompiled regex patterns:

1. Code block tracking -- `$CodeFencePattern` toggles `$InCodeBlock`; everything inside is opaque
2. Header extraction -- `$HeaderPattern` matches lines starting with `#` (outside code blocks)
3. Section accumulation -- content grouped by headers
4. List item parsing -- `$ListItemPattern` captures indent, marker, and text; `$MarkerNumPattern` distinguishes numbered from bullet items
5. Link extraction -- `$MdLinkPattern` and `$PlainUrlPattern` extract both Markdown links and plain URLs

Header hierarchy (stack-based):

```
FOR each header line:
    Pop stack until top header has level < current level
    ParentHeader = stack.Peek() (or null if empty)
    Push current header onto stack
```

Produces a tree via `ParentHeader` back-references.

List item nesting (indent-based) uses indent normalization: `Floor(rawIndent / 2) * 2`. This tolerates 1-3 spaces as a single indent level (common in hand-edited Markdown).

```
FOR each list item line:
    Normalize indent
    Pop stack until top item indent < current indent
    ParentListItem = stack.Peek() (or null if empty)
    Push current item onto stack
    Associate with current section header
```

Link extraction is two-step: (1) extract Markdown `[text](url)` links via `$MdLinkPattern` regex, (2) strip all captured Markdown links from the line text, (3) extract plain `https://...` URLs from the remainder via `$PlainUrlPattern`. This prevents double-counting a URL that appears in both `[text](url)` and as a plain URL.

Content is accumulated into a `StringBuilder` between headers. When a new header is encountered (or EOF), the accumulated content is flushed as a `Section` object. Empty sections (no content and no header) are discarded.

---

## Output Object Schema

```powershell
[PSCustomObject]@{
    FilePath = "path/to/file.md"
    Headers  = List[object]     # Header objects
    Sections = List[object]     # Section objects
    Lists    = List[object]     # All list items (flat)
    Links    = List[object]     # All links (flat)
}
```

Header object:

| Property | Type | Description |
|---|---|---|
| `Level` | int | Header level (1-6) |
| `Text` | string | Header text (without `#` prefix) |
| `ParentHeader` | object | Reference to parent header (or `$null`) |
| `LineNumber` | int | 1-based line number in source file |

Section object:

| Property | Type | Description |
|---|---|---|
| `Header` | object | Associated header (or `$null` for content before first header) |
| `Content` | string | Raw text content (newline-joined) |
| `Lists` | `List[object]` | List items within this section |

List item object:

| Property | Type | Description |
|---|---|---|
| `Type` | string | `"Bullet"` or `"Numbered"` |
| `Text` | string | Item text (without bullet/number prefix) |
| `Indent` | int | Normalized indent level |
| `ParentListItem` | object | Reference to parent item (or `$null`) |
| `SectionHeader` | object | Reference to containing section's header |

Link object:

| Property | Type | Description |
|---|---|---|
| `Type` | string | `"MarkdownLink"` or `"PlainUrl"` |
| `Text` | string | Link text (for Markdown links) or `$null` |
| `Url` | string | URL target |

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Fenced code block with `#` lines | `$InCodeBlock` flag prevents false header detection |
| Inconsistent indentation (1-3 spaces) | Normalized via `Floor(indent/2)*2` |
| URL inside a Markdown link | Extracted once as `MarkdownLink`, not double-counted as `PlainUrl` |
| Content before first header | Captured as a section with `Header = $null` |
| Empty sections | Discarded (`Length > 0 || Header != null` check) |
| Root-level list items | `ParentListItem = $null` |
| `*.markdown` extension | Included in directory scan alongside `*.md` |

---

## Performance Notes

- File I/O uses `[System.IO.File]::ReadAllLines()` for speed
- Directory scanning uses `[System.IO.Directory]::GetFiles()` with `SearchOption.AllDirectories`
- All six regex patterns (`$MdLinkPattern`, `$PlainUrlPattern`, `$CodeFencePattern`, `$HeaderPattern`, `$ListItemPattern`, `$MarkerNumPattern`) are precompiled once at script scope, avoiding per-line regex compilation overhead
- The parser script text (`private/parse-markdownfile.ps1`) is read from disk once and cached at `$script:CachedParseFileScriptStr`. Subsequent `Get-Markdown` calls reuse the cached string for both sequential invocation (via `[scriptblock]::Create`) and parallel workers (via `AddScript`), avoiding repeated file I/O.
- StringBuilder is used for section content accumulation to avoid string concatenation
- Parallelism threshold: 4 files (below this, pool setup overhead exceeds parsing time)

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/get-markdown.Tests.ps1` | File/directory input, parallel vs sequential, return convention |
| `tests/parse-markdownfile.Tests.ps1` | Header hierarchy, list nesting, link extraction, code block handling, indent normalization |

---

## Related Documents

- [SESSIONS.md](SESSIONS.md) - `Get-Session` consumes `Get-Markdown` output for session extraction
- [ENTITIES.md](ENTITIES.md) - `Get-Entity` consumes `Get-Markdown` output for entity parsing
- [MIGRATION.md](MIGRATION.md) - Module Structure lists parser in the non-exported helpers

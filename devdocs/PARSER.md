# Markdown Parser Internals - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the Markdown parsing subsystem: `Get-Markdown` (orchestration and parallelism) and `private/parse-markdownfile.ps1` (single-file parser). These are the foundational data extraction layer - all other functions consume their output.

**Not covered**: How parsed output is consumed by `Get-Player`, `Get-Entity`, `Get-Session`, etc.

---

## 2. Two-File Architecture

```
Get-Markdown (public/get-markdown.ps1)          # public/ root
    │
    ├── Sequential path (≤4 files): & $ParseFileScript $FilePath
    │
    └── Parallel path (>4 files): RunspacePool workers
            │
            └── private/parse-markdownfile.ps1 (self-contained script)
```

The split exists because **RunspacePool workers don't share module scope**. The parser script is loaded as a string (`[System.IO.File]::ReadAllText`) and passed to each worker via `AddScript()`, making it fully self-contained with no external dependencies.

---

## 3. Compiled C# Types

Two compiled C# types in the `Robot` namespace provide native-speed parsing and disk cache persistence for the Markdown subsystem. Both are loaded via `Add-Type` with `PSTypeName` guards (see `devdocs/SYNTAX.md` §Compiled C# Types).

### 3.1 `Robot.MarkdownScanner` (`lib/MarkdownScanner.cs`)

Compiled Markdown line scanner that replaces the interpreted PowerShell line-scan loop with native code. Called by `private/parse-markdownfile.ps1` as the primary parse path; `public/get-markdown.ps1` pre-loads the type before RunspacePool workers start to ensure availability in all runspaces.

**What it does**: Accepts a `string[]` of file lines and produces a `ScanResult` containing four flat arrays — `HeaderEntry[]`, `SectionEntry[]`, `ListEntry[]`, `LinkEntry[]`. The algorithm is a single-pass line scanner applying 6 precompiled regex patterns per line (CodeFence, MdLink, PlainUrl, Header, ListItem, MarkerNum), identical in logic to the interpreted parser described in §5.

**Index-based parent tracking**: Unlike the PSCustomObject-based parser output (which uses object references for `ParentHeader` / `ParentListItem`), the scanner stores parent relationships as integer indices into the flat arrays (`ParentIndex = -1` means no parent). The PowerShell integration layer in `parse-markdownfile.ps1` reconstructs object references from these indices after scanning.

**Output types**:

| Type | Kind | Properties |
|---|---|---|
| `ScanResult` | class | `Headers`, `Sections`, `Lists`, `Links` (typed arrays) |
| `HeaderEntry` | struct | `Level` (int), `Text` (string), `ParentIndex` (int), `LineNumber` (int) |
| `SectionEntry` | struct | `HeaderIndex` (int), `Content` (string), `ListStartIndex` (int), `ListCount` (int) |
| `ListEntry` | class | `Type` (string), `Text` (string), `Indent` (int), `ParentIndex` (int), `LocalIndex` (int), `SectionHeaderIndex` (int) |
| `LinkEntry` | struct | `Type` (string), `Text` (string), `Url` (string) |

`ListEntry` is intentionally a class (not struct) so the PowerShell layer can mutate `LocalIndex` and convert `ParentIndex` from global to section-local without value-type boxing issues. `HeaderEntry`, `SectionEntry`, and `LinkEntry` are structs.

**Key API**: `MarkdownScanner.Parse(string[] lines)` — static, stateless, thread-safe.

**Consumers**: `private/parse-markdownfile.ps1` (primary scanner call), `public/get-markdown.ps1` (type pre-loading for RunspacePool workers).

### 3.2 `Robot.ParseCacheHelper` (`lib/ParseCacheHelper.cs`)

Disk sidecar persistence layer for `MarkdownScanner.ScanResult` objects. Enables cross-session and cross-process cache reuse without re-parsing Markdown files. Called by `public/get-markdown.ps1` (6 call sites for the disk cache tier) and `robot.psm1` (cache clear on module reload).

**What it does**: Serializes and deserializes `ScanResult` to/from JSON cache files on disk. The cache directory lives at `{RepoRoot}/.robot-cache/markdown/`. Each parsed Markdown file gets a corresponding `.json` sidecar in the cache directory, populated lazily on first parse and checked before re-parsing on subsequent loads.

**Serialization strategy**: Hand-rolled `StringBuilder` serialization with compact single-character JSON keys to minimize disk footprint and parse time:

| Entry type | Key mapping |
|---|---|
| `HeaderEntry` | `L` = Level, `T` = Text, `P` = ParentIndex, `N` = LineNumber |
| `SectionEntry` | `H` = HeaderIndex, `C` = Content, `LS` = ListStartIndex, `LC` = ListCount |
| `ListEntry` | `Y` = Type, `T` = Text, `I` = Indent, `P` = ParentIndex, `S` = SectionHeaderIndex |
| `LinkEntry` | `Y` = Type, `T` = Text, `U` = Url |

Polish diacritics (ą, ę, ó, ś, ź, ż, ć, ń, ł) are written unescaped for human readability; only ASCII control characters and JSON-special characters are escaped via a manual escape loop (not `JsonSerializer`).

**Version gating**: The `CacheVersion` constant (currently `1`) is stored in `meta.json`. Mismatched versions invalidate the entire cache tier, forcing a full re-parse. Bump `CacheVersion` when the `ScanResult` schema changes.

**Public methods**:

| Method | Description |
|---|---|
| `SerializeScanResult(ScanResult)` | Returns compact JSON string; `"null"` for null input |
| `DeserializeScanResult(string)` | Returns `ScanResult` or `null` on invalid/corrupt input |
| `WriteScanResultToFile(string, ScanResult)` | Writes JSON to path; creates parent directories as needed; UTF-8 no BOM |
| `ReadScanResultFromFile(string)` | Returns `ScanResult` or `null` if missing/corrupt |
| `WriteMetaFile(string, IDictionary)` | Writes meta/index dictionary via `Robot.JsonHelper.WriteSortedJson` for deterministic key ordering |
| `ReadMetaFile(string)` | Returns case-insensitive `Hashtable`; empty on missing/corrupt file |
| `DeleteCacheDirectory(string)` | Deletes entire `.robot-cache` directory tree; best-effort on locked files |

**Thread safety**: All methods are static and stateless. File I/O is not locked — callers must ensure no concurrent writes to the same path. All written files use UTF-8 no BOM encoding.

**Consumers**: `public/get-markdown.ps1` (6 call sites for disk cache read/write/invalidation), `robot.psm1` (2 call sites for cache clear on module reload).

---

## 4. Orchestration (`Get-Markdown`)

### 4.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `File` | string[] | Specific file paths to parse |
| `Directory` | string | Recursive directory scan (defaults to repo root) |

### 4.2 File Collection

- `-File`: Validates each path via `[System.IO.File]::Exists()`
- `-Directory`: Uses `[System.IO.Directory]::GetFiles($Dir, "*.md", AllDirectories)` plus a second pass for `*.markdown`

### 4.3 Parallelism

| Condition | Strategy | Rationale |
|---|---|---|
| ≤ 4 files | Sequential (`& $ParseFileScript`) | RunspacePool setup overhead ~50ms not justified |
| > 4 files | RunspacePool with `ProcessorCount` threads | Significant speedup for `Get-Session` scanning dozens of files |

**Module-level variables**:

```powershell
$ParallelThreshold = 4
$MaxThreads = [Math]::Min($FileCount, [Environment]::ProcessorCount)
```

**Worker management**:
1. Create `RunspacePool` with `[1, $MaxThreads]` bounds
2. For each file: create `PowerShell` instance -> `AddScript($ParseFileScriptStr)` -> `AddArgument($FilePath)` -> `BeginInvoke()`
3. Track jobs as `[PSCustomObject]@{ PS; Handle }`
4. Collect results via `EndInvoke()` (blocking)
5. Explicit `Dispose()` on each `PowerShell` instance and the pool

### 4.4 Return Convention

- Single file via `-File` with one path -> returns the parsed object directly (unwrapped)
- Multiple files or `-Directory` -> returns `List[object]`

---

## 5. Single-File Parser (`private/parse-markdownfile.ps1`)

### 5.1 Script-Scope Variables

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

### 5.2 Single-Pass Line Scanner

The parser reads all lines via `[System.IO.File]::ReadAllLines()` and processes them in a single pass with 1-based line numbering. Each line is trimmed on the right only (`TrimEnd()`) to preserve leading whitespace needed for indent detection. The scan handles five concerns simultaneously using precompiled regex patterns:

1. **Code block tracking** - `$CodeFencePattern` toggles `$InCodeBlock`; everything inside is opaque
2. **Header extraction** - `$HeaderPattern` matches lines starting with `#` (outside code blocks)
3. **Section accumulation** - Content grouped by headers
4. **List item parsing** - `$ListItemPattern` captures indent, marker, and text; `$MarkerNumPattern` distinguishes numbered from bullet items
5. **Link extraction** - `$MdLinkPattern` and `$PlainUrlPattern` extract both Markdown links and plain URLs

### 5.3 Header Hierarchy (Stack-Based)

```
FOR each header line:
    Pop stack until top header has level < current level
    ParentHeader = stack.Peek() (or null if empty)
    Push current header onto stack
```

Produces a tree via `ParentHeader` back-references.

### 5.4 List Item Nesting (Indent-Based)

**Indent normalization**: `Floor(rawIndent / 2) * 2`

This tolerates 1–3 spaces as a single indent level (common in hand-edited Markdown).

```
FOR each list item line:
    Normalize indent
    Pop stack until top item indent < current indent
    ParentListItem = stack.Peek() (or null if empty)
    Push current item onto stack
    Associate with current section header
```

### 5.5 Link Extraction (Two-Step)

1. Extract Markdown `[text](url)` links via `$MdLinkPattern` regex
2. Strip all captured Markdown links from the line text
3. Extract plain `https://...` URLs from the remainder via `$PlainUrlPattern`

This prevents double-counting a URL that appears in both `[text](url)` and as a plain URL.

### 5.6 Section Accumulation

Content is accumulated into a `StringBuilder` between headers. When a new header is encountered (or EOF), the accumulated content is flushed as a `Section` object. Empty sections (no content and no header) are discarded.

---

## 6. Output Object Schema

```powershell
[PSCustomObject]@{
    FilePath = "path/to/file.md"
    Headers  = List[object]     # Header objects
    Sections = List[object]     # Section objects
    Lists    = List[object]     # All list items (flat)
    Links    = List[object]     # All links (flat)
}
```

### Header Object

| Property | Type | Description |
|---|---|---|
| `Level` | int | Header level (1–6) |
| `Text` | string | Header text (without `#` prefix) |
| `ParentHeader` | object | Reference to parent header (or `$null`) |
| `LineNumber` | int | 1-based line number in source file |

### Section Object

| Property | Type | Description |
|---|---|---|
| `Header` | object | Associated header (or `$null` for content before first header) |
| `Content` | string | Raw text content (newline-joined) |
| `Lists` | `List[object]` | List items within this section |

### List Item Object

| Property | Type | Description |
|---|---|---|
| `Type` | string | `"Bullet"` or `"Numbered"` |
| `Text` | string | Item text (without bullet/number prefix) |
| `Indent` | int | Normalized indent level |
| `ParentListItem` | object | Reference to parent item (or `$null`) |
| `SectionHeader` | object | Reference to containing section's header |

### Link Object

| Property | Type | Description |
|---|---|---|
| `Type` | string | `"MarkdownLink"` or `"PlainUrl"` |
| `Text` | string | Link text (for Markdown links) or `$null` |
| `Url` | string | URL target |

---

## 7. Edge Cases

| Scenario | Behavior |
|---|---|
| Fenced code block with `#` lines | `$InCodeBlock` flag prevents false header detection |
| Inconsistent indentation (1–3 spaces) | Normalized via `Floor(indent/2)*2` |
| URL inside a Markdown link | Extracted once as `MarkdownLink`, not double-counted as `PlainUrl` |
| Content before first header | Captured as a section with `Header = $null` |
| Empty sections | Discarded (`Length > 0 || Header != null` check) |
| Root-level list items | `ParentListItem = $null` |
| `*.markdown` extension | Included in directory scan alongside `*.md` |

---

## 8. Performance Notes

- **File I/O**: Uses `[System.IO.File]::ReadAllLines()` (not `Get-Content`) for speed
- **Directory scanning**: Uses `[System.IO.Directory]::GetFiles()` with `SearchOption.AllDirectories`
- **Regex**: All six patterns (`$MdLinkPattern`, `$PlainUrlPattern`, `$CodeFencePattern`, `$HeaderPattern`, `$ListItemPattern`, `$MarkerNumPattern`) are precompiled once at script scope, avoiding per-line regex compilation overhead
- **Parser script caching**: The parser script text (`private/parse-markdownfile.ps1`) is read from disk once and cached at `$script:CachedParseFileScriptStr`. Subsequent `Get-Markdown` calls reuse the cached string for both sequential invocation (via `[scriptblock]::Create`) and parallel workers (via `AddScript`), avoiding repeated file I/O.
- **StringBuilder**: Used for section content accumulation to avoid string concatenation
- **Parallelism threshold**: 4 files (below this, pool setup overhead exceeds parsing time)

---

## 9. Testing

| Test file | Coverage |
|---|---|
| `tests/get-markdown.Tests.ps1` | File/directory input, parallel vs sequential, return convention |
| `tests/parse-markdownfile.Tests.ps1` | Header hierarchy, list nesting, link extraction, code block handling, indent normalization |

---

## 10. Related Documents

- [SESSIONS.md](SESSIONS.md) - `Get-Session` consumes `Get-Markdown` output for session extraction
- [ENTITIES.md](ENTITIES.md) - `Get-Entity` consumes `Get-Markdown` output for entity parsing
- [MIGRATION.md](MIGRATION.md) - §11 Module Structure lists parser in the non-exported helpers

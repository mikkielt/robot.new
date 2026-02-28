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

## 3. Orchestration (`Get-Markdown`)

### 3.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `File` | string[] | Specific file paths to parse |
| `Directory` | string | Recursive directory scan (defaults to repo root) |

### 3.2 File Collection

- `-File`: Validates each path via `[System.IO.File]::Exists()`
- `-Directory`: Uses `[System.IO.Directory]::GetFiles($Dir, "*.md", AllDirectories)` plus a second pass for `*.markdown`

### 3.3 Parallelism

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

### 3.4 Return Convention

- Single file via `-File` with one path -> returns the parsed object directly (unwrapped)
- Multiple files or `-Directory` -> returns `List[object]`

---

## 4. Single-File Parser (`private/parse-markdownfile.ps1`)

### 4.1 Script-Scope Variables

| Variable | Type | Description |
|---|---|---|
| `$MdLinkPattern` | `[regex]` | `'\[(.+?)\]\((.+?)\)'` - Markdown link capture |
| `$PlainUrlPattern` | `[regex]` | `'https?:\/\/[^\s\)\]]+'` - Plain URL pattern |
| `$HeaderStack` | `Stack[object]` | Maintains header hierarchy |
| `$ListStack` | `Stack[object]` | Maintains list item nesting |
| `$InCodeBlock` | `bool` | Fenced code block toggle |

### 4.2 Single-Pass Line Scanner

The parser reads all lines via `[System.IO.File]::ReadAllLines()` and processes them in a single pass with 1-based line numbering. The scan handles five concerns simultaneously:

1. **Code block tracking** - `` ``` `` toggles `$InCodeBlock`; everything inside is opaque
2. **Header extraction** - Lines starting with `#` (outside code blocks)
3. **Section accumulation** - Content grouped by headers
4. **List item parsing** - Bullet (`-`, `*`) and numbered (`1.`) items with indent tracking
5. **Link extraction** - Both Markdown links and plain URLs

### 4.3 Header Hierarchy (Stack-Based)

```
FOR each header line:
    Pop stack until top header has level < current level
    ParentHeader = stack.Peek() (or null if empty)
    Push current header onto stack
```

Produces a tree via `ParentHeader` back-references.

### 4.4 List Item Nesting (Indent-Based)

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

### 4.5 Link Extraction (Two-Step)

1. Extract Markdown `[text](url)` links via `$MdLinkPattern` regex
2. Strip all captured Markdown links from the line text
3. Extract plain `https://...` URLs from the remainder via `$PlainUrlPattern`

This prevents double-counting a URL that appears in both `[text](url)` and as a plain URL.

### 4.6 Section Accumulation

Content is accumulated into a `StringBuilder` between headers. When a new header is encountered (or EOF), the accumulated content is flushed as a `Section` object. Empty sections (no content and no header) are discarded.

---

## 5. Output Object Schema

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

## 6. Edge Cases

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

## 7. Performance Notes

- **File I/O**: Uses `[System.IO.File]::ReadAllLines()` (not `Get-Content`) for speed
- **Directory scanning**: Uses `[System.IO.Directory]::GetFiles()` with `SearchOption.AllDirectories`
- **Regex**: `$MdLinkPattern` and `$PlainUrlPattern` are compiled once at script scope
- **StringBuilder**: Used for section content accumulation to avoid string concatenation
- **Parallelism threshold**: 4 files (below this, pool setup overhead exceeds parsing time)

---

## 8. Testing

| Test file | Coverage |
|---|---|
| `tests/get-markdown.Tests.ps1` | File/directory input, parallel vs sequential, return convention |
| `tests/parse-markdownfile.Tests.ps1` | Header hierarchy, list nesting, link extraction, code block handling, indent normalization |

---

## 9. Related Documents

- [SESSIONS.md](SESSIONS.md) - `Get-Session` consumes `Get-Markdown` output for session extraction
- [ENTITIES.md](ENTITIES.md) - `Get-Entity` consumes `Get-Markdown` output for entity parsing
- [MIGRATION.md](MIGRATION.md) - §11 Module Structure lists parser in the non-exported helpers

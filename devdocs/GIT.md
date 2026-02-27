# Git Integration — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers `Get-GitChangeLog` (structured Git history extraction) and `Get-RepoRoot` (repository root detection).

---

## 2. `Get-RepoRoot`

Traverses the directory tree upward from the current working directory to find the nearest `.git` folder.

### 2.1 Implementation Details

- Uses `[System.IO.Directory]` and `[System.IO.Path]` (not PowerShell `$PWD`) for **RunspacePool independence** — `$PWD` is not available in worker threads
- Stops at filesystem root (`GetPathRoot()` check)
- Throws if no `.git` directory found in any parent

---

## 3. `Get-GitChangeLog`

Wraps `git log` with structured output parsing. Designed for two use cases:
1. **Full patch mode** (`-p`): Complete diffs with optional content filtering
2. **Lightweight mode** (`-NoPatch`): File status only (`--name-status`)

### 3.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Directory` | string | Directory scope for git log |
| `MinDate` | datetime | `--after` filter |
| `MaxDate` | datetime | `--before` filter |
| `NoPatch` | switch | Lightweight mode (`--name-status` instead of `-p`) |
| `PatchFilter` | string | Regex pattern to filter patch lines (only matching lines + hunk headers stored) |

### 3.2 Process Execution

Uses `[System.Diagnostics.ProcessStartInfo]` with `ArgumentList` (array-based) to safely handle paths containing spaces.

```powershell
$PSI = [System.Diagnostics.ProcessStartInfo]::new()
$PSI.FileName = "git"
$PSI.ArgumentList.Add("log")
$PSI.ArgumentList.Add("--format=COMMIT%x1F%H%x1F%aI%x1F%aN%x1F%aE")
# ... more arguments
$PSI.RedirectStandardOutput = $true
$PSI.RedirectStandardError = $true
$PSI.StandardOutputEncoding = [System.Text.Encoding]::UTF8
```

### 3.3 Async Stderr Capture

Stderr is captured via `.NET event handler` to prevent pipe deadlocks:

```powershell
$ErrorLines = [System.Collections.Generic.List[string]]::new()
$Process.add_ErrorDataReceived({
    param($sender, $e)
    if ($null -ne $e.Data) { $ErrorLines.Add($e.Data) }
})
$Process.BeginErrorReadLine()
```

Without async capture, simultaneous stdout/stderr output can deadlock the process when one buffer fills.

### 3.4 Streaming Parser

Parses `StandardOutput` line-by-line via `ReadLine()` (not `ReadToEnd()`) to avoid materializing large diffs into memory.

**Custom commit format**: Uses `%x1F` (Unit Separator, ASCII 31) as field delimiter:

```
COMMIT%x1F<hash>%x1F<date>%x1F<author>%x1F<email>
```

### 3.5 Commit Parsing (`ConvertFrom-CommitLine`)

Splits on `\x1F` separator. Date parsed via `[System.DateTimeOffset]::Parse()` with `InvariantCulture` to handle ISO 8601 timezone offsets correctly.

### 3.6 File Change Parsing

**Change types**: `A` (Added), `D` (Deleted), `M` (Modified), `R` (Renamed), `C` (Copied).

Rename detection via `--find-renames`. Renames and copies split old/new paths via tab character:

```
R100    old/path.md    new/path.md
```

`RenameScore` is the similarity percentage (e.g., `100` = identical content).

### 3.7 Patch Filtering

Optional `-PatchFilter` parameter compiles a regex and only stores matching patch lines (plus hunk headers starting with `@@`):

```powershell
$FilterRegex = [regex]::new($PatchFilter, [RegexOptions]::Compiled)
# Only store lines where $FilterRegex.IsMatch($Line)
# Always store hunk headers (lines starting with "@@")
```

### 3.8 Encoding

- `StandardOutputEncoding` set to UTF-8
- Git configured with `core.quotepath=false` to prevent escaping of non-ASCII filenames
- `-c core.quotepath=false` passed as argument

---

## 4. Output Objects

### Commit Object

| Property | Type | Description |
|---|---|---|
| `CommitHash` | string | Full SHA-1 hash |
| `CommitDate` | DateTimeOffset | Commit timestamp with timezone |
| `AuthorName` | string | Author display name |
| `AuthorEmail` | string | Author email |
| `Files` | `List[object]` | File change objects |

### File Object

| Property | Type | Description |
|---|---|---|
| `Path` | string | File path (new path for renames) |
| `OldPath` | string | Original path (for renames/copies) |
| `ChangeType` | string | `A`, `D`, `M`, `R`, `C` |
| `RenameScore` | int | Similarity percentage (renames only) |
| `Patch` | `List[string]` | Patch lines (full mode only, filtered if `-PatchFilter`) |

---

## 5. Integration with PU Workflow

`Invoke-PlayerCharacterPUAssignment` uses `Get-GitChangeLog -NoPatch` to optimize session scanning:

```powershell
$ChangedFiles = Get-GitChangeLog -NoPatch -MinDate $MinDate -MaxDate $MaxDate
$MdFiles = $ChangedFiles.Files | Where-Object { $_.Path.EndsWith('.md') }
# Pass only changed .md files to Get-Session -File
```

On failure, the PU workflow falls back to full repository scan via `Get-Session` without `-File`.

---

## 6. Edge Cases

| Scenario | Behavior |
|---|---|
| Paths with spaces | Handled via `ArgumentList` (array-based, not string concatenation) |
| Non-ASCII filenames | `core.quotepath=false` prevents Git escaping |
| Stderr output | Async capture prevents deadlock |
| Empty commit (no files) | Produces commit object with empty `Files` list |
| Rename with similarity < 100% | `RenameScore` reflects partial similarity |
| Large diffs | Stream-parsed line-by-line, never materialized fully into memory |
| Git not available | `Process.Start()` throws; caller must handle |

---

## 7. Testing

| Test file | Coverage |
|---|---|
| `tests/get-gitchangelog.Tests.ps1` | Commit parsing, file change types, rename detection, date filtering |
| `tests/get-reporoot.Tests.ps1` | Directory traversal, error on missing `.git` |

---

## 8. Related Documents

- [PU.md](PU.md) — §3.2 Git Optimization in the PU pipeline
- [MIGRATION.md](MIGRATION.md) — §11 Module Structure

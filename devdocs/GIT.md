# Git Integration - Technical Reference

---

## Scope

This document covers `Get-GitChangeLog` (structured Git history extraction) and `Get-RepoRoot` (repository root detection).

---

## `Get-RepoRoot`

Traverses the directory tree upward from the current working directory to find the nearest `.git` folder.

Uses `[System.IO.Directory]` and `[System.IO.Path]` (not PowerShell `$PWD`) for RunspacePool independence -- `$PWD` is not available in worker threads. Stops at filesystem root (`GetPathRoot()` check). Throws if no `.git` directory found in any parent.

`Get-RepoRoot` caches its result in `$script:CachedRepoRoot` after the first successful traversal. Subsequent calls without an explicit `-ModuleRoot` override return the cached value immediately, avoiding repeated filesystem traversal. The cache is populated as a side effect of the directory walk -- when a `.git` directory is found, the result is stored before returning.

The cache is bypassed when an explicit `-ModuleRoot` parameter is provided (forces fresh traversal from the specified root) or when `$script:DataDirectoryOverride` is set (via `Set-DataDirectory`) -- the override takes absolute priority, returning immediately without consulting or updating the cache.

Cache priority order:
1. `$script:DataDirectoryOverride` (checked first, returns immediately if set)
2. `$script:CachedRepoRoot` (returned when no `-ModuleRoot` override and no data directory override)
3. Fresh traversal (when neither cache nor override applies; result cached for future calls)

`Set-DataDirectory -Reset` does not clear the traversal cache (only the manifest cache). The traversal cache persists for the module session. This is intentional: the traversal result is deterministic for a given module location and does not change within a session.

If no `.git` directory is found in any parent of the module directory, `Get-RepoRoot` checks whether the module directory itself contains a `.git` directory or file (standalone checkout, e.g., CI environments). If found, the module root is treated as the repository root and cached. Otherwise, throws.

`Get-ParentRepoRoot` is a companion function for submodule environments. It walks upward from `Get-RepoRoot` past the submodule `.git` boundary to find the enclosing parent repository root. It starts from `Get-RepoRoot` result (the submodule root), moves one directory up to exit the submodule, and continues upward until a `.git` directory is found (the parent repo root). It is not exported by the module (non Verb-Noun name) and must be dot-sourced directly for testing.

---

## `Get-GitChangeLog`

Wraps `git log` with structured output parsing. Designed for two use cases: full patch mode (`-p`) with complete diffs and optional content filtering, and lightweight mode (`-NoPatch`) with file status only (`--name-status`).

Parameters:

| Parameter | Type | Description |
|---|---|---|
| `Directory` | string | Directory scope for git log |
| `MinDate` | datetime | `--after` filter |
| `MaxDate` | datetime | `--before` filter |
| `NoPatch` | switch | Lightweight mode (`--name-status` instead of `-p`) |
| `PatchFilter` | string | Regex pattern to filter patch lines (only matching lines + hunk headers stored) |

Process execution uses `[System.Diagnostics.ProcessStartInfo]` with `ArgumentList` (array-based) to safely handle paths containing spaces.

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

Stderr is captured via .NET event handler to prevent pipe deadlocks:

```powershell
$ErrorLines = [System.Collections.Generic.List[string]]::new()
$Process.add_ErrorDataReceived({
    param($sender, $e)
    if ($null -ne $e.Data) { $ErrorLines.Add($e.Data) }
})
$Process.BeginErrorReadLine()
```

Without async capture, simultaneous stdout/stderr output can deadlock the process when one buffer fills.

The streaming parser processes `StandardOutput` line-by-line via `ReadLine()` (not `ReadToEnd()`) to avoid materializing large diffs into memory.

Custom commit format uses `%x1F` (Unit Separator, ASCII 31) as field delimiter:

```
COMMIT%x1F<hash>%x1F<date>%x1F<author>%x1F<email>
```

`ConvertFrom-CommitLine` splits on `\x1F` separator. Date is parsed via `[System.DateTimeOffset]::Parse()` with `InvariantCulture` to handle ISO 8601 timezone offsets correctly.

Change types: `A` (Added), `D` (Deleted), `M` (Modified), `R` (Renamed), `C` (Copied). Rename detection uses `--find-renames`. Renames and copies split old/new paths via tab character:

```
R100    old/path.md    new/path.md
```

`RenameScore` is the similarity percentage (e.g., `100` = identical content).

Optional `-PatchFilter` parameter compiles a regex and only stores matching patch lines (plus hunk headers starting with `@@`):

```powershell
$FilterRegex = [regex]::new($PatchFilter, [RegexOptions]::Compiled)
# Only store lines where $FilterRegex.IsMatch($Line)
# Always store hunk headers (lines starting with "@@")
```

Encoding: `StandardOutputEncoding` is set to UTF-8. Git is configured with `core.quotepath=false` to prevent escaping of non-ASCII filenames. `-c core.quotepath=false` is passed as argument.

---

## Output Objects

Commit object:

| Property | Type | Description |
|---|---|---|
| `CommitHash` | string | Full SHA-1 hash |
| `CommitDate` | DateTimeOffset | Commit timestamp with timezone |
| `AuthorName` | string | Author display name |
| `AuthorEmail` | string | Author email |
| `Files` | `List[object]` | File change objects |

File object:

| Property | Type | Description |
|---|---|---|
| `Path` | string | File path (new path for renames) |
| `OldPath` | string | Original path (for renames/copies) |
| `ChangeType` | string | `A`, `D`, `M`, `R`, `C` |
| `RenameScore` | int | Similarity percentage (renames only) |
| `Patch` | `List[string]` | Patch lines (full mode only, filtered if `-PatchFilter`) |

---

## Integration with PU Workflow

`Invoke-PlayerCharacterPUAssignment` uses `Get-GitChangeLog -NoPatch` to optimize session scanning:

```powershell
$ChangedFiles = Get-GitChangeLog -NoPatch -MinDate $MinDate -MaxDate $MaxDate
$MdFiles = $ChangedFiles.Files | Where-Object { $_.Path.EndsWith('.md') }
# Pass only changed .md files to Get-Session -File
```

On failure, the PU workflow falls back to full repository scan via `Get-Session` without `-File`.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Paths with spaces | Handled via `ArgumentList` (array-based) |
| Non-ASCII filenames | `core.quotepath=false` prevents Git escaping |
| Stderr output | Async capture prevents deadlock |
| Empty commit (no files) | Produces commit object with empty `Files` list |
| Rename with similarity < 100% | `RenameScore` reflects partial similarity |
| Large diffs | Stream-parsed line-by-line, never materialized fully into memory |
| Git not available | `Process.Start()` throws; caller must handle |
| `Get-RepoRoot` called repeatedly | Returns cached `$script:CachedRepoRoot` after first successful traversal |
| `Get-RepoRoot -ModuleRoot` with explicit path | Bypasses cache, performs fresh traversal from specified root |
| `$script:DataDirectoryOverride` set | `Get-RepoRoot` returns override path immediately, no traversal or cache |
| Module directory is standalone git repo | `.git` check on module root succeeds; used as repo root (CI fallback) |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/get-gitchangelog.Tests.ps1` | Commit parsing, file change types, rename detection, date filtering |
| `tests/get-reporoot.Tests.ps1` | Directory traversal, error on missing `.git`, `Get-ParentRepoRoot` submodule traversal |

---

## Related Documents

- [PU.md](PU.md) - Git Optimization in the PU pipeline
- [MIGRATION.md](MIGRATION.md) - Module Structure

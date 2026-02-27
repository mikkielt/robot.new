# Testing Guide — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the test infrastructure: Pester conventions, test file organization, fixture design, loading patterns, mock strategies, shared helpers, and how to add tests for new functions.

---

## 2. Prerequisites

- **Pester v5.0+** (the only external dependency)
- **PowerShell 5.1** or **PowerShell Core 7.0+**

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

---

## 3. Running Tests

```powershell
# From the .robot.new/ directory:

# Run all tests
Invoke-Pester ./tests/ -Output Detailed

# Run a single test file
Invoke-Pester ./tests/get-entity.Tests.ps1 -Output Detailed

# Run with configuration file
Invoke-Pester -Configuration (Import-PowerShellDataFile ./tests/.pesterconfig.psd1)

# Run with code coverage
Invoke-Pester ./tests/ -Output Detailed -CodeCoverage ./*.ps1
```

### 3.1 Configuration (`.pesterconfig.psd1`)

```powershell
@{
    Run = @{ Path = './tests'; Exit = $true }
    Output = @{ Verbosity = 'Detailed' }
    TestResult = @{
        Enabled    = $true
        OutputPath = './tests/test-results.xml'
        OutputFormat = 'NUnitXml'
    }
    CodeCoverage = @{
        Enabled    = $false
        Path       = @('./*.ps1')
        OutputPath = './tests/coverage.xml'
    }
}
```

---

## 4. File Organization

### 4.1 Naming Convention

Test files mirror source files with a `.Tests.ps1` suffix:

```
get-entity.ps1           →  tests/get-entity.Tests.ps1
charfile-helpers.ps1     →  tests/charfile-helpers.Tests.ps1
```

`Robot.Tests.ps1` validates module-level behavior (loading, exports).

### 4.2 Directory Structure

```
tests/
├── .pesterconfig.psd1              # Pester configuration
├── TestHelpers.ps1                 # Shared utilities
├── Robot.Tests.ps1                 # Module-level tests
├── get-entity.Tests.ps1            # Per-function tests
├── get-entitystate.Tests.ps1
├── get-session.Tests.ps1
├── ... (one per source file)
└── fixtures/
    ├── Gracze.md                   # Player database fixture
    ├── entities.md                 # Entity registry fixture
    ├── entities-100-ent.md         # Override file (primacy 100)
    ├── entities-200-ent.md         # Override file (primacy 200)
    ├── sessions-gen1.md            # Gen1 format sessions
    ├── sessions-gen2.md            # Gen2 format sessions
    ├── sessions-gen3.md            # Gen3 format sessions
    ├── sessions-gen4.md            # Gen4 format sessions
    ├── sessions-duplicate.md       # Deduplication test data
    ├── sessions-zmiany.md          # Zmiany override test data
    ├── sessions-failed.md          # Malformed dates with valid content
    ├── minimal-entity.md           # Minimal entity for write tests
    ├── pu-sessions.md              # Pre-processed session history
    ├── local.config.psd1           # Config fixture
    └── templates/
        ├── player-character-file.md.template
        └── player-entry.md.template
```

---

## 5. Shared Helpers (`TestHelpers.ps1`)

### 5.1 Path Variables

```powershell
$script:ModuleRoot   = # .robot.new/ (parent of tests directory)
$script:FixturesRoot = # tests/fixtures/
$script:TempRoot     = # GUID-based temp directory (per test run)
```

### 5.2 Functions

| Function | Purpose |
|---|---|
| `New-TestTempDir` | Creates a GUID-based disposable temp directory for write tests |
| `Remove-TestTempDir` | Cleans up the temp directory (called in `AfterAll`) |
| `Copy-FixtureToTemp` | Copies fixture files to temp, with optional rename and parent dir creation |
| `Import-RobotModule` | Imports `robot.psd1 -Force` |
| `Import-RobotHelpers` | Dot-sources helper files by name from module root |
| `Write-TestFile` | Writes UTF-8 no-BOM content to a file path |

---

## 6. Loading Patterns

### Pattern A — Exported Functions

For testing exported `Verb-Noun` functions:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

### Pattern B — Helpers in Function Files

For testing internal helper functions within a function file:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . "$script:ModuleRoot/get-entity.ps1"  # Access internal helpers
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

### Pattern C — Standalone Helper Files

For testing standalone helper scripts (non-Verb-Noun):

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Import-RobotHelpers 'entity-writehelpers.ps1'
    Mock Get-RepoRoot { return $script:TempRoot }
}
```

### Pattern D — Parser (Special)

`parse-markdownfile.ps1` is invoked via `&` operator (not dot-sourced) because it has a top-level `param()`:

```powershell
$Result = & "$script:ModuleRoot/parse-markdownfile.ps1" $FixturePath
```

---

## 7. Test Structure Convention

Every test file follows the same skeleton:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    # Loading strategy (Pattern A, B, C, or D)
}

Describe 'FunctionName' {
    Context 'scenario group' {
        It 'specific behaviour assertion' {
            # Arrange → Act → Assert
        }
    }
}

AfterAll {
    Remove-TestTempDir   # Only in files that create temp dirs
}
```

---

## 8. Mock Patterns

### 8.1 Universal Mocks

`Get-RepoRoot` is mocked in almost every test file:
- **Read tests**: Returns `$script:FixturesRoot` (reads fixtures as if they were the repository)
- **Write tests**: Returns `$script:TempRoot` (writes to disposable temp directory)

### 8.2 Common Mocks

| Mock target | Typical replacement |
|---|---|
| `Get-RepoRoot` | `$script:FixturesRoot` or `$script:TempRoot` |
| `Get-GitChangeLog` | Synthetic commit objects with controlled file lists |
| `Send-DiscordMessage` | Success response object |
| `Get-AdminConfig` | Hashtable with fixture paths |
| `Get-AdminHistoryEntries` | Empty or pre-populated `HashSet[string]` |

### 8.3 What Is NOT Mocked

- `.NET static methods** (`[System.IO.File]::ReadAllLines`, etc.) — use real fixtures instead
- `Get-Markdown` — operates on real fixture files
- `Get-Entity` / `Get-Player` — typically operate on fixture data

### 8.4 Write Test Pattern

```powershell
# 1. Copy fixture to temp
Copy-FixtureToTemp 'minimal-entity.md' -As 'entities.md'

# 2. Mock Get-RepoRoot to point to temp
Mock Get-RepoRoot { return $script:TempRoot }

# 3. Execute the write operation
Set-Player -Name "TestPlayer" -MargonemID "12345"

# 4. Read back and verify
$Lines = [System.IO.File]::ReadAllLines("$script:TempRoot/entities.md")
$Lines | Should -Contain "    - @margonemid: 12345"
```

---

## 9. Fixture Design

### 9.1 Principles

- **Synthetic, controlled data** — no dependency on actual repository content
- **Minimal but complete** — enough data to exercise all code paths
- **Cross-referencing** — fixtures reference each other (e.g., `Gracze.md` players match `entities.md` entries)

### 9.2 Key Fixtures

| Fixture | Contents | Tests |
|---|---|---|
| `Gracze.md` | 3 players with full PU data, character variations, MargonemID, webhooks | `get-player`, `get-playercharacter` |
| `entities.md` | NPCs, orgs, locations (with hierarchy), Gracz/Postać (Gracz) entries | `get-entity`, `get-entitystate` |
| `entities-100-ent.md` | Override entries (primacy 100) | Multi-file merge, override primacy |
| `entities-200-ent.md` | Override entries (primacy 200) | Multi-file merge |
| `sessions-gen{1,2,3,4}.md` | Session metadata in each format generation | `get-session`, format detection |
| `sessions-duplicate.md` | Identical headers for deduplication | `Merge-SessionGroup` |
| `sessions-zmiany.md` | Zmiany blocks with `@tag` overrides | `get-entitystate` |
| `sessions-failed.md` | Malformed dates with valid PU content | `test-playercharacterpuassignment` |
| `pu-sessions.md` | Pre-processed session history | History deduplication |

---

## 10. Testing Strategies

### 10.1 Temporal Filtering

Extensive date-range testing for validity windows. Fixtures include entities with various `(YYYY-MM:YYYY-MM)` ranges to verify `Test-TemporalActivity`, `Get-LastActiveValue`, and `Get-AllActiveValues`.

### 10.2 Merge Logic

Multiple fixture files (`entities.md`, `entities-100-ent.md`, `entities-200-ent.md`) test override precedence and alias merging across files.

### 10.3 Polish Declension

`resolve-name.Tests.ps1` includes test cases for suffix stripping and stem alternation with Polish morphological forms (e.g., `"Solmyra"` → `"Solmyr"`, `"Vidominie"` → `"Vidomina"`).

### 10.4 Format Generation

Separate fixture files per format generation ensure all four formats are tested independently for parsing, metadata extraction, and format upgrade paths.

---

## 11. Adding Tests for New Functions

1. **Create test file**: `tests/<function-name>.Tests.ps1`
2. **Choose loading pattern**: A (exported), B (internal helpers), C (standalone helper), or D (parser)
3. **Create fixtures** (if needed): Add to `tests/fixtures/` with minimal but complete data
4. **Follow skeleton**: `BeforeAll` → `Describe` → `Context` → `It` → `AfterAll`
5. **Mock `Get-RepoRoot`**: Point to fixtures (read) or temp dir (write)
6. **Use temp dirs for writes**: `New-TestTempDir` + `Copy-FixtureToTemp` + `Remove-TestTempDir`
7. **Verify with assertions**: Use Pester's `Should` syntax

---

## 12. Related Documents

- [SYNTAX.md](SYNTAX.md) — Code style conventions (applies to test code too)
- [MIGRATION.md](MIGRATION.md) — §15 Testing section lists test coverage per area
- [PU.md](PU.md) — §15 Testing lists PU-specific test files

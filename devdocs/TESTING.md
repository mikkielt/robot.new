# Testing Guide - Technical Reference

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
Invoke-Pester ./tests/ -Output Detailed -CodeCoverage ./public/*.ps1,./public/**/*.ps1,./private/*.ps1
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
        Path       = @('./public/*.ps1', './public/**/*.ps1', './private/*.ps1')
        OutputPath = './tests/coverage.xml'
    }
}
```

---

## 4. File Organization

### 4.1 Naming Convention

Test files mirror source files with a `.Tests.ps1` suffix:

```
public/get-entity.ps1                ->  tests/get-entity.Tests.ps1
private/charfile-helpers.ps1         ->  tests/charfile-helpers.Tests.ps1
```

`Robot.Tests.ps1` validates module-level behavior (loading, exports).

### 4.2 Directory Structure

```
tests/
├── .pesterconfig.psd1                              # Pester configuration
├── TestHelpers.ps1                                 # Shared utilities
├── Robot.Tests.ps1                                 # Module-level tests
│
│   # Infrastructure & config
├── admin-config.Tests.ps1
├── admin-state.Tests.ps1
├── get-reporoot.Tests.ps1
├── get-markdown.Tests.ps1
├── parse-markdownfile.Tests.ps1
│
│   # Entity data access
├── get-entity.Tests.ps1
├── get-entitystate.Tests.ps1
├── get-nameindex.Tests.ps1
├── resolve-name.Tests.ps1
│
│   # Entity CRUD
├── new-entity.Tests.ps1
├── set-entity.Tests.ps1
├── remove-entity.Tests.ps1
├── entity-writehelpers.Tests.ps1
├── entity-status.Tests.ps1
├── przedmiot-entity.Tests.ps1
│
│   # Currency
├── new-currencyentity.Tests.ps1
├── set-currencyentity.Tests.ps1
├── get-currencyentity.Tests.ps1
├── remove-currencyentity.Tests.ps1
├── currency-entity.Tests.ps1
├── currency-helpers.Tests.ps1
├── get-currencyreport.Tests.ps1
├── test-currencyreconciliation.Tests.ps1
│
│   # Sessions
├── get-session.Tests.ps1
├── set-session.Tests.ps1
├── new-session.Tests.ps1
├── format-sessionblock.Tests.ps1
├── resolve-narrator.Tests.ps1
├── get-sessionlog.Tests.ps1
├── invoke-sessionlogfetch.Tests.ps1
├── test-sessionintegrity.Tests.ps1
│
│   # Player & character
├── get-player.Tests.ps1
├── get-playercharacter.Tests.ps1
├── get-playercharacter-state.Tests.ps1
├── new-player.Tests.ps1
├── new-playercharacter.Tests.ps1
├── set-player.Tests.ps1
├── set-playercharacter.Tests.ps1
├── set-playercharacter-charfile.Tests.ps1
├── remove-playercharacter.Tests.ps1
├── charfile-helpers.Tests.ps1
│
│   # PU & workflow
├── get-newplayercharacterpucount.Tests.ps1
├── invoke-playercharacterpuassignment.Tests.ps1
├── test-playercharacterpuassignment.Tests.ps1
├── get-gitchangelog.Tests.ps1
├── send-discordmessage.Tests.ps1
│
│   # Reporting & auditing
├── get-changelog.Tests.ps1
├── get-entityhistory.Tests.ps1
├── get-notificationlog.Tests.ps1
├── get-puassignmentlog.Tests.ps1
├── get-transactionledger.Tests.ps1
├── get-narratorreport.Tests.ps1
├── get-namedloglocationreport.Tests.ps1
│
│   # CLI
├── cli-fuzzy.Tests.ps1
├── cli-help.Tests.ps1
├── cli-primitives.Tests.ps1
├── cli-registry.Tests.ps1
├── cli-wizard.Tests.ps1
│
│   # Plugins & migration
├── plugin-system.Tests.ps1
├── narrator-normalization.Tests.ps1
│
└── fixtures/
    │   # Player database
    ├── Gracze.md                                   # Standard player DB
    ├── Gracze-brak-pu.md                           # Player DB with missing PU
    ├── Gracze-many-characters.md                   # Player DB with many characters
    ├── Gracze-no-characters.md                     # Player DB with no characters
    │
    │   # Entity registry
    ├── entities.md                                 # Standard entity registry
    ├── entities-100-ent.md                         # Override file (primacy 100)
    ├── entities-200-ent.md                         # Override file (primacy 200)
    ├── entities-brak-pu.md                         # Missing PU scenario
    ├── entities-changes.md                         # Zmiany test data
    ├── entities-currency-crud.md                   # Currency CRUD (3 entities)
    ├── entities-currency-edge.md                   # Currency edge cases
    ├── entities-currency-update.md                 # Currency update scenarios
    ├── entities-deep-locations.md                  # Nested location hierarchy
    ├── entities-drzwi-typ.md                       # @drzwi/@typ tag tests
    ├── entities-duplicate-names.md                 # Duplicate name handling
    ├── entities-empty-sections.md                  # Empty section headers
    ├── entities-generic-crud.md                    # Generic CRUD (all 6 types)
    ├── entities-many-aliases.md                    # Multiple aliases per entity
    ├── entities-many-characters.md                 # Many characters scenario
    ├── entities-many-groups.md                     # Many groups scenario
    ├── entities-multi-transfer.md                  # Multiple transfers
    ├── entities-multiline-info.md                  # Multi-line entity info
    ├── entities-overlapping-temporal.md            # Overlapping temporal ranges
    ├── entities-przedmiot-existing.md              # Pre-existing Przedmiot entries
    ├── entities-remove-pc.md                       # Character removal test
    ├── entities-status-basic.md                    # Basic status transitions
    ├── entities-status-default.md                  # Default status handling
    ├── entities-status-przedmiot.md                # Przedmiot status handling
    ├── entities-status-transitions.md              # Complex status transitions
    ├── entities-unicode-names.md                   # Unicode entity names
    ├── entities-unresolved.md                      # Unresolved references
    │
    │   # Session fixtures
    ├── sessions-gen1.md                            # Gen1 format
    ├── sessions-gen2.md                            # Gen2 format
    ├── sessions-gen2-multi-loc.md                  # Gen2 with multiple locations
    ├── sessions-gen3.md                            # Gen3 format
    ├── sessions-gen4.md                            # Gen4 format
    ├── sessions-gen4-full.md                       # Gen4 with all metadata tags
    ├── sessions-changes.md                         # Session with Zmiany block
    ├── sessions-co-narrator.md                     # Co-narrated sessions
    ├── sessions-code-fence.md                      # Code fences in content
    ├── sessions-date-range.md                      # Multi-day date ranges
    ├── sessions-deep-zmiany.md                     # Complex nested Zmiany
    ├── sessions-duplicate.md                       # Deduplication test data
    ├── sessions-empty-body.md                      # Sessions with empty body
    ├── sessions-failed.md                          # Malformed dates
    ├── sessions-many.md                            # Large session count
    ├── sessions-multi-transfer.md                  # Multiple @Transfer lines
    ├── sessions-narrator-override.md               # Narrator mapping overrides
    ├── sessions-no-metadata.md                     # Sessions without metadata
    ├── sessions-unicode.md                         # Unicode in session content
    ├── sessions-unresolved.md                      # Unresolved references
    ├── sessions-zmiany.md                          # Zmiany override test data
    ├── sessions-integrity/                         # Session integrity check fixtures
    │   ├── base.md
    │   ├── duplicate-pu.md
    │   ├── format-anomaly.md
    │   ├── future-dated.md
    │   ├── malformed.md
    │   └── modified.md
    │
    │   # Character files
    ├── charfile-anglebracket.md                    # Angle bracket edge case
    ├── charfile-empty.md                           # Empty character file
    ├── charfile-empty-reputation.md                # Empty reputation section
    ├── charfile-full.md                            # Full character file
    ├── charfile-missing-sections.md                # Missing sections
    ├── charfile-multilinestan.md                   # Multi-line stan
    ├── charfile-rich.md                            # Rich content character
    ├── charfile-set-pc.md                          # Set-PlayerCharacter test data
    ├── charfile-unicode.md                         # Unicode in character data
    │
    │   # Other
    ├── minimal-entity.md                           # Minimal entity for writes
    ├── pu-sessions.md                              # PU session history
    ├── pu-sessions-sample.md                       # Sample PU history
    ├── local.config.psd1                           # Config fixture
    ├── log-chatlog.txt                             # Chat log fixture
    ├── log-prose.txt                               # Prose log fixture
    │
    └── templates/                                  # Template subset (2 of 8)
        ├── player-character-file.md.template       # Character file skeleton
        └── player-entry.md.template                # Character entry in entities.md
```

> **Note**: The `templates/` fixture directory contains only the 2 templates used by write tests (`New-PlayerCharacter`). The remaining 6 production templates (in the module's `templates/` dir) are not duplicated; tests that need them reference the module root directly.

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

### Pattern A - Exported Functions

For testing exported `Verb-Noun` functions:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

### Pattern B - Helpers in Function Files

For testing internal helper functions within a function file:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . "$script:ModuleRoot/public/get-entity.ps1"  # Access internal helpers (adjust path for subdirectory functions)
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

### Pattern C - Standalone Helper Files

For testing standalone helper scripts (non-Verb-Noun):

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Import-RobotHelpers 'private/entity-writehelpers.ps1'
    Mock Get-RepoRoot { return $script:TempRoot }
}
```

### Pattern D - Parser (Special)

`private/parse-markdownfile.ps1` is invoked via `&` operator (not dot-sourced) because it has a top-level `param()`:

```powershell
$Result = & "$script:ModuleRoot/private/parse-markdownfile.ps1" $FixturePath
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
            # Arrange -> Act -> Assert
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

- `.NET static methods** (`[System.IO.File]::ReadAllLines`, etc.) - use real fixtures instead
- `Get-Markdown` - operates on real fixture files
- `Get-Entity` / `Get-Player` - typically operate on fixture data

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

- **Synthetic, controlled data** - no dependency on actual repository content
- **Minimal but complete** - enough data to exercise all code paths
- **Cross-referencing** - fixtures reference each other (e.g., `Gracze.md` players match `entities.md` entries)

### 9.2 Key Fixtures

| Fixture | Contents | Tests |
|---|---|---|
| `Gracze.md` | 3 players with full PU data, character variations, MargonemID, webhooks | `get-player`, `get-playercharacter` |
| `entities.md` | NPCs, orgs, locations (with hierarchy), Gracz/Postać entries | `get-entity`, `get-entitystate` |
| `entities-100-ent.md` | Override entries (primacy 100) | Multi-file merge, override primacy |
| `entities-200-ent.md` | Override entries (primacy 200) | Multi-file merge |
| `entities-generic-crud.md` | All 6 entity types populated | `new-entity`, `set-entity`, `remove-entity` |
| `entities-currency-crud.md` | 3 currency entities with denominations | `new-currencyentity`, `set-currencyentity`, `remove-currencyentity` |
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

`resolve-name.Tests.ps1` includes test cases for suffix stripping and stem alternation with Polish morphological forms (e.g., `"Solmyra"` -> `"Solmyr"`, `"Vidominie"` -> `"Vidomina"`).

### 10.4 Format Generation

Separate fixture files per format generation ensure all four formats are tested independently for parsing, metadata extraction, and format upgrade paths.

---

## 11. Adding Tests for New Functions

1. **Create test file**: `tests/<function-name>.Tests.ps1`
2. **Choose loading pattern**: A (exported), B (internal helpers), C (standalone helper), or D (parser)
3. **Create fixtures** (if needed): Add to `tests/fixtures/` with minimal but complete data
4. **Follow skeleton**: `BeforeAll` -> `Describe` -> `Context` -> `It` -> `AfterAll`
5. **Mock `Get-RepoRoot`**: Point to fixtures (read) or temp dir (write)
6. **Use temp dirs for writes**: `New-TestTempDir` + `Copy-FixtureToTemp` + `Remove-TestTempDir`
7. **Verify with assertions**: Use Pester's `Should` syntax

---

## 12. Related Documents

- [SYNTAX.md](SYNTAX.md) - Code style conventions (applies to test code too)
- [MIGRATION.md](MIGRATION.md) - §15 Testing section lists test coverage per area
- [PU.md](PU.md) - §15 Testing lists PU-specific test files

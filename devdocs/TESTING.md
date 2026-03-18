# Testing Guide - Technical Reference

---

## Scope

This document covers the test infrastructure: Pester conventions, test file organization, fixture design, loading patterns, mock strategies, shared helpers, and how to add tests for new functions.

---

## Prerequisites

Pester v5.0+ is the only external dependency. PowerShell 5.1 or PowerShell Core 7.0+ is required.

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

---

## Running Tests

```powershell
# From the .robot.powershell/ directory:

# Run all tests
Invoke-Pester ./tests/ -Output Detailed

# Run a single test file
Invoke-Pester ./tests/get-entity.Tests.ps1 -Output Detailed

# Run with configuration file
Invoke-Pester -Configuration (Import-PowerShellDataFile ./tests/.pesterconfig.psd1)

# Run with code coverage
Invoke-Pester ./tests/ -Output Detailed -CodeCoverage ./public/*.ps1,./public/**/*.ps1,./private/*.ps1
```

Configuration (`.pesterconfig.psd1`):

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

## File Organization

Test files mirror source files with a `.Tests.ps1` suffix:

```
public/get-entity.ps1                ->  tests/get-entity.Tests.ps1
private/charfile-helpers.ps1         ->  tests/charfile-helpers.Tests.ps1
```

Directory structure:

```
tests/
+-- .pesterconfig.psd1                              # Pester configuration
+-- TestHelpers.ps1                                 # Shared utilities
|
|   # Infrastructure & config
+-- admin-config.Tests.ps1
+-- admin-state.Tests.ps1
+-- get-reporoot.Tests.ps1
+-- get-markdown.Tests.ps1
+-- parse-markdownfile.Tests.ps1
+-- operation-context.Tests.ps1
+-- argument-completers.Tests.ps1
|
|   # Entity data access
+-- get-entity.Tests.ps1
+-- get-entitystate.Tests.ps1
+-- get-nameindex.Tests.ps1
+-- resolve-name.Tests.ps1
+-- get-entity-mapa.Tests.ps1
|
|   # Entity CRUD
+-- new-entity.Tests.ps1
+-- set-entity.Tests.ps1
+-- remove-entity.Tests.ps1
+-- entity-writehelpers.Tests.ps1
+-- entity-status.Tests.ps1
+-- przedmiot-entity.Tests.ps1
+-- resolve-entity.Tests.ps1
|
|   # Currency
+-- new-currencyentity.Tests.ps1
+-- set-currencyentity.Tests.ps1
+-- get-currencyentity.Tests.ps1
+-- remove-currencyentity.Tests.ps1
+-- currency-entity.Tests.ps1
+-- currency-helpers.Tests.ps1
+-- get-currencyreport.Tests.ps1
+-- test-currencyreconciliation.Tests.ps1
|
|   # Item
+-- get-itementity.Tests.ps1
+-- transfer-items.Tests.ps1
|
|   # Sessions
+-- get-session.Tests.ps1
+-- set-session.Tests.ps1
+-- new-session.Tests.ps1
+-- add-session.Tests.ps1
+-- format-sessionblock.Tests.ps1
+-- resolve-narrator.Tests.ps1
+-- session-parsehelpers.Tests.ps1
+-- session-parsehelpers-local-logs.Tests.ps1
+-- session-decomposehelpers-localization.Tests.ps1
+-- get-sessionlog.Tests.ps1
+-- invoke-sessionlogfetch.Tests.ps1
+-- parse-logcontent.Tests.ps1
+-- test-sessionintegrity.Tests.ps1
|
|   # Player & character
+-- get-player.Tests.ps1
+-- get-playercharacter.Tests.ps1
+-- get-playercharacter-state.Tests.ps1
+-- new-player.Tests.ps1
+-- new-playercharacter.Tests.ps1
+-- set-player.Tests.ps1
+-- set-playercharacter.Tests.ps1
+-- set-playercharacter-charfile.Tests.ps1
+-- remove-playercharacter.Tests.ps1
+-- charfile-helpers.Tests.ps1
|
|   # PU & workflow
+-- get-newplayercharacterpucount.Tests.ps1
+-- invoke-playercharacterpuassignment.Tests.ps1
+-- test-playercharacterpuassignment.Tests.ps1
+-- get-gitchangelog.Tests.ps1
+-- send-discordmessage.Tests.ps1
|
|   # Discord
+-- discord-state.Tests.ps1
+-- get-discorddeliverylog.Tests.ps1
|
|   # Reporting & auditing
+-- get-changelog.Tests.ps1
+-- get-entityhistory.Tests.ps1
+-- get-entitydelta.Tests.ps1
+-- get-notificationlog.Tests.ps1
+-- get-puassignmentlog.Tests.ps1
+-- get-transactionledger.Tests.ps1
+-- get-narratorreport.Tests.ps1
+-- get-namedloglocationreport.Tests.ps1
+-- get-dormancyreport.Tests.ps1
+-- get-sessionfrequencytrend.Tests.ps1
|
|   # Economy
+-- get-economicsnapshot.Tests.ps1
+-- get-economictimeline.Tests.ps1
+-- get-materializationreport.Tests.ps1
|
|   # CLI
+-- cli-fuzzy.Tests.ps1
+-- cli-help.Tests.ps1
+-- cli-primitives.Tests.ps1
+-- cli-registry.Tests.ps1
+-- cli-wizard.Tests.ps1
+-- cli-engine.Tests.ps1
+-- cli-buffer.Tests.ps1
+-- cli-components.Tests.ps1
+-- cli-input.Tests.ps1
+-- cli-progress.Tests.ps1
|
|   # Session graph
+-- get-sessiongraph.Tests.ps1
+-- set-sessiongraph.Tests.ps1
+-- test-sessiongraphintegrity.Tests.ps1
+-- get-entitysessionprofile.Tests.ps1
+-- get-narratorsessionprofile.Tests.ps1
+-- compare-sessionparticipation.Tests.ps1
+-- get-sessiongraphleaderboard.Tests.ps1
|
|   # Location graph & CRUD
+-- koordynaty-parsing.Tests.ps1
+-- get-namedlocationreport.Tests.ps1
+-- get-locationgraph.Tests.ps1
+-- get-locationgraph-integration.Tests.ps1
+-- get-locationentity.Tests.ps1
+-- new-locationentity.Tests.ps1
+-- set-locationentity.Tests.ps1
+-- new-mapentity.Tests.ps1
+-- seasonal-and-location.Tests.ps1
+-- mapa-entity.Tests.ps1
|
|   # API
+-- export-staticapi.Tests.ps1
|
|   # Plugins & migration
+-- plugin-system.Tests.ps1
+-- narrator-normalization.Tests.ps1
+-- migration-phase4-log-download.Tests.ps1
+-- migration-phase5-location-import.Tests.ps1
+-- migration-phase6-door-inference.Tests.ps1
|
+-- fixtures/
    |   # Player database
    +-- Gracze.md                                   # Standard player DB
    +-- Gracze-brak-pu.md                           # Player DB with missing PU
    +-- Gracze-many-characters.md                   # Player DB with many characters
    +-- Gracze-no-characters.md                     # Player DB with no characters
    |
    |   # Entity registry
    +-- entities.md                                 # Standard entity registry
    +-- entities-100-ent.md                         # Override file (primacy 100)
    +-- entities-200-ent.md                         # Override file (primacy 200)
    +-- entities-brak-pu.md                         # Missing PU scenario
    +-- entities-changes.md                         # Zmiany test data
    +-- entities-currency-crud.md                   # Currency CRUD (3 entities)
    +-- entities-currency-edge.md                   # Currency edge cases
    +-- entities-currency-update.md                 # Currency update scenarios
    +-- entities-deep-locations.md                  # Nested location hierarchy
    +-- entities-drzwi-typ.md                       # @drzwi/@typ tag tests
    +-- entities-duplicate-names.md                 # Duplicate name handling
    +-- entities-empty-sections.md                  # Empty section headers
    +-- entities-generic-crud.md                    # Generic CRUD (all 6 types)
    +-- entities-many-aliases.md                    # Multiple aliases per entity
    +-- entities-many-characters.md                 # Many characters scenario
    +-- entities-many-groups.md                     # Many groups scenario
    +-- entities-multi-transfer.md                  # Multiple transfers
    +-- entities-multiline-info.md                  # Multi-line entity info
    +-- entities-overlapping-temporal.md            # Overlapping temporal ranges
    +-- entities-przedmiot-existing.md              # Pre-existing Przedmiot entries
    +-- entities-remove-pc.md                       # Character removal test
    +-- entities-status-basic.md                    # Basic status transitions
    +-- entities-status-default.md                  # Default status handling
    +-- entities-status-przedmiot.md                # Przedmiot status handling
    +-- entities-status-transitions.md              # Complex status transitions
    +-- entities-unicode-names.md                   # Unicode entity names
    +-- entities-unresolved.md                      # Unresolved references
    +-- entities-item-transfer.md                   # Item transfer scenarios
    +-- entities-location-crud.md                   # Location CRUD operations
    +-- entities-location-graph.md                  # Location graph test data
    +-- entities-mapa.md                            # Mapa entity test data
    +-- entities-seasonal.md                        # Seasonal temporal scoping
    +-- entities-slug.md                            # @slug tag test data
    +-- entities-temporal-plik.md                   # Temporal @plik tag test data
    |
    |   # Session fixtures
    +-- sessions-gen1.md                            # Gen1 format
    +-- sessions-gen2.md                            # Gen2 format
    +-- sessions-gen2-multi-loc.md                  # Gen2 with multiple locations
    +-- sessions-gen3.md                            # Gen3 format
    +-- sessions-gen4.md                            # Gen4 format
    +-- sessions-gen4-full.md                       # Gen4 with all metadata tags
    +-- sessions-changes.md                         # Session with Zmiany block
    +-- sessions-co-narrator.md                     # Co-narrated sessions
    +-- sessions-code-fence.md                      # Code fences in content
    +-- sessions-date-range.md                      # Multi-day date ranges
    +-- sessions-deep-zmiany.md                     # Complex nested Zmiany
    +-- sessions-duplicate.md                       # Deduplication test data
    +-- sessions-empty-body.md                      # Sessions with empty body
    +-- sessions-failed.md                          # Malformed dates
    +-- sessions-many.md                            # Large session count
    +-- sessions-multi-transfer.md                  # Multiple @Transfer lines
    +-- sessions-narrator-override.md               # Narrator mapping overrides
    +-- sessions-no-metadata.md                     # Sessions without metadata
    +-- sessions-unicode.md                         # Unicode in session content
    +-- sessions-unresolved.md                      # Unresolved references
    +-- sessions-zmiany.md                          # Zmiany override test data
    +-- sessions-item-transfer.md                   # Item transfer session data
    +-- sessions-location-graph.md                  # Location graph session data
    +-- sessions-plik-zmiany.md                     # @plik Zmiany test data
    +-- sessions-transfer-fuzzy.md                  # Fuzzy transfer resolution data
    +-- sessions-integrity/                         # Session integrity check fixtures
    |   +-- base.md
    |   +-- duplicate-pu.md
    |   +-- format-anomaly.md
    |   +-- future-dated.md
    |   +-- malformed.md
    |   +-- modified.md
    |
    |   # Character files
    +-- charfile-anglebracket.md                    # Angle bracket edge case
    +-- charfile-empty.md                           # Empty character file
    +-- charfile-empty-reputation.md                # Empty reputation section
    +-- charfile-full.md                            # Full character file
    +-- charfile-missing-sections.md                # Missing sections
    +-- charfile-multilinestan.md                   # Multi-line stan
    +-- charfile-rich.md                            # Rich content character
    +-- charfile-set-pc.md                          # Set-PlayerCharacter test data
    +-- charfile-unicode.md                         # Unicode in character data
    |
    |   # Location graph
    +-- entities-koordynaty.md                      # Coordinate parsing test data
    +-- sessions-route-edges.md                     # Route edge extraction test data
    |
    |   # Other
    +-- minimal-entity.md                           # Minimal entity for writes
    +-- pu-sessions.json                            # PU session history (JSON)
    +-- pu-sessions.md                              # PU session history (Markdown)
    +-- pu-sessions-sample.json                     # Sample PU history (JSON)
    +-- pu-sessions-sample.md                       # Sample PU history (Markdown)
    +-- local.config.psd1                           # Config fixture
    +-- maps-test.json                              # Map data test fixture
    +-- log-chatlog.txt                             # Chat log fixture
    +-- log-chatlog-avlee.txt                       # Chat log Avlee fixture
    +-- log-chatlog-route.txt                       # Chat log route fixture
    +-- log-prose.txt                               # Prose log fixture
    +-- log-prose-dungeon.txt                       # Prose dungeon log fixture
    |
    +-- templates/                                  # Template subset (2 of 8)
        +-- player-character-file.md.template       # Character file skeleton
        +-- player-entry.md.template                # Character entry in entities.md
```

The `templates/` fixture directory contains only the 2 templates used by write tests (`New-PlayerCharacter`). The remaining 6 production templates (in the module's `templates/` dir) are not duplicated; tests that need them reference the module root directly.

---

## Shared Helpers (`TestHelpers.ps1`)

Path variables:

```powershell
$script:ModuleRoot   = # .robot.powershell/ (parent of tests directory)
$script:FixturesRoot = # tests/fixtures/
$script:TempRoot     = # GUID-based temp directory (per test run)
```

Functions:

| Function | Purpose |
|---|---|
| `New-TestTempDir` | Creates a GUID-based disposable temp directory for write tests |
| `Remove-TestTempDir` | Cleans up the temp directory (called in `AfterAll`) |
| `Copy-FixtureToTemp` | Copies fixture files to temp, with optional rename and parent dir creation |
| `Import-RobotModule` | Imports `Robot.PowerShell.psd1 -Force` |
| `Import-RobotHelpers` | Dot-sources helper files by name from module root |
| `Write-TestFile` | Writes UTF-8 no-BOM content to a file path |

---

## Loading Patterns

Pattern A -- Exported Functions:

For testing exported `Verb-Noun` functions:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

Pattern B -- Helpers in Function Files:

For testing internal helper functions within a function file:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . "$script:ModuleRoot/public/get-entity.ps1"  # Access internal helpers (adjust path for subdirectory functions)
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

Pattern C -- Standalone Helper Files:

For testing standalone helper scripts (non-Verb-Noun):

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Import-RobotHelpers 'private/entity-writehelpers.ps1'
    Mock Get-RepoRoot { return $script:TempRoot }
}
```

Pattern D -- Parser (Special):

`private/parse-markdownfile.ps1` is invoked via `&` operator (not dot-sourced) because it has a top-level `param()`:

```powershell
$Result = & "$script:ModuleRoot/private/parse-markdownfile.ps1" $FixturePath
```

Pattern E -- Engine Components:

For testing CLI engine files in `private/cli/engine/`. Engine files depend on each other in a specific order and must be dot-sourced with their dependencies:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Dot-source dependencies in order
    . "$script:ModuleRoot/private/cli/cli-primitives.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-engine.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-buffer.ps1"
    # ... additional engine files as needed by the component under test

    # Set up known screen dimensions (engine uses these module-scoped vars)
    $script:ScreenWidth  = 80
    $script:ScreenHeight = 24
    Build-Regions
}
```

Engine tests validate data structures and logic (region calculation, buffer operations, segment comparison, component state management) without actual terminal rendering. Engine files use `$script:` variables for screen state (`ScreenWidth`, `ScreenHeight`, `Regions`). Components are hashtables with `Render` and `HandleKey` scriptblocks. Tests exercise component factories (`New-MenuListComponent`, `New-ResultTableComponent`, etc.) and their state transitions. No mocking of `Get-RepoRoot` is needed (engine tests are pure UI logic).

---

## Test Structure Convention

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

## Mock Patterns

`Get-RepoRoot` is mocked in almost every test file. Read tests return `$script:FixturesRoot` (reads fixtures as if they were the repository). Write tests return `$script:TempRoot` (writes to disposable temp directory).

Common mocks:

| Mock target | Typical replacement |
|---|---|
| `Get-RepoRoot` | `$script:FixturesRoot` or `$script:TempRoot` |
| `Get-GitChangeLog` | Synthetic commit objects with controlled file lists |
| `Send-DiscordMessage` | Success response object |
| `Get-AdminConfig` | Hashtable with fixture paths |
| `Get-AdminHistoryEntries` | Empty or pre-populated `HashSet[string]` |

.NET static methods (`[System.IO.File]::ReadAllLines`, etc.) are not mocked -- they use real fixtures instead. `Get-Markdown`, `Get-Entity`, and `Get-Player` typically operate on fixture data and are not mocked.

Write test pattern:

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

## Fixture Design

Fixtures use synthetic, controlled data with no dependency on actual repository content. They are minimal but complete -- enough data to exercise all code paths. Fixtures cross-reference each other (e.g., `Gracze.md` players match `entities.md` entries).

Key fixtures:

| Fixture | Contents | Tests |
|---|---|---|
| `Gracze.md` | 3 players with full PU data, character variations, MargonemID, webhooks | `get-player`, `get-playercharacter` |
| `entities.md` | NPCs, orgs, locations (with hierarchy), Gracz/Postac entries | `get-entity`, `get-entitystate` |
| `entities-100-ent.md` | Override entries (primacy 100) | Multi-file merge, override primacy |
| `entities-200-ent.md` | Override entries (primacy 200) | Multi-file merge |
| `entities-generic-crud.md` | All 6 entity types populated | `new-entity`, `set-entity`, `remove-entity` |
| `entities-currency-crud.md` | 3 currency entities with denominations | `new-currencyentity`, `set-currencyentity`, `remove-currencyentity` |
| `sessions-gen{1,2,3,4}.md` | Session metadata in each format generation | `get-session`, format detection |
| `sessions-duplicate.md` | Identical headers for deduplication | `Merge-SessionGroup` |
| `sessions-zmiany.md` | Zmiany blocks with `@tag` overrides | `get-entitystate` |
| `sessions-failed.md` | Malformed dates with valid PU content | `test-playercharacterpuassignment` |
| `pu-sessions.json` | Pre-processed session history | History deduplication |

---

## Testing Strategies

Temporal filtering tests use extensive date-range testing for validity windows. Fixtures include entities with various `(YYYY-MM:YYYY-MM)` ranges to verify `Test-TemporalActivity`, `Get-LastActiveValue`, and `Get-AllActiveValues`.

Merge logic tests use multiple fixture files (`entities.md`, `entities-100-ent.md`, `entities-200-ent.md`) to verify override precedence and alias merging across files.

Polish declension tests in `resolve-name.Tests.ps1` include test cases for suffix stripping and stem alternation with Polish morphological forms (e.g., `"Solmyra"` -> `"Solmyr"`, `"Vidominie"` -> `"Vidomina"`).

Format generation tests use separate fixture files per format generation to ensure all four formats are tested independently for parsing, metadata extraction, and format upgrade paths.

---

## Adding Tests for New Functions

1. Create test file: `tests/<function-name>.Tests.ps1`
2. Choose loading pattern: A (exported), B (internal helpers), C (standalone helper), D (parser), or E (engine component)
3. Create fixtures (if needed): add to `tests/fixtures/` with minimal but complete data
4. Follow skeleton: `BeforeAll` -> `Describe` -> `Context` -> `It` -> `AfterAll`
5. Mock `Get-RepoRoot`: point to fixtures (read) or temp dir (write)
6. Use temp dirs for writes: `New-TestTempDir` + `Copy-FixtureToTemp` + `Remove-TestTempDir`
7. Verify with assertions: use Pester's `Should` syntax

---

## Statistics

| Metric | Count |
|---|---|
| Test files | 105 |
| Test cases (`It` blocks) | ~2,160 |
| Fixture files | ~90 |
| Loading patterns | 5 (A: exported, B: internal+dot-source, C: standalone helper, D: parser, E: engine component) |

---

## Related Documents

- [SYNTAX.md](SYNTAX.md) - Code style conventions (applies to test code too)
- [MIGRATION.md](MIGRATION.md) - Testing section lists test coverage per area
- [PU.md](PU.md) - Testing section lists PU-specific test files

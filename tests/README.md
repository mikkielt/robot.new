# Test Logic Reference

## Pester Setup & Conventions

### Requirements

- **Pester v5.0+** (the only external dependency)
- **PowerShell 5.1** or **PowerShell Core 7.0+**

### File Naming Convention

Test files mirror source files with a `.Tests.ps1` suffix:

```
get-entity.ps1  →  tests/get-entity.Tests.ps1
```

One additional file `Robot.Tests.ps1` validates module-level behaviour (loading, exports).

### Test Structure Convention

Every test file follows the same skeleton:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    # ... loading strategy (see Loading Patterns below)
}

Describe 'FunctionName' {
    Context 'scenario group' {
        It 'specific behaviour assertion' {
            # Arrange → Act → Assert
        }
    }
}

AfterAll {
    Remove-TestTempDir   # only in files that create temp dirs
}
```

### Configuration File

`tests/.pesterconfig.psd1` provides default invocation settings:

```powershell
@{
    Run = @{
        Path = './tests'
        Exit = $true
    }
    Output = @{
        Verbosity = 'Detailed'
    }
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

Invocation:

```powershell
# All tests
Invoke-Pester ./tests/ -Output Detailed

# Single file
Invoke-Pester ./tests/get-entity.Tests.ps1 -Output Detailed

# With config
Invoke-Pester -Configuration (Import-PowerShellDataFile ./tests/.pesterconfig.psd1)
```

---

## TestHelpers.ps1 — Shared Bootstrap

Every test file dot-sources `TestHelpers.ps1` in its `BeforeAll`. This file provides:

```powershell
$script:ModuleRoot   = Split-Path $PSScriptRoot -Parent    # .robot.new/
$script:FixturesRoot = Join-Path $PSScriptRoot 'fixtures'
$script:TempRoot     = Join-Path ([System.IO.Path]::GetTempPath()) "robot-tests-$(New-Guid ...)"
```

Utility functions:

| Function | Purpose |
|----------|---------|
| `New-TestTempDir` | Creates disposable temp directory for write tests |
| `Remove-TestTempDir` | Cleans up temp directory |
| `Copy-FixtureToTemp` | Copies a fixture file into the temp dir |
| `Import-RobotModule` | `Import-Module robot.psd1 -Force` |
| `Import-RobotHelpers` | Dot-sources a helper file by name |

---

## Loading Patterns

### Pattern A — Exported functions

For testing the 20 Verb-Noun functions available through the module:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
}
```

### Pattern B — Helpers inside exported function files

For testing helpers defined in the same file as an exported function (e.g. `ConvertFrom-ValidityString` inside `get-entity.ps1`). Import module first (so dependencies like `Get-RepoRoot` are available), then dot-source the file to bring helpers into scope:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    . (Join-Path $script:ModuleRoot 'get-entity.ps1')
}
```

### Pattern C — Standalone helper files

For testing `entity-writehelpers.ps1`, `admin-state.ps1`, `admin-config.ps1`, `format-sessionblock.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    Mock Get-RepoRoot { return $script:FixturesRoot }
    Import-RobotHelpers 'entity-writehelpers.ps1'
}
```

### Exception — parse-markdownfile.ps1

This is a standalone script with `param()` at the top level. It must be invoked via `&`, not dot-sourced:

```powershell
$Result = & (Join-Path $script:ModuleRoot 'parse-markdownfile.ps1') $FixturePath
```

---

## Mocking Strategy

### Get-RepoRoot (universal)

Nearly every function calls `Get-RepoRoot`. Mock it to return the fixtures directory (reads) or temp directory (writes):

```powershell
Mock Get-RepoRoot { return $script:FixturesRoot }      # read tests
Mock Get-RepoRoot { return $script:TempRoot }           # write tests
```

### Git process execution

`Get-GitChangeLog` spawns `git log` via `ProcessStartInfo`. Mock the entire function:

```powershell
Mock Get-GitChangeLog {
    return @([PSCustomObject]@{
        CommitHash  = 'abc123'
        CommitDate  = [datetime]'2025-01-15'
        AuthorName  = 'TestAuthor'
        AuthorEmail = 'test@example.com'
        Files       = @([PSCustomObject]@{
            Path = 'sessions-gen3.md'; ChangeType = 'M'
        })
    })
}
```

For `ConvertFrom-CommitLine` (internal helper): construct synthetic regex match strings matching the `COMMIT<US>hash<US>date<US>name<US>email` format.

### Discord HTTP calls

Mock `Send-DiscordMessage` at the function level:

```powershell
Mock Send-DiscordMessage {
    return [PSCustomObject]@{
        Webhook = $Webhook; StatusCode = 200; Success = $true; WhatIf = $false
    }
}
```

For testing `Send-DiscordMessage` itself: test validation logic and `-WhatIf` path only. The actual HTTP call (`HttpClient.PostAsync`) cannot be reliably mocked via Pester.

### File I/O for write operations

Copy fixture files to a temp directory, run the function against the copy, read back and verify:

```powershell
BeforeEach {
    $TempDir = New-TestTempDir
    $TestFile = Copy-FixtureToTemp 'minimal-entity.md' 'entities.md'
}
AfterEach { Remove-TestTempDir }
```

### ShouldProcess

Test `-WhatIf` behaviour by passing the switch and verifying no file changes:

```powershell
It 'does not modify file with -WhatIf' {
    Set-Player -Name 'Test' -PRFWebhook $Url -WhatIf
    # Assert file unchanged
}
```

### Why not mock .NET static methods

The codebase uses `[System.IO.File]::ReadAllLines()`, `[System.IO.Directory]::GetFiles()`, etc. Pester cannot reliably mock .NET static methods. Fixture files on disk + `Get-RepoRoot` redirection is the correct approach.

---

## Fixture Design

### Directory layout

```
tests/fixtures/
  Gracze.md                    # 3 players, 5 characters, PU variants
  entities.md                  # NPCs, orgs, locations, Gracz, Postać (Gracz)
  entities-200-ent.md          # Override file (lower primacy)
  entities-100-ent.md          # Override file (higher primacy)
  sessions-gen1.md             # Gen1 plain text sessions
  sessions-gen2.md             # Gen2 italic location sessions
  sessions-gen3.md             # Gen3 list metadata sessions
  sessions-gen4.md             # Gen4 @-prefixed sessions + @Intel
  sessions-duplicate.md        # Same headers for dedup testing
  sessions-zmiany.md           # Zmiany blocks for Get-EntityState
  sessions-failed.md           # Malformed dates with valid PU content
  empty.md                     # Empty file
  no-headers.md                # Markdown with no level-3 headers
  minimal-entity.md            # Single entity for write tests
  pu-sessions.md               # Pre-populated history file
  templates/
    player-character-file.md.template
    player-entry.md.template
  local.config.psd1            # Config fixture
```

### Gracze.md fixture

Must contain 3 players under `## Lista` with level-3 headers:
- Player 1 (`Solmyr`): 2 characters (one active `**bold**`), full PU data (NADMIAR, STARTOWE, SUMA, ZDOBYTE), MargonemID, PRFWebhook, triggers, character aliases
- Player 2 (`Crag Hack`): 1 character, PU with BRAK values (null testing), no PRFWebhook
- Player 3 (`Sandro`): 0 characters (edge case)

### entities.md fixture

- 2–3 NPCs with `@alias` (temporal), `@lokacja` (temporal), `@grupa`, `@info` (multi-line nested bullets)
- 2 organizations with `@alias`
- 5–6 locations forming a hierarchy (`Enroth` → `Erathia` → `Ratusz Erathii`) for CN resolution testing
- 2 `## Gracz` entries matching players in `Gracze.md`
- 2 `## Postać (Gracz)` entries with `@należy_do`, `@alias`, PU override tags

### Override files

- `entities-200-ent.md`: adds an NPC with an alias that also exists in `entities.md` (merge testing)
- `entities-100-ent.md`: overrides a PU value from `entities.md` (100 < 200, so 100-file has highest primacy)

### Session fixtures

**sessions-gen1.md**: 2 sessions with plain text, no structured metadata
**sessions-gen2.md**: 2 sessions with `*Lokalizacja: ...*` italic lines
**sessions-gen3.md**: 3 sessions with Gen3 list metadata (`- Lokalizacje:`, `- PU:`, `- Logi:`, `- Zmiany:`)
**sessions-gen4.md**: 2 sessions with Gen4 `@`-prefixed metadata, including `- @Intel:` blocks with `Grupa/`, `Lokacja/`, and bare name directives
**sessions-duplicate.md**: headers identical to sessions-gen3.md for deduplication testing
**sessions-zmiany.md**: sessions with `- Zmiany:` blocks with various `@tag` overrides for `Get-EntityState`
**sessions-failed.md**: intentionally malformed dates (`2024-1-5`, `2024-13-01`) with valid `- PU:` content in the body

### pu-sessions.md fixture

Pre-populated with 2–3 already-processed session headers:

```markdown
W tym pliku znajduje się lista sesji przetworzonych przez system.

## Historia

- 2025-01-15 14:30 (UTC+01:00):
    - ### 2024-06-15, Ucieczka z Erathii, Solmyr
```

### local.config.psd1 fixture

```powershell
@{
    RepoWebhook  = 'https://discord.com/api/webhooks/test/fixture'
    BotUsername   = 'TestBot'
}
```

---

## Test Logic by Source File

---

### robot.psm1 — Module Loader

**Test file**: `Robot.Tests.ps1` | **Loading**: Pattern A | **Status**: implemented

#### Module loading and export verification

- Importing `robot.psd1` succeeds without errors
- All 22 Verb-Noun functions are exported: `Get-RepoRoot`, `Get-Markdown`, `Get-GitChangeLog`, `Get-Player`, `Get-Entity`, `Get-EntityState`, `Get-PlayerCharacter`, `Get-Session`, `Get-NameIndex`, `Get-NewPlayerCharacterPUCount`, `Resolve-Name`, `Resolve-Narrator`, `Set-Player`, `Set-PlayerCharacter`, `New-Player`, `New-PlayerCharacter`, `Remove-PlayerCharacter`, `New-Session`, `Set-Session`, `Send-DiscordMessage`, `Invoke-PlayerCharacterPUAssignment`, `Test-PlayerCharacterPUAssignment`
- Non-Verb-Noun files (`entity-writehelpers.ps1`, `admin-state.ps1`, etc.) are NOT exported
- Re-importing with `-Force` replaces previous definitions cleanly

---

### get-reporoot.ps1 — `Get-RepoRoot`

**Test file**: `get-reporoot.Tests.ps1` | **Loading**: Pattern A (but do NOT mock `Get-RepoRoot` here) | **Status**: implemented

#### Get-RepoRoot

- Returns a path containing a `.git` directory when called from within a git repository
- Returned path is an ancestor (or equal to) the process working directory
- Throws `"No git repository found"` when no `.git` exists in any parent (mock by temporarily changing process CWD to a temp dir with no git repo)
- Uses `[System.IO.Directory]::GetCurrentDirectory()` (process CWD), not PowerShell `$PWD`

---

### parse-markdownfile.ps1 — Standalone Script

**Test file**: `parse-markdownfile.Tests.ps1` | **Loading**: Script invocation via `&` | **Status**: implemented

#### Script invocation

- Returns object with `FilePath`, `Headers`, `Sections`, `Lists`, `Links` properties
- **Headers**: correct `Level`, `Text`, `LineNumber` (1-based), `ParentHeader` chain matching nesting
- **Sections**: content grouped by header, `Lists` populated for each section
- **Lists**: indent normalization, `ParentListItem` parent-child linking, `Indent` property consistent
- **Links**: extracts `[text](url)` Markdown links and bare `https://` URLs
- Content inside ``` code fences is not parsed as headers, lists, or links
- Empty file: returns object with empty collections
- File with no headers: all content in a single root section

---

### get-markdown.ps1 — `Get-Markdown`

**Test file**: `get-markdown.Tests.ps1` | **Loading**: Pattern A | **Status**: implemented

#### Get-Markdown

- `-File` with single file: returns unwrapped single object (not an array)
- `-File` with array of files: returns `List[object]` with one element per file
- `-Directory`: scans all `.md` and `.markdown` files recursively under the given path
- `-Directory` default: uses `Get-RepoRoot` (mocked to fixtures dir)
- Validation: throws for non-existent file path
- Validation: throws for non-existent directory path
- Result structure matches `parse-markdownfile.ps1` output (same `Headers`, `Sections`, `Lists`, `Links` shape)
- Multiple files produce deterministic, identical output regardless of sequential vs. parallel execution path

---

### get-entity.ps1 — `Get-Entity` + 7 helpers

**Test file**: `get-entity.Tests.ps1` | **Loading**: Pattern B (dot-source to access helpers)

#### ConvertFrom-ValidityString

- `"Value (2021-01:2024-06)"` → `Text="Value"`, `ValidFrom=2021-01-01`, `ValidTo=2024-06-30`
- `"Value (2024-07:)"` → `ValidFrom=2024-07-01`, `ValidTo=$null` (open-ended)
- `"Value (:2024-03)"` → `ValidFrom=$null`, `ValidTo=2024-03-31`
- `"Plain Value"` → `Text="Plain Value"`, `ValidFrom=$null`, `ValidTo=$null`
- `"Value (2024:)"` → `ValidFrom=2024-01-01` (year-only partial date)
- `"Value (2024:2025)"` → `ValidFrom=2024-01-01`, `ValidTo=2025-12-31`
- Leading/trailing whitespace on input is trimmed

#### Resolve-PartialDate

- `"2024"` with `IsEnd=$false` → `2024-01-01`
- `"2024"` with `IsEnd=$true` → `2024-12-31`
- `"2024-06"` with `IsEnd=$false` → `2024-06-01`
- `"2024-06"` with `IsEnd=$true` → `2024-06-30`
- `"2024-02"` with `IsEnd=$true` → `2024-02-29` (leap year 2024)
- `"2025-02"` with `IsEnd=$true` → `2025-02-28` (non-leap year)
- `"2024-06-15"` → `2024-06-15` (exact day returned unchanged)
- Empty/whitespace string → `$null`
- Invalid date string (e.g. `"abc"`) → `$null`

#### Test-TemporalActivity

- `$null` ActiveOn → always returns `$true`
- Item within range (ValidFrom ≤ ActiveOn ≤ ValidTo) → `$true`
- Item before ValidFrom → `$false`
- Item after ValidTo → `$false`
- Item with no bounds (ValidFrom=$null, ValidTo=$null) → always `$true`
- Item with only ValidFrom set, ActiveOn after it → `$true`
- Item with only ValidTo set, ActiveOn before it → `$true`

#### Get-NestedBulletText

- Returns newline-joined text from children that pass temporal filter
- Returns `$null` when no children exist (empty ChildrenOf lookup)
- Returns `$null` when all children filtered out by ActiveOn
- Multi-child: joins with `\n`

#### Get-LastActiveValue

- Returns last active entry's property value from a history list
- Returns `$null` when history list is empty
- Returns `$null` when all entries filtered out by ActiveOn
- With multiple active entries: returns the value from the last (highest-index) entry

#### Get-AllActiveValues

- Returns `string[]` of all active values from history list
- Returns empty array `@()` when history is empty
- Returns empty array when all entries filtered out
- Preserves order of active entries

#### Resolve-EntityCN

- Non-location entity: returns `"Type/Name"` (e.g. `"NPC/Kupiec Orrin"`)
- Top-level location (no `@lokacja` history): returns `"Lokacja/Name"`
- Nested location: returns `"Lokacja/Parent/Child"` hierarchy
- Deeply nested: returns full chain (e.g. `"Lokacja/Enroth/Erathia/Ratusz Erathii"`)
- Cycle detection: circular `@lokacja` chain emits warning to stderr and returns flat `"Lokacja/Name"`
- CNCache memoization: second call for same entity returns cached value without recursion
- Fallback: uses first active `@drzwi` when no `@lokacja` history exists

#### Get-Entity

- Parses all entity types from fixture: NPC, Organizacja, Lokacja, Gracz, Postać (Gracz), Przedmiot
- Entity object has correct properties: Name, CN, Names, Aliases, Type, Owner, Groups, Overrides, Location, LocationHistory, Doors, DoorHistory, Status, StatusHistory, Contains, TypeHistory, OwnerHistory, GroupHistory
- Multi-file merge: entities from `entities-100-ent.md` override `entities-200-ent.md` override `entities.md` (lowest numeric suffix = highest primacy, applied last)
- `@alias` parsing with temporal ranges — alias objects have Text, ValidFrom, ValidTo
- `@lokacja`, `@drzwi`, `@grupa`, `@zawiera`, `@typ`, `@należy_do`, `@status` tag parsing
- `@status` temporal parsing: `Aktywny (YYYY-MM:)`, `Nieaktywny (YYYY-MM:YYYY-MM)`, `Usunięty (YYYY-MM:)` — stored in `Status` (active scalar) and `StatusHistory` (full history)
- Default `Status` = `Aktywny` when no `@status` tag present
- Generic `@tag` → Overrides dictionary (e.g. `@info`, `@margonemid`, `@prfwebhook`)
- Multi-line `@info` via nested bullets: joined with newline
- `-ActiveOn` temporal filtering: aliases, locations, groups filtered to date
- CN resolution: hierarchical location paths match expected hierarchy
- Duplicate entity names across files are merged (aliases, overrides, histories combined)
- Empty directory: returns empty list

---

### entity-status.Tests.ps1 — @status Tag & Przedmiot Parsing Tests

**Test file**: `entity-status.Tests.ps1` | **Loading**: dot-source `get-entity.ps1`, module import, temp dir with inline entities.md | **Status**: implemented

Focused tests for `@status` tag parsing and Przedmiot entity type in `Get-Entity`. Creates inline `entities.md` fixtures per context.

#### Basic @status parsing

- `@status: Aktywny (2024-01:)` → `Status` = `'Aktywny'`
- `@status: Nieaktywny (2025-01:)` → `Status` = `'Nieaktywny'`
- `@status: Usunięty (2025-06:)` → `Status` = `'Usunięty'`
- `StatusHistory` populated with 1 entry, entry's `Status` matches tag value

#### Default Aktywny when no @status

- Entity with no `@status` tag: `Status` defaults to `'Aktywny'`
- `StatusHistory` has count 0 (no explicit entries)

#### Temporal status transitions

- Three consecutive `@status` tags: `Aktywny (2024-01:2024-06)` → `Nieaktywny (2024-07:2025-01)` → `Aktywny (2025-02:)`
- Without date filter: `Status` resolves to most recent = `'Aktywny'`
- With `-ActiveOn 2024-10-15` (mid-inactive period): `Status` = `'Nieaktywny'`

#### Przedmiot entity type

- Parses `## Przedmiot` section: entity `Type` = `'Przedmiot'`
- Resolves `@należy_do` ownership: `Owner` = `'Solmyr'`

---

### get-player.ps1 — `Get-Player` + 1 helper

**Test file**: `get-player.Tests.ps1` | **Loading**: Pattern B

#### Complete-PUData

- SUMA present + ZDOBYTE missing + STARTOWE present → derives `ZDOBYTE = SUMA - STARTOWE`
- ZDOBYTE present + SUMA missing + STARTOWE present → derives `SUMA = STARTOWE + ZDOBYTE`
- Both SUMA and ZDOBYTE present → no change (values preserved)
- STARTOWE missing (`$null`) → no derivation performed
- Decimal precision: results rounded to 2 decimal places

#### Get-Player

- Parses players from `Gracze.md` fixture: correct `Name`, `MargonemID`, `PRFWebhook`, `Triggers`
- Characters: `Name`, `IsActive` (detected via `**bold**` markdown), `Path`, `Aliases`
- PU parsing: NADMIAR/STARTOWE/SUMA/ZDOBYTE with decimal values
- PU `"BRAK"` → `$null`
- PU derivation (`Complete-PUData`) applied automatically after parsing
- `Names` HashSet: contains player name + all character names + all aliases (case-insensitive via `OrdinalIgnoreCase`)
- `-Name` filter: returns only matching player(s)
- Entity override injection: entities of type `Gracz` / `Postać (Gracz)` merged into player roster — aliases, PU values, triggers, webhooks injected
- New player stub creation: entity-only players (in entities.md but not in Gracze.md) appear as stubs
- PRFWebhook: only `https://discord.com/api/webhooks/*` URLs preserved

---

### get-session.ps1 — `Get-Session` + 11 helpers

**Test file**: `get-session.Tests.ps1` | **Loading**: Pattern B

#### ConvertFrom-SessionHeader

- `"2024-06-15, Title, Narrator"` → `Date=2024-06-15`, `DateEnd=$null`
- Date range `"2024-06-15/16, Title, Narrator"` → `Date=2024-06-15`, `DateEnd=2024-06-16`
- Invalid date `"2024-13-01, Title, Narrator"` → returns `$null`
- No date in header → returns `$null`

#### Get-SessionTitle

- `"2024-06-15, Ucieczka z Erathii, Solmyr"` → `"Ucieczka z Erathii"`
- Strips date and narrator, returns middle part
- Multiple commas in title: only strips first (date) and last (narrator) segments
- Single comma (no narrator field): returns text after date

#### Get-SessionFormat

- Italic location line (`*Lokalizacja: ...*`) → Gen2
- `@`-prefixed list items (`- @Lokacje:`) → Gen4
- Undecorated list items (`- Lokalizacje:`, `- PU:`) → Gen3
- No structured content → Gen1

#### Get-SessionLocations

- Gen2: parses `*Lokalizacja: Erathia, Steadwick*` italic regex → `["Erathia", "Steadwick"]`
- Gen3/Gen4: parses nested list items under `Lokalizacje`/`@Lokacje` → location array
- Inline comma-separated fallback

#### Get-SessionListMetadata

- **PU**: parses `"CharName: 0,3"` with comma→period decimal normalization → `Value=0.3`
- **PU**: null value for unparseable decimal strings
- **Logs**: extracts URLs from nested items and inline text
- **Zmiany**: three-level parsing: Zmiany → EntityName → `@tag: value`
- **Intel**: parses `"RawTarget: Message"` format
- Gen4 `@`-prefix stripping for all tag matching

#### Get-SessionPlainTextLogs

- Extracts URLs from `"Logi: https://..."` lines (Gen1/Gen2 fallback)

#### Merge-SessionGroup

- Deduplicates sessions with identical headers across files
- Picks metadata-richest instance as primary (by scoring)
- Unions array fields: locations, logs, PU entries
- Scalar conflicts (title, format) emit warnings to stderr

#### Resolve-EntityWebhook

- Returns entity's own `@prfwebhook` if present in Overrides
- Falls back to owning Player's `PRFWebhook` for `Postać (Gracz)` entities without own webhook
- Returns `$null` when no webhook found at any level

#### Test-LocationMatch

- Exact match: `"Erathia"` matches `"Erathia"` → `$true`
- Hierarchical path match: `"Lokacja/Enroth/Erathia"` contains `"Erathia"`

#### Resolve-IntelTargets

- `Grupa/Nocarze`: resolves to all entities with `@grupa` membership matching `"Nocarze"` at session date
- `Lokacja/Erathia`: resolves to entities in `"Erathia"` and sub-locations at session date
- `Rion` (bare name): resolves directly to the named entity
- Multi-recipient: `Kyrre, Adrienne Darkfire` → array of two recipients

#### Get-SessionMentions

- Extracts entity mentions from session body text using stages 1/2/2b (no fuzzy matching)
- Excludes metadata list content (PU, Logi, Lokalizacje, Zmiany, Intel)
- Deduplicates mentions by entity name
- Returns `Mentions` array with `Name`, `Type`, `Owner` properties

#### Get-Session

- Parses sessions from Gen1/2/3/4 fixture files with correct format detection
- Date filtering via `-MinDate`/`-MaxDate` restricts output
- `-File` parameter: parses specific file(s)
- `-Directory` parameter: scans all `.md` files recursively
- Narrator resolution integrated: `Narrator.Narrators`, `Narrator.IsCouncil`, `Narrator.Confidence`
- Deduplication across files: `sessions-gen3.md` + `sessions-duplicate.md` → merged session objects with `IsMerged=$true`
- `-IncludeContent` includes raw section text in `Content` property
- `-IncludeFailed` includes sessions with parse errors (malformed dates)
- `-IncludeMentions` enables mention extraction
- `@Intel` always parsed when present — `Intel` property populated
- Session object schema matches all documented properties: FilePath, FilePaths, Header, Date, DateEnd, Title, Narrator, Locations, Logs, PU, Format, IsMerged, DuplicateCount, Content, Changes, Mentions, Intel, ParseError

---

### get-nameindex.ps1 — `Get-NameIndex` + 4 helpers

**Test file**: `get-nameindex.Tests.ps1` | **Loading**: Pattern B

#### Add-BKTreeNode

- Inserts keys at correct distance children positions
- Duplicate key (distance 0) is skipped without error
- Recursive insertion for existing distance slots

#### Search-BKTree

- Finds all keys within threshold distance
- Empty tree returns empty array
- Threshold 0 returns only exact matches (distance = 0)
- Triangle inequality pruning works correctly (no false negatives)

#### Add-IndexToken

- New token: inserted into index with correct Owner, OwnerType, Priority
- Same owner, higher priority: updates entry to higher priority
- Same owner, lower priority: keeps existing higher-priority entry
- Different owner, same priority: marks entry as `Ambiguous=$true`, populates `Owners` array
- Player/Gracz dedup: Player entries take precedence over `Gracz`/`Postać (Gracz)` entity entries at same priority

#### Add-NamedObjectTokens

- Full names indexed at priority 1
- Individual words from multi-word names indexed at priority 2
- Short tokens (< `MinTokenLength`, default 3) skipped
- Single-word names: only full-name token generated (no word tokens)

#### Get-NameIndex

- Returns hashtable with `Index`, `StemIndex`, `BKTree` keys
- `Index` contains all player names + entity names + aliases (case-insensitive)
- Case-insensitive lookups work: `$Index['xeron']` matches `"Xeron Demonlord"`
- BK-tree built from all index keys
- `StemIndex` built inline for declension lookups

---

### get-newplayercharacterpucount.ps1 — `Get-NewPlayerCharacterPUCount`

**Test file**: `get-newplayercharacterpucount.Tests.ps1` | **Loading**: Pattern A

#### Get-NewPlayerCharacterPUCount

- Formula: `Floor((Sum(PUTaken) / 2) + 20)`
- Only includes characters with `PUStart > 0`
- Excludes characters with `PUStart` null or 0 — listed in `ExcludedCharacters`
- Throws `"Player '...' not found."` for unknown player name
- Returns structured result: `PU`, `PUTakenSum`, `IncludedCharacters`, `ExcludedCharacters`
- Edge case: player with no characters → `PU = 20` (Floor(0/2 + 20))

---

### resolve-name.ps1 — `Resolve-Name` + 3 helpers

**Test file**: `resolve-name.Tests.ps1` | **Loading**: Pattern B

#### Get-DeclensionStem

- Strips Polish suffixes: `"Xeronowi"` → `"Xeron"` (strips `-owi`)
- Longest suffix first: `"Draconem"` → `"Dracon"` (strips `-em`, not `-m`)
- Minimum stem length 3: `"Aba"` → `"Aba"` (too short to strip `-a`)
- No matching suffix: returns original unchanged
- Suffix list: `owi`, `ami`, `ach`, `iem`, `em`, `om`, `ą`, `ę`, `ie`, `a`, `u`, `y`

#### Get-StemAlternationCandidates

- `"Bracadzie"` → `["Adrienne"]` (strips `-dzie`, appends `-da`)
- `"Korce"` → `["Korka"]` (strips `-ce`, appends `-ka`)
- Returns empty list when no alternation rule matches
- Minimum stem length prevents false matches on short inputs
- Multiple alternations can match the same input (returns all candidates)

#### Get-LevenshteinDistance

- Same string → 0
- Empty vs non-empty → length of the non-empty string
- `"kitten"` / `"sitting"` → 3 (known test vector)
- Case insensitive: `"ABC"` / `"abc"` → 0
- Single character difference → 1

#### Resolve-Name

- **Stage 1** exact match: `"Xeron Demonlord"` → entity/player (case-insensitive)
- **Stage 1** ambiguous: skips ambiguous entries, falls through to later stages
- **Stage 2** declension: `"Xerona"` (genitive) → resolves to Xeron Demonlord
- **Stage 2b** stem alternation: `"Bracadzie"` → resolves to Adrienne
- **Stage 3** fuzzy: `"Xrom"` (typo, distance 1) → resolves to Xeron Demonlord
- **Stage 3** threshold: names < 5 chars allow distance ≤ 1, longer names allow `⌊length/3⌋`
- `-OwnerType` filter: restricts resolution to specified type
- `-Cache`: caches hits and misses (`[DBNull]::Value` sentinel for cached misses)
- Cache key includes OwnerType: `"Xeron|Player"` vs `"Xeron"`
- Builds index internally when not provided (calls `Get-Player`, `Get-Entity`, `Get-NameIndex`)
- Returns `$null` for completely unresolvable query
- BK-tree path: uses `Search-BKTree` when available, falls back to linear scan

---

### resolve-narrator.ps1 — `Resolve-Narrator` + 1 helper

**Test file**: `resolve-narrator.Tests.ps1` | **Loading**: Pattern B

#### Resolve-NarratorCandidate

- Exact index match: returns `{ Player, Confidence = 'High' }`
- Fuzzy/declension match: returns `{ Player, Confidence = 'Medium' }`
- No match: returns `$null`
- Only matches `OwnerType = "Player"`

#### Resolve-Narrator

- Single narrator: resolves from last comma-delimited segment of header
- Requires ≥ 2 commas for narrator field extraction (header format: `date, title, narrator`)
- `"Rada"`: `IsCouncil=$true`, `Confidence="High"`, empty `Narrators` array
- Co-narrators `"Solmyr i Crag Hack"`: splits on ` i `, resolves each → 2 narrator objects
- Plus sign `"Rothen + Rion"`: splits on ` + `
- Parenthetical `"X (autorstwo: Rada)"`: strips `autorstwo:` prefix, detects council
- Overall confidence = lowest among resolved narrators
- Caching: same raw text returns cached result on subsequent calls
- Unresolved narrator: `Confidence="None"`, empty `Narrators` array
- Header with only 1 comma (no narrator field): `Confidence="None"`, `RawText=$null`

---

### get-entitystate.ps1 — `Get-EntityState`

**Test file**: `get-entitystate.Tests.ps1` | **Loading**: Pattern A

#### Get-EntityState

- Merges entity file data with session Zmiany overrides
- Auto-dating: tags without explicit temporal ranges receive session date as `ValidFrom` (open-ended)
- Tags with explicit ranges `(YYYY-MM:YYYY-MM)` keep those ranges
- History lists sorted by `ValidFrom` after merge
- Active values recomputed for modified entities
- Entity name resolution: tries exact entity-name lookup first, then `Resolve-Name` fuzzy fallback
- Player-to-entity mapping: when `Resolve-Name` returns a Player object, maps back to the corresponding entity via shared names in `EntityByName`
- Unresolved entities: emits `[WARN Get-EntityState]` to stderr, skips without failing
- `-ActiveOn`: temporal filtering of merged state
- Pre-fetching: accepts `-Entities` and `-Sessions` parameters to avoid redundant parsing

---

### get-playercharacter.ps1 — `Get-PlayerCharacter`

**Test file**: `get-playercharacter.Tests.ps1` | **Loading**: Pattern A

#### Get-PlayerCharacter

- Flattens `Player → Characters` into flat rows with `PlayerName` backreference
- Each row has: `PlayerName`, `Player` (object reference), `Name`, `IsActive`, `Aliases`, `Path`, `PUExceeded`, `PUStart`, `PUSum`, `PUTaken`, `AdditionalInfo`, `Status`, `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation`, `AdditionalNotes`, `DescribedSessions`
- State properties are `$null` when `-IncludeState` is not set
- `-PlayerName` filter: returns only characters of matching player (case-insensitive via `OrdinalIgnoreCase`)
- `-CharacterName` filter: returns only matching character names (case-insensitive)
- `-Entities` pass-through: avoids redundant entity parsing inside `Get-Player`
- Player with no characters: produces no rows for that player
- `-IncludeState`: performs three-layer merge (character file → entities.md overrides → session @zmiany) via `Get-EntityState` and `charfile-helpers.ps1`
- `-IncludeState` populates: `Status` (default `Aktywny`), `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (Positive/Neutral/Negative), `AdditionalNotes`, `DescribedSessions`
- `-IncludeDeleted`: includes characters with `@status: Usunięty` (filtered out by default with `-IncludeState`)
- `-ActiveOn`: temporal filtering for state properties — entity overrides filtered to specified date

---

### get-playercharacter-state.Tests.ps1 — Three-Layer Merge Tests

**Test file**: `get-playercharacter-state.Tests.ps1` | **Loading**: dot-source `get-entity.ps1`, `charfile-helpers.ps1`, `Get-PlayerCharacter.ps1`, temp dir | **Status**: implemented

Focused unit tests for the three merge helper functions used by `Get-PlayerCharacter -IncludeState`. Operates on in-memory entity objects with `Overrides` dictionaries.

#### Merge-ScalarProperty

- Returns character file value when no entity overrides
- Returns `$null` when no value from any layer (char file `$null`, entity `$null`)
- Override with temporal date `(2025-06:)` wins over undated character file value
- `-ActiveOn` temporal filtering: before override range → falls back to char file value; during range → returns override value

#### Merge-MultiValuedProperty

- Returns character file values when no entity overrides
- Returns empty array when no values from any layer
- Combines character file and override values: 1 existing + 1 override = 2 total; result contains both

#### Merge-ReputationTier

- Returns character file tier entries when no entity overrides (Location + Detail preserved)
- Combines character file and override locations: 1 char file entry + 1 override entry = 2 total; Location arrays contain both original and override values

---

### entity-writehelpers.ps1 — 10 helpers

**Test file**: `entity-writehelpers.Tests.ps1` | **Loading**: Pattern C

#### Find-EntitySection

- Finds `## NPC` section with correct `HeaderIdx`, `StartIdx`, `EndIdx` boundaries
- Handles type normalization: `"NPC"`, `"Organizacja"`, `"Lokacja"`, `"Gracz"`, `"Postać (Gracz)"`, `"Przedmiot"`
- Also matches plural variants: `"Organizacje"` → `"Organizacja"`, `"Gracze"` → `"Gracz"`, `"Przedmioty"` → `"Przedmiot"`
- `EndIdx` is next `##` header line or end of file
- Returns `$null` when section not found

#### Find-EntityBullet

- Finds `* EntityName` bullet within section range (case-insensitive match)
- Returns `BulletIdx`, `ChildrenStartIdx`, `ChildrenEndIdx` (exclusive)
- Trims trailing blank lines from children range
- Returns `$null` when bullet not found
- Children range ends at next top-level `*` bullet or non-indented line

#### Find-EntityTag

- Finds `- @tag: value` within children range (case-insensitive tag matching)
- Strips leading `@` from tag name before comparison
- Returns last occurrence when multiple exist (for update semantics)
- Returns `$null` when tag not found
- Returned object: `TagIdx`, `Tag`, `Value`

#### Set-EntityTag

- Updates existing tag: replaces line content in-place
- Appends new tag: inserts at children end position
- Returns updated children end index (incremented by 1 if new line inserted)
- Operates on `List[string]` lines — modifies in-place

#### New-EntityBullet

- Creates `* EntityName` line with optional `@tag` children
- Ensures blank line before new entity if previous line isn't blank
- Tags sorted alphabetically (deterministic order via `SortedKeys`)
- Supports both single-value and array-value tags
- Returns insertion end index

#### Ensure-EntityFile

- Creates file with `## Gracz`, `## Postać (Gracz)`, and `## Przedmiot` sections if not exists
- Returns path unchanged if file already exists
- UTF-8 no BOM encoding
- Uses default path (`$PSScriptRoot/entities.md`) when no path parameter

#### Write-EntityFile

- Writes `List[string]` lines to file joined with specified newline style
- UTF-8 no BOM encoding
- Supports both `\n` and `\r\n` newline styles

#### Read-EntityFile

- Reads file into `List[string]` lines
- Detects newline style: CRLF vs LF
- Returns hashtable with `Lines` and `NL` properties
- Handles both newline styles correctly

#### Resolve-EntityTarget

- Ensures file exists (calls `Ensure-EntityFile`)
- Creates section if needed (appends `## Type` header)
- Creates bullet if needed (with `InitialTags`)
- Returns hashtable: `Lines`, `NL`, `BulletIdx`, `ChildrenStart`, `ChildrenEnd`, `FilePath`, `Created`
- `Created` is `$true` when a new bullet was created, `$false` when existing
- Re-finds section/bullet after insertion to return accurate indices

#### ConvertTo-EntitiesFromPlayers

- Generates `entities.md` content from `Get-Player` data
- `## Gracz` section: player entries with `@margonemid`, `@prfwebhook`, `@trigger`
- `## Postać (Gracz)` section: character entries with `@należy_do`, `@alias`, PU tags (`@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`), `@info`
- Skips players with blank names
- PU values formatted with invariant culture (period decimal separator)
- `@pu_nadmiar` only written when non-zero
- UTF-8 no BOM output

---

### charfile-helpers.ps1 — 5 helpers

**Test file**: `charfile-helpers.Tests.ps1` | **Loading**: dot-source `charfile-helpers.ps1`, temp dir with fixtures | **Status**: implemented

Tests character file parsing and writing helpers. Creates 4 in-memory fixture files: full character file, empty/template file, angle-bracket URL file, multi-line Stan file.

#### Read-CharacterFile — Full character file parsing

- `CharacterSheet`: parses URL from `**Karta Postaci:**` line
- `RestrictedTopics`: parses content from `**Tematy zastrzeżone:**` section
- `Condition`: parses content from `**Stan:**` section
- `SpecialItems`: parses bullet list from `**Przedmioty specjalne:**` — count = 2, items match `*Magiczny miecz*` and `*Tarcza ognia*`
- `Reputation.Positive`: parses nested tier — 2 entries, Erathia with detail `*obronie*`, Steadwick without detail
- `Reputation.Neutral`: parses inline format — 3 entries, first is `Deyja`
- `Reputation.Negative`: parses nested tier with detail — 2 entries, `Nighon` with `*Thant*`
- `AdditionalNotes`: parses bullet list — 2 entries, first matches `*bliznę*`
- `DescribedSessions`: parses `### date, title, narrator` headers — 2 sessions, correct Title/Narrator/Date

#### Read-CharacterFile — Empty/template file

- `RestrictedTopics`: returns null for `"brak"` placeholder
- `SpecialItems`: returns empty array for `"Brak."` placeholder
- `AdditionalNotes`: returns empty array for `"Brak."` placeholder
- `Reputation.Neutral`: parses inline format with many entries (> 5)

#### Read-CharacterFile — Angle-bracket URL

- Strips angle brackets: `<https://...>` → bare URL
- Dash-only reputation tiers (`- Pozytywna: -`): Positive and Negative counts = 0

#### Read-CharacterFile — Multi-line Stan

- Joins multi-line condition text: result matches both `*Zginęła*` and `*duszy*`

#### Read-CharacterFile — Non-existent file

- Returns `$null` for missing file path

#### Find-CharacterSection

- Finds section by name: `HeaderIdx` correct, `ContentStart` = line after header
- Returns `$null` for missing section name

#### Write-CharacterFileSection

- Replaces section content in-place on `List[string]` lines
- Updates inline value via `-InlineValue` parameter

#### Format-ReputationSection

- Inline format: renders `- Pozytywna: Erathia, Steadwick` when no entries have details
- Nested format: renders `- Pozytywna:` + indented `    - Erathia: pomógł w obronie` + `    - Steadwick` when any entry has detail
- Empty tiers: renders `- Pozytywna: `, `- Neutralna: `, `- Negatywna: ` (with trailing space)

---

### przedmiot-entity.Tests.ps1 — Przedmiot Type Tests

**Test file**: `przedmiot-entity.Tests.ps1` | **Loading**: dot-source `entity-writehelpers.ps1`, temp dir | **Status**: implemented

Focused tests for Przedmiot (item) entity type support in entity-writehelpers.

#### Przedmiot type mappings in entity-writehelpers

- `EntityTypeMap['przedmiot']` → `'Przedmiot'`
- `EntityTypeMap['przedmioty']` → `'Przedmiot'` (plural variant)
- `TypeToHeader['Przedmiot']` → `'Przedmiot'`

#### Ensure-EntityFile includes Przedmiot section

- Creates new `entities.md` with `## Przedmiot`, `## Gracz`, and `## Postać (Gracz)` sections
- Verifies all three section headers present in file content

#### Resolve-EntityTarget for Przedmiot

- Creates new Przedmiot entity with `@należy_do` tag via `InitialTags`
- Writes file and verifies: bullet `* Zaklęty miecz` present, `@należy_do: Erdamon` present
- `Created` = `$true` for new entity
- Finds existing Przedmiot entity without creating duplicate: `Created` = `$false`, `BulletIdx` ≥ 0

---

### admin-state.ps1 — 2 helpers

**Test file**: `admin-state.Tests.ps1` | **Loading**: Pattern C

#### Get-AdminHistoryEntries

- Parses `    - ### header` lines from state file
- Returns `HashSet[string]` (case-insensitive via `OrdinalIgnoreCase`)
- Normalizes: trims whitespace, collapses multiple spaces via `$script:MultiSpacePattern`
- Returns empty `HashSet` for non-existent file
- Skips lines not matching `$script:HistoryEntryPattern`
- Ignores blank headers (length 0 after trim)

#### Add-AdminHistoryEntry

- Appends timestamped entry block to file
- Timestamp format: `- YYYY-MM-dd HH:mm (UTC+HH:MM):`
- Headers sorted chronologically (ordinal sort)
- Adds `### ` prefix to headers that don't already start with `### `
- Creates file with preamble if it doesn't exist (creates parent directory too)
- Empty headers array → no-op (early return)
- UTF-8 no BOM encoding

---

### admin-config.ps1 — 3 helpers

**Test file**: `admin-config.Tests.ps1` | **Loading**: Pattern C

#### Resolve-ConfigValue

- Priority 1: explicit value (non-whitespace) → returned immediately
- Priority 2: environment variable → returned if set and non-whitespace
- Priority 3: local config file key → returned if present and non-whitespace
- All sources empty → returns `$null`
- Empty string / whitespace-only values are treated as absent at every level

#### Get-AdminConfig

- Returns hashtable with resolved paths: `RepoRoot`, `ModuleRoot`, `EntitiesFile`, `TemplatesDir`, `ResDir`, `CharactersDir`, `PlayersFile`
- `RepoWebhook` and `BotUsername` resolved via `Resolve-ConfigValue` chain (explicit → env var → config file)
- `Overrides` hashtable: additional keys merged into config, existing keys not overwritten
- Loads `local.config.psd1` from `$PSScriptRoot` (mock via fixture copy)

#### Get-AdminTemplate

- Loads template file content from templates directory
- Performs `{Placeholder}` substitution from `Variables` hashtable
- Throws `"Template not found: ..."` for missing template file
- Unmatched placeholders remain in output (no error for missing variables)
- `-TemplatesDir` override: uses custom directory instead of `$PSScriptRoot/templates`

---

### format-sessionblock.ps1 — 2 helpers

**Test file**: `format-sessionblock.Tests.ps1` | **Loading**: Pattern C

#### ConvertTo-Gen4MetadataBlock

- **Lokacje**: renders `- @Lokacje:` with nested `    - LocationName` items
- **PU**: renders `- @PU:` with `    - Character: Value` pairs, decimal formatted with invariant culture
- **PU null value**: renders `    - Character:` (no value after colon)
- **Logi**: renders `- @Logi:` with nested `    - URL` items
- **Zmiany**: renders three-level structure: `    - EntityName` → `        - @tag: value`
- **Zmiany**: tag names without `@` prefix get one prepended
- **Intel**: renders `    - RawTarget: Message` pairs
- Returns `$null` for empty/null `Items` parameter

#### ConvertTo-SessionMetadata

- Renders all blocks in canonical order: Lokacje, Logi, PU, Zmiany, Intel
- Skips null blocks (from `ConvertTo-Gen4MetadataBlock` returning `$null`)
- Returns empty string when all blocks are empty
- Blocks joined by `$NL` (newline parameter)

---

### set-player.ps1 — `Set-Player`

**Test file**: `set-player.Tests.ps1` | **Loading**: Pattern A + temp dir

#### Set-Player

- Updates `@prfwebhook` tag in `entities.md` under `## Gracz` section
- Updates `@margonemid` tag
- Triggers: removes all existing `@trigger` lines before adding new ones
- Creates player entity entry if it doesn't exist (via `Resolve-EntityTarget`)
- Webhook validation: throws for URLs not matching `https://discord.com/api/webhooks/*`
- `-WhatIf`: no file modification occurs
- File verification after write: tag values match input values

---

### set-playercharacter.ps1 — `Set-PlayerCharacter`

**Test file**: `set-playercharacter.Tests.ps1` | **Loading**: Pattern A + temp dir

#### Set-PlayerCharacter

- **Target 1 — entities.md**:
- Updates PU tags: `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`
- PU derivation: SUMA present + ZDOBYTE missing → derives `ZDOBYTE = SUMA - PUStart`
- Creates entity entry with `@należy_do: <PlayerName>` under `## Postać (Gracz)` if character doesn't exist
- Aliases: additive — existing aliases preserved, new ones appended if not duplicate
- `-Status`: writes `@status: <Value> (YYYY-MM:)` — validates `Aktywny`, `Nieaktywny`, `Usunięty`
- Auto-creates `Przedmiot` entities for unknown items in `-SpecialItems` (with `@należy_do: <CharacterName>`)
- **Target 2 — Postaci/Gracze/<Name>.md** (via `charfile-helpers.ps1`):
- `-CharacterSheet`: updates inline value on `**Karta Postaci:**` header
- `-RestrictedTopics`, `-Condition`: replaces section content
- `-SpecialItems`: replaces `**Przedmioty specjalne:**` section (full-replace)
- `-ReputationPositive`/`-ReputationNeutral`/`-ReputationNegative`: renders three-tier reputation via `Format-ReputationSection`
- `-AdditionalNotes`: replaces `**Dodatkowe informacje:**` section
- `-CharacterFile`: explicit path override (auto-resolved from `Get-PlayerCharacter` if omitted)
- `-WhatIf`: no file modification occurs (both targets)
- File verification after write: PU values, aliases, and character file sections match expectations

---

### set-playercharacter-charfile.Tests.ps1 — Character File Write Tests

**Test file**: `set-playercharacter-charfile.Tests.ps1` | **Loading**: dot-source `charfile-helpers.ps1` + `entity-writehelpers.ps1`, temp dir | **Status**: implemented

Focused tests for `Write-CharacterFileSection` and `Format-ReputationSection` operating on character `.md` files. Uses a shared template fixture (`$script:CharFileTemplate`) copied to temp dir per test.

#### Write-CharacterFileSection — Condition update

- Replaces `**Stan:**` section content with new value (`'Ranny, złamana ręka.'`)
- Original value (`'Zdrowy.'`) no longer present after replacement

#### Write-CharacterFileSection — SpecialItems update

- Replaces `**Przedmioty specjalne:**` section with bullet list (`'- Magiczny miecz'`, `'- Tarcza ognia'`)
- Original `'Brak.'` placeholder removed

#### Write-CharacterFileSection — Reputation partial update

- Updates only Positive tier while preserving existing Neutral/Negative tiers
- Reads existing reputation via `Read-CharacterFile`, modifies Positive, renders via `Format-ReputationSection`
- Verifies `'Erathia: walczył w obronie'` present and `'Neutralna: Deyja, Erathia'` preserved

#### Write-CharacterFileSection — Opisane sesje boundary

- Updates `**Dodatkowe informacje:**` section without modifying content after `**Opisane sesje:**`
- Session headers (`### 2025-01-15, Test session, Narrator`) and body content remain intact

#### Write-CharacterFileSection — CharacterSheet inline update

- Updates `**Karta Postaci:**` inline value from old URL to `'https://new.example.com/sheet'`
- Uses `-InlineValue` parameter (not `-NewContent`)

---

### new-playercharacter.ps1 — `New-PlayerCharacter`

**Test file**: `new-playercharacter.Tests.ps1` | **Loading**: Pattern A + temp dir

#### New-PlayerCharacter

- Creates character entry under `## Postać (Gracz)` with `@należy_do` and `@pu_startowe` tags
- Bootstraps `## Gracz` entry for the player if none exists
- Creates `Postaci/Gracze/<CharacterName>.md` from template (verify file content)
- Initial character file properties: `-Condition`, `-SpecialItems`, `-ReputationPositive`/`-ReputationNeutral`/`-ReputationNegative`, `-AdditionalNotes` applied to character file via `charfile-helpers.ps1`
- `-NoCharacterFile`: skips character file creation
- Throws for duplicate character name
- `InitialPUStart`: uses provided value or falls back to `Get-NewPlayerCharacterPUCount`
- Fallback: if `Get-NewPlayerCharacterPUCount` is unavailable, defaults to 20
- `-WhatIf`: no file modification occurs
- Returns result object: `PlayerName`, `CharacterName`, `PUStart`, `EntitiesFile`, `CharacterFile`, `PlayerCreated`

---

### new-player.ps1 — `New-Player`

**Test file**: `new-player.Tests.ps1` | **Loading**: Pattern A + temp dir

#### New-Player

- Creates `## Gracz` entity entry with `@margonemid`, `@prfwebhook`, `@trigger` tags in `entities.md`
- Duplicate detection: throws `"Player '...' already exists in entities.md"` for existing player
- Webhook validation: throws for URLs not matching `https://discord.com/api/webhooks/*`
- Optional first character: `-CharacterName` delegates to `New-PlayerCharacter` (creates both entity entry and character file)
- `-WhatIf`: no file modification occurs
- Returns result object: `PlayerName`, `MargonemID`, `PRFWebhook`, `Triggers`, `EntitiesFile`, `CharacterName`, `CharacterFile`
- Character-related fields null when no `-CharacterName` provided

---

### remove-playercharacter.ps1 — `Remove-PlayerCharacter`

**Test file**: `remove-playercharacter.Tests.ps1` | **Loading**: Pattern A + temp dir | **Status**: implemented

#### Remove-PlayerCharacter

- Writes `@status: Usunięty (YYYY-MM:)` to character entity under `## Postać (Gracz)`
- Does **not** delete the entity entry — entity and `@należy_do` tag remain intact
- `-ValidFrom` parameter: uses specified month; defaults to current month when omitted
- `-WhatIf`: file content unchanged after call
- `ConfirmImpact` is `High` — requires `-Confirm:$false` for non-interactive execution

---

### new-session.ps1 — `New-Session`

**Test file**: `new-session.Tests.ps1` | **Loading**: Pattern A

#### New-Session

- Generates Gen4 format session string (returns string, does NOT write to disk)
- Header format: `### yyyy-MM-dd, Title, Narrator`
- Date range: `### yyyy-MM-dd/DD, Title, Narrator` (DD from DateEnd)
- DateEnd validation: throws if different month from Date
- DateEnd validation: throws if DateEnd ≤ Date
- Metadata rendered in canonical order: Lokacje, Logi, PU, Zmiany, Intel
- `-Content`: free-form body text appended after metadata
- Empty metadata: no metadata section in output (just header)
- Round-trip compatible with `Get-Session -IncludeContent`

---

### set-session.ps1 — `Set-Session` + 5 helpers

**Test file**: `set-session.Tests.ps1` | **Loading**: Pattern B + temp dir

#### Find-SessionInFile

- Locates session section by exact header text match
- Locates session section by date match
- Returns section boundaries (start/end line indices)
- Returns `$null` when session not found

#### Split-SessionSection

- Decomposes section into `MetaBlocks`, `PreservedBlocks`, `BodyLines`
- MetaTags recognized: `pu`, `logi`, `lokalizacje`/`lokacje`, `zmiany`, `intel`
- PreservedTags recognized: `objaśnienia`, `efekty`, `komunikaty`, `straty`, `nagrody`
- Content inside code fences (```) not parsed as metadata
- Gen2 italic location line classified as metadata

#### ConvertTo-Gen4FromRawBlock

- Converts Gen3 tag names to Gen4 `@`-prefixed (`Lokalizacje` → `@Lokacje`)
- Re-indents children to 4-space base indent

#### ConvertFrom-ItalicLocation

- Converts `*Lokalizacja: Erathia, Steadwick*` → Gen4 `- @Lokacje:\n    - Erathia\n    - Steadwick`

#### ConvertFrom-PlainTextLog

- Converts `Logi: https://example.com/log1` → Gen4 `- @Logi:\n    - https://example.com/log1`

#### Set-Session

- Full metadata replacement (not merge — replaces existing metadata blocks)
- Format upgrade (`-UpgradeFormat`): converts Gen2/Gen3 to Gen4 format
- Preserved blocks (`Objaśnienia`, `Efekty`, etc.) kept as-is through updates
- Pipeline input: accepts Session object or explicit `-Date` + `-File`
- `-WhatIf`: no file modification

---

### send-discordmessage.ps1 — `Send-DiscordMessage`

**Test file**: `send-discordmessage.Tests.ps1` | **Loading**: Pattern A

#### Send-DiscordMessage

- Webhook URL validation: throws for URLs not matching `https://discord.com/api/webhooks/*`
- JSON payload: contains `content` key, optional `username` key
- `-WhatIf`: returns result with `WhatIf=$true`, `Success=$false`, `StatusCode=$null` — no HTTP call made
- ShouldProcess integration: respects `$ConfirmPreference`
- Return object schema: `Webhook`, `StatusCode`, `Success`, `WhatIf`
- Note: actual HTTP POST testing requires integration test setup (not unit-testable without HTTP mocking)

---

### get-gitchangelog.ps1 — `Get-GitChangeLog` + 1 helper

**Test file**: `get-gitchangelog.Tests.ps1` | **Loading**: Pattern B

#### ConvertFrom-CommitLine

- Parses `COMMIT<US>hash<US>date<US>name<US>email` format from regex match
- `CommitDate` parsed via `DateTimeOffset.Parse` with `InvariantCulture`
- Fallback: `datetime.Parse` when `DateTimeOffset.Parse` fails
- Returns `PSCustomObject` with `CommitHash`, `CommitDate`, `AuthorName`, `AuthorEmail`, `Files` (empty List)
- Invalid date string → `CommitDate=$null`

#### Get-GitChangeLog

- Note: testing the full function requires either a real git repo or mocking at the process level. Test the parameter validation and output structure, mock the function for consumers.
- `-NoPatch`: produces file-level change info only (no patch content)
- `-PatchFilter`: only stores matching patch lines
- Change types: `A` (Added), `D` (Deleted), `M` (Modified), `R` (Renamed), `C` (Copied)
- Rename detection: `R` entries have `RenameScore` and `OldPath` populated
- Date filtering: `-MinDate`/`-MaxDate` maps to `--after`/`--before` git arguments

---

### invoke-playercharacterpuassignment.ps1 — `Invoke-PlayerCharacterPUAssignment`

**Test file**: `invoke-playercharacterpuassignment.Tests.ps1` | **Loading**: Pattern A, mock `Get-GitChangeLog`, `Get-Session`, `Send-DiscordMessage`

#### Invoke-PlayerCharacterPUAssignment

- Date range: `Year`/`Month` → first and last day of that month
- Default range: last 2 months (no explicit Year/Month)
- Git optimization: calls `Get-GitChangeLog -NoPatch` to narrow file scan
- Filters to sessions with PU entries only
- Excludes already-processed sessions (via `Get-AdminHistoryEntries`)
- **Fail-early**: unresolved character names throw `ErrorRecord` with ErrorId `UnresolvedPUCharacters` and structured `TargetObject`
- PU calculation per `pu-unification-logic.md`:
    - `BasePU = 1 + Sum(session PU values)` (1 = unconditional monthly base)
    - If `BasePU > 5`: excess → overflow pool (`OverflowPU = BasePU - 5`, `GrantedPU = 5`)
    - If `BasePU ≤ 5` and character has `PUExceeded > 0`: supplement from overflow up to cap
    - `GrantedPU` capped at 5. No flooring — decimal PU granted as-is
    - `RemainingPUExceeded = (OriginalPUExceeded - UsedExceeded) + OverflowPU`
- `-UpdatePlayerCharacters`: calls `Set-PlayerCharacter` (writes PUSum, PUTaken, PUExceeded)
- `-SendToDiscord`: calls `Send-DiscordMessage` per-player with username `Bothen`
- `-AppendToLog`: appends processed headers to `pu-sessions.md`
- `-WhatIf`: all side effects suppressed
- Returns assignment result objects always (regardless of switches)
- `-PlayerName` filter: processes only matching player's characters
- Return schema: `CharacterName`, `PlayerName`, `Character`, `BasePU`, `GrantedPU`, `OverflowPU`, `UsedExceeded`, `OriginalPUExceeded`, `RemainingPUExceeded`, `NewPUSum`, `NewPUTaken`, `SessionCount`, `Sessions`, `Message`, `Resolved`

---

### test-playercharacterpuassignment.ps1 — `Test-PlayerCharacterPUAssignment`

**Test file**: `test-playercharacterpuassignment.Tests.ps1` | **Loading**: Pattern A, mock dependencies

#### Test-PlayerCharacterPUAssignment

- Runs `Invoke-PlayerCharacterPUAssignment` in compute-only mode (`-WhatIf`)
- Catches `UnresolvedPUCharacters` error by matching `FullyQualifiedErrorId` and extracts `TargetObject`
- Detects malformed/null PU values
- Detects duplicate PU entries within the same session
- Uses `Get-Session -IncludeFailed -IncludeContent` to find sessions with broken date headers containing `- PU:` content
- Cross-references `pu-sessions.md` history against all sessions to detect stale entries
- Returns structured diagnostic: `OK`, `UnresolvedCharacters`, `MalformedPU`, `DuplicateEntries`, `FailedSessionsWithPU`, `StaleHistoryEntries`, `AssignmentResults`
- `OK = $true` only when all diagnostic arrays are empty

---

## Implementation Order

Tests should be implemented bottom-up along the dependency chain:

| Phase | Test Files | Status | Rationale |
|-------|-----------|--------|-----------|
| **1. Foundation** | `TestHelpers.ps1`, `.pesterconfig.psd1`, `fixtures/*`, `Robot.Tests.ps1`, `get-reporoot.Tests.ps1`, `parse-markdownfile.Tests.ps1` | **done** | Infrastructure and leaf functions first |
| **2. Pure helpers** | `format-sessionblock.Tests.ps1`, `admin-config.Tests.ps1`, `resolve-name.Tests.ps1`, `charfile-helpers.Tests.ps1` | charfile-helpers **done** | No I/O dependencies |
| **3. Core parsing** | `get-markdown.Tests.ps1`, `get-entity.Tests.ps1`, `entity-status.Tests.ps1`, `get-player.Tests.ps1`, `get-nameindex.Tests.ps1`, `resolve-narrator.Tests.ps1`, `get-session.Tests.ps1`, `get-entitystate.Tests.ps1`, `get-playercharacter.Tests.ps1`, `get-playercharacter-state.Tests.ps1`, `get-newplayercharacterpucount.Tests.ps1` | get-markdown, entity-status, get-playercharacter-state **done** | Bottom-up dependency chain |
| **4. Write ops** | `entity-writehelpers.Tests.ps1`, `przedmiot-entity.Tests.ps1`, `admin-state.Tests.ps1`, `set-player.Tests.ps1`, `set-playercharacter.Tests.ps1`, `set-playercharacter-charfile.Tests.ps1`, `new-playercharacter.Tests.ps1`, `new-player.Tests.ps1`, `remove-playercharacter.Tests.ps1`, `new-session.Tests.ps1`, `set-session.Tests.ps1` | przedmiot-entity, set-playercharacter-charfile, remove-playercharacter **done** | File I/O via temp directories |
| **5. Integration** | `send-discordmessage.Tests.ps1`, `get-gitchangelog.Tests.ps1`, `invoke-playercharacterpuassignment.Tests.ps1`, `test-playercharacterpuassignment.Tests.ps1` | — | Mock-heavy orchestrators |

# Robot PowerShell Module

## Overview

The `Robot` module is a set of PowerShell functions designed for parsing, managing, and resolving lore and metadata from the Nerthus repository. It extracts structured information from Markdown files (such as players, characters, sessions, entities, and locations) and enriches it using Git history.

### Core Design Principles
- **Minimal external dependencies**: The module relies on Git and native PowerShell/.NET features at runtime. [Pester](https://pester.dev/) (v5.0+) is required for the test suite.
- **Cross-platform**: Compatible with Windows PowerShell 5.1 and PowerShell Core 7.0+.
- **Performance-focused**: Uses .NET classes for file I/O, regex, and process execution for optimal performance.
- **Streaming architecture**: Git output is parsed line-by-line from `StandardOutput` to avoid materializing large diffs into memory.

## Architecture

### Data Flow

The module follows a layered data pipeline:

```
Markdown Files ──> Get-Markdown ──> Structured Document Objects
                   (delegates to      │
                  parse-markdownfile   │
                   via RunspacePool)   │
                        ┌─────────────┼──────────────────────┐
                        ▼             ▼                      ▼
                   Get-Player    Get-Entity            Get-Session
                   (Gracze.md)  (entities*.md)        (all *.md files)
                        │    ▲        │                      │
                        │    └─ overrides                    │
                        └────────┬────┘                      │
                                 ▼                           │
                           Get-NameIndex ◄───────────────────┤
                           (token index)                     │
                                 │                           │
                        ┌────────┘                           │
                        ▼                                    ▼
                  Resolve-Name ──────────────────> Resolve-Narrator
                  (general)                       (per-session)

  Get-GitChangeLog (standalone — wraps git log, used by PU workflow)

  Pass 2 (optional):    Get-Entity ─────┐
                                        ├──> Get-EntityState (merged entity state)
                        Get-Session ────┘    (Zmiany + @status overrides applied)

  Pass 3 (optional):    Get-PlayerCharacter -IncludeState
                            │          │          │
                        Get-EntityState │   charfile-helpers.ps1
                        (layers 2+3)   │   (layer 1: character file)
                                       ▼
                           Three-layer merged character state

  Write path (entities):
                   entity-writehelpers.ps1 (shared file manipulation)
                        ▲         ▲         ▲         ▲
                        │         │         │         │
                   Set-Player  Set-Player  New-Player  New-Player
                               Character   Character
                        │         │         │         │
                        ▼         ▼         ▼         ▼
                     entities.md (write target, never Gracze.md)

  Write path (character files):
                   charfile-helpers.ps1 (character file read/write)
                        ▲                ▲
                        │                │
                   Set-Player       New-Player
                    Character        Character
                        │                │
                        ▼                ▼
                   Postaci/Gracze/<Name>.md (dual-target writes)

  Write path (soft-delete):
                   Remove-PlayerCharacter
                        │
                        ▼
                   entities.md (@status: Usunięty)

  Session write path:
                   format-sessionblock.ps1 (shared Gen4 rendering)
                        ▲                ▲
                        │                │
                   New-Session       Set-Session
                   (string output)  (in-place file modification)
                                    (supports -UpgradeFormat Gen2/3→Gen4)

  Admin/PU workflow:
        Get-GitChangeLog ──> Get-Session ──> Invoke-PlayerCharacterPUAssignment
                                                    │         │         │
                                  ┌─────────────────┘         │         └──────────┐
                                  ▼                           ▼                    ▼
                        Set-PlayerCharacter        Send-DiscordMessage    admin-state.ps1
                        (entities.md update)       (webhook POST)        (pu-sessions.md)

        Get-NewPlayerCharacterPUCount (pure computation, used by New-PlayerCharacter)
        Test-PlayerCharacterPUAssignment (diagnostic validation wrapper)
```

`Get-Markdown` is the foundational parser — all other functions consume its output. It delegates per-file parsing to `parse-markdownfile.ps1` via RunspacePool workers for parallel I/O. `Get-Player` calls `Get-Entity` for override injection. `Get-NameIndex` builds a unified token dictionary from players and entities, which powers the two `Resolve-*` functions (`Resolve-Narrator` uses `Resolve-Name` internally). `Get-Session` orchestrates the full pipeline: it calls `Get-Entity`, `Get-Player`, `Get-NameIndex`, `Get-Markdown`, and `Resolve-Narrator` internally to produce fully enriched session objects. `Get-EntityState` performs a second-pass merge of entity file data with session-based overrides (`- Zmiany:` blocks), resolving entity names via `Resolve-Name` and applying `@tag` overrides (including `@status`) chronologically. `Get-PlayerCharacter -IncludeState` performs a third-pass three-layer merge: character file data (layer 1, undated baseline), entities.md overrides (layer 2), and session `@zmiany` overrides (layer 3, via `Get-EntityState`), producing enriched character state with `Condition`, `Reputation`, `SpecialItems`, etc. `Get-GitChangeLog` provides structured Git history — used by `Invoke-PlayerCharacterPUAssignment` to optimize file scanning to only files changed in the target date range. The PU workflow (`Invoke-PlayerCharacterPUAssignment`) ties together `Get-GitChangeLog`, `Get-Session`, `Get-PlayerCharacter`, `Set-PlayerCharacter`, `Send-DiscordMessage`, and `admin-state.ps1` to compute and optionally apply monthly PU awards. The authoritative specification for PU computation is `pu-unification-logic.md`. The session write path (`New-Session`, `Set-Session`) uses `format-sessionblock.ps1` for Gen4 metadata rendering. `Set-Session` supports in-place modification with `-UpgradeFormat` for Gen2/Gen3→Gen4 migration. `Remove-PlayerCharacter` performs soft-deletion via `@status: Usunięty`. `New-Player` creates player entity entries and optionally bootstraps their first character via `New-PlayerCharacter`.

### Entity Override System

`Get-Player` merges data from two sources: the primary `Gracze.md` file and `entities*.md` override files. Entities of type `Gracz` or `Postać (Gracz)` are matched to players by name (or `@należy_do` tag) and their aliases, PU values, triggers, and webhooks are injected into the player roster. This allows the entities file to act as a supplementary override layer without modifying `Gracze.md`.

### Session-Based Entity Overrides

`Get-EntityState` merges entity file data with session-based overrides via a two-pass architecture:

1. **Pass 1**: `Get-Entity` (file data only) + `Get-Session` (extracts `- Zmiany:` blocks as raw data)
2. **Pass 2**: `Get-EntityState` merges both chronologically, applying `@tag` overrides from sessions to entity objects

**Zmiany syntax** (Gen3 sessions):
```markdown
### 2024-06-15, Ucieczka z Erathii, Dracon
- Lokalizacje:
  - Erathia
  - Steadwick
- PU:
  - Xeron: 0.3
- Zmiany:
  - Xeron Demonlord
    - @grupa: Gildia Handlarzy
    - @lokacja: Steadwick
  - Kupiec Orrin
    - @lokacja: Steadwick
```

**Gen4 syntax** (`@`-prefixed metadata tags):
```markdown
### 2025-06-15, Ucieczka z Erathii, Dracon
- @Lokacje:
  - Erathia
  - Steadwick
- @PU:
  - Xeron: 0.3
- @Logi:
  - https://example.com/log1
- @Zmiany:
  - Xeron Demonlord
    - @grupa: Gildia Handlarzy
    - @lokacja: Steadwick
- Notatki MG: free-form text, ignored by parser
```

**Auto-dating**: Tags in `- Zmiany:` without explicit temporal ranges `(YYYY-MM:YYYY-MM)` receive the session date as their `ValidFrom` (open-ended). Tags with explicit ranges use those instead.

**Override priority**: Most-recent-dated entry wins regardless of source (entity file or session Zmiany). History lists are sorted by `ValidFrom` after merge, so `Get-LastActiveValue` naturally returns the most recently dated active entry.

**Location model** (three tiers):
1. **Persistent `@lokacja` in entity file** — where an entity permanently resides
2. **Session visits** (`- Lokalizacje:`) — transient, where characters were during that session
3. **Persistent `@lokacja` in `- Zmiany:`** — permanent move as session outcome

Query resolution for "where was X on date Y?": session visits first → persistent `@lokacja` fallback.

### @Intel Tag

`@Intel` declares targeted messages dispatched to entities via Discord webhooks. Parsed from `- @Intel:` (Gen4) or `- Intel:` (Gen3) session blocks. Always resolved when present (no switch guard).

Targeting directives:
- `Grupa/Name`: Fan-out to all entities with `@grupa` membership matching the named organization (at session date)
- `Lokacja/Name`: Fan-out to all entities `@lokacja`'d in the named location or its sub-locations (at session date)
- `Name` (bare): Direct targeting, no fan-out. Comma-separated for multi-recipient.

Syntax:
```markdown
- @Intel:
    - Grupa/Nocarze: Message to all NOC members
    - Lokacja/Erathia: Message to everyone in Erathia
    - Rion: Private message
    - Kyrre, Adrienne Darkfire: Message to multiple recipients
```

`@prfwebhook` is supported on any entity type (not just Players). Organizations, locations, and NPCs can have their own Discord webhook endpoints via the generic Overrides system. For `Postać (Gracz)` entities without their own `@prfwebhook`, the owning Player's `PRFWebhook` is used as fallback.

### Session Deduplication

Sessions with identical headers appearing across multiple Markdown files (location logs, thread files, character files) are deduplicated. The merge strategy picks the "primary" instance with the richest metadata and unions all array fields (locations, logs, effects, PU entries, mentions, intel) across duplicates. Scalar field conflicts (title, format) emit warnings to stderr.

## Files

### Module Core
* `robot.psd1` — PowerShell module manifest (GUID `69ca95ec-45b6-43d5-bfa8-6a2eea6ea16b`). Declares exported functions, minimum PowerShell version (5.1), and module metadata.
* `robot.psm1` — Root module script that auto-discovers and dot-sources all `*.ps1` files in the module directory (excluding itself and `core.ps1`). Exports functions matching the `Verb-Noun` naming convention via regex filter.
* `parse-markdownfile.ps1` — Self-contained Markdown file parser script designed for `RunspacePool` worker threads. Extracted from `Get-Markdown` because RunspacePool threads don't share module scope. Accepts a single file path as positional parameter, returns a `PSCustomObject` with `FilePath`, `Headers`, `Sections`, `Lists`, and `Links`. Single-pass line-by-line scan with code block tracking, header hierarchy via stack, indent-normalized list nesting, and dual link extraction (Markdown `[text](url)` + plain URLs).

### Functions

#### Data Extraction

* **`Get-RepoRoot.ps1`** — Traverses up the directory tree from the current working directory to find the nearest `.git` folder. Uses `[System.IO.Directory]` and `[System.IO.Path]` for cross-platform compatibility. Throws if no repository root is found.

* **`Get-Markdown.ps1`** — Custom Markdown parser that extracts structural elements into typed objects:
    - **Headers**: Level, text, line number (1-based), and parent header reference (stack-based hierarchy tracking).
    - **Sections**: Content grouped by headers, with associated list items.
    - **List items**: Bullet and numbered types, with indent normalization (multiples of 2 spaces), parent-child relationships via stack, and section header references.
    - **Links**: Both `[text](url)` Markdown links and plain `https://` URLs.
    - Correctly handles fenced code blocks (``` markers toggle `$InCodeBlock` flag).
    - Accepts `-File` (single or array) or `-Directory` (recursive `*.md`/`*.markdown` scan, defaults to repo root).
    - Returns a single object (unwrapped) for single-file `-File` input, `List[object]` for multi-file or `-Directory` input.

* **`Get-GitChangeLog.ps1`** — Wraps `git log` with structured output parsing:
    - Uses `ProcessStartInfo` with `ArgumentList` (array-based) to handle paths containing spaces.
    - Stderr is captured asynchronously via `.add_ErrorDataReceived()` (.NET event handler) to prevent pipe deadlocks.
    - Custom commit format uses `%x1F` (Unit Separator) as field delimiter.
    - Supports two modes: full patch (`-p`) and lightweight `--name-status` (`-NoPatch` switch).
    - Optional `-PatchFilter` parameter compiles a regex and only stores matching patch lines (plus hunk headers).
    - Change types: `A` (Added), `D` (Deleted), `M` (Modified), `R` (Renamed), `C` (Copied).
    - Rename detection via `--find-renames`; `RenameScore` is the similarity percentage.
    - Dates parsed as ISO 8601 via `DateTimeOffset.Parse` with `InvariantCulture` to avoid locale issues.
    - UTF-8 encoding enforced via `StandardOutputEncoding` and `core.quotepath=false`.

* **`Get-Player.ps1`** — Parses `Gracze.md` to build structured player objects:
    - Scans level-3 headers under the `## Lista` section (one header per player).
    - Extracts per-player: Margonem ID, PRFWebhook (Discord, validated URL prefix), triggers (restricted session topics).
    - Characters identified as list children of `Postaci:` entry containing `[Name](Path)` links. Active character marked with `**bold**`.
    - PU (Player Unit) values parsed from `PU: NADMIAR: X, STARTOWE: Y, SUMA: Z` format. Derived values auto-calculated: `ZDOBYTE = SUMA - STARTOWE` or `SUMA = STARTOWE + ZDOBYTE`. Values marked `BRAK` treated as null.
    - Builds a consolidated `Names` HashSet (case-insensitive) from player name + character names + aliases.
    - Post-parse: calls `Get-Entity` and injects overrides from entities of type `Gracz` or `Postać (Gracz)` — new players/characters are stubbed if not found in `Gracze.md`.

* **`Get-Entity.ps1`** — Parses entity registry files (`entities.md` and `*-*-ent.md` variants):
    - Multi-file support with precedence: files sorted by numeric suffix descending, so the lowest number has final override primacy (applied last). Base `entities.md` has lowest precedence.
    - Entities grouped by section header type (mapped via `$TypeMap`): NPC, Organizacja, Lokacja, Gracz, Postać (Gracz), Przedmiot.
    - Supported `@`-tags per entity:
        - `@alias` — time-scoped alternative names `(YYYY-MM:YYYY-MM)`.
        - `@lokacja` — time-scoped location assignment (for NPCs/orgs and location containment hierarchy).
        - `@drzwi` — time-scoped physical access connections (for locations).
        - `@zawiera` — declares child containment.
        - `@typ` — time-scoped type override.
        - `@należy_do` — time-scoped ownership linking (entity → player).
        - `@grupa` — time-scoped group membership (e.g. factions, organizations, alliances). Multiple active groups per entity. Stored in `Groups` (active array) and `GroupHistory` (full history).
        - `@status` — time-scoped entity lifecycle status (`Aktywny`, `Nieaktywny`, `Usunięty`). Defaults to `Aktywny` if absent. Stored in `Status` (active scalar) and `StatusHistory` (full history). Used by `Remove-PlayerCharacter` for soft-deletion and `Get-PlayerCharacter -IncludeState` for filtering.
        - Any other `@tag` → generic override stored in `Overrides` dictionary (e.g. `@pu_startowe`, `@info`, `@margonemid`, `@trigger`, `@prfwebhook`).
    - Temporal filtering: `-ActiveOn` date parameter filters aliases and metadata to only those valid at that point in time. Validity uses inclusive bounds with partial date support (YYYY, YYYY-MM, YYYY-MM-DD).
    - Canonical Name (CN) resolution in post-parse pass: non-location entities get `Type/Name`; locations get hierarchical paths via `@lokacja` chain resolution (e.g. `Lokacja/Enroth/Erathia/Ratusz Erathii`). Cycle detection prevents infinite loops.
    - Duplicate entity names across files are merged: names, aliases, overrides, and all history lists are combined.

* **`Get-EntityState.ps1`** — Second-pass entity enrichment via session Zmiany overrides:
    - Accepts pre-fetched entities (from `Get-Entity`) and sessions (from `Get-Session`).
    - For each session with `- Zmiany:` data, resolves entity names using the full `Resolve-Name` pipeline (exact lookup → declension → stem alternation → Levenshtein fuzzy matching).
    - When `Resolve-Name` returns a Player object (due to Player/Gracz priority dedup in the name index), maps back to the corresponding entity via shared names.
    - Applies `@tag` overrides (including `@status`) to entity history lists with auto-dating (session date as implicit `ValidFrom` for tags without explicit temporal ranges).
    - After all overrides are applied, sorts history lists (including `StatusHistory`) by `ValidFrom` and recomputes active scalar/array values for modified entities.
    - Supports `-ActiveOn` for temporal filtering of the merged state.

* **`Get-PlayerCharacter.ps1`** — Typed projection from `Get-Player` into per-character rows:
    - Flattens the nested Player→Characters structure into flat objects with `PlayerName` backreference and `Player` parent object link.
    - Supports `-PlayerName` and `-CharacterName` filters (case-insensitive via `[System.StringComparison]::OrdinalIgnoreCase`).
    - Pass-through `-Entities` parameter avoids redundant entity parsing.
    - `-IncludeState` switch: performs three-layer merge to produce enriched character state:
        - **Layer 1**: Character file (`Postaci/Gracze/<Name>.md`) — undated baseline parsed by `Read-CharacterFile` from `charfile-helpers.ps1`.
        - **Layers 2+3**: Entity overrides (entities.md + session `@zmiany`) — already merged by `Get-EntityState`.
        - Merged properties: `Status`, `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (Positive/Neutral/Negative), `AdditionalNotes`, `DescribedSessions`.
        - Last-dated entry wins for scalars; multi-valued properties use additive merge.
    - `-ActiveOn` parameter: temporal filtering for state properties.
    - `-IncludeDeleted` switch: includes characters with `@status: Usunięty` (filtered out by default when `-IncludeState` is set).

#### Data Modification

* **`Set-Player.ps1`** — Updates player-level metadata by writing to `entities.md`:
    - Writes `@prfwebhook`, `@margonemid`, and `@trigger` tags to the player's entity entry under `## Gracz`.
    - Creates the player entity entry if it doesn't exist.
    - Validates Discord webhook URL format (`https://discord.com/api/webhooks/*`).
    - Trigger replacement semantics: all existing `@trigger` lines are removed before adding new ones.
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `entity-writehelpers.ps1`.

* **`Set-PlayerCharacter.ps1`** — Dual-target writer for character PU values, metadata, and character file properties:
    - **Target 1 — `entities.md`**: Writes `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`, `@alias`, and `@status` tags under `## Postać (Gracz)`.
    - PU derivation rule (same as `Complete-PUData`): if SUMA present and ZDOBYTE missing → derives ZDOBYTE; if ZDOBYTE present and SUMA missing → derives SUMA.
    - Creates entity entry with `@należy_do: <PlayerName>` if the character doesn't exist.
    - Aliases are additive (existing aliases preserved, new ones appended if not duplicate).
    - `-Status` parameter: writes `@status: <Value> (YYYY-MM:)` with `ValidateSet("Aktywny", "Nieaktywny", "Usunięty")`.
    - Auto-creates `Przedmiot` entities for unknown items in `-SpecialItems` (with `@należy_do: <CharacterName>`).
    - **Target 2 — `Postaci/Gracze/<Name>.md`**: Writes character file sections via `charfile-helpers.ps1`. Parameters: `-CharacterSheet`, `-RestrictedTopics`, `-Condition`, `-SpecialItems`, `-ReputationPositive`/`-ReputationNeutral`/`-ReputationNegative`, `-AdditionalNotes`. Character file path auto-resolved from `Get-PlayerCharacter` or overridden with `-CharacterFile`.
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `entity-writehelpers.ps1` and `charfile-helpers.ps1`.

* **`New-Player.ps1`** — Creates a new player entry in `entities.md`:
    - Creates `## Gracz` entity entry with `@margonemid`, `@prfwebhook`, and `@trigger` tags.
    - Validates Discord webhook URL format (`https://discord.com/api/webhooks/*`).
    - Duplicate detection: throws if player already exists in `entities.md`.
    - Optionally creates first character by delegating to `New-PlayerCharacter` (pass `-CharacterName`, `-CharacterSheetUrl`, `-InitialPUStart`, `-NoCharacterFile`).
    - Returns structured result with `PlayerName`, `MargonemID`, `PRFWebhook`, `Triggers`, `EntitiesFile`, `CharacterName`, `CharacterFile`.
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `entity-writehelpers.ps1` and `admin-config.ps1`.

* **`New-PlayerCharacter.ps1`** — Creates a new character entry for an existing or new player:
    - Creates entity entry under `## Postać (Gracz)` with `@należy_do` and `@pu_startowe` tags.
    - Bootstraps `## Gracz` entry for the player if none exists.
    - Creates `Postaci/Gracze/<CharacterName>.md` from `player-character-file.md.template` (skip with `-NoCharacterFile`).
    - Optionally applies initial character file property values: `-Condition`, `-SpecialItems`, `-ReputationPositive`/`-ReputationNeutral`/`-ReputationNegative`, `-AdditionalNotes` (via `charfile-helpers.ps1`).
    - Duplicate detection: throws if character already exists in `entities.md`.
    - Falls back to PU start of 20 if `Get-NewPlayerCharacterPUCount` is not available.
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `entity-writehelpers.ps1`, `admin-config.ps1`, and `charfile-helpers.ps1`.

* **`Remove-PlayerCharacter.ps1`** — Soft-deletes a character by setting `@status: Usunięty` in `entities.md`:
    - Writes `@status: Usunięty (YYYY-MM:)` to the character's entity entry under `## Postać (Gracz)`.
    - Does **not** delete the character file or remove the entity entry.
    - Characters with status `Usunięty` are filtered out by `Get-PlayerCharacter -IncludeState` unless `-IncludeDeleted` is set.
    - `-ValidFrom` parameter (defaults to current month).
    - `ConfirmImpact` is `High` for safety.
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `entity-writehelpers.ps1`.

#### Session Management

* **`New-Session.ps1`** — Generates a Gen4-format session markdown string:
    - Builds a complete `### YYYY-MM-DD, Title, Narrator` section with `@`-prefixed metadata blocks.
    - Parameters: `-Date`, `-DateEnd` (multi-day, same month), `-Title`, `-Narrator`, `-Locations`, `-PU`, `-Logs`, `-Changes`, `-Intel`, `-Content`.
    - Returns a string — does **not** write to disk. The caller decides where to place the output.
    - Round-trip compatible with `Get-Session -IncludeContent`.
    - Dot-sources `format-sessionblock.ps1`.

* **`Set-Session.ps1`** — Modifies existing session metadata and/or body content in Markdown files:
    - Session identification: pipeline input from `Get-Session` or explicit `-Date` + `-File` parameters.
    - Metadata replacement is always full-replace (not merge). Pass `@()` to clear a block. Pass `$null` (or omit) to leave unchanged.
    - Supports `-Locations`, `-PU`, `-Logs`, `-Changes`, `-Intel`, `-Content` parameters, or `-Properties` hashtable.
    - `-UpgradeFormat` converts Gen2/Gen3 metadata to Gen4 `@`-prefixed syntax.
    - Non-metadata blocks (`Objaśnienia`, `Efekty`, `Komunikaty`, `Straty`, `Nagrody`) are preserved as-is during modification.
    - Internal helpers: `Find-SessionInFile` (section boundary detection), `Split-SessionSection` (decompose into meta/preserved/body), `ConvertTo-Gen4FromRawBlock`, `ConvertFrom-ItalicLocation`, `ConvertFrom-PlainTextLog`.
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `format-sessionblock.ps1`.

#### Admin & PU Workflows

* **`Invoke-PlayerCharacterPUAssignment.ps1`** — Monthly PU awarding workflow (see `pu-unification-logic.md` for the normative specification):
    - Determines date range from `Year`/`Month` parameters or `MinDate`/`MaxDate` (defaults to last 2 months — sessions may be documented late).
    - **Git optimization**: uses `Get-GitChangeLog -NoPatch` to identify files changed in the date range, then passes only those to `Get-Session` instead of scanning the full repository.
    - Filters to sessions with PU entries, then excludes already-processed headers via `Get-AdminHistoryEntries` on `.robot/res/pu-sessions.md`.
    - **Fail-early**: if any PU entry references an unresolved character name, throws a terminating error (`UnresolvedPUCharacters`) and aborts all processing before any side effects. The error's `TargetObject` contains structured unresolved character data.
    - PU calculation per character (per `pu-unification-logic.md`):
        - `BasePU = 1 + Sum(session PU values)` (1 = unconditional universal monthly base).
        - If `BasePU <= 5` and character has `PUExceeded > 0`: supplements from overflow pool up to cap.
        - If `BasePU > 5`: excess goes into overflow pool (unbounded) for future months.
        - Granted PU capped at 5 per month. No flooring — decimal PU granted as-is.
        - `RemainingPUExceeded = (OriginalPUExceeded - UsedExceeded) + OverflowPU`.
    - Side effects gated by switches:
        - `-UpdatePlayerCharacters`: calls `Set-PlayerCharacter` (writes PUSum, PUTaken, PUExceeded to `entities.md`).
        - `-SendToDiscord`: sends per-player grouped notifications via `Send-DiscordMessage` with username `Bothen`.
        - `-AppendToLog`: appends processed headers to `pu-sessions.md` via `Add-AdminHistoryEntry`.
    - Returns structured assignment result objects (always, regardless of switches).
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).
    - Dot-sources `admin-state.ps1` and `admin-config.ps1`.

* **`Test-PlayerCharacterPUAssignment.ps1`** — PU assignment diagnostic validation:
    - Default range: last 2 months (legacy parity).
    - Runs `Invoke-PlayerCharacterPUAssignment` in compute-only mode (`-WhatIf`).
    - Detects: unresolved character names, malformed/null PU values, duplicate PU entries within the same session.
    - Uses `Get-Session -IncludeFailed -IncludeContent` to find sessions with broken date headers (e.g. `2024-1-5`, `2024-13-01`) whose PU data would be silently dropped by the normal pipeline. Scans their content for `- PU:` sections and reports any PU candidates found.
    - Cross-references `pu-sessions.md` history against all repository sessions to detect stale entries — headers logged as processed that no longer match any session (renamed, deleted, or corrupted).
    - Returns a structured diagnostic object (`OK`, `UnresolvedCharacters`, `MalformedPU`, `DuplicateEntries`, `FailedSessionsWithPU`, `StaleHistoryEntries`, `AssignmentResults`).
    - Dot-sources `admin-state.ps1` and `admin-config.ps1`.

* **`Get-NewPlayerCharacterPUCount.ps1`** — Estimates initial PU for a new character:
    - Formula (legacy parity): `Floor((Sum(PUTaken) / 2) + 20)`, including only characters with `PUStart > 0`.
    - Pure computation, no side effects.
    - Returns structured result with `PU`, `PUTakenSum`, `IncludedCharacters`, `ExcludedCharacters`.
    - Used by `New-PlayerCharacter` as a fallback when `InitialPUStart` is not explicitly provided.

* **`Send-DiscordMessage.ps1`** — Low-level Discord webhook message sender:
    - Validates webhook URL format (`https://discord.com/api/webhooks/*`).
    - Builds JSON payload (`content`, `username`) and POSTs via .NET `HttpClient`.
    - Returns result object with `Webhook`, `StatusCode`, `Success` properties.
    - No retry logic at this level (handled by Phase 3 queue system).
    - `SupportsShouldProcess` (`-WhatIf`, `-Confirm`).

#### Data Extraction

* **`Get-Session.ps1`** — Full pipeline orchestrator for session metadata extraction:
    - Scans all `*.md` files (or specific file/directory) for level-3 headers containing dates.
    - Format detection heuristics:
        - **Gen 1** (2021-2022): Plain text, no structured metadata.
        - **Gen 2** (2022-2023): Italic location line `*Lokalizacja: ...*`, plain text logs.
        - **Gen 3** (2024-2025): List-based metadata (`- Lokalizacje:`, `- Logi:`, `- PU:`). `- Zmiany:` blocks contain entity state overrides (extracted to `Changes` property). Other tags like `- Efekty:` and `- Objaśnienia:` are present in source but not extracted to session object fields.
        - **Gen 4** (2025+): `@`-prefixed list-based metadata (`- @Lokacje:`, `- @PU:`, `- @Logi:`, `- @Zmiany:`, `- @Intel:`). Backwards compatible — Gen3 sessions continue to parse identically. Non-`@` items (e.g. `- Efekty:`, free-form notes) are ignored by the parser.
    - Date parsing from headers: `yyyy-MM-dd` format, supports date ranges like `2022-12-21/22` (stored as `Date` + `DateEnd`).
    - Title extraction: header text minus date and narrator parts.
    - Pre-fetches all dependencies in batch: `Get-Entity`, `Get-Player`, `Get-NameIndex`, and batch-parses all Markdown files via `Get-Markdown`.
    - PU values normalized (comma → period decimal separator).
    - Deduplication pass merges sessions with identical headers across files, using a scoring system to pick the primary instance.
    - `-IncludeMentions` switch enables entity mention extraction from session body text (stages 1/2/2b of name resolution, no fuzzy matching). Metadata lists (PU, Logi, Lokalizacje, Zmiany, Intel) are excluded from scanning.
    - `@Intel` tag support: parses `- @Intel:` (Gen4) or `- Intel:` (Gen3) blocks with targeting directives (`Grupa/`, `Lokacja/`, bare name). Resolves targets to recipient entities with Discord webhook URLs via temporal group membership and location occupancy analysis. `@prfwebhook` is supported on any entity type (not just Players).

#### Name Resolution

* **`Get-NameIndex.ps1`** — Builds a token-based reverse lookup dictionary:
    - Priority 1: Full names and registered aliases (exact entries).
    - Priority 2: Individual word tokens from multi-word names (minimum `$MinTokenLength` characters, default 3).
    - Collision handling: same owner at same priority keeps higher-priority entry; different owners at same priority marked `Ambiguous`. Player entries take precedence over `Gracz`/`Postać (Gracz)` entity entries (same logical entity).
    - Each entry stores: `Owner` (object reference), `OwnerType` (string), `Owners` (array for ambiguous entries), `Source`, `Priority`, `Ambiguous` flag.
    - Case-insensitive via `OrdinalIgnoreCase` comparer.

* **`Resolve-Name.ps1`** — Multi-stage name resolution engine:
    - **Stage 1**: Exact index lookup (case-insensitive). Skips ambiguous entries.
    - **Stage 2**: Polish grammatical declension stripping. Strips suffixes (`-owi`, `-em`, `-iem`, `-ą`, `-ę`, `-ie`, `-a`, `-u`, `-y`, `-om`, `-ami`, `-ach`) from the query and looks up the resulting stem in a pre-built stem index (built by `Get-NameIndex`). Minimum stem length of 3.
    - **Stage 2b**: Stem-alternation reversal. Handles Polish consonant mutations (e.g. `-da` → `-dzie`, `-ka` → `-ce`, `-ra` → `-rze`, `-ga` → `-dze`, `-sta` → `-ście`, soft consonant mutations `-ń`→`-ni`, `-ś`→`-si`, `-ź`→`-zi`, `-ć`→`-ci`). Generates candidate base forms from the query and looks them up in the index.
    - **Stage 3**: Levenshtein fuzzy matching with dynamic threshold: names < 5 chars allow distance ≤ 1, longer names allow ⌊length / 3⌋. Two-row matrix implementation for memory efficiency. Length pre-filter eliminates ~60-70% of comparisons.
    - Supports `-OwnerType` filter for type-specific resolution and `-Cache` hashtable for cross-call memoization (uses `[DBNull]::Value` sentinel for cached misses).

* **`Resolve-Narrator.ps1`** — Narrator resolution for session headers:
    - Extracts the last comma-delimited part from the header (requires ≥ 2 commas), resolves via `Resolve-Name` with `OwnerType = "Player"`.
    - **Special tokens**: `Rada` = council session (no individual narrator). Co-narrator patterns (` i `, ` oraz `, ` + `, `(`) trigger split-and-resolve.
    - **Confidence levels**: High = exact name match (case-insensitive index lookup); Medium = matched via declension stripping or fuzzy matching (Levenshtein distance); None = unresolved.
    - Legacy narrators not in `Gracze.md` should be added as `Gracz` entities in `entities.md` for resolution.
    - Returns per-session: `Narrators` (array of Name/Player/Confidence objects), `IsCouncil`, `Confidence` (overall), `RawText`.

### Shared Helpers (non-exported, dot-sourced)

* **`entity-writehelpers.ps1`** — Entity file write operations:
    - `Find-EntitySection`: locates `## Type` section boundaries in file lines.
    - `Find-EntityBullet`: locates `* EntityName` bullet and its children range within a section.
    - `Find-EntityTag`: locates `- @tag:` line within an entity's children (returns last occurrence).
    - `Set-EntityTag`: adds or updates a `@tag: value` line under an entity.
    - `New-EntityBullet`: creates a new `* EntityName` entry with optional `@tag` children.
    - `Resolve-EntityTarget`: high-level orchestrator — ensures file, section, and bullet exist (creating as needed).
    - `Ensure-EntityFile`: creates `entities.md` with `## Gracz` and `## Postać (Gracz)` sections if it doesn't exist.
    - `Read-EntityFile` / `Write-EntityFile`: line-array I/O with newline style preservation.
    - `ConvertTo-EntitiesFromPlayers`: bootstraps `entities.md` from `Gracze.md` data via `Get-Player`.
    - All operations use raw line-array manipulation (same pattern as `Set-Session`).

* **`admin-state.ps1`** — Append-only state file read/write for admin workflow history:
    - `Get-AdminHistoryEntries`: reads processed session headers from a state file (`.robot/res/*.md`). Parses lines matching `    - ### ` prefix, normalizes whitespace, and returns a `HashSet[string]` (OrdinalIgnoreCase) for O(1) dedup lookups.
    - `Add-AdminHistoryEntry`: appends new entries with a timestamped header line (`- YYYY-MM-dd HH:mm (timezone):`) followed by indented `    - ### header` lines. Creates file with preamble if it doesn't exist.
    - State file format matches legacy `.robot/res/pu-sessions.md` convention.

* **`admin-config.ps1`** — Configuration resolution and template rendering:
    - `Get-AdminConfig`: returns a hashtable with resolved paths (`RepoRoot`, `EntitiesFile`, `CharactersDir`, etc.) and config values.
    - `Resolve-ConfigValue`: priority-chain resolution (explicit parameter → environment variable → `local.config.psd1` → `$null`).
    - `Get-AdminTemplate`: loads `.robot.new/templates/*.md.template` files and performs `{Placeholder}` substitution.

* **`charfile-helpers.ps1`** — Character file (`Postaci/Gracze/*.md`) parser and writer:
    - `Find-CharacterSection`: locates `**Header:**` section boundaries in character file lines.
    - `Read-CharacterFile`: parses an entire character file into a structured object with properties: `CharacterSheet`, `RestrictedTopics`, `Condition`, `SpecialItems`, `Reputation` (three-tier: Positive/Neutral/Negative), `AdditionalNotes`, `DescribedSessions`.
    - `Read-ReputationTier`: parses a single reputation tier into `@{ Location; Detail }` arrays, handling inline comma-separated entries, nested child bullets, and sub-bullet descriptions.
    - `Write-CharacterFileSection`: replaces content of a single bold-header section in-place via `List[string]` mutation.
    - `Format-ReputationSection`: renders three-tier reputation structure as markdown lines.
    - All operations use raw line-array manipulation. Non-exported, dot-sourced by `Get-PlayerCharacter`, `Set-PlayerCharacter`, and `New-PlayerCharacter`.

* **`format-sessionblock.ps1`** — Shared Gen4 metadata rendering (consumed by `New-Session` and `Set-Session`).

### Templates

* **`templates/player-character-file.md.template`** — Template for `Postaci/Gracze/<Name>.md` character files. Placeholders: `{CharacterSheetUrl}`, `{Triggers}`, `{AdditionalInfo}`.
* **`templates/player-entry.md.template`** — Template for entity entries. Placeholders: `{CharacterName}`, `{PlayerName}`, `{PUStart}`.

## Usage

Load the module by importing the `.psd1` file:

```powershell
Import-Module ./robot.psd1
```

Once loaded, all functions in the module become available in the session.

### Quick Examples

```powershell
# Get all players with their characters and PU data
$Players = Get-Player

# Get a specific player
$Dracon = Get-Player -Name "Dracon"

# Parse all entities with temporal filtering
$Entities = Get-Entity -ActiveOn (Get-Date "2024-06-15")

# Build the name index for batch resolution
$Index = Get-NameIndex -Players $Players -Entities $Entities

# Resolve a name (handles declensions, typos, aliases)
$Result = Resolve-Name -Query "Xerona" -Index $Index

# Resolve specifically to a player
$Player = Resolve-Name -Query "Adriennie" -Index $Index -OwnerType "Player"

# Get all sessions from 2024
$Sessions = Get-Session -MinDate "2024-01-01" -MaxDate "2024-12-31"

# Get sessions from a specific file with full content
$Sessions = Get-Session -File "Wątki/Sesje lokalne.md" -IncludeContent

# Parse a single Markdown file
$Doc = Get-Markdown -File "Gracze.md"

# Get git history for a specific directory
$Changes = Get-GitChangeLog -Directory "./Postaci/Gracze" -NoPatch

# Get entity state enriched with session Zmiany overrides
$State = Get-EntityState
$Xeron = $State | Where-Object { $_.Name -eq 'Xeron Demonlord' }
$Xeron.Groups  # includes session-sourced group changes

# Pre-fetch for efficiency (avoids redundant Get-Entity/Get-Session calls)
$Entities = Get-Entity
$Sessions = Get-Session
$State = Get-EntityState -Entities $Entities -Sessions $Sessions

# Temporal filtering: entity state as of a specific date
$State2024 = Get-EntityState -ActiveOn (Get-Date "2024-06-15")

# Get sessions with entity mentions extracted from body text
$Sessions = Get-Session -IncludeMentions -MinDate "2024-01-01"
$Sessions[0].Mentions | Format-Table Name, Type

# Sessions with @Intel entries (always parsed when present)
$WithIntel = Get-Session | Where-Object { $_.Intel.Count -gt 0 }
$WithIntel[0].Intel | Format-Table RawTarget, Directive, Message
$WithIntel[0].Intel[0].Recipients | Format-Table Name, Type, Webhook

# Get characters as flat rows (from Get-Player)
$Chars = Get-PlayerCharacter -PlayerName "Solmyr"
$Chars | Format-Table PlayerName, Name, PUStart, PUSum, IsActive

# Filter by character name across all players
$Xeron = Get-PlayerCharacter -CharacterName "Xeron Demonlord"

# Update player metadata (writes to entities.md)
Set-Player -Name "Solmyr" -PRFWebhook "https://discord.com/api/webhooks/123/abc"
Set-Player -Name "Solmyr" -Triggers @("spiders", "heights")

# Update character PU values (with auto-derivation)
Set-PlayerCharacter -PlayerName "Solmyr" -CharacterName "Solmyr" -PUSum 130
# PUTaken is auto-derived: 130 - 20 (PUStart) = 110

# Preview changes without writing
Set-PlayerCharacter -PlayerName "Solmyr" -CharacterName "Solmyr" -PUExceeded 2.5 -WhatIf

# Update character file properties (dual-target write)
Set-PlayerCharacter -PlayerName "Solmyr" -CharacterName "Solmyr" `
    -Condition "Ranny." -SpecialItems @("Miecz Ognia", "Tarcza Lodu")

# Update reputation tiers
Set-PlayerCharacter -PlayerName "Solmyr" -CharacterName "Solmyr" `
    -ReputationPositive @([PSCustomObject]@{ Location = "Nithal"; Detail = "Bohater miasta" })

# Set character status
Set-PlayerCharacter -PlayerName "Solmyr" -CharacterName "OldChar" -Status "Nieaktywny"

# Create a new player with first character
New-Player -Name "NewPlayer" -MargonemID "12345" `
    -PRFWebhook "https://discord.com/api/webhooks/123/abc" `
    -CharacterName "NewHero" -InitialPUStart 30

# Create a new player without a character
New-Player -Name "NewPlayer" -MargonemID "12345"

# Create a new character (creates entity entry + character file)
New-PlayerCharacter -PlayerName "NewPlayer" -CharacterName "NewHero" -InitialPUStart 30

# Create character with initial properties
New-PlayerCharacter -PlayerName "Solmyr" -CharacterName "NewChar" `
    -Condition "Zdrowy." -SpecialItems @("Miecz Ognia", "Tarcza Lodu")

# Create without the Postaci/Gracze/ file
New-PlayerCharacter -PlayerName "NewPlayer" -CharacterName "SecondHero" -NoCharacterFile

# Soft-delete a character (sets @status: Usunięty)
Remove-PlayerCharacter -PlayerName "Solmyr" -CharacterName "OldChar"

# Get characters with full state (three-layer merge)
$Chars = Get-PlayerCharacter -IncludeState
$Chars | Format-Table Name, Status, Condition, CharacterSheet

# Temporal state query
$State2024 = Get-PlayerCharacter -IncludeState -ActiveOn (Get-Date "2024-06-15")

# Exclude soft-deleted characters (default) vs. include them
$Active = Get-PlayerCharacter -IncludeState
$All = Get-PlayerCharacter -IncludeState -IncludeDeleted

# Generate a new session in Gen4 format (returns string)
$SessionText = New-Session -Date (Get-Date "2025-06-15") -Title "Ucieczka z Erathii" `
    -Narrator "Dracon" -Locations @("Erathia", "Steadwick") `
    -PU @([PSCustomObject]@{ Character = "Xeron"; Value = 0.3 })
$SessionText | Add-Content "Wątki/Sesje lokalne.md"

# Modify existing session metadata (pipeline input)
$Session = Get-Session -MinDate "2025-06-15" -MaxDate "2025-06-15"
$Session | Set-Session -Locations @("Erathia", "Steadwick", "Las Elfów")

# Modify by date + file (explicit)
Set-Session -Date (Get-Date "2025-06-15") -File "Wątki/Sesje lokalne.md" `
    -PU @([PSCustomObject]@{ Character = "Xeron"; Value = 0.5 })

# Upgrade session format Gen3 → Gen4
$Session | Set-Session -UpgradeFormat

# Preview session changes without writing
$Session | Set-Session -Locations @("Erathia") -WhatIf

# Bootstrap entities.md from Gracze.md (one-time migration)
. ./.robot.new/entity-writehelpers.ps1
ConvertTo-EntitiesFromPlayers -OutputPath ./.robot.new/entities.md

# Monthly PU assignment — compute only (dry run)
$Results = Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 1
$Results | Format-Table CharacterName, PlayerName, BasePU, GrantedPU, OverflowPU, NewPUSum

# Full monthly PU workflow: compute, write, notify, log
Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 1 `
    -UpdatePlayerCharacters -SendToDiscord -AppendToLog

# Preview what would happen without making changes
Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 1 `
    -UpdatePlayerCharacters -SendToDiscord -AppendToLog -WhatIf

# PU assignment for a specific player only
Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 1 -PlayerName "Solmyr"

# Custom date range
Invoke-PlayerCharacterPUAssignment -MinDate "2025-01-01" -MaxDate "2025-01-31"

# Validate PU data correctness (last 2 months by default)
$Diag = Test-PlayerCharacterPUAssignment
if ($Diag.OK) { "All OK!" } else {
    $Diag.UnresolvedCharacters | Format-Table CharacterName, Sessions
    $Diag.MalformedPU | Format-Table CharacterName, SessionHeader, Issue
    $Diag.FailedSessionsWithPU | Format-Table Header, ParseError, PUCandidates
    $Diag.StaleHistoryEntries | Format-Table Header, Issue
}

# Estimate PU for a new character
$Estimate = Get-NewPlayerCharacterPUCount -PlayerName "Solmyr"
"New character starts with $($Estimate.PU) PU (based on $($Estimate.PUTakenSum) total earned)"

# Send a Discord webhook message
Send-DiscordMessage -Webhook "https://discord.com/api/webhooks/123/abc" `
    -Message "Test notification" -Username "Bothen"

# Preview without sending
Send-DiscordMessage -Webhook "https://discord.com/api/webhooks/123/abc" `
    -Message "Test notification" -WhatIf
```

### Batch Processing Pattern

For resolving many names efficiently, pre-build the index and pass a shared cache:

```powershell
$Players = Get-Player
$Entities = Get-Entity
$Index = Get-NameIndex -Players $Players -Entities $Entities
$Cache = @{}

foreach ($Name in $NamesToResolve) {
    $Result = Resolve-Name -Query $Name -Index $Index -Cache $Cache
}
```

## Testing

### Prerequisites

Install [Pester](https://pester.dev/) v5.0+ (the PowerShell testing framework):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

### Running Tests

```powershell
# From the .robot.new/ directory:

# Run all tests
Invoke-Pester ./tests/ -Output Detailed

# Run a single test file
Invoke-Pester ./tests/get-entity.Tests.ps1 -Output Detailed

# Run with configuration file (includes test result XML output)
Invoke-Pester -Configuration (Import-PowerShellDataFile ./tests/.pesterconfig.psd1)

# Run with code coverage
Invoke-Pester ./tests/ -Output Detailed -CodeCoverage ./*.ps1
```

### Test Architecture

Tests are organized with one test file per source file in the `tests/` directory. Synthetic fixture files in `tests/fixtures/` provide controlled test data — no dependency on repository content. See `tests/README.md` for the complete test logic reference, fixture design documentation, and loading patterns.

## Documentation

* **`SYNTAX.md`** — Gen4 session metadata syntax reference. Documents all `@`-prefixed metadata tags, their structure, and parsing rules.
* **`pu-unification-logic.md`** — Authoritative PU computation specification. Normative rules for monthly PU calculation, overflow pools, and cap enforcement.
* **`docs/README.md`** — Module documentation index and contributor guide.
* **`docs/Glossary.md`** — Domain terminology glossary (PU, Narrator, Entity types, etc.).

## Output Object Schemas

### Player Object (Get-Player)
| Property     | Type       | Description                                              |
|-------------|------------|----------------------------------------------------------|
| Name        | string     | Player's display name (from level-3 header)              |
| Names       | HashSet    | All resolvable names (player + characters + aliases)     |
| MargonemID  | string     | Margonem game ID                                         |
| PRFWebhook  | string     | Discord webhook URL for notifications                    |
| Triggers    | string[]   | Restricted session topics                                |
| Characters  | List       | Character objects (see below)                            |

### Character Object (nested in Player)
| Property       | Type     | Description                                    |
|---------------|----------|------------------------------------------------|
| Name          | string   | Character name                                 |
| IsActive      | bool     | Whether this is the player's active character  |
| Aliases       | string[] | Alternative names                              |
| Path          | string   | Markdown file path                             |
| PUExceeded    | decimal? | PU exceeded/overflow value                     |
| PUStart       | decimal? | Starting PU value                              |
| PUSum         | decimal? | Total PU value                                 |
| PUTaken       | decimal? | PU earned (derived or explicit)                |
| AdditionalInfo| string   | Free-form notes                                |

### PlayerCharacter Object (Get-PlayerCharacter)
| Property          | Type     | Description                                                    |
|-------------------|----------|----------------------------------------------------------------|
| PlayerName        | string   | Owning player's name                                           |
| Player            | object   | Reference to parent Player object                              |
| Name              | string   | Character name                                                 |
| IsActive          | bool     | Whether this is the player's active character                  |
| Aliases           | string[] | Alternative names                                              |
| Path              | string   | Markdown file path                                             |
| PUExceeded        | decimal? | PU exceeded/overflow value                                     |
| PUStart           | decimal? | Starting PU value                                              |
| PUSum             | decimal? | Total PU value                                                 |
| PUTaken           | decimal? | PU earned (derived or explicit)                                |
| AdditionalInfo    | string   | Free-form notes                                                |
| Status            | string   | Lifecycle status: `Aktywny`/`Nieaktywny`/`Usunięty` (only with `-IncludeState`) |
| CharacterSheet    | string   | Character sheet URL (only with `-IncludeState`)                |
| RestrictedTopics  | string   | Restricted session topics (only with `-IncludeState`)          |
| Condition         | string   | Character condition/health (only with `-IncludeState`)         |
| SpecialItems      | string[] | Special items list (only with `-IncludeState`)                 |
| Reputation        | object   | Three-tier reputation: Positive/Neutral/Negative arrays of `@{ Location; Detail }` (only with `-IncludeState`) |
| AdditionalNotes   | string[] | Additional notes entries (only with `-IncludeState`)           |
| DescribedSessions | object[] | Session entries from character file (only with `-IncludeState`)|

### NewPlayer Result (New-Player)
| Property       | Type     | Description                                          |
|---------------|----------|------------------------------------------------------|
| PlayerName    | string   | Player name                                          |
| MargonemID    | string   | Margonem game ID (null if not provided)              |
| PRFWebhook    | string   | Discord webhook URL (null if not provided)           |
| Triggers      | string[] | Trigger topics (null if not provided)                |
| EntitiesFile  | string   | Path to entities.md that was modified                |
| CharacterName | string   | First character name (null if not created)           |
| CharacterFile | string   | Path to character file (null if not created)         |

### NewPlayerCharacter Result (New-PlayerCharacter)
| Property       | Type     | Description                                          |
|---------------|----------|------------------------------------------------------|
| PlayerName    | string   | Player name                                          |
| CharacterName | string   | Created character name                               |
| PUStart       | decimal  | Initial PU start value used                          |
| EntitiesFile  | string   | Path to entities.md that was modified                |
| CharacterFile | string   | Path to created character file (null if `-NoCharacterFile`) |
| PlayerCreated | bool     | Whether a new player entry was bootstrapped          |

### Entity Object (Get-Entity)
| Property        | Type       | Description                                          |
|----------------|------------|------------------------------------------------------|
| Name           | string     | Entity's canonical display name                      |
| CN             | string     | Hierarchical canonical name (e.g. `Lokacja/Enroth/Erathia`) |
| Names          | HashSet    | All resolvable names                                 |
| Aliases        | List       | Time-scoped alias objects (Text, ValidFrom, ValidTo) |
| Type           | string     | Entity type: NPC, Organizacja, Lokacja, Gracz, Postać (Gracz), Przedmiot |
| Owner          | string     | Owning player name (if applicable)                   |
| Groups         | string[]   | Active group memberships (after temporal filtering)  |
| Overrides      | hashtable  | Generic `@tag` → value list dictionary               |
| Location       | string     | Active location (for NPCs/orgs)                      |
| LocationHistory| List       | All location assignments with validity ranges        |
| Doors          | string[]   | Active physical access connections                   |
| DoorHistory    | List       | All door assignments with validity ranges            |
| Status         | string     | Active lifecycle status: `Aktywny` (default), `Nieaktywny`, `Usunięty` |
| StatusHistory  | List       | Status changes with validity ranges (Status, ValidFrom, ValidTo) |
| Contains       | List       | Child entity names                                   |
| TypeHistory    | List       | Type changes with validity ranges                    |
| OwnerHistory   | List       | Ownership changes with validity ranges               |
| GroupHistory   | List       | Group membership history (Group, ValidFrom, ValidTo) |

### Session Object (Get-Session)
| Property           | Type     | Description                                        |
|-------------------|----------|----------------------------------------------------|
| FilePath          | string   | Source file path                                   |
| FilePaths         | string[] | All source files (after dedup merge)               |
| Header            | string   | Raw header text                                    |
| Date              | datetime | Session date                                       |
| DateEnd           | datetime | End date (for multi-day sessions)                  |
| Title             | string   | Session title (header minus date and narrator)     |
| Narrator          | object   | Narrator info (see subproperties below)            |
| Locations         | string[] | Session locations                                  |
| Logs              | string[] | Session log URLs                                   |
| PU                | object[] | PU awards (Character + Value)                      |
| Format            | string   | Detected format generation: Gen1, Gen2, Gen3, Gen4 |
| IsMerged          | bool     | Whether this session was deduplicated               |
| DuplicateCount    | int      | Number of duplicates found                         |
| Content           | string   | Full section content (only with `-IncludeContent`) |
| Changes           | object[] | Entity state overrides from `- Zmiany:` block      |
| Mentions          | object[] | Deduplicated array of mention objects (only with `-IncludeMentions`) |
| Intel             | object[] | Resolved `@Intel` entries with recipient webhooks  |
| ParseError        | string   | Error description (only with `-IncludeFailed`)     |

### Mention Object (Session.Mentions)
| Property | Type   | Description                                                                      |
|----------|--------|----------------------------------------------------------------------------------|
| Name     | string | Entity's canonical display name (nominative form)                                |
| Type     | string | Entity type: `Player`, `NPC`, `Organizacja`, `Lokacja`, `Gracz`, `Postać (Gracz)` |
| Owner    | object | Reference to the resolved owner object (Player or Entity)                        |

### Intel Object (Session.Intel)
| Property   | Type     | Description                                                           |
|------------|----------|-----------------------------------------------------------------------|
| RawTarget  | string   | Original target string from Markdown (e.g. `Grupa/Nocarze`, `Rion`) |
| Message    | string   | Intel message text                                                    |
| Directive  | string   | Parsed directive: `Grupa`, `Lokacja`, or `Direct`                     |
| TargetName | string   | Resolved target name (after stripping prefix)                         |
| Recipients | object[] | Array of recipient objects with resolved webhooks                     |

### Recipient Object (Intel.Recipients)
| Property | Type   | Description                                                  |
|----------|--------|--------------------------------------------------------------|
| Name     | string | Recipient entity's canonical name                            |
| Type     | string | Entity type                                                  |
| Webhook  | string | Discord webhook URL, or `$null` if entity has no webhook     |

### Change Object (nested in Session.Changes)
| Property    | Type     | Description                                              |
|------------|----------|----------------------------------------------------------|
| EntityName | string   | Raw entity name from the Zmiany block                    |
| Tags       | object[] | Array of tag objects (Tag + Value)                       |

### Change Tag Object (nested in Change.Tags)
| Property | Type   | Description                                                |
|----------|--------|------------------------------------------------------------|
| Tag      | string | Lowercase `@tag` name (e.g. `@lokacja`, `@grupa`)         |
| Value    | string | Raw value string (may include temporal range)              |

### Narrator Subproperties (Session.Narrator)
| Property    | Type     | Description                                              |
|------------|----------|----------------------------------------------------------|
| Narrators  | object[] | Array of narrator objects (Name, Player, Confidence)     |
| IsCouncil  | bool     | Whether this is a "Rada" (council) session               |
| Confidence | string   | Overall resolution confidence: High, Medium, None        |
| RawText    | string   | Raw narrator text from header                            |

### PU Assignment Result (Invoke-PlayerCharacterPUAssignment)
| Property              | Type     | Description                                                |
|----------------------|----------|------------------------------------------------------------|
| CharacterName        | string   | Character name                                             |
| PlayerName           | string   | Owning player name (null if unresolved)                    |
| Character            | object   | Reference to PlayerCharacter object (null if unresolved)   |
| BasePU               | decimal  | Raw PU before overflow: `1 + Sum(session PU)`              |
| GrantedPU            | decimal  | PU actually awarded (capped at 5)                          |
| OverflowPU           | decimal  | Excess PU going to overflow pool                           |
| UsedExceeded         | decimal  | PU consumed from existing overflow pool                    |
| OriginalPUExceeded   | decimal  | Overflow pool value before this assignment                 |
| RemainingPUExceeded  | decimal  | Overflow pool value after this assignment                  |
| NewPUSum             | decimal  | Updated total PU sum                                       |
| NewPUTaken           | decimal  | Updated earned PU                                          |
| SessionCount         | int      | Number of sessions contributing PU                         |
| Sessions             | string[] | Session headers contributing PU                            |
| Message              | string   | Discord notification message text                          |
| Resolved             | bool     | Always `true` (unresolved characters cause fail-early throw) |

### PU Diagnostic Result (Test-PlayerCharacterPUAssignment)
| Property              | Type     | Description                                                |
|----------------------|----------|------------------------------------------------------------|
| OK                   | bool     | True if no issues found                                    |
| UnresolvedCharacters | object[] | PU entries with unknown character names                    |
| MalformedPU          | object[] | PU entries with null/invalid values                        |
| DuplicateEntries     | object[] | Same character appearing multiple times in one session     |
| FailedSessionsWithPU | object[] | Sessions with broken dates but PU-resolvable content       |
| StaleHistoryEntries  | object[] | pu-sessions.md headers not found in any repo session       |
| AssignmentResults    | object[] | Full assignment results from compute-only run              |

### New Player Character PU Count (Get-NewPlayerCharacterPUCount)
| Property            | Type     | Description                                                  |
|--------------------|----------|--------------------------------------------------------------|
| PlayerName         | string   | Player name                                                  |
| PU                 | decimal  | Estimated starting PU: `Floor((SumPUTaken / 2) + 20)`       |
| PUTakenSum         | decimal  | Total PUTaken across included characters                     |
| IncludedCharacters | int      | Number of characters with PUStart > 0                        |
| ExcludedCharacters | List     | Names of characters excluded (PUStart null or 0)             |

### Discord Message Result (Send-DiscordMessage)
| Property    | Type   | Description                                           |
|------------|--------|-------------------------------------------------------|
| Webhook    | string | Target webhook URL                                    |
| StatusCode | int    | HTTP response status code (null if WhatIf)            |
| Success    | bool   | Whether the message was sent successfully             |
| WhatIf     | bool   | True if this was a WhatIf preview                     |

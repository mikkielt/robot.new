# Repository Model - Technical Reference

---

## Scope

This document describes the lore repository layout that the Robot module expects, how Markdown files are discovered and parsed into domain objects, and how data from multiple sources is merged into a unified world model. It covers file discovery, tag semantics, temporal validity, multi-source merge rules, and cache architecture.

Data structure shapes are documented in [STRUCTURES.md](STRUCTURES.md). Individual subsystem behavior is documented in [ENTITIES.md](ENTITIES.md), [SESSIONS.md](SESSIONS.md), [CHARFILE.md](CHARFILE.md), and [PARSER.md](PARSER.md). Write mechanics are in [ENTITY-WRITES.md](ENTITY-WRITES.md). Configuration resolution is in [CONFIG-STATE.md](CONFIG-STATE.md).

---

## Architecture Overview

```
Lore Repository (git root)
│
├── entities.md                     Entity registry (default location)
├── *-NNN-ent.md                    Entity overflow files
│
├── .robot.powershell/               MODULE (git submodule)
│   ├── local.config.psd1     Local config overrides (git-ignored)
│   ├── lib/*.cs              Compiled C# types (17 files)
│   ├── templates/            Markdown templates
│   └── plugins/              Plugin directories
│
├── .robot.local/                   RUNTIME STATE
│   ├── robot-data.psd1       Data manifest (path overrides)
│   └── res/
│       ├── pu-sessions.json   PU processing history
│       ├── session-hashes/   Session integrity SHA256s
│       ├── session-graph/    Participation graph index
│       ├── logs/             Cached session log text
│       └── narrator-mappings.txt
│
├── .robot.local/.cache/                PARSE CACHE (auto-created, gitignored)
│   └── markdown/             Disk-persisted Markdown scan results
│
├── Gracze.md                 Player database (legacy, read-only)
├── Postaci/Gracze/*.md       Character files
├── **/*.md                   Session files (repo-wide scan)
└── Logi/**/*.log             Session log files
```

Data flows through three stages: file discovery, parsing, and enrichment.

```
Stage 1: Discovery          Stage 2: Parsing              Stage 3: Enrichment
─────────────────           ────────────────              ─────────────────────
Find entity files ──────>   Get-Markdown ──────>          Get-Entity (tag dispatch)
Find session files ─────>   Get-Markdown ──────>          Get-Session (metadata extraction)
Find Gracze.md ─────────>   Get-Markdown ──────>          Get-Player (character list)
Find charfiles ─────────>   Read-CharacterFile ──────>    Get-PlayerCharacter (merge)
                                                          Get-EntityState (session overlay)
```

---

## Repository Discovery

`Get-RepoRoot` (`public/get-reporoot.ps1`) walks parent directories from `$script:ModuleRoot` (the `.robot.powershell/` directory) looking for a `.git` subdirectory or file. Returns the first ancestor containing `.git`. The result is cached in `$script:CachedRepoRoot`. `Set-DataDirectory` overrides this via `$script:DataDirectoryOverride` for testing or alternate layouts.

The module expects to be a child of the lore repository, typically installed as a git submodule at `.robot.powershell/`.

---

## Configuration Resolution

`Get-AdminConfig` (`private/admin-config.ps1`) resolves each path through a four-tier priority chain:

| Priority | Source | Example |
|---|---|---|
| 1 | Explicit parameter | Caller passes `-EntitiesFile` directly |
| 2 | Environment variable | `$env:NERTHUS_REPO_WEBHOOK` |
| 3 | Local config file | `.robot.powershell/local.config.psd1` (git-ignored) |
| 4 | Hard-coded default | `{RepoRoot}/entities.md` |

Default paths resolved at tier 4:

| Key | Default Value |
|---|---|
| `EntitiesFile` | `{RepoRoot}/entities.md` |
| `PlayersFile` | `{RepoRoot}/Gracze.md` |
| `CharactersDir` | `{RepoRoot}/Postaci/Gracze` |
| `ResDir` | `{RepoRoot}/.robot.local/res` |
| `TemplatesDir` | `{ModuleRoot}/templates` |
| `CacheDir` | `{RepoRoot}/.robot.local/.cache` |
| `SeasonMapping` | From `local.config.psd1` or `$null` (default meteorological) |

The data manifest at `{RepoRoot}/.robot.local/robot-data.psd1` provides optional path overrides. All manifest-resolved paths are validated against the repo root via `Test-PathUnderRoot` to prevent path traversal.

---

## Entity File Model

Entity data lives in Markdown files with a specific structure. The module discovers entity files in two ways:

- `entities.md` — the primary entity registry (always processed first via sort key `[int]::MaxValue`)
- `*-NNN-ent.md` — overflow files where NNN is a numeric identifier extracted from the filename

Overflow files are sorted by NNN descending. Lower numbers have higher override primacy because they are processed later in the merge. When the same entity name appears in multiple files, properties from later-processed files extend (not replace) the entity.

Each entity file contains level-2 headers that define entity type sections:

| Header Pattern | Entity Type |
|---|---|
| `## NPC` / `## npc` | NPC |
| `## Grupy` / `## Grupa` | Grupa |
| `## Lokacje` / `## Lokacja` | Lokacja |
| `## Gracz` / `## Gracze` | Gracz |
| `## Postać (Gracz)` | Postać |
| `## Przedmiot` / `## Przedmioty` | Przedmiot |
| `## Mapa` / `## Mapy` | Mapa |

Within each section, entities are level-1 bullets (`* Entity Name`) with indented child bullets for tags (`- @tag: value`).

---

## Entity Tag System

Tags use `@` prefix and are case-insensitive. `Robot.EntityTagParser` (`lib/EntityTagParser.cs`) dispatches each tag to the appropriate property via a 14-way switch. Tags fall into three categories:

Temporal tags store history lists. Each value can carry validity ranges parsed by `ConvertFrom-ValidityString`:

| Tag | Target Property | History List |
|---|---|---|
| `@lokacja` | `Location` | `LocationHistory` |
| `@drzwi` | `Doors` | `DoorHistory` |
| `@typ` | `Type` | `TypeHistory` |
| `@należy_do` | `Owner` | `OwnerHistory` |
| `@grupa` | `Groups` | `GroupHistory` |
| `@status` | `Status` | `StatusHistory` |
| `@ilość` | `Quantity` | `QuantityHistory` |
| `@alias` | — | `Aliases` |
| `@plik` | `FilePath` | `FilePathHistory` |
| `@nazwa_nerthus` | `NerthusName` | `NerthusNameHistory` |
| `@koordynaty` | `Coordinates` | `CoordinateHistory` |
| `@slug` | — | (filtered to Names set only) |

Static tags do not carry temporal validity:

| Tag | Target Property |
|---|---|
| `@generyczne_nazwy` | `GenericNames` (comma-separated) |
| `@zawiera` | `Contains` |

Any unrecognized `@tag` is stored in the `Overrides` dictionary with its values as a `List[string]`.

---

## Temporal Validity

Temporal values follow the format `Value (ValidFrom:ValidTo)` with optional season keyword:

| Format | Example | Parsed Result |
|---|---|---|
| Plain value | `Erathia` | Text only, always active |
| Date range | `Erathia (2021-01:2024-06)` | ValidFrom = 2021-01-01, ValidTo = 2024-06-30 |
| Open-ended | `Targowisko (2024-01:)` | ValidFrom = 2024-01-01, ValidTo = null |
| Season only | `ithan-zima.png (zima)` | Season = zima |
| Combined | `Targowisko (2024-01:, lato)` | Date range + season |
| Non-temporal parens | `Rada (Ithan)` | Preserved as literal text |

Partial date expansion rules (`Resolve-PartialDate` in `private/temporal-helpers.ps1`):

- Start dates expand to first-of-period: `2024` becomes `2024-01-01`, `2024-06` becomes `2024-06-01`
- End dates expand to last-of-period: `2024` becomes `2024-12-31`, `2024-06` becomes `2024-06-30`

`Test-TemporalActivity` checks whether an entry is active on a given date. Null bounds always pass (open-ended). Season constraints are checked via `Resolve-SeasonForDate` which maps dates to Polish season names: wiosna (March-May), lato (June-August), jesień (September-November), zima (December-February).

Current scalar values (`Location`, `Owner`, `Status`, etc.) are derived from history lists via `Get-LastActiveValue` — the last entry whose validity window includes the query date. Multi-valued properties (`Groups`, `Doors`) use `Get-AllActiveValues` to collect all currently active entries.

---

## Session File Model

`Get-Session` scans the entire repository tree for `*.md` files. Auto-excluded directories:

- The module directory (`.robot.powershell/`)
- `docs/` and `devdocs/`
- User-specified directories via `-ExcludeDirectory`

Session headers follow the format `### YYYY-MM-DD, Title, Narrator` where Title and Narrator are optional comma-separated segments. Multi-day sessions use `### YYYY-MM-DD/DD` format. `Robot.SessionExtractor` (`lib/SessionExtractor.cs`) performs per-section structural extraction with format detection.

Four session format generations exist, detected by `Get-SessionFormat`:

| Generation | Era | Detection Pattern |
|---|---|---|
| Gen1 | pre-2022 | No structured metadata |
| Gen2 | 2022-2023 | Italic location prefix: `*Lokalizacja: ...*` |
| Gen3 | 2024-2026 | List metadata: `- Lokacje:`, `- PU:`, `- Zmiany:` |
| Gen4 | 2026+ | @-prefixed tags: `- @Lokacje:`, `- @PU:`, `- @Zmiany:` |

Session metadata tags are dispatched by `Robot.SessionTagParser` (`lib/SessionTagParser.cs`):

| Tag | Output Type | Format |
|---|---|---|
| `@PU` | `SessionPU[]` | Children: `Character: Value` pairs |
| `@Zmiany` | `SessionChange[]` | Children: entity names with `@tag` children |
| `@Intel` | `SessionIntel[]` | Children: `Target: Message` pairs |
| `@Transfer` | `SessionTransfer[]` | Inline: `Amount Denom, Source -> Destination` |
| `@Logi` | `string[]` | Children: log URLs |
| `@Lokacje` | `string[]` | Children: location names |
| `@Narrator` | `string[]` | Children: narrator names |
| `@Data` | `string` | Date override |

When the same session header appears in multiple files, `Merge-SessionGroup` deduplicates and merges metadata into a single Session object with combined `FilePaths` and `IsMerged = $true`.

---

## Player Database Model

`Gracze.md` is a legacy read-only file containing a `## Lista` section with `### PlayerName` subsections. Each player carries:

- `Postaci:` — character list with bold active marker (`**Name**`)
- PU data per character: `NADMIAR`, `STARTOWE`, `SUMA`, `ZDOBYTE`
- `Tematy zastrzeżone:` — restricted topics (triggers)
- `PRFWebhook:` — Discord notification URL
- `ID Margonem:` — game account ID

`Get-Player` also scans the entity registry for entities of type `Gracz` or `Postać`. Entity-sourced player data extends (not replaces) Gracze.md data, enabling new player properties without modifying the frozen file.

---

## Character File Model

Character files live at `{CharactersDir}/{CharacterName}.md` (default: `Postaci/Gracze/*.md`). They use bold-delimited sections:

| Section Header | Content |
|---|---|
| `**Karta Postaci:**` | Character sheet URL |
| `**Stan:**` | Character condition |
| `**Przedmioty specjalne:**` | Special items list |
| `**Reputacja:**` | Three-tier reputation (Pozytywna/Neutralna/Negatywna) |
| `**Dodatkowe informacje:**` | Notes |
| `**Opisane sesje:**` | Session descriptions with `### YYYY-MM-DD` headers |
| `**Tematy zastrzeżone:**` | Restricted topics ("Brak" = none) |

`Read-CharacterFile` (`private/charfile-helpers.ps1`) parses these into a `CharacterFile` PSCustomObject. Files preserve original newline style (CRLF/LF auto-detected) and use UTF-8 without BOM.

---

## Three-Layer Character State Merge

`Get-PlayerCharacter -IncludeState` combines three data sources into a unified `PlayerCharacter` object:

| Layer | Source | Priority |
|---|---|---|
| 1 (baseline) | Character file (`Read-CharacterFile`) | Undated baseline, lowest priority |
| 2 (entity registry) | Entity from `entities.md` (`Get-Entity`) | Temporal values from file tags |
| 3 (session overlay) | Session `@Zmiany` directives (`Get-EntityState`) | Highest priority, dated changes |

Merge rules in `Get-PlayerCharacter`:

- Scalar properties (`Location`, `Owner`, `Status`): last-dated value wins via `Merge-ScalarProperty`
- Multi-valued properties (`Groups`, `Doors`): all active values collected via `Merge-MultiValuedProperty`
- Reputation: tier-level merge via `Merge-ReputationTier` — character file tiers are extended (not replaced) by entity data

---

## Entity State Enrichment

`Get-EntityState` (`public/get-entitystate.ps1`) applies session `@Zmiany` directives chronologically on top of `Get-Entity` output:

1. Load all entities via `Get-Entity` (file data only)
2. Load all sessions via `Get-Session`
3. For each session's `@Zmiany` block, match entity names to known entities
4. Apply each `@tag: value` change with the session's date as `ValidFrom`
5. Sort all history lists by date via `Robot.TemporalSorter`
6. Recompute current scalar values from enriched histories

Unresolved entity names in `@Zmiany` blocks are recorded in the entity's `UnresolvedTransfers` list for diagnostic reporting.

---

## Name Resolution Pipeline

`Resolve-Name` (`public/resolve/resolve-name.ps1`) runs a four-stage cascade:

| Stage | Method | Speed |
|---|---|---|
| 1 | Exact match — case-insensitive dictionary lookup | O(1) |
| 2 | Declension-stripped — Polish noun suffix removal + stem lookup | O(1) |
| 3 | Stem alternation — consonant mutation reversal (e.g., "Valesce" to "Valeska") | O(k) |
| 4 | Fuzzy match — Levenshtein distance via BK-tree | O(log n) |

The name index (`Get-NameIndex` in `public/get-nameindex.ps1`) indexes all entity names, aliases, generic names, Nerthus names, and slugs. Player names and character names from Gracze.md are also indexed. The index is cached in `$script:CachedNameIndex` and invalidated when entity file modification times change.

Polish declension suffixes stripped (longest-first): `-owi`, `-ami`, `-ach`, `-iem`, `-em`, `-om`, `-ą`, `-ę`, `-ie`, `-a`, `-u`, `-y`. Consonant mutations handled by `Robot.DeclensionEngine` (`lib/DeclensionEngine.cs`).

---

## Item and Currency Layer

Items and currency entities are `Przedmiot` entities. The unified item lookup (`Robot.ItemHelper` in `lib/ItemHelper.cs`) builds two indexes:

| Index | Key Format | Purpose |
|---|---|---|
| `ByNameAndOwner` | `{EntityName}\|{Owner}` | Item transfer resolution (all name variants) |
| `ByDenomAndOwner` | `{Denomination}\|{Owner}` | Currency transfer resolution (via `GenericNames`) |

`@Transfer` directives in sessions are resolved through denomination lookup first (currency path), then item name lookup (general path). Transfer resolution is atomic — if either source or destination fails, the entire transfer is skipped and logged.

Currency denominations are string identifiers matching `GenericNames` entries on `Przedmiot` entities. `@ilość` tracks balance via integer quantities with support for `+`/`-` deltas.

---

## Cache Architecture

Four memory caches and one disk cache accelerate repeated operations:

| ID | Variable | Scope | Key | Invalidation |
|---|---|---|---|---|
| WP-1 | `$script:CachedNameIndex` | Module | Concatenated entity file mod times | Entity file change |
| WP-2 | `$script:MarkdownCache` | Module | FilePath to {ModTime, Result} | File mod time mismatch |
| WP-3 | `$script:CachedEntities` | Module | Concatenated entity file mod ticks | Entity file change |
| WP-4 | `$script:SessionFileCache` | Module | FilePath to {ModTime, Sessions, Failed} | File mod time mismatch |
| Disk | `.robot.local/.cache/markdown/` | Cross-process | JSON sidecar per parsed file | File mod time or version mismatch |

`Clear-ParseCaches` nulls all memory caches and deletes the `.robot.local/.cache/` directory. Called before all write operations. Disk cache failure is non-fatal.

---

## File I/O Invariants

- All written files use UTF-8 without BOM
- Original newline style (CRLF/LF) is auto-detected and preserved on write
- `.NET static methods` for file I/O: `[System.IO.File]::ReadAllLines()`, `[System.IO.File]::WriteAllText()`
- Entities are soft-deleted only — marked `@status: Usunięty`, never physically removed
- Session headers (`### YYYY-MM-DD, Title, Narrator`) are unique identifiers across the repository
- PU assignment is fail-early — any unresolved character name aborts the entire batch

---

## Related Documents

- [STRUCTURES.md](STRUCTURES.md) — property tables for all returned objects
- [ENTITIES.md](ENTITIES.md) — entity parsing, temporal helpers, canonical names
- [SESSIONS.md](SESSIONS.md) — session parsing, format generations, metadata extraction
- [PARSER.md](PARSER.md) — Markdown scanner internals and parallelism
- [CONFIG-STATE.md](CONFIG-STATE.md) — configuration resolution, admin state, operation context
- [ENTITY-WRITES.md](ENTITY-WRITES.md) — write operations, tag modification, file persistence
- [CHARFILE.md](CHARFILE.md) — character file format and parsing
- [NAME-RESOLUTION.md](NAME-RESOLUTION.md) — fuzzy matching, declension engine, BK-tree
- [CURRENCY.md](CURRENCY.md) — currency denominations, entity queries, reconciliation

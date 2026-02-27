# PU Assignment — Technical Specification

**Status**: Normative specification. Implementations SHALL conform to this document.

This specification defines the authoritative behavior of the monthly PU (Punkty Umiejętności / Player Units) assignment pipeline implemented in `invoke-playercharacterpuassignment.ps1`, the diagnostic tool in `test-playercharacterpuassignment.ps1`, and the new-character PU formula in `get-newplayercharacterpucount.ps1`. Where the rules document (`Nerthus/Mechanika/Tworzenie i Rozwój Postaci.md`) and this specification diverge, this specification takes precedence for implementation purposes. Divergences are documented explicitly in §9.

---

## 1. Glossary

| Term | Type | Definition |
|------|------|------------|
| **PU** | decimal | Punkty Umiejętności — skill points awarded to characters |
| **PUStart** | decimal | Starting PU granted when the character was created (entity tag: `@pu_startowe`) |
| **PUSum** | decimal | Total PU the character possesses: PUStart + PUTaken (entity tag: `@pu_suma`) |
| **PUTaken** | decimal | PU earned through gameplay: PUSum − PUStart (entity tag: `@pu_zdobyte`) |
| **PUExceeded** | decimal | Overflow pool — accumulated excess PU carried forward across months, unbounded (entity tag: `@pu_nadmiar`) |
| **BasePU** | decimal | Raw monthly PU before overflow pool interaction: `1 + Sum(session PU values)` |
| **GrantedPU** | decimal | PU actually awarded this month (capped at 5) |
| **OverflowPU** | decimal | Excess PU generated this month: `BasePU − 5`, when `BasePU > 5` |
| **UsedExceeded** | decimal | PU consumed from the overflow pool this month |

---

## 2. Entry Points

### 2.1 `Invoke-PlayerCharacterPUAssignment`

Primary pipeline function. Computes and optionally applies monthly PU awards.

```
File:        invoke-playercharacterpuassignment.ps1
Dot-sources: admin-state.ps1, admin-config.ps1
CmdletBinding: SupportsShouldProcess, ConfirmImpact = High
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `Year` | int | Year for the PU assignment period |
| `Month` | int | Month for the PU assignment period |
| `MinDate` | datetime | Start date for custom date range |
| `MaxDate` | datetime | End date for custom date range |
| `PlayerName` | string[] | Filter to specific player name(s) |
| `UpdatePlayerCharacters` | switch | Write updated PU values to `entities.md` via `Set-PlayerCharacter` |
| `SendToDiscord` | switch | Send PU notification messages to Discord via player webhooks |
| `AppendToLog` | switch | Append processed session headers to `pu-sessions.md` history |

### 2.2 `Test-PlayerCharacterPUAssignment`

Diagnostic validation wrapper. Runs the pipeline in compute-only mode (`-WhatIf`) and validates data quality.

```
File:        test-playercharacterpuassignment.ps1
Dot-sources: admin-state.ps1, admin-config.ps1
CmdletBinding: default
```

**Parameters:** `Year`, `Month`, `MinDate`, `MaxDate` (same semantics as §2.1, but no side-effect switches).

### 2.3 `Get-NewPlayerCharacterPUCount`

Pure computation function for new character starting PU.

```
File:        get-newplayercharacterpucount.ps1
CmdletBinding: default
```

**Parameters:** `PlayerName` (mandatory), `Players` (optional pre-fetched player list).

---

## 3. Input Pipeline

### 3.1 Date Range Determination

The pipeline operates on a date range `[MinDate, MaxDate]` determined as follows:

1. **Year/Month parameters**: `MinDate = YYYY-MM-01`, `MaxDate = last day of that month` (computed via `$MinDate.AddMonths(1).AddDays(-1)`).
2. **Explicit MinDate/MaxDate**: used directly. Either can be provided independently — only the missing bound falls back to the default.
3. **Default** (no parameters): `MinDate = 1st of the month two months ago`, `MaxDate = last day of the previous month`.

The 2-month lookback is intentional: sessions are sometimes documented late, and the assignment typically runs at the end of the current month or beginning of the next.

**Implementation note**: The default computation uses `[datetime]::Now.AddMonths(-2)` for MinDate and `[datetime]::new($Now.Year, $Now.Month, 1).AddDays(-1)` for MaxDate. Both bounds can be individually overridden when only one of `MinDate`/`MaxDate` is passed.

**Diagnostic default range**: `Test-PlayerCharacterPUAssignment` uses a slightly different default — MinDate is 1st of the previous month (not two months ago) and MaxDate is tomorrow (`Now.AddDays(1)`). This extends the window forward to catch today's sessions.

### 3.2 Git Optimization

To avoid scanning the entire repository, the pipeline uses `Get-GitChangeLog -NoPatch` to identify Markdown files (`*.md`) changed in the date range, then passes only those files to `Get-Session`.

**Implementation details:**
- Changed files are collected into a `HashSet[string]` (OrdinalIgnoreCase).
- Only files whose `Path` ends with `.md` and exist on disk at `$Config.RepoRoot + FileEntry.Path` are included.
- Each changed file is individually passed to `Get-Session -File` with the date range.
- If Git optimization fails (exception from `Get-GitChangeLog`), the pipeline falls back to `Get-Session` without `-File` (full repository scan). The failure is logged to stderr as a `[WARN]`.

### 3.3 Session Extraction

Sessions are extracted from Markdown files by `Get-Session`, which parses level-3 headers (`### YYYY-MM-DD, Title, Narrator`) and their associated metadata blocks. Only sessions whose date falls within `[MinDate, MaxDate]` are included.

**PU entry format** — two equivalent syntaxes:

```markdown
- PU:
  - CharacterName: 0.3
  - AnotherCharacter: 0.5
```

```markdown
- @PU:
  - CharacterName: 0.3
```

The `@`-prefixed form is Gen4 syntax; both are parsed identically. PU values use period (`.`) as the decimal separator. Comma (`,`) in PU values is normalized to period before decimal parsing by `Get-Session`.

### 3.4 Session Deduplication

Sessions with identical headers appearing across multiple Markdown files (location logs, thread files, character files) represent the **same session**. PU entries across these duplicates are a single reward, not additive.

`Get-Session` deduplicates by header (Ordinal comparison). The merge strategy picks the primary instance with the richest metadata (scored by field count) and unions all array fields (including PU entries) via `HashSet` union. When the same character appears in PU entries across duplicates of the same session, the value is taken once (not summed).

### 3.5 History Deduplication

Session headers already recorded in the state file (`pu-sessions.md`) are excluded from processing. The state file is read by `Get-AdminHistoryEntries` which returns a `HashSet[string]` (OrdinalIgnoreCase) of normalized headers.

**Normalization for comparison:**
1. Trim leading/trailing whitespace.
2. Collapse multiple spaces to single space (via precompiled `\s{2,}` regex).
3. Strip leading `### ` prefix for comparison.
4. Both the stripped and unstripped forms are checked (the code tests `$ProcessedHeaders.Contains($CompareHeader) -and -not $ProcessedHeaders.Contains($NormalizedHeader)`).

**State file format** (`admin-state.ps1`):
- Entry lines match the pattern `^\s+-\s+###\s+(.+)$` (precompiled regex `$script:HistoryEntryPattern`).
- Timestamp header lines follow the format `- YYYY-MM-dd HH:mm (UTC±HH:MM):`.

---

## 4. Character Resolution

Each character name found in PU entries is resolved against a lookup dictionary built from `Get-PlayerCharacter`. Resolution uses:

1. Exact name match (case-insensitive, via `OrdinalIgnoreCase` comparer)
2. Registered alias match (case-insensitive)

The lookup dictionary (`$CharacterLookup`) maps both canonical names and aliases to character objects. First-registered entry wins for collisions (checked via `ContainsKey` before insertion).

**Fail-early behavior**: If **any** PU entry references a character name that cannot be resolved, the pipeline throws a terminating error (`ErrorId: UnresolvedPUCharacters`, `ErrorCategory: InvalidData`) and aborts all processing. No PU is awarded, no Discord messages are sent, no log entries are appended.

The error's `TargetObject` contains a structured array of `[PSCustomObject]@{ CharacterName; SessionCount; Sessions }` for each unresolved name — this is consumed by `Test-PlayerCharacterPUAssignment` to build diagnostic reports.

---

## 5. PU Computation Algorithm

For each resolved character that has PU entries in the filtered, deduplicated session set:

### 5.1 Base Computation

```
SessionPUSum = Sum of all PU values for this character across all sessions in the batch
               (null values contribute 0 — they are skipped via $null -ne check)
BasePU       = 1 + SessionPUSum
```

The `+1` is an unconditional universal monthly base granted to any character that appears in PU entries. It is not conditional on activity type (see §9.2 for divergence from rules).

### 5.2 Overflow Pool Interaction

```
OriginalPUExceeded = character's current PUExceeded value
                     (coalesced: if $null then [decimal]0)
UsedExceeded       = 0
OverflowPU         = 0

IF BasePU <= 5 AND OriginalPUExceeded > 0:
    UsedExceeded = min(5 - BasePU, OriginalPUExceeded)

IF BasePU > 5:
    OverflowPU = BasePU - 5
```

Note: The supplement threshold is `<= 5` (implemented as `-le 5`). When `BasePU == 5`, `UsedExceeded = min(0, OriginalPUExceeded) = 0`, producing no behavioral difference, but the `<=` form explicitly encodes that the pool supplements up to the cap.

The two conditions are mutually exclusive: if `BasePU > 5`, the first branch is skipped; if `BasePU <= 5`, the second branch produces `OverflowPU = 0`.

### 5.3 Granted PU and Pool Update

```
GrantedPU           = min(BasePU + UsedExceeded, 5)
RemainingPUExceeded = (OriginalPUExceeded - UsedExceeded) + OverflowPU
```

**No flooring to integer.** Decimal PU values are granted as-is (e.g., 3.70 PU is granted as 3.70, not floored to 3). See §9.1.

The overflow pool (`PUExceeded`) is unbounded — there is no maximum cap.

### 5.4 Updated Character Totals

```
CurrentPUSum   = character's current PUSum   (coalesced: if $null then [decimal]0)
CurrentPUTaken = character's current PUTaken  (coalesced: if $null then [decimal]0)
NewPUSum       = [math]::Round(CurrentPUSum + GrantedPU, 2)
NewPUTaken     = [math]::Round(CurrentPUTaken + GrantedPU, 2)
```

Both values are rounded to 2 decimal places via `[math]::Round`.

### 5.5 Worked Example

Character Crag Hack has: `PUSum = 45.00`, `PUTaken = 25.00`, `PUStart = 20.00`, `PUExceeded = 1.50`

Sessions in the batch award Crag Hack: 0.3 + 0.5 + 0.2 = 1.0 PU

```
BasePU              = 1 + 1.0 = 2.0
OriginalPUExceeded  = 1.50
UsedExceeded        = min(5 - 2.0, 1.50) = min(3.0, 1.50) = 1.50
OverflowPU          = 0   (BasePU <= 5)
GrantedPU           = min(2.0 + 1.50, 5) = min(3.50, 5) = 3.50
RemainingPUExceeded = (1.50 - 1.50) + 0 = 0.00
NewPUSum            = 45.00 + 3.50 = 48.50
NewPUTaken          = 25.00 + 3.50 = 28.50
```

### 5.6 Overflow Example

Character Gem has: `PUSum = 80.00`, `PUTaken = 60.00`, `PUStart = 20.00`, `PUExceeded = 0.00`

Sessions award Gem: 2.0 + 1.5 + 1.0 + 0.5 = 5.0 PU

```
BasePU              = 1 + 5.0 = 6.0
OriginalPUExceeded  = 0.00
UsedExceeded        = 0    (BasePU > 5)
OverflowPU          = 6.0 - 5.0 = 1.0
GrantedPU           = min(6.0 + 0, 5) = 5.00
RemainingPUExceeded = (0.00 - 0) + 1.0 = 1.00
NewPUSum            = 80.00 + 5.00 = 85.00
NewPUTaken          = 60.00 + 5.00 = 65.00
```

Next month, Gem has `PUExceeded = 1.00` to draw from.

---

## 6. Side Effects

Side effects are gated by explicit `-Switch` parameters. The pipeline always computes and returns assignment results regardless of which switches are active. All side effects are guarded by `ShouldProcess` (`-WhatIf` / `-Confirm`).

### 6.1 UpdatePlayerCharacters

Writes updated values to `entities.md` via `Set-PlayerCharacter`. Three fields are written per character:

| Field | Entity tag | Value |
|-------|-----------|-------|
| PUSum | `@pu_suma` | `NewPUSum` |
| PUTaken | `@pu_zdobyte` | `NewPUTaken` |
| PUExceeded | `@pu_nadmiar` | `max(0, RemainingPUExceeded)` |

`Set-PlayerCharacter` resolves the entity target in `entities.md` under `## Postać (Gracz)`, creating the entry with `@należy_do: <PlayerName>` if it doesn't exist. PU derivation rules (`Complete-PUData`) may auto-derive missing fields (e.g., if SUMA is given but ZDOBYTE is missing, ZDOBYTE = SUMA − STARTOWE).

PUTaken is written explicitly (not left to derivation) to ensure data consistency.

### 6.2 SendToDiscord

Discord notifications are **grouped per player**. All characters belonging to the same player are combined into a single message, sent via the player's `PRFWebhook`.

**Grouping**: A `Dictionary[string, List[object]]` (OrdinalIgnoreCase) groups assignment results by `PlayerName`. Characters without a `PlayerName` are skipped.

**Message format** (Polish, mandatory):

For each character in the player's results:
```
Postać "<CharacterName>" (Gracz "<PlayerName>") otrzymuje <GrantedPU> PU.
Aktualna suma PU tej Postaci: <NewPUSum>
```

Conditional suffixes (appended to the second line, comma-separated):
- If `UsedExceeded > 0`: `, wykorzystano PU nadmiarowe: <UsedExceeded>`
- If `RemainingPUExceeded > 0`: `, pozostałe PU nadmiarowe: <RemainingPUExceeded>`

Numeric values use `F2` format with `InvariantCulture` (period decimal separator, two decimal places).

Multiple characters for the same player are separated by `\n\n` (blank line).

**Message construction**: Uses `StringBuilder` with initial capacity 256 for each character's message, then joins with `\n\n`.

**Bot username**: `Bothen` (hardcoded in the pipeline; note: `Get-AdminConfig` resolves a `BotUsername` from config but it is not used by PU assignment).

**Webhook resolution**: Taken from `$Items[0].Character.Player.PRFWebhook` (the first result's Character→Player→PRFWebhook path).

**Missing webhook**: If a player has no `PRFWebhook` configured, the notification is skipped with a `[WARN]` to stderr. This does **not** prevent other players' notifications from being sent.

**Failure handling**: Individual `Send-DiscordMessage` failures are caught and logged to stderr as `[WARN]`. They do not abort the remaining notifications.

### 6.3 AppendToLog

Processed session headers are appended to `pu-sessions.md` via `Add-AdminHistoryEntry`.

**Entry format** (written by `admin-state.ps1`):
```
- YYYY-MM-dd HH:mm (UTC+HH:MM):
    - ### session header 1
    - ### session header 2
```

Headers are sorted chronologically using `[StringComparer]::Ordinal` (string-lexicographic, which works because headers start with `YYYY-MM-DD`). The `### ` prefix is added if not already present.

**File creation**: If `pu-sessions.md` doesn't exist, it is created with the preamble: `"W tym pliku znajduje się lista sesji przetworzonych przez system.\n\n## Historia\n\n"`.

**File location**: `$Config.ResDir` → `<RepoRoot>/.robot/res/pu-sessions.md`.

---

## 7. Player Name Filtering

An optional `-PlayerName` filter (string array) restricts processing to specific player(s). When set:

- Character resolution still verifies **all** PU character names (fail-early applies to the full set).
- Only characters whose `PlayerName` matches one of the filter values (case-insensitive, `OrdinalIgnoreCase`) proceed to computation.
- PU entries for non-matching players' characters are silently skipped (not an error).
- Session scanning and deduplication still cover all sessions (the filter applies **after** PU aggregation, at the per-character computation loop).

---

## 8. Edge Cases

| Scenario | Behavior |
|----------|----------|
| No sessions with PU in date range | Return empty array `@()`. Log `[INFO]` to stderr. No side effects. |
| All sessions already processed | Return empty array `@()`. Log `[INFO]` to stderr. No side effects. |
| BasePU exactly 5.00 | No overflow generated, no pool consumed. GrantedPU = 5.00. |
| PUExceeded is `$null` | Coalesced to `[decimal]0` before computation. |
| PUSum or PUTaken is `$null` | Coalesced to `[decimal]0` for computation. |
| Character has no PUStart | PUStart is not used in monthly computation (only PUSum and PUTaken). |
| Player has no PRFWebhook | Skip Discord for that player, warn to stderr. Continue others. |
| PU value is `$null` | Skipped in session PU summation (contributes 0). Flagged by diagnostic tool. |
| Multiple characters, same player | Each character computed independently with its own overflow pool. Notifications grouped into one message. |
| Git optimization failure | Falls back to full `Get-Session` scan. Logged to stderr. |
| `Send-DiscordMessage` failure | Logged to stderr. Other notifications continue. |
| Character without PlayerName | Skipped in Discord grouping (no notification sent). |

---

## 9. Divergences from Rules Document

### 9.1 No Integer Flooring

The rules document (`Tworzenie i Rozwój Postaci.md`) states:

> "Postać otrzymuje tylko pełne zgromadzone PU i nie otrzymuje nadwyżki"

This implies flooring to integer, with fractional remainders going to the overflow pool. Example in the rules document:

> Hjero Nim earned 2.4 PU → receives 2 PU, 0.4 carries to next month.

**This specification does not implement flooring.** Decimal PU values are granted as-is. The overflow pool (`PUExceeded`) accumulates only the excess beyond the 5 PU monthly cap, not fractional remainders.

This is a deliberate implementation decision reflecting long-standing practice. Both the legacy and current implementations have always granted decimal PU.

### 9.2 Universal +1 Base

The rules document describes the activity bonus as conditional with sub-categories:
- 0.25 PU for declarations activity
- 0.5 PU for session participation

In implementation, the `+1` is unconditional for any character appearing in PU entries. The sub-category values serve as narrator guidelines for the session-level PU amounts within the `- PU:` / `- @PU:` block.

---

## 10. New Character PU Formula

Implemented in `Get-NewPlayerCharacterPUCount`. Used by `New-PlayerCharacter` as a fallback when `InitialPUStart` is not explicitly provided.

```
IncludedCharacters = all characters of this player where PUStart > 0
                     (null PUStart treated as excluded)
PUTakenSum         = Sum(PUTaken) across IncludedCharacters
                     (null PUTaken contributes 0)
NewPUStart         = Floor((PUTakenSum / 2) + 20)
```

The result is always at least 20 (players with no qualifying characters get `Floor(0/2 + 20) = 20`).

This matches the rules document formula: *(Zdobyte PU Gracza na wszystkich postaciach) / 2 + 20*, rounded down.

**Return object:**

| Property | Type | Description |
|----------|------|-------------|
| `PlayerName` | string | Player name |
| `PU` | decimal | Computed starting PU |
| `PUTakenSum` | decimal | Sum of PUTaken across included characters |
| `IncludedCharacters` | int | Number of characters with PUStart > 0 |
| `ExcludedCharacters` | List[string] | Names of characters excluded |

---

## 11. Diagnostic Validation

`Test-PlayerCharacterPUAssignment` runs the assignment pipeline in compute-only mode (via `-WhatIf` on `Invoke-PlayerCharacterPUAssignment`) and performs five checks:

| Check | Detection method | Result property |
|-------|-----------------|-----------------|
| **Unresolved characters** | Catches `UnresolvedPUCharacters` error thrown by `Invoke-`, extracts `TargetObject` | `UnresolvedCharacters` |
| **Malformed PU** | Iterates parsed sessions, checks `PUEntry.Value -eq $null` | `MalformedPU` |
| **Duplicate entries** | Tracks character names per session via `Dictionary[string, int]`, flags when count ≥ 2 | `DuplicateEntries` |
| **Failed sessions with PU** | Uses `Get-Session -IncludeFailed -IncludeContent`, scans content of failed sessions for `- PU:` / `- @PU:` sections and PU-like child lines | `FailedSessionsWithPU` |
| **Stale history entries** | Reads all headers from `pu-sessions.md`, builds a `HashSet` of all known session headers from `Get-Session` (full repo, no date filter), finds unmatched history entries | `StaleHistoryEntries` |

**PU-like pattern matching** (for failed session scanning):
- Section header: `^\s*[-\*]\s+@?[Pp][Uu]\s*:` (precompiled `$script:PUSectionPattern`)
- Child line: `^\s+[-\*]\s+(.+?):\s*([\d,\.]+)\s*$` (precompiled `$script:PULikePattern`)
- A blank or non-indented line ends the PU section.

**Return object:**

| Property | Type | Description |
|----------|------|-------------|
| `OK` | bool | `$true` if all five checks found zero issues |
| `UnresolvedCharacters` | object[] | `CharacterName`, `SessionCount`, `Sessions` |
| `MalformedPU` | object[] | `CharacterName`, `SessionHeader`, `RawValue`, `Issue` |
| `DuplicateEntries` | object[] | `CharacterName`, `SessionHeader`, `Count` |
| `FailedSessionsWithPU` | object[] | `Header`, `FilePath`, `ParseError`, `PUCandidates` |
| `StaleHistoryEntries` | object[] | `Header`, `Issue` |
| `AssignmentResults` | object[] | Full assignment results (null if pipeline threw) |

---

## 12. Assignment Result Object

Each character produces one result object:

| Property | Type | Description |
|----------|------|-------------|
| `CharacterName` | string | Canonical character name (from resolved Character object) |
| `PlayerName` | string | Owning player name |
| `Character` | object | Reference to the full PlayerCharacter object |
| `BasePU` | decimal | `1 + Sum(session PU)` |
| `GrantedPU` | decimal | PU actually awarded (capped at 5) |
| `OverflowPU` | decimal | Excess going to overflow pool |
| `UsedExceeded` | decimal | PU consumed from existing overflow pool |
| `OriginalPUExceeded` | decimal | Overflow pool value before this assignment |
| `RemainingPUExceeded` | decimal | Overflow pool value after this assignment |
| `NewPUSum` | decimal | Updated total PU sum |
| `NewPUTaken` | decimal | Updated earned PU |
| `SessionCount` | int | Number of sessions contributing PU |
| `Sessions` | string[] | Session header strings |
| `Message` | string | Pre-formatted Discord notification text |
| `Resolved` | bool | Always `true` (unresolved characters cause fail-early throw) |

---

## 13. Dependency Graph

```
Invoke-PlayerCharacterPUAssignment
├── admin-state.ps1 (dot-sourced)
│   ├── Get-AdminHistoryEntries    → reads pu-sessions.md
│   └── Add-AdminHistoryEntry      → appends to pu-sessions.md
├── admin-config.ps1 (dot-sourced)
│   └── Get-AdminConfig            → resolves RepoRoot, ResDir, etc.
├── Get-GitChangeLog -NoPatch      → identifies changed .md files
├── Get-Session                    → extracts sessions with PU data
├── Get-PlayerCharacter            → loads all characters for resolution
├── Set-PlayerCharacter            → writes PU to entities.md (gated)
│   ├── entity-writehelpers.ps1    → entity file manipulation
│   └── charfile-helpers.ps1       → character file manipulation
├── Send-DiscordMessage            → Discord webhook POST (gated)
└── Add-AdminHistoryEntry          → history log append (gated)

Test-PlayerCharacterPUAssignment
├── Invoke-PlayerCharacterPUAssignment -WhatIf
├── Get-Session -IncludeFailed -IncludeContent
├── Get-AdminHistoryEntries
├── Get-Session (full repo, for stale detection)
└── admin-state.ps1, admin-config.ps1 (dot-sourced)

Get-NewPlayerCharacterPUCount
└── Get-Player (optional, auto-fetched if not pre-supplied)
```

---

## 14. Data Flow Diagram

```
                    ┌─────────────────────┐
                    │    Date Range        │
                    │  (Year/Month or      │
                    │   MinDate/MaxDate    │
                    │   or 2-month default)│
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │  Get-GitChangeLog   │
                    │  -NoPatch           │──── fallback on failure ──┐
                    └─────────┬───────────┘                          │
                              │ changed .md files                    │
                    ┌─────────▼───────────┐                          │
                    │  Get-Session        │◄─────────────────────────┘
                    │  (per-file or full)  │    full repo scan
                    └─────────┬───────────┘
                              │ sessions with PU
                    ┌─────────▼───────────┐
                    │  History Dedup       │
                    │  (pu-sessions.md)    │
                    └─────────┬───────────┘
                              │ new sessions only
                    ┌─────────▼───────────┐
                    │  Character          │
                    │  Resolution         │──── fail-early if unresolved
                    │  (Get-PlayerChar)    │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │  PlayerName Filter   │ (optional)
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │  PU Computation      │
                    │  (per character)     │
                    │  BasePU → Overflow → │
                    │  GrantedPU → Totals  │
                    └─────────┬───────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
    ┌─────────▼──────┐ ┌─────▼──────┐ ┌──────▼────────┐
    │ Set-Player     │ │ Send-      │ │ Add-Admin     │
    │ Character      │ │ Discord    │ │ HistoryEntry  │
    │ (entities.md)  │ │ Message    │ │ (pu-sessions) │
    │ [gated]        │ │ [gated]    │ │ [gated]       │
    └────────────────┘ └────────────┘ └───────────────┘
```

---

## 15. Testing

Test files covering PU functionality:

| Test file | Coverage |
|-----------|----------|
| `tests/invoke-playercharacterpuassignment.Tests.ps1` | BasePU computation, cap enforcement, overflow pool supplement/generation, new totals, fail-early on unresolved characters, PlayerName filter, empty result scenarios, alias resolution |
| `tests/test-playercharacterpuassignment.Tests.ps1` | Clean data OK, unresolved characters capture, malformed PU detection, duplicate entries detection, failed sessions with PU data, stale history entries, output structure |
| `tests/get-newplayercharacterpucount.Tests.ps1` | Formula correctness, BRAK PU handling, zero-character players, non-existent player error |

All tests use mock objects — no dependency on repository content. Mock patterns include session objects, character objects, admin config, git log, and admin history entries.

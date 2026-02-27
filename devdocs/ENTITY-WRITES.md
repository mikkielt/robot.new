# Entity Write Operations — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the entity write subsystem: `entity-writehelpers.ps1` (low-level line-array manipulation primitives) and all mutating commands (`Set-Player`, `Set-PlayerCharacter`, `New-Player`, `New-PlayerCharacter`, `Remove-PlayerCharacter`).

**Not covered**: Entity reading/parsing — see [ENTITIES.md](ENTITIES.md). Character file writing — see [CHARFILE.md](CHARFILE.md).

---

## 2. Architecture Overview

```
entity-writehelpers.ps1 (shared file manipulation)
     ▲         ▲         ▲         ▲         ▲
     │         │         │         │         │
Set-Player  Set-Player  New-Player  New-Player  Remove-Player
            Character              Character   Character
     │         │         │         │         │
     ▼         ▼         ▼         ▼         ▼
  entities.md (write target, never Gracze.md)
```

All mutating commands dot-source `entity-writehelpers.ps1` and operate on `List[string]` line arrays with in-place index manipulation.

---

## 3. Line-Array Primitives (`entity-writehelpers.ps1`)

### 3.1 Functions

| Function | Purpose | Returns |
|---|---|---|
| `Find-EntitySection` | Locates `## Type` section boundaries | `{ HeaderIdx, StartIdx, EndIdx, HeaderText, EntityType }` |
| `Find-EntityBullet` | Locates `* EntityName` within a section range | `{ BulletIdx, ChildrenStartIdx, ChildrenEndIdx, EntityName }` |
| `Find-EntityTag` | Finds **last** occurrence of `- @tag: value` in children | `{ TagIdx, Tag, Value }` or `$null` |
| `Set-EntityTag` | Upserts a tag line: replaces if found, inserts at children end | Updated `ChildrenEnd` index |
| `New-EntityBullet` | Inserts `* EntityName` with sorted `@tag` children | — |
| `Resolve-EntityTarget` | High-level orchestrator: ensure file → find/create section → find/create bullet | `{ Lines, NL, BulletIdx, ChildrenStart, ChildrenEnd, FilePath, Created }` |
| `Read-EntityFile` | Reads file into `List[string]` with newline detection | `{ Lines, NL }` |
| `Write-EntityFile` | Writes `List[string]` back to file (UTF-8 no BOM) | — |
| `Ensure-EntityFile` | Creates `entities.md` with skeleton sections if missing | — |
| `ConvertTo-EntitiesFromPlayers` | Bootstrap: generates `entities.md` from `Get-Player` output | — |

### 3.2 `Find-EntitySection`

Linear scan for `## headers`. Returns the section's content range:
- `HeaderIdx`: line index of the `## Type` header
- `StartIdx`: first content line after header
- `EndIdx`: line before next `##` header or EOF

### 3.3 `Find-EntityBullet`

Scans within a section for `* EntityName` (case-insensitive, `OrdinalIgnoreCase`).

**Children boundary logic**: Extends from bullet line until:
- Next top-level bullet (`* `)
- Non-indented, non-blank line
- EOF

Trailing blank lines within children are trimmed.

### 3.4 `Find-EntityTag`

Returns the **last** occurrence of `- @tag:` within a bullet's children range. Case-insensitive tag matching.

Last-occurrence semantics ensure update safety (always modifying the most recent value).

### 3.5 `Set-EntityTag`

**Upsert logic**:
- If tag found → replace the existing line in-place
- If tag not found → insert new line at `ChildrenEnd` via `List[string].Insert()`

Returns the updated `ChildrenEnd` index (may shift by 1 on insert).

### 3.6 `New-EntityBullet`

Creates a new `* EntityName` entry at section end:
1. Ensures a blank line before the new entry (if prior line isn't blank)
2. Inserts `* EntityName`
3. Adds `@tag` children in **alphabetically sorted** order

### 3.7 `Resolve-EntityTarget`

High-level orchestrator that ensures the entity exists, creating intermediate structures as needed:

```
1. Ensure-EntityFile (create entities.md if missing)
2. Read-EntityFile → List[string]
3. Find-EntitySection (create section if missing)
4. Find-EntityBullet (create bullet if missing via New-EntityBullet)
5. Return { Lines, BulletIdx, ChildrenStart, ChildrenEnd, FilePath, Created }
```

### 3.8 File I/O

**`Read-EntityFile`**: Reads file via `[System.IO.File]::ReadAllText()`, detects newline style (`\r\n` vs `\n`), splits into `List[string]`.

**`Write-EntityFile`**: Rejoins lines with detected newline style, writes via `[System.IO.File]::WriteAllText()` with `UTF8Encoding(false)` (no BOM).

**`Ensure-EntityFile`**: Creates `entities.md` with skeleton:
```markdown
## Gracz

## Postać (Gracz)

## Przedmiot
```

### 3.9 Module-Level Regex Patterns

Three precompiled regex patterns (`RegexOptions.Compiled`):
- Section header pattern (`## `)
- Entity bullet pattern (`* `)
- Tag pattern (`- @tag:`)

---

## 4. Mutating Commands

### 4.1 `Set-Player`

| Aspect | Detail |
|---|---|
| **Target** | `entities.md` `## Gracz` section |
| **Tags written** | `@margonemid`, `@prfwebhook`, `@trigger` |
| **Creation** | Creates player entity if missing |
| **Webhook validation** | Regex: `https://discord.com/api/webhooks/*` |
| **Trigger semantics** | Full replacement: all existing `@trigger` lines removed, then new ones inserted |
| **Dot-sources** | `entity-writehelpers.ps1` |
| **SupportsShouldProcess** | Yes (`-WhatIf`, `-Confirm`) |

### 4.2 `Set-PlayerCharacter`

| Aspect | Detail |
|---|---|
| **Target 1** | `entities.md` `## Postać (Gracz)` section |
| **Target 2** | `Postaci/Gracze/<Name>.md` (character file) |
| **Entity tags** | `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`, `@alias`, `@status` |
| **PU derivation** | If SUMA given + ZDOBYTE missing → `ZDOBYTE = SUMA - STARTOWE`. Converse applies. |
| **Creation** | Creates entity entry with `@należy_do: <PlayerName>` if missing |
| **Aliases** | Additive (existing preserved, new appended if not duplicate) |
| **Status** | Writes `@status: <Value> (YYYY-MM:)` with `ValidateSet("Aktywny", "Nieaktywny", "Usunięty")` |
| **Auto-creates** | `## Przedmiot` entities for unknown items in `-SpecialItems` |
| **Charfile params** | `-CharacterSheet`, `-RestrictedTopics`, `-Condition`, `-SpecialItems`, `-ReputationPositive`/`Neutral`/`Negative`, `-AdditionalNotes` |
| **Dot-sources** | `entity-writehelpers.ps1`, `charfile-helpers.ps1` |
| **SupportsShouldProcess** | Yes |

### 4.3 `New-Player`

| Aspect | Detail |
|---|---|
| **Target** | `entities.md` `## Gracz` section |
| **Tags** | `@margonemid`, `@prfwebhook`, `@trigger` |
| **Duplicate detection** | Throws if player already exists in `entities.md` |
| **Webhook validation** | Same as `Set-Player` |
| **Optional delegation** | Creates first character via `New-PlayerCharacter` if `-CharacterName` provided |
| **Returns** | `{ PlayerName, MargonemID, PRFWebhook, Triggers, EntitiesFile, CharacterName, CharacterFile }` |
| **Dot-sources** | `entity-writehelpers.ps1`, `admin-config.ps1` |
| **SupportsShouldProcess** | Yes |

### 4.4 `New-PlayerCharacter`

| Aspect | Detail |
|---|---|
| **Target 1** | `entities.md` `## Postać (Gracz)` section (new entry) |
| **Target 2** | `entities.md` `## Gracz` section (ensures player exists) |
| **Target 3** | `Postaci/Gracze/<Name>.md` (character file from template) |
| **Tags** | `@należy_do`, `@pu_startowe` |
| **Duplicate detection** | Throws if character already exists |
| **PU start** | Uses `Get-NewPlayerCharacterPUCount` as fallback when `InitialPUStart` not specified (minimum 20) |
| **Template** | `player-character-file.md.template` with `{CharacterSheetUrl}`, `{Triggers}`, `{AdditionalInfo}` placeholders |
| **Skip file** | `-NoCharacterFile` switch |
| **Optional** | Initial character file properties: `-Condition`, `-SpecialItems`, `-Reputation*`, `-AdditionalNotes` |
| **Returns** | `{ PlayerName, CharacterName, PUStart, EntitiesFile, CharacterFile, PlayerCreated }` |
| **Dot-sources** | `entity-writehelpers.ps1`, `admin-config.ps1`, `charfile-helpers.ps1` |
| **SupportsShouldProcess** | Yes |

### 4.5 `Remove-PlayerCharacter`

| Aspect | Detail |
|---|---|
| **Target** | `entities.md` `## Postać (Gracz)` section |
| **Operation** | Soft-delete: writes `@status: Usunięty (YYYY-MM:)` |
| **No physical deletion** | Entity bullet and character file remain |
| **Filtering** | Characters with `Usunięty` status excluded from `Get-PlayerCharacter -IncludeState` unless `-IncludeDeleted` |
| **`-ValidFrom`** | Defaults to current month |
| **ConfirmImpact** | `High` |
| **Dot-sources** | `entity-writehelpers.ps1` |
| **SupportsShouldProcess** | Yes |

---

## 5. Bootstrap Migration (`ConvertTo-EntitiesFromPlayers`)

One-time function that generates a complete `entities.md` from `Get-Player` output:

1. Reads all players (optionally pre-fetched, or calls `Get-Player -Entities @()` to avoid circular dependency)
2. Generates `## Gracz` section: `* PlayerName` with `@margonemid`, `@prfwebhook`, `@trigger`
3. Generates `## Postać (Gracz)` section: `* CharacterName` with `@należy_do`, `@alias`, `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`, `@info`
4. PU values formatted with `([decimal]).ToString('G', InvariantCulture)`
5. Output: UTF-8 no BOM, `StringBuilder` with 4096 initial capacity

---

## 6. Write Invariants

1. **`Gracze.md` is never mutated** by any module command
2. **All mutable state** persists in `entities.md` (and `*-NNN-ent.md`)
3. **Soft-delete via `@status`** — no physical removal of entity bullets or character files
4. **All write commands support `SupportsShouldProcess`** (`-WhatIf`, `-Confirm`)
5. **UTF-8 no BOM** for all written files
6. **Newline style preserved** on round-trip (CRLF or LF, auto-detected)

### NewPlayer Result (`New-Player`)

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Player name |
| `MargonemID` | string | Margonem game ID (null if not provided) |
| `PRFWebhook` | string | Discord webhook URL (null if not provided) |
| `Triggers` | string[] | Trigger topics (null if not provided) |
| `EntitiesFile` | string | Path to entities.md that was modified |
| `CharacterName` | string | First character name (null if not created) |
| `CharacterFile` | string | Path to character file (null if not created) |

### NewPlayerCharacter Result (`New-PlayerCharacter`)

| Property | Type | Description |
|---|---|---|
| `PlayerName` | string | Player name |
| `CharacterName` | string | Created character name |
| `PUStart` | decimal | Initial PU start value used |
| `EntitiesFile` | string | Path to entities.md that was modified |
| `CharacterFile` | string | Path to created character file (null if `-NoCharacterFile`) |
| `PlayerCreated` | bool | Whether a new player entry was bootstrapped |

---

## 7. Testing

| Test file | Coverage |
|---|---|
| `tests/entity-writehelpers.Tests.ps1` | Find/Set/New primitives, file I/O, bootstrap |
| `tests/set-player.Tests.ps1` | Tag upsert, trigger replacement, webhook validation |
| `tests/set-playercharacter.Tests.ps1` | Dual-target writes, PU derivation, alias handling |
| `tests/set-playercharacter-charfile.Tests.ps1` | Character file property writes |
| `tests/new-player.Tests.ps1` | Creation, duplicate detection, delegation |
| `tests/new-playercharacter.Tests.ps1` | Creation, template rendering, PU start fallback |
| `tests/remove-playercharacter.Tests.ps1` | Soft-delete, status writing |
| `tests/przedmiot-entity.Tests.ps1` | Auto-creation of Przedmiot entities |

---

## 8. Related Documents

- [ENTITIES.md](ENTITIES.md) — Entity reading and state merging
- [CHARFILE.md](CHARFILE.md) — Character file format and write operations
- [CONFIG-STATE.md](CONFIG-STATE.md) — Configuration resolution used by write commands
- [MIGRATION.md](MIGRATION.md) — §2 Entity Write Operations

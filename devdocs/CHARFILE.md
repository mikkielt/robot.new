# Character File Format - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers `private/charfile-helpers.ps1`: the parser and writer for character files (`Postaci/Gracze/*.md`), and the template system used by `New-PlayerCharacter`.

**Not covered**: Entity-level character data (PU tags, aliases, status) - see [ENTITY-WRITES.md](ENTITY-WRITES.md). Three-layer state merge - see [ENTITIES.md](ENTITIES.md).

---

## 2. Character File Structure

Character files use bold-header sections (`**Header:**`) as their organizing principle:

```markdown
# CharacterName

**Karta postaci:** <url>

**Tematy zastrzeżone:** topic1, topic2

**Stan:** Zdrowy.

**Przedmioty specjalne:**
- Item1
- Item2

**Reputacja:**
- Pozytywna: Location1, Location2
- Neutralna: Location3
    - Detail about Location3
- Negatywna: Brak.

**Dodatkowe notatki:**
- Note1
- Note2

**Opisane sesje:**
- Session1
- Session2
```

---

## 3. Functions

### 3.1 `Find-CharacterSection`

Locates a `**Header:**` section in the file lines.

**Detection**: Regex pattern matching `**Header:**` bold-header format and `###` level-3 headers.

**Returns**: `{ StartIdx, EndIdx }` - the content range between this header and the next (or EOF). Trailing blank lines are trimmed.

### 3.2 `Read-CharacterFile`

Parses an entire character file into a structured object.

**Section name mapping** (Polish -> property):

| Section header | Property | Type |
|---|---|---|
| `Karta postaci` | `CharacterSheet` | string (URL) |
| `Tematy zastrzeżone` / `Tematy zastrzezone` | `RestrictedTopics` | string |
| `Stan` | `Condition` | string |
| `Przedmioty specjalne` | `SpecialItems` | string[] |
| `Reputacja` | `Reputation` | `{ Positive, Neutral, Negative }` |
| `Dodatkowe notatki` | `AdditionalNotes` | string[] |
| `Opisane sesje` | `DescribedSessions` | object[] (read-only) |

**Special handling**:
- `"Brak."` marker treated as empty/null
- Angle brackets stripped from URLs (`<url>` -> `url`)
- Diacritic normalization: maps both `Tematy zastrzeżone` and `Tematy zastrzezone`

### 3.3 `Read-ReputationTier`

Parses a single reputation tier (Positive/Neutral/Negative) from list items.

**Two input formats**:

1. **Inline comma-separated**: `- Pozytywna: Loc1, Loc2`
2. **Nested bullets**: Children of the tier bullet, with optional sub-bullets for details

**Output**: Array of `@{ Location; Detail }` objects.

**Location detail extraction**: Regex splits `Location (detail)` or `Location: detail` patterns.

**Sub-bullet support**: Items nested below a location header are collected as multi-line details.

### 3.4 `Write-CharacterFileSection`

Replaces the content of a single bold-header section in-place.

**Algorithm**:
1. `Find-CharacterSection` to locate section boundaries
2. Remove existing content lines from `List[string]`
3. Insert new content lines at the same position

Uses `List[string]` mutation (same pattern as entity write helpers).

### 3.5 `Format-ReputationSection`

Renders the three-tier reputation structure as Markdown lines.

**Format selection** per tier:
- **Inline** (no details): `- Pozytywna: Loc1, Loc2`
- **Nested** (with details): Tier header + nested bullets with location and detail sub-bullets

---

## 4. Template System

### 4.1 Template Files

Located in `.robot.new/templates/`:

| File | Purpose |
|---|---|
| `player-character-file.md.template` | New character file skeleton |
| `player-entry.md.template` | Entity entry template |

### 4.2 Placeholder Substitution

Templates use `{Placeholder}` syntax, rendered via `Get-AdminTemplate`:

```powershell
$Template = Get-AdminTemplate -Name "player-character-file.md.template"
$Result = $Template.Replace("{CharacterSheetUrl}", $Url)
                   .Replace("{Triggers}", $Triggers)
                   .Replace("{AdditionalInfo}", $Info)
```

Simple string `.Replace()` - no advanced template engine.

### 4.3 Character File Template Placeholders

| Placeholder | Source |
|---|---|
| `{CharacterSheetUrl}` | `-CharacterSheetUrl` parameter or empty |
| `{Triggers}` | Player's restricted topics or `"Brak."` |
| `{AdditionalInfo}` | Additional info from entity data or empty |

---

## 5. Dual-Target Write Pattern

`Set-PlayerCharacter` and `New-PlayerCharacter` perform dual-target writes:

```
Set-PlayerCharacter
    │
    ├── Target 1: entities.md (entity-level data)
    │   └── @pu_suma, @pu_zdobyte, @pu_nadmiar, @alias, @status
    │
    └── Target 2: Postaci/Gracze/<Name>.md (character file)
        └── CharacterSheet, RestrictedTopics, Condition,
            SpecialItems, Reputation, AdditionalNotes
```

Character file path is auto-resolved from `Get-PlayerCharacter` or overridden with `-CharacterFile`.

---

## 6. Precompiled Regex Patterns

| Variable | Purpose |
|---|---|
| `$CharSectionPattern` | Matches `**Header:**` bold-header format |
| `$ReputationTierPattern` | Matches reputation tier labels (Pozytywna/Neutralna/Negatywna) |
| `$LocationDetailPattern` | Extracts `Location (detail)` or `Location: detail` |

---

## 7. Edge Cases

| Scenario | Behavior |
|---|---|
| `"Brak."` in any section | Treated as empty (no items, no condition) |
| Missing section in character file | Returns `$null` for that property |
| Angle brackets around URL | Stripped: `<url>` -> `url` |
| Diacritic variation in headers | Both `zastrzeżone` and `zastrzezone` recognized |
| Inline vs nested reputation | Auto-detected; rendered back in matching format |
| Sub-bullets under location | Collected as multi-line detail text |
| `DescribedSessions` | Read-only - never written back by `Write-CharacterFileSection` |

---

## 8. Testing

| Test file | Coverage |
|---|---|
| `tests/charfile-helpers.Tests.ps1` | Section detection, full parse, reputation tiers, write operations |
| `tests/set-playercharacter-charfile.Tests.ps1` | Dual-target writes, property updates |

---

## 9. Related Documents

- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Entity-level write operations (Target 1)
- [ENTITIES.md](ENTITIES.md) - Three-layer state merge (character file is Layer 1)
- [CONFIG-STATE.md](CONFIG-STATE.md) - Template loading via `Get-AdminTemplate`

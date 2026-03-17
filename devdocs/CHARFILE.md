# Character File Format

## Scope

The character file subsystem comprises `private/charfile-helpers.ps1` and `private/charfile-reputation.ps1` (dot-sourced by `charfile-helpers.ps1`): the parser and writer for character files (`Postaci/Gracze/*.md`), and the template system used by `New-PlayerCharacter`.

Entity-level character data (PU tags, aliases, status) is documented in [ENTITY-WRITES.md](ENTITY-WRITES.md). Three-layer state merge is documented in [ENTITIES.md](ENTITIES.md).

---

## Character File Structure

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

**Dodatkowe informacje:**
- Note1
- Note2

**Opisane sesje:**
- Session1
- Session2
```

---

## Functions

`Find-CharacterSection` locates a `**Header:**` section in the file lines. Detection uses a regex pattern matching `**Header:**` bold-header format and `###` level-3 headers. Returns `{ HeaderIdx, InlineContent, ContentStart, ContentEnd }` -- the content range between this header and the next (or EOF). `InlineContent` captures text on the same line as the header (e.g. `**Karta Postaci:** <url>`). Trailing blank lines are trimmed from the `ContentStart..ContentEnd` range.

`Read-CharacterFile` parses an entire character file into a structured object. Section name mapping (Polish to property):

| Section header | Property | Type |
|---|---|---|
| `Karta Postaci` | `CharacterSheet` | string (URL) |
| `Tematy zastrzeżone` / `Tematy zastrzezone` | `RestrictedTopics` | string |
| `Stan` | `Condition` | string |
| `Przedmioty specjalne` | `SpecialItems` | string[] |
| `Reputacja` | `Reputation` | `{ Positive, Neutral, Negative }` |
| `Dodatkowe informacje` | `AdditionalNotes` | string[] |
| `Opisane sesje` | `DescribedSessions` | object[] (read-only) |

Special handling: `"Brak."` marker is treated as empty/null. Angle brackets are stripped from URLs (`<url>` becomes `url`). Diacritic normalization maps both `Tematy zastrzeżone` and `Tematy zastrzezone`.

`Read-ReputationTier` (in `private/charfile-reputation.ps1`) parses a single reputation tier (Positive/Neutral/Negative) from list items. Two input formats are supported: inline comma-separated (`- Pozytywna: Loc1, Loc2`) and nested bullets (children of the tier bullet, with optional sub-bullets for details). Output is an array of `@{ Location; Detail }` objects. Location detail extraction uses a regex that splits `Location (detail)` or `Location: detail` patterns. Items nested below a location header are collected as multi-line details.

`Write-CharacterFileSection` replaces the content of a single bold-header section in-place. Algorithm: (1) `Find-CharacterSection` to locate section boundaries. (2) Remove existing content lines from `List[string]`. (3) Insert new content lines at the same position. Uses `List[string]` mutation (same pattern as entity write helpers).

`Write-CharacterFile` writes a character file to disk with plugin hook integration. Mirrors the `Write-EntityFile` pattern from `entity-writehelpers.ps1`.

| Parameter | Type | Description |
|---|---|---|
| `Path` | string | Mandatory. Absolute path to the character file. |
| `Content` | string | Mandatory. Complete file content to write. |

Behavior: (1) Invokes `Invoke-PluginHook -Operation 'Write-CharacterFile' -Phase 'BeforeWrite'` (if plugin system loaded). (2) Writes content via `[System.IO.File]::WriteAllText()` with `UTF8Encoding(false)` (no BOM). (3) Calls `Add-OperationFile` to register the file path (if operation context available). (4) Invokes `Invoke-PluginHook -Operation 'Write-CharacterFile' -Phase 'AfterWrite'`. Operation context integration checks `$script:HasOpCtx` (set at file load time by probing for `Add-OperationFile` command availability). When available, the written file path is tracked in the operation accumulators.

`Format-ReputationSection` (in `private/charfile-reputation.ps1`) renders the three-tier reputation structure as Markdown lines. Format selection per tier: inline (no details) produces `- Pozytywna: Loc1, Loc2`; nested (with details) produces tier header + nested bullets with location and detail sub-bullets.

---

## Template System

Template files are located in `.robot.new/templates/`:

| File | Purpose |
|---|---|
| `player-character-file.md.template` | New character file skeleton |
| `player-entry.md.template` | Entity entry template (parsed by `ConvertFrom-EntityTemplate`) |
| `entities-skeleton.md.template` | Initial `entities.md` structure (7 section headers) |
| `currency-entity.md.template` | New currency entity bullet structure |
| `pu-notification-base.txt.template` | PU Discord notification -- always present |
| `pu-notification-overflow.txt.template` | PU notification -- overflow supplement consumed |
| `pu-notification-remaining.txt.template` | PU notification -- overflow pool remaining |
| `pu-sessions-header.md.template` | State file preamble for `pu-sessions.json` |

Templates use `{Placeholder}` syntax, rendered via `Get-AdminTemplate`:

```powershell
$Template = Get-AdminTemplate -Name "player-character-file.md.template"
$Result = $Template.Replace("{CharacterSheetUrl}", $Url)
                   .Replace("{Triggers}", $Triggers)
                   .Replace("{AdditionalInfo}", $Info)
```

Simple string `.Replace()` -- no advanced template engine.

`ConvertFrom-EntityTemplate` parses a rendered template into a structured object for use with `New-EntityBullet`. Located in `private/entity-writehelpers.ps1`. Input is rendered template text containing `* EntityName` and `- @tag: value` lines. Output is `@{ Name = "EntityName"; Tags = [ordered]@{ tag1 = value1; tag2 = value2 } }`. Used by `New-PlayerCharacter` to derive the default tag set from `player-entry.md.template` -- the template is the source of truth for which tags a new character entry receives.

Character file template placeholders:

| Placeholder | Source |
|---|---|
| `{CharacterSheetUrl}` | `-CharacterSheetUrl` parameter or empty |
| `{Triggers}` | Player's restricted topics or `"Brak."` |
| `{AdditionalInfo}` | Additional info from entity data or empty |

---

## Dual-Target Write Pattern

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

## Precompiled Regex Patterns

| Variable | Source File | Purpose |
|---|---|---|
| `$CharSectionPattern` | `charfile-helpers.ps1` | Matches `**Header:**` bold-header format with optional inline content |
| `$SessionHeaderPattern_CF` | `charfile-helpers.ps1` | Matches `### YYYY-MM-DD, Title, Narrator` session headers in character files |
| `$LocationDetailPattern` | `charfile-helpers.ps1` | Extracts `Location (detail)` or `Location: detail` |
| `$ReputationTierPattern` | `charfile-reputation.ps1` | Matches reputation tier labels (Pozytywna/Neutralna/Negatywna) with `IgnoreCase` |

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| `"Brak."` in any section | Treated as empty (no items, no condition) |
| Missing section in character file | Returns `$null` for that property |
| Angle brackets around URL | Stripped: `<url>` becomes `url` |
| Diacritic variation in headers | Both `zastrzeżone` and `zastrzezone` recognized |
| Inline vs nested reputation | Auto-detected; rendered back in matching format |
| Sub-bullets under location | Collected as multi-line detail text |
| `DescribedSessions` | Read-only -- never written back by `Write-CharacterFileSection` |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/charfile-helpers.Tests.ps1` | Section detection, full parse, reputation tiers, write operations |
| `tests/set-playercharacter-charfile.Tests.ps1` | Dual-target writes, property updates |

---

## Related Documents

- [ENTITY-WRITES.md](ENTITY-WRITES.md) -- Entity-level write operations (Target 1)
- [ENTITIES.md](ENTITIES.md) -- Three-layer state merge (character file is Layer 1)
- [STRUCTURES.md](STRUCTURES.md) -- Canonical data structure reference (CharacterFile, Reputation, DescribedSession)
- [CONFIG-STATE.md](CONFIG-STATE.md) -- Template loading via `Get-AdminTemplate`, operation context for `Write-CharacterFile`

# Session Recording Guide

## Purpose

This guide explains how narrators document game sessions in the repository. Proper session recording ensures that PU awards, world-state changes, and notifications are processed correctly and automatically.

## Scope

**What is included:**

- How to write a session entry in the current format
- What metadata fields are required and optional
- How the system reads session data
- Common mistakes and how to fix them

**What is excluded:**

- Monthly PU assignment process (see [PU.md](PU.md))
- Player and character registration (see [Players.md](Players.md))

## Actors and Responsibilities

### Narrator

- Writes the session entry in the designated Markdown file after each session
- Ensures character names in PU entries match registered names or aliases exactly
- Records world-state changes (Zmiany) so they are applied automatically
- Adds Intel entries when targeted information needs to reach specific recipients

### Coordinator

- Reviews session entries for data quality issues (unresolved names, broken dates)
- Runs diagnostics to catch silent parsing failures
- Upgrades older session formats if needed

## Inputs Required

- The session date, title, and narrator name
- List of locations visited during the session
- Link(s) to the session log/transcript
- PU awards for each participating character
- Any world-state changes resulting from the session
- Any Intel messages for specific recipients (optional)

## Session Format

### Session Header

Every session starts with a level-3 header containing the date, title, and narrator name:

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine
```

**Date format**: Always `YYYY-MM-DD`. Incorrect formats (like `2025-6-15` or `15-06-2025`) will cause the session to be silently skipped during PU processing.

**Multi-day sessions**: Use a slash for the end day: `### 2025-06-21/22, Weekend Session, Catherine` (must be in the same month).

### Metadata Blocks (Current Format)

All metadata uses `@`-prefixed tags:

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine
- @Lokacje:
    - Erathia
    - Bracada
- @Logi:
    - https://example.com/session-log
- @PU:
    - Crag Hack: 0.3
    - Gem: 0.5
- @Zmiany:
    - Crag Hack
        - @grupa: Bractwo Miecza
        - @lokacja: Bracada
    - Sandro
        - @lokacja: Bracada
- @Intel:
    - Grupa/Nekromanci: Wiadomość do wszystkich członków Nekromantów
    - Solmyr: Prywatna wiadomość

Free-form narrative text goes here. It is preserved by the system
but not parsed for metadata.
```

### Metadata Fields

| Field | Required | Description |
|---|---|---|
| `@Lokacje` | Recommended | Where the session took place (one location per line) |
| `@Logi` | Recommended | Link(s) to the session transcript |
| `@PU` | Required for PU processing | Character name and PU value (e.g., `Crag Hack: 0.3`) |
| `@Zmiany` | As needed | World-state changes (entity name + `@tag: value` pairs) |
| `@Intel` | As needed | Targeted messages to specific recipients |

### PU Entry Format

Each PU entry is a character name followed by a colon and a decimal value:

```markdown
- @PU:
    - CharacterName: 0.3
```

- Use a **period** (`.`) as the decimal separator (commas are also accepted but not preferred)
- PU values are typically between 0.1 and 0.5 per session
- Character names must match a registered name or alias **exactly** (case-insensitive)

### Changes (Zmiany) Format

Changes record permanent updates to the game world:

```markdown
- @Zmiany:
    - EntityName
        - @tag: value
```

Common tags:
- `@lokacja: LocationName` — entity permanently moves to a new location
- `@grupa: GroupName` — entity joins a group/faction
- `@status: Aktywny` / `Nieaktywny` / `Usunięty` — entity status change

Changes are applied automatically with the session's date as the effective date.

### Intel Format

Intel entries send targeted messages to specific recipients via Discord:

```markdown
- @Intel:
    - Grupa/Nekromanci: Message to all Necromancer members
    - Lokacja/Erathia: Message to everyone in Erathia
    - Solmyr: Private message to Solmyr
    - Gem, Vidomina: Message to multiple recipients
```

Targeting options:
- `Grupa/Name` — all entities in the named group/organization
- `Lokacja/Name` — all entities in the named location and sub-locations
- `Name` — direct targeting (comma-separated for multiple recipients)

## Older Format Generations

The system reads four format generations. Sessions written before 2026 do not need to be rewritten — the system auto-detects and parses all formats.

| Period | Format | Example |
|---|---|---|
| Before 2022 | Plain text | `Logi: https://...` as plain text, no structured metadata |
| 2022–2023 | Italic locations | `*Lokalizacja: Erathia, Bracada*` |
| 2024–2026 | Structured lists | `- Lokalizacje:`, `- PU:` (without `@` prefix) |
| 2026 onward | Current format | `- @Lokacje:`, `- @PU:` (with `@` prefix) |

When writing new sessions, always use the current format (with `@` prefix).

## Sessions Across Multiple Files

The same session may appear in multiple Markdown files (e.g., a location log file and a thread file). This is handled automatically:

- Sessions with identical headers are merged — PU is counted only once
- The instance with the richest metadata is used as the primary source
- Location lists, log links, and other array fields are combined

## Expected Outcomes

A properly recorded session:

1. Appears in PU processing for the correct month
2. Awards PU to the correct characters in the correct amounts
3. Applies world-state changes to the correct entities with the session date
4. Delivers Intel messages to the correct recipients via Discord
5. Is logged in the processing history to prevent double-counting

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **Wrong date format** (e.g., `2025-6-15`) | Session silently skipped during PU processing | Fix to `YYYY-MM-DD` format |
| **Character name typo in PU** | Entire PU assignment stops | Fix the name to match a registered name or alias |
| **Missing PU block** | Session processed but no PU awarded | Add `- @PU:` block with entries |
| **Session in wrong file** | Still found if the file is a `.md` file in the repository | No action needed |
| **Preserved blocks** (`Objaśnienia`, `Efekty`) | Kept as-is during format upgrades | No action needed |

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Glossary](Glossary.md) — Term definitions
- [Players.md](Players.md) — Player and character management

# Session Recording Guide

## Overview

Narrators document game sessions in the repository using a structured Markdown format. Proper session recording ensures that PU awards, world-state changes, and notifications are processed correctly and automatically.

## Actors and Responsibilities

The Narrator writes the session entry in the designated Markdown file after each session, ensures character names in PU entries match registered names or aliases exactly, records world-state changes (Zmiany) so they are applied automatically, and adds Intel entries when targeted information needs to reach specific recipients.

The Coordinator reviews session entries for data quality issues (unresolved names, broken dates), runs diagnostics to catch silent parsing failures, and upgrades older session formats if needed.

## Inputs Required

- The session date, title, and narrator name
- List of locations visited during the session
- Link(s) to the session log/transcript
- PU awards for each participating character
- Any world-state changes resulting from the session
- Any Intel messages for specific recipients (optional)

## Session Header

Every session starts with a level-3 header containing the date, title, and narrator name:

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine
```

The date format is always `YYYY-MM-DD`. Incorrect formats (like `2025-6-15` or `15-06-2025`) are reported as errors.

For multi-day sessions, use a slash for the end day: `### 2025-06-21/22, Weekend Session, Catherine` (must be in the same month).

## Metadata Blocks (Current Format)

All metadata uses `@`-prefixed tags:

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine

Free-form narrative text goes here. It is preserved by the system
but not parsed for metadata.

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
- @Transfer: 100 koron, Crag Hack -> Gem
- @Intel:
    - Grupa/Nekromanci: Wiadomość do wszystkich członków Nekromantów
    - Solmyr: Prywatna wiadomość
```

## Metadata Fields

| Field | Required | Description |
|---|---|---|
| `@Narrator` | Optional | Canonical narrator name override (replaces header-based narrator resolution) |
| `@Data` | Optional | Date override in `YYYY-MM-DD` format (replaces date parsed from header; rescues sessions with malformed header dates) |
| `@Lokacje` | Recommended | Where the session took place (one location per line) |
| `@Logi` | Recommended | Link(s) to the session transcript |
| `@PU` | Required for PU processing | Character name and PU value (e.g., `Crag Hack: 0.3`) |
| `@Zmiany` | As needed | World-state changes (entity name + `@tag: value` pairs) |
| `@Transfer` | As needed | Currency transfers between entities (see [Currency.md](Currency.md)) |
| `@Intel` | As needed | Targeted messages to specific recipients |

## PU Entry Format

Each PU entry is a character name followed by a colon and a decimal value:

```markdown
- @PU:
    - Crag Hack: 0.3
```

- Use a period (`.`) as the decimal separator (commas are also accepted but periods are preferred)
- PU values are typically between 0.1 and 0.5 per session
- Character names must match a registered name or alias exactly (case-insensitive)

## Changes (Zmiany) Format

Changes record permanent updates to the game world:

```markdown
- @Zmiany:
    - Sandro
        - @lokacja: Deyja
```

Common tags: `@lokacja: Erathia` moves an entity permanently to a new location; `@grupa: Nekromanci` adds the entity to a group/faction; `@status: Aktywny` / `Nieaktywny` / `Usunięty` changes entity status.

Changes are applied automatically with the session's date as the effective date.

## Intel Format

Intel entries send targeted messages to specific recipients via Discord:

```markdown
- @Intel:
    - Grupa/Nekromanci: Message to all Necromancer members
    - Lokacja/Erathia: Message to everyone in Erathia
    - Solmyr: Private message to Solmyr
    - Gem, Vidomina: Message to multiple recipients
```

Targeting options: `Grupa/Name` reaches all entities in the named group, `Lokacja/Name` reaches all entities in the named location and sub-locations, and a direct name (comma-separated for multiple recipients) targets individuals.

## Transfer Format

Transfers record currency movements between entities during a session:

```markdown
- @Transfer: 100 koron, Crag Hack -> Gem
- @Transfer: 50 talarów, Kupiec Orrin -> Kyrre
```

The format is: `@Transfer: {amount} {denomination}, {source} -> {destination}`

You can use colloquial denomination names ("koron", "talarów", "kogi") — the system recognizes them automatically. Multiple transfers per session are allowed.

For more details on currency tracking, see [Currency.md](Currency.md).

## Older Format Generations

The system reads four format generations. Sessions written before 2026 do not need to be rewritten — the system auto-detects and parses all formats.

| Period | Format | Example |
|---|---|---|
| Before 2022 | Plain text | `Logi: https://...` as plain text, no structured metadata |
| 2022-2023 | Italic locations | `*Lokalizacja: Erathia, Bracada*` |
| 2024-2026 | Structured lists | `- Lokalizacje:`, `- PU:` (without `@` prefix) |
| 2026 onward | Current format | `- @Lokacje:`, `- @PU:` (with `@` prefix) |

When writing new sessions, always use the current format (with `@` prefix).

The main difference between Gen3 (2024-2026) and Gen4 (current) is the `@` prefix on metadata tags. Gen4 uses `@Lokacje` (instead of `Lokalizacje`), `@Logi` (instead of `Logi`), `@PU` (instead of `PU`), and `@Zmiany` (instead of `Zmiany`). Gen4 also introduces `@Transfer`, `@Intel`, `@Narrator`, and `@Data` metadata blocks. Entity-level tags inside `@Zmiany` always used the `@` prefix in both formats.

## Editing Existing Sessions

Coordinators can modify the metadata of an existing session (locations, PU, logs, changes, Intel, and body text) without manually editing the Markdown file. The system locates the session by its header, replaces the specified metadata blocks, and preserves any non-metadata content (such as Objaśnienia or Efekty blocks).

When editing a session written in an older format (Gen2 or Gen3), the Coordinator must request a format upgrade at the same time. The system converts all metadata to the current Gen4 `@`-prefixed syntax automatically, while preserving the session's body text and non-metadata blocks.

## Sessions Across Multiple Files

The same session may appear in multiple Markdown files (e.g., a location log file and a thread file). This is handled automatically: sessions with identical headers are merged so PU is counted only once, the instance with the richest metadata is used as the primary source, and location lists, log links, and other array fields are combined.

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
| Wrong date format (e.g., `2025-6-15`) | Session silently skipped during PU processing | Fix to `YYYY-MM-DD` format |
| Character name typo in PU | Entire PU assignment stops | Fix the name to match a registered name or alias |
| Missing PU block | Session processed but no PU awarded | Add `- @PU:` block with entries |
| Session in wrong file | Still found if the file is a `.md` file in the repository | No action needed |
| Preserved blocks (`Objaśnienia`, `Efekty`) | Kept as-is during format upgrades | No action needed |

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [World-State.md](World-State.md) — Entity management and world-state changes
- [Currency.md](Currency.md) — Currency tracking and transfers
- [Session-Logs.md](Session-Logs.md) — Session log fetching and location analysis
- [Session-Graph.md](Session-Graph.md) — Session participation tracking
- [Session-Integrity.md](Session-Integrity.md) — Session content verification
- [Location-Graph.md](Location-Graph.md) — Location analysis from session routes
- [Players.md](Players.md) — Player and character management
- [Structures](Structures.md) — What data the system tracks for each concept
- [Campaign Data API](REST-API.md) — Querying session data from external tools
- [Glossary](Glossary.md) — Term definitions

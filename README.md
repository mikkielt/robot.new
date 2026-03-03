# Robot PowerShell Module

A PowerShell module for managing an online RPG lore repository ([Nerthus](https://github.com/search?q=Nerthus)). Runs as a Git submodule at `.robot.new/` inside the lore repository, parsing Markdown files into structured, queryable data.

- **Players & Characters** — Full CRUD for players, characters, and their state. Characters use a three-layer merge model (entity registry → character file → session overrides) for a unified view.
- **Entities** — Manage NPCs, groups, locations, and items with temporal scoping — every tag change carries an effective date, enabling point-in-time queries. Soft-delete only; no data is ever physically removed.
- **Currency** — Denomination-validated currency entities with delta adjustments, transfer tracking between sessions, and balance reconciliation reporting.
- **Sessions** — Parse four format generations (Gen1–Gen4) with automatic detection. Record PU awards, world-state changes (`@Zmiany`), and targeted Intel messages. Duplicate sessions across files are merged automatically.
- **Session Logs** — Fetch, cache, and parse session transcripts (ChatLog and Prose formats). Analyze location headers against the entity registry for data quality reporting.
- **PU (Skill Points)** — Monthly assignment pipeline with a 5 PU cap, overflow pool mechanics, fail-early validation, Discord notifications, and an append-only processing log to prevent double-counting.
- **Name Resolution** — Four-stage pipeline: exact match → Polish declension stemming → consonant alternation → Levenshtein fuzzy matching. Handles aliases, short names, and common typos.
- **Audit & Integrity** — Read-only reporting across entity history, change logs, transaction ledgers, PU assignment logs, and notification logs. SHA-256 session content hashing with tamper detection.
- **Notifications** — Discord webhook integration for PU award notifications (per-player, multi-character) and Intel fan-out (group, location, or direct targeting).

## Requirements

- PowerShell 5.1+ or PowerShell Core 7.0+
- Git in `PATH`
- [Pester](https://pester.dev/) v5.0+ (tests only)

## Quick Start

```powershell
Import-Module ./.robot.new/robot.psd1

Get-Player                                              # all players with characters
Get-Entity -ActiveOn (Get-Date)                         # entities active today
Get-Session -MinDate "2025-01-01"                       # sessions from 2025

Invoke-PlayerCharacterPUAssignment -Year 2026 -Month 1  # monthly PU (dry run)
Test-PlayerCharacterPUAssignment                        # validate PU data quality
```

## Testing

```powershell
Invoke-Pester ./tests/ -Output Detailed
```

## Interactive CLI

```powershell
Invoke-RobotCLI
```

Menu-driven interface with fuzzy search, wizards, and role-based filtering (Coordinator / Narrator / Player).

## Documentation

`devdocs/` contains internal documentation for module development and maintenance. `docs/` contains user-facing documentation for players and coordinators.

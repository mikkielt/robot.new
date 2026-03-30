# Robot PowerShell Module

A PowerShell module for managing an online RPG lore repository ([Nerthus](https://nerthus.pl/)). Runs as a Git submodule at `.robot.powershell/` inside the lore repository, parsing Markdown files into structured, queryable data.

- Players and Characters — full CRUD for players, characters, and their state. Characters use a three-layer merge model (entity registry → character file → session overrides) for a unified view.
- Entities — NPCs, groups, locations, and items with temporal scoping. Every tag change carries an effective date, enabling point-in-time queries. Entities are soft-deleted, preserving full history.
- Currency — denomination-validated currency entities with delta adjustments, transfer tracking between sessions, and balance reconciliation reporting.
- Sessions — four format generations (Gen1–Gen4) with automatic detection. Records PU awards, world-state changes (`@Zmiany`), and targeted Intel messages. Duplicate sessions across files are merged automatically.
- Session Logs — fetch, cache, and parse session transcripts (ChatLog and Prose formats). Analyzes location headers against the entity registry for data quality reporting.
- PU (Skill Points) — monthly assignment pipeline with a 5 PU cap, overflow pool mechanics, fail-early validation, Discord notifications, and an append-only processing log.
- Name Resolution — four-stage pipeline: exact match → Polish declension stemming → consonant alternation → Levenshtein fuzzy matching. Handles aliases, short names, and common typos.
- Audit and Integrity — read-only reporting across entity history, change logs, transaction ledgers, PU assignment logs, and notification logs. SHA-256 session content hashing with tamper detection.
- Notifications — Discord webhook integration for PU award notifications (per-player, multi-character) and Intel fan-out (group, location, or direct targeting).

## Requirements

- PowerShell 5.1+ or PowerShell Core 7.0+
- Git in `PATH`
- [Pester](https://pester.dev/) v5.0+ (tests only)

## Adding as a Submodule

From the root of your lore repository:

```bash
git submodule add git@github.com:mikkielt/robot.new.git .robot.powershell
git submodule update --init
```

## Quick Start

```powershell
Import-Module ./.robot.powershell/Robot.PowerShell.psd1

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

## Documentation

`devdocs/` contains internal documentation for module development and maintenance. `docs/` contains user-facing documentation for players and coordinators.

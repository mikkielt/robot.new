# Interactive CLI Guide

## Purpose

This guide explains how to use the interactive CLI menu for managing the game world - creating sessions, players, entities, handling currency, PU assignments, and Discord notifications - without writing PowerShell commands directly.

## Scope

**What is included:**

- How to start the CLI
- How to navigate the menu
- Walkthroughs for common tasks
- Troubleshooting common issues

**What is excluded:**

- Direct PowerShell commands (see function help via `Get-Help <FunctionName>`)
- Session file format (see [Sessions.md](Sessions.md))
- Monthly PU process details (see [PU.md](PU.md))

## Actors and Responsibilities

### Narrator

- Creates and edits sessions
- Registers new players and characters
- Creates and edits entities (NPCs, locations, groups, items)
- Views character and entity cards
- Searches for entities by name

### Coordinator

- All narrator tasks
- Runs monthly PU assignments
- Runs diagnostics (PU, currency, session validation)
- Manages currency transfers
- Sends Discord notifications and announcements
- Runs migration tools

## Starting the CLI

After importing the Robot module, run:

```powershell
Invoke-RobotCLI
```

The CLI loads game data and presents the main menu. This may take a few seconds on first load.

**Requirements**: A standard terminal (not PowerShell ISE). The CLI uses arrow-key navigation which requires `[Console]::ReadKey` support.

## Navigation

| Key | Action |
|---|---|
| Up/Down arrows | Move between menu items |
| Enter | Select the highlighted item |
| Escape | Go back one level |
| `/` followed by a letter | Open the command palette (see Komendy below) |

The breadcrumb at the top of the screen shows your current location (e.g., `Robot > Encje > Nowa encja`).

## Komendy

Press `/` followed by a letter to execute a command from any screen:

| Komenda | Opis |
|---|---|
| `/h` | Otwiera nakładkę pomocy z opisem aktualnego widoku |
| `/h tekst` | Wyszukuje tematy pomocy pasujące do wpisanego tekstu |
| `/s` | Pokazuje panel stanu systemu — statusy PU, walut, integralności sesji i grafu sesji |
| `/r` | Odświeża dane (encje, gracze, indeks nazw) bez wychodzenia z CLI |
| `/b` | Cofnij — działa tak samo jak Escape |
| `/q` | Zamyka CLI |

Commands execute immediately — there is no need to press Enter after the letter.

## Main Menu Categories

| Category | Description |
|---|---|
| Sesje | Create, edit, query, and validate sessions |
| Gracze | Register players and characters, view player/character cards |
| Encje | Create, edit, search, and browse entities (NPCs, locations, groups, items) |
| Waluta | Transfer currency between entities, run reconciliation checks |
| PU | Monthly PU assignment, PU diagnostics |
| Discord | Send PU notifications, post announcements |
| Migracja | Migration tools (when migration files are available) |

Each category shows the number of available actions. Select a category to see its items.

Plugins can add their own menu items to existing categories or introduce entirely new categories. Plugin-provided items appear alongside core items and work the same way (wizard, query, or workflow).

## Common Tasks

### Creating a New Session

1. Navigate to **Sesje** > **Nowa sesja**
2. The wizard walks through each field (file path, date, locations, narrator, etc.)
3. Skip optional fields by pressing Enter without typing
4. Review the preview - it shows exactly what will be written
5. Confirm to create, or cancel to discard

### Registering a New Player

1. Navigate to **Gracze** > **Nowy gracz**
2. Enter the player name and other fields
3. After creation, the CLI asks whether to add a first character
4. If adding a character, you can also add starting currency

### Creating a New Entity

1. Navigate to **Encje** > **Nowa encja**
2. Select the entity type (NPC, Grupa, Lokacja, Przedmiot)
3. Enter the entity name
4. Add tags one by one (lokacja, grupa, status, alias, etc.)
5. For location and group tags, a fuzzy search picker appears
6. Select "Zakoncz dodawanie tagow" when done
7. Review and confirm

### Editing an Entity

1. Navigate to **Encje** > **Edytuj encje**
2. Use fuzzy search to find the entity (start typing to filter)
3. The current tags are shown for context
4. Add or change tags using the same tag picker
5. Review changes and confirm

### Searching for Entities

1. Navigate to **Encje** > **Szukaj encji**
2. Start typing the entity name
3. The search filters in real time (prefix matches first, then partial matches)
4. Select an entity to view its full detail card

### Viewing Entity or Character Cards

Entity and character cards show all known information in a formatted view:

- Entity cards show type, status, location, groups, aliases, tags, and history
- Character cards show active status, PU stats, aliases, and additional notes
- Player cards show all characters with their PU and aliases

### Monthly PU Assignment

1. Navigate to **PU** > **Przydzial miesieczny PU**
2. Enter the year and month
3. Review the dry-run results (shows what would be assigned)
4. Choose options: update characters, send to Discord, append to log, reconcile currency
5. Confirm to execute

### Currency Transfer

1. Navigate to **Waluta** > **Transfer walutowy**
2. Use fuzzy search to select the source currency entity
3. Enter the amount to transfer
4. Use fuzzy search to select the destination currency entity
5. Review the transfer preview (source debited, destination credited)
6. Confirm to execute

### Running Diagnostics

Several diagnostic tools are available:

- **PU > Diagnostyka PU** - checks for unresolved character names, malformed PU values, duplicates
- **PU > Diagnostyka przed przydzialem** - pre-assignment checks with name suggestions
- **Waluta > Uzgodnienie walut** - verifies currency entity consistency
- **Sesje > Walidacja sesji** - checks sessions for unresolved names in PU and Changes blocks

### Querying Data

Query-mode items (e.g., **Sesje** > **Lista sesji**, **Gracze** > **Lista graczy**) show results in a scrollable table. Select a row to view its detail card. Press Escape to return to the table.

Some queries have filters (date range, search text) shown before results.

## Fuzzy Search

When the CLI asks to select a player, character, entity, or location, a fuzzy search picker appears:

1. Start typing any part of the name
2. Matches appear in real time (prefix matches are shown first)
3. Use arrow keys to navigate the results
4. Press Enter to select
5. Press Escape to cancel

The search is case-insensitive and matches anywhere in the name. Approximate matches (based on similar spelling) appear after a short delay and are marked with `≈`.

## Filtrowanie

In table views (lists of sessions, entities, players, etc.), start typing to filter results in real time. The filter matches across all visible columns.

### Filtrowanie po kolumnie

Type a prefix followed by `:` and the search text to filter only a specific column. Available prefixes depend on the view:

| Widok | Dostępne filtry |
|---|---|
| Przeglądaj sesje | `narrator:` — filtruj po narratorze |
| Przeglądaj graczy | `postac:` — filtruj po aktywnej postaci |
| Przeglądaj encje | `typ:` — filtruj po typie (NPC, Lokacja, Grupa, Przedmiot); `status:` — filtruj po statusie |
| Salda walut | `nominal:` — filtruj po nominale waluty; `wlasciciel:` — filtruj po właścicielu |
| Log zmian | `encja:` — filtruj po nazwie encji; `tag:` — filtruj po tagu |
| Raport lokacji | `encja:` — filtruj po nazwie encji |
| Powiadomienia | `cel:` — filtruj po odbiorcy; `typ:` — filtruj po rodzaju powiadomienia |

Example: typing `typ:NPC` in the entity browser shows only NPCs. Typing `narrator:Anna` in the session list shows only sessions narrated by Anna.

Press Escape to clear the filter and return to the full list.

## Preview and Confirmation

Before any write operation, the CLI shows a preview:

- The action that will be performed
- All parameters and their values
- A simulation showing what would change

You can confirm (execute) or cancel (discard). This prevents accidental modifications.

## Pomoc

### Pomoc kontekstowa

Press `/h` in any view to open a help overlay describing the current screen — available actions, expected inputs, and tips. The overlay scrolls with arrow keys. Press Escape to close it.

### Wyszukiwanie pomocy

Press `/h` followed by a space and a search term (e.g., `/h waluta`) to search across all help topics. The CLI shows matching entries from all menu items. Select an entry to view its full help text.

### Panel stanu systemu

Press `/s` to open the health dashboard showing the status of four subsystems:

| Sekcja | Co sprawdza |
|---|---|
| PU | Czy przydział PU jest gotowy do wykonania |
| Waluta | Czy salda walut są spójne |
| Integralność sesji | Czy sesje nie zostały zmodyfikowane po weryfikacji |
| Graf sesji | Czy indeks grafu sesji jest aktualny |

Each section shows ✓ (OK) or ⚠ (warnings found) with a count of issues. The dashboard also shows when the last check was performed.

## Refreshing Data

Select **Odswież dane** from the main menu or press `/r` from any screen to reload entities, players, and the name index. This is useful after making changes outside the CLI or if data seems stale.

## Troubleshooting

| Issue | Solution |
|---|---|
| "Terminal nie wspiera trybu interaktywnego" | Use a standard terminal, not PowerShell ISE |
| "Terminal jest za mały" or garbled display | Resize the terminal to at least 60 columns × 15 rows |
| Fuzzy search returns no results | Check spelling; try a shorter prefix; press `/r` to refresh data |
| "Funkcja nie jest dostepna" | The target function may not be loaded; check module import |
| Menu items show unexpected state | Press `/r` to refresh or select "Odswież dane" from the main menu |
| Migration menu shows "niedostepna" | Migration files are not present in the repository |

## Related Documents

- [Sessions.md](Sessions.md) - Session recording format
- [Players.md](Players.md) - Player and character registration
- [PU.md](PU.md) - Monthly PU assignment process
- [Glossary](Glossary.md) - Term definitions

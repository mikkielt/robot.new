# Interactive CLI Guide

## Purpose

This guide explains how to use the interactive CLI for managing the game world — creating sessions, players, entities, handling currency, PU assignments, and Discord notifications — without writing PowerShell commands directly. The CLI provides a full-screen terminal interface with arrow-key navigation, inline filtering, fuzzy search, guided wizards, and a built-in help system.

## Scope

**What is included:**

- How to start and navigate the CLI
- Available menu categories and actions
- Filtering, fuzzy search, and keyboard shortcuts
- The help system and health dashboard
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

The CLI loads game data and presents the main menu. This may take a few seconds on first load as entities, players, and the name index are preloaded and background health checks run.

**Requirements**: A standard terminal (not PowerShell ISE). The CLI uses full-screen rendering which requires `[Console]::ReadKey` support. Minimum terminal size: 60 columns by 15 rows.

## Screen Layout

The CLI divides the terminal into four fixed areas:

| Area | Position | Contents |
|---|---|---|
| Pasek nawigacji | Top row | Breadcrumb showing your current location (e.g., `Robot > Encje > Nowa encja`) and health badges on the right |
| Obszar treści | Center | The main content: menu items, table rows, detail cards, or wizard steps |
| Pasek filtru | Below content | Your current filter text, match count, or command palette input |
| Pasek statusu | Bottom row | Available keyboard shortcuts for the current view |

Health badges appear in the top-right corner as small status indicators (checkmark or warning icon) for PU, currency, session integrity, and session graph status.

## Navigation

| Key | Action |
|---|---|
| Up / Down | Move between menu items or table rows |
| Enter | Select the highlighted item |
| Escape | Go back one level (or clear the active filter) |
| Tab | Open fuzzy search across all entities, players, and characters |
| Any letter | Start filtering the current list (in menu and table views) |

The CLI remembers your navigation path. Press Escape to go back one level at a time.

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
| Gracze i Postacie | Register players and characters, view player/character cards |
| Encje | Create, edit, search, and browse entities (NPCs, locations, groups, items) |
| Waluta | Transfer currency between entities, run reconciliation checks, analyze the economy |
| PU | Monthly PU assignment, PU diagnostics |
| Raporty i Narzędzia | Reporting, auditing, session graph, location reports, and utilities |
| Migracja | Migration tools (when migration files are available) |

Each category shows the number of available actions. Select a category to see its items. Some items are marked with a role badge — **N** for Narrator-only, **K** for Coordinator-only, or **N/K** for both.

Plugins can add their own menu items to existing categories or introduce entirely new categories. Plugin-provided items appear alongside core items and work the same way.

## Pomoc

### Pomoc kontekstowa

Press `/h` in any view to open a help overlay describing the current screen — available actions, expected inputs, and tips. The overlay scrolls with arrow keys. Press Escape to close it.

Every menu entry has its own help content. When viewing a submenu, `/h` describes the entire category. When running a wizard, `/h` describes the current step.

### Wyszukiwanie pomocy

Press `/h` followed by a space and a search term (e.g., `/h waluta`) to search across all help topics. The CLI shows matching entries from all menu items and categories. Select an entry to view its full help text.

### Panel stanu systemu

Press `/s` to open the health dashboard showing the status of four subsystems:

| Sekcja | Co sprawdza |
|---|---|
| PU | Czy przydział PU jest gotowy do wykonania |
| Waluta | Czy salda walut są spójne |
| Integralność sesji | Czy sesje nie zostały zmodyfikowane po weryfikacji |
| Graf sesji | Czy indeks grafu sesji jest aktualny |

Each section shows a checkmark (OK) or warning icon (issues found) with a count of problems. The dashboard also shows when the last check was performed. Press Escape to close the dashboard and return to your previous view.

The same health status is summarized as compact badges in the top-right corner of the navigation bar, visible at all times.

## Filtrowanie

In menu views and table views (lists of sessions, entities, players, etc.), start typing to filter results in real time. The filter bar at the bottom shows your current text and the number of matching items.

The search applies a three-stage pipeline:

1. **Prefix match** — items whose name starts with your text appear first
2. **Contains match** — items that contain your text anywhere
3. **Fuzzy match** — approximate matches (based on similar spelling) appear after a short delay and are marked with `≈`

Press Escape to clear the filter and return to the full list.

### Filtrowanie po kolumnie

In table views, type a prefix followed by `:` and the search text to filter only a specific column. Available prefixes depend on the view:

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

## Fuzzy Search

When the CLI asks to select a player, character, entity, or location, a fuzzy search picker appears. The same picker opens when you press Tab from menus.

1. Start typing any part of the name
2. Matches appear in real time (prefix matches are shown first)
3. After a brief pause, approximate matches appear marked with `≈`
4. Use arrow keys to navigate the results
5. Press Enter to select
6. Press Escape to cancel

The search is case-insensitive and handles Polish declension. If the name index is loaded, BK-tree fuzzy matching catches misspellings and inflected forms.

## Common Tasks

### Creating a New Session

1. Navigate to **Sesje** > **Nowa sesja**
2. The wizard walks through each field: date, narrator (fuzzy search among players), locations (add multiple via fuzzy search), PU entries, changes, intel, and log URLs
3. Skip optional fields by pressing Enter without typing
4. Review the preview — it shows exactly what will be written
5. Confirm to create, or cancel to discard

### Registering a New Player

1. Navigate to **Gracze i Postacie** > **Nowy gracz**
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
3. The search filters in real time (prefix matches first, then partial matches, then approximate matches)
4. Select an entity to view its full detail card

### Viewing Entity or Character Cards

Entity and character cards show all known information in a formatted view:

- Entity cards show type, status, location, groups, aliases, quantity, info notes, tags, and history
- Character cards show active status, PU stats, aliases, and additional notes
- Player cards show all characters with their PU and aliases

Cards are scrollable. Press Escape to return to the previous view.

### Browsing Data Tables

Query-mode items (e.g., **Sesje** > **Przeglądaj sesje**, **Gracze i Postacie** > **Przeglądaj graczy**) show results in a scrollable table.

- Tables adapt to your terminal width — less important columns hide automatically when the window is too narrow
- Start typing to filter rows in real time
- Use column-specific prefixes (like `typ:NPC`) for targeted filtering
- Select a row to view its detail card
- Press Escape to return to the table

### Monthly PU Assignment

1. Navigate to **PU** > **Przydział miesięczny PU**
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

- **PU > Diagnostyka PU** — checks for unresolved character names, malformed PU values, duplicates
- **PU > Diagnostyka przed przydziałem** — pre-assignment checks with name suggestions
- **Waluta > Uzgodnienie walut** — verifies currency entity consistency
- **Waluta > Obraz gospodarki** — shows a complete picture of the economy at a point in time: total currency in circulation, treasury reserves, player balances, and wealth distribution. The Coordinator uses this to understand the current economic state before making decisions about budgets or supply adjustments
- **Waluta > Oś czasu gospodarki** — shows how the economy evolved over time, tracking total currency supply, physical vs virtual holdings, and transfer volume across months. Useful for spotting trends like supply growth or unusual transaction spikes
- **Waluta > Raport materializacji** — analyzes where currency exists as physical game items vs virtual bookkeeping. Shows per-denomination and per-player breakdowns, and flags orphan physical currency held by inactive characters that may need to be recovered
- **Sesje > Walidacja sesji** — checks sessions for unresolved names in PU and Changes blocks

## Preview and Confirmation

Before any write operation, the CLI shows a preview:

- The action that will be performed
- All parameters and their values
- A simulation showing what would change

You can confirm (execute) or cancel (discard). This prevents accidental modifications.

## Wizards

When you select a menu entry that creates or modifies data, a guided wizard walks you through each required and optional field. Wizard step types include:

| Typ kroku | Opis |
|---|---|
| Tekst | Wpisz dowolny tekst (np. nazwa, tytuł) |
| Liczba | Wpisz liczbę całkowitą |
| Kwota | Wpisz kwotę z ułamkiem dziesiętnym |
| Data | Wpisz datę w formacie RRRR-MM-DD |
| Wybór | Wybierz jedną opcję z listy strzałkami |
| Tak/Nie | Potwierdź lub odrzuć strzałkami |
| Wyszukiwanie | Znajdź gracza, postać, encję lub lokację przybliżonym wyszukiwaniem |

If you enter an invalid value (e.g., text where a number is expected), the wizard shows an error message and lets you try again. You can navigate back to previous steps with Escape.

At the end of every wizard, a preview shows what will happen. Only after confirmation does the operation execute.

## Refreshing Data

Press `/r` from any screen to reload entities, players, and the name index. This is useful after making changes outside the CLI or if data seems stale. The health dashboard badges also refresh when you use `/r`.

## Display

### Kolory i dostępność

The CLI uses a colorblind-safe palette — it never relies on red/green distinction alone. Symbols (checkmarks, warning icons, arrows) reinforce meaning alongside color. The CLI auto-detects whether your terminal uses a dark or light background and adjusts colors accordingly.

### Responsywność

Tables and menus adapt to your terminal size. When the terminal is too narrow, less important columns in tables are hidden automatically so that the most critical information stays visible. If the terminal is resized below the minimum (60 columns by 15 rows), a message asks you to enlarge the window.

## Troubleshooting

| Issue | Solution |
|---|---|
| "Terminal nie wspiera trybu interaktywnego" | Use a standard terminal, not PowerShell ISE |
| "Terminal jest za mały" or garbled display | Resize the terminal to at least 60 columns by 15 rows |
| Fuzzy search returns no results | Check spelling; try a shorter prefix; press `/r` to refresh data |
| "Funkcja nie jest dostępna" | The target function may not be loaded; check module import |
| Menu items show unexpected state | Press `/r` to refresh or restart the CLI |
| Migration menu shows "niedostępna" | Migration files are not present in the repository |
| Screen flickers or renders incorrectly | Ensure your terminal supports ANSI escape sequences; try a different terminal emulator |
| Health badges show warnings | Press `/s` to see details; resolve the reported issues |

## Related Documents

- [Sessions.md](Sessions.md) — Session recording format
- [Players.md](Players.md) — Player and character registration
- [PU.md](PU.md) — Monthly PU assignment process
- [World-State.md](World-State.md) — Entity and currency management
- [Session-Integrity.md](Session-Integrity.md) — Session hash verification
- [Session-Graph.md](Session-Graph.md) — Session participation tracking
- [Glossary](Glossary.md) — Term definitions

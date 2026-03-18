# Interactive CLI Guide

## Overview

The interactive CLI manages the game world — creating sessions, players, entities, handling currency, PU assignments, and Discord notifications — through a full-screen terminal interface with arrow-key navigation, inline filtering, fuzzy search, guided wizards, and a built-in help system.

## Actors and Responsibilities

Narrators create and edit sessions, register new players and characters, create and edit entities (NPCs, locations, groups, items), view character and entity cards, and search for entities by name.

Coordinators perform all narrator tasks, plus run monthly PU assignments, run diagnostics (PU, currency, session validation), manage currency transfers, send Discord notifications and announcements, and run migration tools.

## Starting the CLI

After importing the Robot module, run `Invoke-RobotCLI`. The CLI loads game data and presents the main menu. This may take a few seconds on first load as entities, players, and the name index are preloaded and background health checks run. During loading, a progress panel shows each step with a spinner, step name, and elapsed time, so the Coordinator can see exactly what is happening.

The CLI requires a standard terminal (not PowerShell ISE) because it uses full-screen rendering with `[Console]::ReadKey` support. Minimum terminal size is 60 columns by 15 rows.

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
| Raporty i Narzędzia | Reporting, auditing, session graph, location graph, participation comparison, leaderboard, and utilities |
| Migracja | Migration tools (when migration files are available) |
| API | Start, stop, and monitor the REST API server; open the web dashboard (added by the API and Dashboard plugins) |

Each category shows the number of available actions. Select a category to see its items. Some items are marked with a role badge — N for Narrator-only, K for Coordinator-only, or N/K for both.

Plugins can add their own menu items to existing categories or introduce entirely new categories. Plugin-provided items appear alongside core items and work the same way. The API category, for example, is added by plugins and provides items for starting and stopping the REST API server, viewing server status, and opening the web dashboard in a browser.

## Pomoc

Press `/h` in any view to open a help overlay describing the current screen — available actions, expected inputs, and tips. The overlay scrolls with arrow keys. Press Escape to close it. Every menu entry has its own help content. When viewing a submenu, `/h` describes the entire category. When running a wizard, `/h` describes the current step.

Press `/h` followed by a space and a search term (e.g., `/h waluta`) to search across all help topics. The CLI shows matching entries from all menu items and categories. Select an entry to view its full help text.

Press `/s` to open the health dashboard showing the status of four subsystems:

| Sekcja | Co sprawdza |
|---|---|
| PU | Czy przydział PU jest gotowy do wykonania |
| Waluta | Czy salda walut są spójne |
| Integralność sesji | Czy sesje nie zostały zmodyfikowane po weryfikacji |
| Graf sesji | Czy indeks grafu sesji jest aktualny |

Each section shows a checkmark (OK) or warning icon (issues found) with a count of problems. The dashboard also shows when the last check was performed. Press Escape to close the dashboard and return to your previous view.

When the health dashboard runs its checks, a progress panel shows each subsystem being validated (PU, currency, session integrity, session graph) with spinners and elapsed times, so the Coordinator can see exactly which check is running. The same health status is summarized as compact badges in the top-right corner of the navigation bar, visible at all times.

## Filtrowanie

In menu views and table views (lists of sessions, entities, players, etc.), start typing to filter results in real time. The filter bar at the bottom shows your current text and the number of matching items.

The search applies a three-stage pipeline. Prefix matches — items whose name starts with your text — appear first. Contains matches — items that contain your text anywhere — appear next. Fuzzy matches — approximate matches based on similar spelling — appear after a short delay and are marked with `≈`.

Press Escape to clear the filter and return to the full list.

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

To create a new session, navigate to Sesje > Nowa sesja. The wizard walks through each field: date, narrator (fuzzy search among players), locations (add multiple via fuzzy search), PU entries, changes, intel, and log URLs. Skip optional fields by pressing Enter without typing. Review the preview — it shows exactly what will be written. Confirm to create, or cancel to discard.

To register a new player, navigate to Gracze i Postacie > Nowy gracz. Enter the player name and other fields. After creation, the CLI asks whether to add a first character. If adding a character, you can also add starting currency.

To create a new entity, navigate to Encje > Nowa encja. Select the entity type (NPC, Grupa, Lokacja, Przedmiot), enter the entity name, and add tags one by one (lokacja, grupa, status, alias, etc.). For location and group tags, a fuzzy search picker appears. Select "Zakoncz dodawanie tagow" when done, then review and confirm.

To edit an entity, navigate to Encje > Edytuj encje. Use fuzzy search to find the entity (start typing to filter). The current tags are shown for context. Add or change tags using the same tag picker. Review changes and confirm.

To search for entities, navigate to Encje > Szukaj encji. Start typing the entity name. The search filters in real time (prefix matches first, then partial matches, then approximate matches). Select an entity to view its full detail card.

Entity and character cards show all known information in a formatted view. Entity cards show type, status, location, groups, aliases, quantity, info notes, tags, and history. Character cards show active status, PU stats, aliases, and additional notes. Player cards show all characters with their PU and aliases. Cards are scrollable. Press Escape to return to the previous view.

Query-mode items (e.g., Sesje > Przeglądaj sesje, Gracze i Postacie > Przeglądaj graczy) show results in a scrollable table. Tables adapt to your terminal width — less important columns hide automatically when the window is too narrow. Start typing to filter rows in real time, and use column-specific prefixes (like `typ:NPC`) for targeted filtering. Select a row to view its detail card. Press Escape to return to the table.

To run the monthly PU assignment, navigate to PU > Przydział miesięczny PU. Enter the year and month. Review the dry-run results (shows what would be assigned). Choose options: update characters, send to Discord, append to log, reconcile currency. Confirm to execute.

To perform a currency transfer, navigate to Waluta > Transfer walutowy. Use fuzzy search to select the source currency entity, enter the amount to transfer, and use fuzzy search to select the destination currency entity. Review the transfer preview (source debited, destination credited). Confirm to execute.

## Diagnostics

Several diagnostic tools are available under different menu categories:

| Tool | Category | What it checks |
|---|---|---|
| Diagnostyka PU | PU | Unresolved character names, malformed PU values, duplicates |
| Diagnostyka przed przydziałem | PU | Pre-assignment checks with name suggestions |
| Uzgodnienie walut | Waluta | Currency entity consistency |
| Obraz gospodarki | Waluta | Total currency in circulation, treasury reserves, player balances, and wealth distribution at a point in time |
| Oś czasu gospodarki | Waluta | Currency supply evolution over time, tracking total supply, physical vs virtual holdings, and transfer volume across months |
| Raport materializacji | Waluta | Physical game items vs virtual bookkeeping, per-denomination and per-player breakdowns, orphan physical currency held by inactive characters |
| Walidacja sesji | Sesje | Unresolved names in PU and Changes blocks |

## Reporting and Analysis Tools

The Raporty i Narzędzia category provides tools for analyzing entity participation across sessions:

| Tool | What it does |
|---|---|
| Graf sesji | Queries the session participation index: which sessions an entity appeared in, who co-participated with an entity, who participated in a specific session, and overall statistics. A staleness warning appears if entity data has changed since the last full index rebuild |
| Graf lokacji | Builds and displays a graph of connections between locations based on entity data, session routes, and optionally movement edges from session logs. Each location shows its connection count and coordinates (if available) |
| Porównanie uczestnictwa | Compares two or more entities to find shared sessions, sessions exclusive to each entity, and a pairwise overlap matrix showing what percentage of sessions they share |
| Ranking uczestnictwa | Ranks entities by the number of sessions they participated in, with optional filter by entity type (Postac, NPC, Lokacja, Grupa) and configurable number of positions. Each entry shows a breakdown by detection confidence tier |
| Profil encji w sesjach | A comprehensive profile of a single entity's session history: total sessions, date range, confidence tier breakdown, total PU weight, top co-participants, and monthly activity trend |
| Profil narratora w sesjach | Statistics for a narrator: how many sessions they narrated, unique participants, participant type distribution, and average party size |

## Progress Indicators

When the CLI performs multi-step operations (loading data, running diagnostics, building graphs, fetching logs), it displays a progress panel. The panel shows a group title at the top identifying the overall operation, numbered steps (`[1/3]`, `[2/3]`, etc.) with the current step name, an animated spinner while a step is in progress showing real-time detail (e.g., the count of items processed so far), a checkmark or cross when each step completes along with the elapsed time, and a total elapsed time on the title line after all steps finish.

This feedback appears during health checks, session loading, graph building, log fetching, and any other operation that takes more than a moment. The Coordinator always knows which step is running and how long it has taken.

## Preview and Confirmation

Before any write operation, the CLI shows a preview of the action that will be performed, all parameters and their values, and a simulation showing what would change. You can confirm (execute) or cancel (discard). This prevents accidental modifications.

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

The CLI uses a colorblind-safe palette — it never relies on red/green distinction alone. Symbols (checkmarks, warning icons, arrows) reinforce meaning alongside color. The CLI auto-detects whether your terminal uses a dark or light background and adjusts colors accordingly.

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
- [World-State.md](World-State.md) — Entity management and world-state changes
- [Currency.md](Currency.md) — Currency tracking and transfers
- [Session-Integrity.md](Session-Integrity.md) — Session hash verification
- [Session-Graph.md](Session-Graph.md) — Session participation tracking
- [Glossary](Glossary.md) — Term definitions

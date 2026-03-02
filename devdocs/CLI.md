# CLI System - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the interactive CLI subsystem: `public/cli/invoke-robotcli.ps1` (entry point), the 14 private modules in `private/cli/` (UI primitives, fuzzy search, wizard auto-generation, menu registry, routing, display, workflows, migration integration), and the 4 test files in `tests/cli-*.Tests.ps1`.

**Not covered**: Individual public functions that wizards wrap (e.g., `New-Player`, `Set-Entity`). Migration phase implementations - see migration subsystem docs. Plugin system - see [PLUGINS.md](PLUGINS.md).

---

## 2. Architecture Overview

```
Invoke-RobotCLI (public/cli/invoke-robotcli.ps1)
    │
    ├── Layer 1: cli-primitives.ps1     (leaf - no CLI deps)
    │       Colors, Write-CLILine, Read-ArrowKey, Show-ArrowMenu, Show-ResultTable
    │
    ├── Layer 2: cli-fuzzy.ps1          (depends on L1)
    │       Get-FuzzySearchCandidates, Filter-FuzzyCandidates, Show-FuzzySearch
    │
    ├── Layer 2: cli-display.ps1        (depends on L1)
    │       Show-DetailCard, Format-DetailValidityRange, Refresh-NavState
    │
    ├── Layer 3: cli-wizard.ps1         (depends on L1 + L2)
    │       $script:CommonParams, Resolve-StepType, Invoke-WizardStep,
    │       Invoke-Wizard, Show-Preview
    │
    ├── Layer 4: cli-registry.ps1       (pure data)
    │       $script:MenuOrder, $script:MenuRegistry (39 entries)
    │
    ├── Layer 5: cli-routing.ps1        (depends on all above)
    │       Get-MenuCategories, Get-MenuItems, Get-RegistryEntry,
    │       Invoke-MenuAction, Invoke-QueryAction, Show-SubMenu, Show-MainMenu
    │
    ├── Layer 6: Workflows (depend on L1–L3)
    │   ├── cli-wf-session.ps1          Session edit + validation
    │   ├── cli-wf-player.ps1           Player/character create, edit, cards
    │   ├── cli-wf-entity.ps1           Entity create, edit, history, search, card
    │   ├── cli-wf-currency.ps1         Currency transfer + reconciliation display
    │   ├── cli-wf-pu.ps1               PU assignment + diagnostics
    │   ├── cli-wf-discord.ps1          Discord PU notification + announcement
    │   └── cli-wf-reporting.ps1        Intel preview, name search, migration reports
    │
    └── Layer 7: cli-wizard-migration.ps1 (overrides stubs from L5)
            Get-MigrationMenuItems, Invoke-MigrationPhaseAction
```

All files are dot-sourced on demand when `Invoke-RobotCLI` is called (not at module import). They share `$script:` scope so variables and functions defined in earlier layers are accessible in later layers.

---

## 3. File Structure

### 3.1 `private/cli/` (14 files)

| File | Lines | Layer | Contents |
|---|---|---|---|
| `cli-primitives.ps1` | ~420 | 1 | Color scheme, theme detection, banner, breadcrumb, arrow menu, result table |
| `cli-fuzzy.ps1` | ~340 | 2 | Fuzzy search candidate generation, filtering, interactive picker |
| `cli-display.ps1` | ~210 | 2 | Detail card rendering, validity range formatting, NavState refresh |
| `cli-wizard.ps1` | ~650 | 3 | CommonParams, step type resolution, wizard step execution, wizard orchestration, preview |
| `cli-registry.ps1` | ~600 | 4 | Menu order array, menu registry (39 entries, pure data) |
| `cli-routing.ps1` | ~360 | 5 | Menu helpers, action dispatch, query execution, main/sub menu loops |
| `cli-wf-session.ps1` | ~150 | 6 | `Invoke-EditSessionWorkflow`, `Invoke-SessionValidation` |
| `cli-wf-player.ps1` | ~400 | 6 | `Invoke-NewPlayerWorkflow`, `Invoke-NewCharacterWorkflow`, `Invoke-EditCharacterWorkflow`, `Invoke-CharacterCardWorkflow`, `Show-CharacterCard`, `Show-PlayerCard` |
| `cli-wf-entity.ps1` | ~480 | 6 | `Invoke-NewEntityWorkflow`, `Invoke-EditEntityWorkflow`, `Invoke-EntityHistoryWorkflow`, `Invoke-EntitySearchWorkflow`, `Format-ValidityRange`, `Show-EntityCard` |
| `cli-wf-currency.ps1` | ~155 | 6 | `Invoke-CurrencyTransferWorkflow`, `Invoke-CurrencyReconciliationDisplay` |
| `cli-wf-pu.ps1` | ~340 | 6 | `Invoke-PUAssignmentWorkflow`, `Invoke-PrePUDiagnostics`, `Invoke-PUDiagnosticsDisplay` |
| `cli-wf-discord.ps1` | ~130 | 6 | `Invoke-DiscordPUNotificationWorkflow`, `Invoke-DiscordAnnouncementWorkflow` |
| `cli-wf-reporting.ps1` | ~120 | 6 | `Invoke-IntelPreviewWorkflow`, `Invoke-NameSearchWorkflow`, `Invoke-MigrationQuickCheck`, `Invoke-MigrationFullReport` |
| `cli-wizard-migration.ps1` | ~165 | 7 | `Get-MigrationMenuItems`, `Invoke-MigrationPhaseAction` |

### 3.2 Entry Point

`public/cli/invoke-robotcli.ps1` exports `Invoke-RobotCLI`. It dot-sources all 14 CLI files in layer order, validates terminal compatibility, detects theme, pre-loads entity/player/name index data, and enters the main menu loop.

### 3.3 Tests

| File | Describe Blocks |
|---|---|
| `cli-primitives.Tests.ps1` | `Get-CLIColor`, `Resolve-CLITheme`, `Banner art` |
| `cli-wizard.Tests.ps1` | `CommonParams HashSet`, `Resolve-StepType` |
| `cli-fuzzy.Tests.ps1` | `Filter-FuzzyCandidates`, `Get-FuzzySearchCandidates` |
| `cli-registry.Tests.ps1` | `Menu Registry`, `Get-MenuCategories`, `Get-MenuItems`, `Get-RegistryEntry`, `Migration Phase Registry`, `Migration UI color resolution` |

---

## 4. UI Primitives Contract (`cli-primitives.ps1`)

### 4.1 Color Scheme

`$script:CLIColorScheme` maps semantic roles to Dark/Light ConsoleColor pairs. Red and Green are never used (colorblind safety - symbols reinforce meaning alongside color).

| Role | Dark | Light | Usage |
|---|---|---|---|
| Accent | Cyan | DarkCyan | Titles, prompts, active elements |
| Success | Blue | DarkBlue | Checkmarks, completion messages |
| Warning | Yellow | DarkYellow | Caution notices, dry-run output |
| Error | Magenta | DarkMagenta | Error messages, failure marks |
| Disabled | DarkGray | Gray | Inactive items, hints |
| Info | White | DarkBlue | Information labels |
| RoleTag | DarkYellow | DarkCyan | Role badges (N, K, N/K) |

`Resolve-CLITheme` detects terminal background brightness via `[Console]::BackgroundColor` heuristics.

`Get-CLIColor -Role <string>` returns the appropriate ConsoleColor for the current theme. Falls back to `White` for unknown roles.

### 4.2 Show-ArrowMenu

Input: `-Items` (array of `PSCustomObject` with `ID`, `Label`, `Description`, `RoleTag`, `InfoText`, `Disabled`), optional `-Title`, optional `-ShowBack`.

Returns: selected item's `ID` string, `'__back__'` (Escape), or `'__quit__'` (Q key).

### 4.3 Show-ResultTable

Input: `-Data` (array), `-Columns` (property names), `-Headers` (display names), optional `-Widths`, optional `-Title`.

Returns: selected row object or `$null` (Escape to go back). Supports arrow-key scrolling and pagination.

### 4.4 Read-ArrowKey

Wraps `[Console]::ReadKey($true)` to return a normalized key object. Used by all interactive components.

---

## 5. Fuzzy Search System (`cli-fuzzy.ps1`)

### 5.1 Candidate Generation

`Get-FuzzySearchCandidates -Source <string> -State <NavState>` returns a list of `PSCustomObject` with `Name`, `Type`, `DisplayText`, `Owner` based on the source:

| Source | Candidates |
|---|---|
| `players` | All players (Type = `Gracz`) |
| `characters` | All characters from all players |
| `entities` | All entities |
| `locations` | Entities where Type = `Lokacja` |
| `groups` | Entities where Type = `Grupa` |
| `npcs` | Entities where Type = `NPC` |
| `currency` | Entities where Type = `Przedmiot` and has `ilość` tag |
| `narrators` | All players (Type = `Narrator`) |

### 5.2 Filtering Pipeline

`Filter-FuzzyCandidates` applies a 3-stage filter:

1. **Prefix match** (case-insensitive `StartsWith`)
2. **Contains match** (case-insensitive `IndexOf`)
3. **Resolve-Name fallback** (BK-tree fuzzy matching from the name index, if available)

Prefix matches are ranked before contains matches. Results are capped at `MaxResults` (default 10).

### 5.3 Interactive Picker

`Show-FuzzySearch` renders a live-filtering UI: as the user types, candidates are re-filtered and displayed. Arrow keys navigate, Enter selects, Escape cancels.

---

## 6. Wizard Auto-Generation (`cli-wizard.ps1`)

### 6.1 Step Type Resolution

`Resolve-StepType -ParamInfo <ParameterMetadata> [-Override <hashtable>]` maps PowerShell parameter metadata to wizard step types:

| Parameter Type | Auto-detected StepType |
|---|---|
| `[string]` | `text` |
| `[string[]]` | `multitext` |
| `[int]` / `[int32]` | `number` |
| `[decimal]` | `decimal` |
| `[switch]` | `yesno` |
| `[datetime]` | `date` |
| `[bool]` | `yesno` |
| ValidateSet attribute | `selection` (options from the set) |

Overrides can change any auto-detected step type. Override keys: `Type`, `Label`, `Source`, `Options`, `Hidden`, `EntrySource`.

### 6.2 Wizard Orchestration

`Invoke-Wizard -RegistryEntry <hashtable> -State <NavState>`:

1. Reads the target function's `[Parameter]` metadata via `Get-Command`
2. Filters out `$script:CommonParams` (WhatIf, Confirm, ErrorAction, etc.)
3. Applies overrides from the registry entry
4. Walks each step with back/forward navigation
5. Calls `Show-Preview` for -WhatIf confirmation
6. Executes the function with collected parameters

### 6.3 Step Types

| StepType | Input Method | Validation |
|---|---|---|
| `text` | `Read-Host`-style line input | Required check |
| `multitext` | Loop: add items one-by-one until empty | Builds `string[]` |
| `number` | Text input parsed as `[int]` | Numeric validation |
| `decimal` | Text input parsed as `[decimal]` | Decimal validation |
| `date` | Text input parsed as `[datetime]` | Date format check |
| `yesno` | Arrow menu (Tak/Nie) | Boolean conversion |
| `selection` | Arrow menu from options list | Single selection |
| `fuzzy` | `Show-FuzzySearch` with specified source | Returns candidate name |
| `multi-entry` | Fuzzy-pick loop with EntrySource | Builds array |

---

## 7. Menu Registry (`cli-registry.ps1`)

### 7.1 Structure

`$script:MenuOrder` defines the 7 top-level categories: `Sesje`, `Gracze`, `Encje`, `Waluta`, `PU`, `Discord`, `Migracja`.

`$script:MenuRegistry` is a flat array of hashtables. Each entry:

| Key | Required | Description |
|---|---|---|
| `ID` | Yes | Unique identifier (e.g., `new-session`) |
| `Menu` | Yes | Category from MenuOrder |
| `Label` | Yes | Display text |
| `Description` | No | Secondary text shown in menu |
| `Role` | No | `N` (Narrator), `K` (Coordinator), or `N/K` |
| `Mode` | No | `Wizard` (default), `Query`, or `Workflow` |
| `Function` | Wizard/Query | Target function name |
| `Overrides` | No | Wizard step overrides |
| `WorkflowFunction` | Workflow | Workflow function name |
| `Columns` / `Headers` / `Widths` | Query | Table display config |
| `FilterOverrides` | No | Query filter UI config |
| `ColumnResolvers` | No | Computed column functions |
| `DataTransform` | No | Pre-display data transformation |
| `DetailFunction` | No | Custom detail card function |
| `PreChecks` | No | Info box checks shown before action |
| `InfoText` | No | Additional info text |

### 7.2 Adding a Menu Item

Add a hashtable to `$script:MenuRegistry` in `cli-registry.ps1`:

```powershell
@{
    ID       = 'my-action'
    Menu     = 'Encje'
    Label    = 'Moja akcja'
    Role     = 'N'
    Mode     = 'Wizard'        # or 'Query' or 'Workflow'
    Function = 'Invoke-MyAction'
    Overrides = @{
        'SomeParam' = @{ Type = 'fuzzy'; Source = 'entities' }
        'HiddenParam' = @{ Hidden = $true }
    }
}
```

---

## 8. Routing & Dispatch (`cli-routing.ps1`)

### 8.1 Action Dispatch

`Invoke-MenuAction -ItemID <string> -State <NavState>` looks up the registry entry and dispatches by mode:

| Mode | Handler |
|---|---|
| `Wizard` | `Invoke-Wizard -RegistryEntry $Entry -State $State` |
| `Query` | `Invoke-QueryAction -Entry $Entry -State $State` |
| `Workflow` | `& $Entry.WorkflowFunction -State $State -Entry $Entry` |

### 8.2 Query Pipeline

`Invoke-QueryAction` executes:

1. Collect filter parameters via `FilterOverrides` (each rendered as a wizard step)
2. Apply smart defaults (e.g., `MinDate = 3 months ago` for date-based queries)
3. Execute the query function with splatted parameters
4. Apply `DataTransform` if defined
5. Apply `ColumnResolvers` for computed columns
6. Loop: `Show-ResultTable` → select row → `DetailFunction` or `Show-DetailCard` → back

### 8.3 Menu Loop

`Show-MainMenu` renders top-level categories. `Show-SubMenu` renders items within a category. Both support Escape (back) and Q (quit). The Migracja category dynamically prepends migration phase items from `Get-MigrationMenuItems`.

### 8.4 Migration Stubs

`cli-routing.ps1` defines stub functions `Get-MigrationMenuItems` (returns empty) and `Invoke-MigrationPhaseAction` (shows "not loaded" message). These are overridden by `cli-wizard-migration.ps1` when migration files are available.

---

## 9. Workflow Conventions

All workflow functions receive `$State` (NavState) and `$Entry` (registry entry) parameters.

Common patterns:
- **Guided wizard**: Chain multiple wizard steps with contextual redraw between steps
- **Diff review**: Pick entity → auto-gen edit wizard → preview → execute
- **Diagnostic display**: Call test function → format results with color-coded severity
- **Fuzzy-pick → action**: `Show-FuzzySearch` → process result → display card or table

Workflows use `Refresh-NavState -State $State` to reload entities/players/name index after write operations.

---

## 10. NavState Object

The `NavState` PSCustomObject is created by `Invoke-RobotCLI` and threaded through all functions:

| Property | Type | Description |
|---|---|---|
| `BreadcrumbStack` | `Stack[string]` | Navigation path for breadcrumb display |
| `NameIndex` | `PSCustomObject` | Contains `Index`, `StemIndex`, `BKTree` for name resolution |
| `Players` | `array` | Pre-loaded player data |
| `Entities` | `array` | Pre-loaded entity data |
| `ResolveCache` | `hashtable` | Memoization cache for `Resolve-Name` calls |
| `Theme` | `string` | `'Dark'` or `'Light'` |

---

## 11. Testing

Run all CLI tests:

```powershell
Invoke-Pester tests/cli-primitives.Tests.ps1, tests/cli-wizard.Tests.ps1, tests/cli-fuzzy.Tests.ps1, tests/cli-registry.Tests.ps1
```

Tests cover pure logic functions only. Interactive UI functions (`Show-ArrowMenu`, `Show-FuzzySearch`, `Invoke-WizardStep`, etc.) are not tested as they require a live terminal with `[Console]::ReadKey`.

Migration phase tests are conditionally skipped when migration files are not available in the test environment.

---

## 12. Related Documents

- [PLUGINS.md](PLUGINS.md) - Plugin system (same hook/registry pattern)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Entity write operations wrapped by CLI wizards
- [SESSIONS.md](SESSIONS.md) - Session pipeline wrapped by session workflows

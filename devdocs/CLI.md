# CLI System - Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers the interactive CLI subsystem: `public/cli/invoke-robotcli.ps1` (entry point), the 19 private modules in `private/cli/` (UI primitives, fuzzy search, context-sensitive help, wizard auto-generation, menu registry, routing, display, workflows, economy workflows, migration integration), the 9 engine files in `private/cli/engine/` (screen management, virtual buffer, input loop, chrome rendering, 6 component types), and the 9 test files in `tests/cli-*.Tests.ps1`.

**Not covered**: Individual public functions that wizards wrap (e.g., `New-Player`, `Set-Entity`). Migration phase implementations - see migration subsystem docs. Plugin system - see [PLUGINS.md](PLUGINS.md).

---

## 2. Architecture Overview

```
Invoke-RobotCLI (public/cli/invoke-robotcli.ps1)
    │
    ├── Layer 1: cli-primitives.ps1       (leaf - no CLI deps)
    │   │   Colors, Write-CLILine, Read-ArrowKey [DEPRECATED]
    │   ├── cli-menus.ps1                 (chain-loaded by cli-primitives.ps1)
    │   │       Show-ArrowMenu [DEPRECATED], Show-ResultTable [DEPRECATED],
    │   │       Show-HelpOverlay [DEPRECATED]
    │   └── engine/*.ps1                  (chain-loaded by cli-primitives.ps1, 9 files)
    │       ├── cli-engine.ps1            Screen/region management, tier styles
    │       ├── cli-buffer.ps1            Virtual buffer, diff-based rendering
    │       ├── cli-input.ps1             Input loop, key routing, filter/command modes
    │       ├── cli-chrome.ps1            TopBar, FilterBar, StatusBar rendering
    │       ├── cli-menulist.ps1          MenuListComponent (arrow-nav + filter + fuzzy)
    │       ├── cli-table.ps1             ResultTableComponent (pagination + responsive columns)
    │       ├── cli-detail.ps1            DetailCardComponent (scrollable key-value card)
    │       ├── cli-overlays.ps1          HelpOverlayComponent, HealthDashboardComponent
    │       └── cli-wizard-step.ps1       WizardStepComponent (text/selection/yesno input)
    │
    ├── Layer 2: cli-fuzzy.ps1            (depends on L1)
    │       Get-FuzzySearchCandidates, Filter-FuzzyCandidates, Show-FuzzySearch [DEPRECATED]
    │
    ├── Layer 2: cli-display.ps1          (depends on L1)
    │       Show-DetailCard [DEPRECATED], Format-DetailValidityRange [DEPRECATED]
    │
    ├── Layer 2: cli-help.ps1             (depends on L1)
    │       $script:HelpContent, Show-HelpScreen [DEPRECATED]
    │
    ├── Layer 3: cli-wizard.ps1           (depends on L1 + L2)
    │   │   $script:CommonParams, Resolve-StepType, Invoke-Wizard
    │   ├── cli-wizard-steps.ps1          (dot-sourced by cli-wizard.ps1)
    │   │       Invoke-EngineLifecycle, Invoke-WizardStep
    │   └── cli-wizard-preview.ps1        (dot-sourced by cli-wizard.ps1)
    │           Show-Preview
    │
    ├── Layer 4: cli-registry.ps1         (pure data)
    │       $script:MenuOrder, $script:MenuRegistry (54 entries)
    │
    ├── Layer 5: cli-routing.ps1          (depends on all above)
    │       Get-MenuCategories, Get-MenuItems, Get-RegistryEntry,
    │       Merge-PluginMenuItems, Refresh-NavState,
    │       Invoke-EngineRender, Invoke-EngineCommand,
    │       Invoke-EngineFuzzySearch, Invoke-EngineDetailCard,
    │       Invoke-MenuAction, Invoke-QueryAction, Show-SubMenu, Show-MainMenu
    │
    ├── Layer 5.5: Plugin menu merge      (merges plugin items/categories/help)
    │       Merge-PluginMenuItems called after routing is loaded
    │
    ├── Layer 6: Workflows (depend on L1–L3)
    │   ├── cli-wf-session.ps1            Session edit + validation
    │   ├── cli-wf-player.ps1             Player/character create, edit, cards
    │   ├── cli-wf-entity.ps1             Entity create, edit, history, search
    │   │   └── cli-display-entity.ps1    (dot-sourced by cli-wf-entity.ps1)
    │   │           Format-ValidityRange, Show-EntityCard
    │   ├── cli-wf-currency.ps1           Currency transfer + reconciliation display
    │   ├── cli-wf-economy.ps1            Economic snapshot, timeline, materialization
    │   ├── cli-wf-pu.ps1                 PU assignment + diagnostics
    │   ├── cli-wf-discord.ps1            Discord PU notification + announcement
    │   └── cli-wf-reporting.ps1          Intel preview, name search, migration reports
    │
    ├── Layer 6.5: Plugin CLI workflows   (dot-source plugin cli/*.ps1)
    │       Per loaded plugin: dot-source all .ps1 files from plugins/<name>/cli/
    │
    └── Layer 7: cli-wizard-migration.ps1 (overrides stubs from L5)
            Get-MigrationMenuItems, Invoke-MigrationPhaseAction
```

All files are dot-sourced on demand when `Invoke-RobotCLI` is called (not at module import). They share `$script:` scope so variables and functions defined in earlier layers are accessible in later layers. Engine files are chain-loaded from within `cli-primitives.ps1` (Layer 1) in dependency order; this means the engine is available to all subsequent layers without a separate loading step in the entry point.

---

## 3. File Structure

### 3.1 `private/cli/engine/` (9 files — TUI engine)

| File | Contents |
|---|---|
| `cli-engine.ps1` | `Initialize-Screen`, `Resize-Screen`, `Restore-Cursor`, `Build-Regions`, `Get-Region`, `Get-RegionHeight`, `Test-MinimumSize`, `Test-TerminalResized`; tier style helpers (`Get-TierStyle`, `New-TierSegment`); ANSI helpers (`Get-ANSIBold`, `Get-ANSIDim`, `Get-ANSIReset`) |
| `cli-buffer.ps1` | `Initialize-Buffers`, `New-ScreenBuffer`, `Clear-BufferRegion`, `Set-BufferLine`, `Compare-BufferLine`, `Render-Segment`, `Render-Line`, `Render-BufferDiff`, `Render-FullBuffer`, `Snapshot-Region`, `Restore-Region`, `New-Segment`, `New-PaddedLine` |
| `cli-input.ps1` | `Start-InputLoop`, `Route-KeyPress`, `Invoke-SlashCommand`, `Invoke-FuzzyDebounce`, `New-InputAction`, `Test-PasteSequence`, `Reset-Filter`, `Get-FilterText`, `Split-FilterQuery`, `Reset-CommandMode` |
| `cli-chrome.ps1` | `Render-TopBar`, `Render-FilterBar`, `Render-StatusBar`, `Split-HighlightSegments` |
| `cli-menulist.ps1` | `New-MenuListComponent`, `Invoke-MenuFilter`, `Invoke-MenuFuzzyExtend` |
| `cli-table.ps1` | `New-ResultTableComponent`, `Invoke-TableFilter`, `Resolve-VisibleColumns` |
| `cli-detail.ps1` | `New-DetailCardComponent`, `Format-DetailValue` |
| `cli-overlays.ps1` | `New-HelpOverlayComponent`, `New-HealthDashboardComponent`, `Render-HealthSection`, `Search-HelpTopics`, `Get-AutoStepHelp` |
| `cli-wizard-step.ps1` | `New-WizardStepComponent` |

### 3.2 `private/cli/` (19 files — routing, workflows, legacy)

| File | Lines | Layer | Contents |
|---|---|---|---|
| `cli-primitives.ps1` | ~420 | 1 | Color scheme, theme detection, banner, breadcrumb; chain-loads `cli-menus.ps1` and all 9 `engine/*.ps1` files |
| `cli-menus.ps1` | — | 1 | `Show-ArrowMenu`, `Show-ResultTable`, `Show-HelpOverlay` [DEPRECATED] (chain-loaded by `cli-primitives.ps1`) |
| `cli-fuzzy.ps1` | ~340 | 2 | Fuzzy search candidate generation, filtering; `Show-FuzzySearch` [DEPRECATED] |
| `cli-display.ps1` | ~210 | 2 | `Show-DetailCard` [DEPRECATED], `Format-DetailValidityRange` [DEPRECATED] |
| `cli-help.ps1` | ~120 | 2 | Help content dictionary (`$script:HelpContent`), `Show-HelpScreen` [DEPRECATED] |
| `cli-wizard.ps1` | ~650 | 3 | `$script:CommonParams`, step type resolution, `Invoke-Wizard`; dot-sources `cli-wizard-steps.ps1` and `cli-wizard-preview.ps1` |
| `cli-wizard-steps.ps1` | — | 3 | `Invoke-EngineLifecycle`, `Invoke-WizardStep` (dot-sourced by `cli-wizard.ps1`) |
| `cli-wizard-preview.ps1` | — | 3 | `Show-Preview` (dot-sourced by `cli-wizard.ps1`) |
| `cli-registry.ps1` | ~600 | 4 | Menu order array, menu registry (54 entries, pure data) |
| `cli-routing.ps1` | ~480 | 5 | Menu helpers, plugin menu merge, engine helper functions, action dispatch, query execution, main/sub menu loops, `Refresh-NavState` |
| `cli-wf-session.ps1` | ~150 | 6 | `Invoke-EditSessionWorkflow`, `Invoke-SessionValidation` |
| `cli-wf-player.ps1` | ~400 | 6 | `Invoke-NewPlayerWorkflow`, `Invoke-NewCharacterWorkflow`, `Invoke-EditCharacterWorkflow`, `Invoke-CharacterCardWorkflow`, `Show-CharacterCard`, `Show-PlayerCard` |
| `cli-wf-entity.ps1` | ~480 | 6 | `Invoke-NewEntityWorkflow`, `Invoke-EditEntityWorkflow`, `Invoke-EntityHistoryWorkflow`, `Invoke-EntitySearchWorkflow`; dot-sources `cli-display-entity.ps1` |
| `cli-display-entity.ps1` | — | 6 | `Format-ValidityRange`, `Show-EntityCard` (dot-sourced by `cli-wf-entity.ps1`). `Show-EntityCard` surfaces `@info` as a first-class field (after Quantity, before Groups) and excludes it from the generic Tagi loop to avoid duplication. |
| `cli-wf-currency.ps1` | ~155 | 6 | `Invoke-CurrencyTransferWorkflow`, `Invoke-CurrencyReconciliationDisplay` |
| `cli-wf-economy.ps1` | ~240 | 6 | `Invoke-EconomicSnapshotWorkflow`, `Invoke-EconomicTimelineWorkflow`, `Invoke-MaterializationReportWorkflow` |
| `cli-wf-pu.ps1` | ~340 | 6 | `Invoke-PUAssignmentWorkflow`, `Invoke-PrePUDiagnostics`, `Invoke-PUDiagnosticsDisplay` |
| `cli-wf-discord.ps1` | ~130 | 6 | `Invoke-DiscordPUNotificationWorkflow`, `Invoke-DiscordAnnouncementWorkflow` |
| `cli-wf-reporting.ps1` | ~120 | 6 | `Invoke-IntelPreviewWorkflow`, `Invoke-NameSearchWorkflow`, `Invoke-MigrationQuickCheck`, `Invoke-MigrationFullReport` |
| `cli-wizard-migration.ps1` | ~165 | 7 | `Get-MigrationMenuItems`, `Invoke-MigrationPhaseAction` |

### 3.3 Entry Point

`public/cli/invoke-robotcli.ps1` exports `Invoke-RobotCLI`. It dot-sources CLI files in layer order: `cli-primitives.ps1` (Layer 1, which chain-loads `cli-menus.ps1` and all 9 engine files), then `cli-fuzzy.ps1`, `cli-display.ps1`, `cli-help.ps1` (Layer 2), `cli-wizard.ps1` (Layer 3, which chain-loads `cli-wizard-steps.ps1` and `cli-wizard-preview.ps1`), `cli-registry.ps1` (Layer 4), `cli-routing.ps1` (Layer 5). It then calls `Merge-PluginMenuItems` (Layer 5.5), dot-sources the 8 workflow files (Layer 6) and plugin `cli/*.ps1` files (Layer 6.5), and finally `cli-wizard-migration.ps1` (Layer 7). After loading, it validates terminal compatibility (`[Console]::KeyAvailable`), detects theme, pre-loads entity/player/name index data, runs health checks into `HealthCache`, and enters the main menu loop via `Show-MainMenu`.

### 3.4 Tests

| File | Describe Blocks |
|---|---|
| `cli-primitives.Tests.ps1` | `Get-CLIColor`, `Resolve-CLITheme`, `Banner art` |
| `cli-wizard.Tests.ps1` | `CommonParams HashSet`, `Resolve-StepType` |
| `cli-fuzzy.Tests.ps1` | `Filter-FuzzyCandidates`, `Get-FuzzySearchCandidates` |
| `cli-registry.Tests.ps1` | `Menu Registry`, `Get-MenuCategories`, `Get-MenuItems`, `Get-RegistryEntry`, `Merge-PluginMenuItems`, `Migration Phase Registry`, `Migration UI color resolution` |
| `cli-help.Tests.ps1` | `Help Content` (completeness, key matching) |
| `cli-engine.Tests.ps1` | `Initialize-Screen`, `Build-Regions`, `Get-TierStyle`, `Test-MinimumSize`, ANSI helpers |
| `cli-buffer.Tests.ps1` | `New-ScreenBuffer`, `Set-BufferLine`, `Compare-BufferLine`, `New-Segment`, `New-PaddedLine`, `Render-BufferDiff` |
| `cli-input.Tests.ps1` | `New-InputAction`, `Route-KeyPress`, `Split-FilterQuery`, `Reset-Filter`, `Invoke-SlashCommand` |
| `cli-components.Tests.ps1` | `New-MenuListComponent`, `New-ResultTableComponent`, `New-DetailCardComponent`, `New-WizardStepComponent`, `New-HelpOverlayComponent`, `Invoke-MenuFilter`, `Invoke-TableFilter`, `Resolve-VisibleColumns`, `Format-DetailValue`, `Search-HelpTopics` |

---

## 4. TUI Engine Architecture

### 4.1 Overview

The TUI engine provides a retained-mode rendering system with virtual buffers, diff-based screen updates, and a unified input loop. It replaces the immediate-mode rendering of the legacy primitives (`Show-ArrowMenu`, `Show-ResultTable`, etc.) for all core CLI paths.

### 4.2 Engine Lifecycle

Every engine-driven view follows the same lifecycle:

```
Initialize-Screen → Initialize-Buffers → Render → Start-InputLoop → Restore-Cursor
```

Standard pattern used by `Show-MainMenu`, `Show-SubMenu`, `Invoke-QueryAction`, and all engine helpers:

```powershell
$ScreenOK = Initialize-Screen -State $State
if (-not $ScreenOK) { return }
Initialize-Buffers
$RenderCB = { param($S, $C) Invoke-EngineRender -State $S -Component $C }
$CmdHandler = { param($CA, $S, $C, $RCB) Invoke-EngineCommand -CmdAction $CA -State $S -Component $C -RenderCallback $RCB }
& $RenderCB $State $Component
Render-FullBuffer
$Selected = Start-InputLoop -State $State -Component $Component -RenderCallback $RenderCB -CommandHandler $CmdHandler
Restore-Cursor
```

`Invoke-EngineLifecycle` (`cli-wizard-steps.ps1`) encapsulates this pattern for wizard steps and workflow views.

### 4.3 4-Region Layout

The engine divides the terminal into 4 fixed regions calculated by `Build-Regions`:

| Region | Height | Contents |
|---|---|---|
| TopBar | 1 row | Breadcrumb path (left) + health badges (right) |
| Content | Variable | Component-rendered content (menu, table, card, overlay) |
| Filter | 1 row | Filter text + match count, or command palette input |
| StatusBar | 1 row | Contextual key hints |

### 4.4 Virtual Buffer and Diff Rendering

Two screen-sized buffers (`$script:FrontBuffer` and `$script:BackBuffer`) hold arrays of segment arrays. Each segment is a hashtable:

```powershell
@{ Text = [string]; Color = [string]; Bold = [bool]; Dim = [bool] }
```

On each render cycle:
1. Components write segments into `$script:BackBuffer` via `Set-BufferLine`
2. `Render-BufferDiff` compares back vs front buffer line-by-line
3. Only changed lines are re-rendered to the terminal
4. Back buffer becomes the new front buffer

On PS 7+, Bold and Dim use ANSI escape sequences. On PS 5.1, Bold is simulated via the Accent ConsoleColor and Dim is suppressed.

### 4.5 Component Contract

Components are hashtables with standardized keys:

| Key | Type | Description |
|---|---|---|
| `Render` | `scriptblock` | `param($State, $ComponentRef)` — writes segments into Content region |
| `HandleKey` | `scriptblock` | `param($Action, $State, $ComponentRef)` — processes input, returns `@{ Type; Value }` |
| `StatusHints` | `string` | Key hint text for the StatusBar |
| `Filterable` | `bool` | Whether the component accepts filter input |
| `TextInputMode` | `bool` | Routes printable chars as TextInput instead of filter |
| `HelpContent` | `string[]` | Content for `/h` help overlay |

`HandleKey` returns `$null` for no-op (continue processing), or `@{ Type = 'Return'; Value = $result }` to exit the input loop with a value.

### 4.6 6 Component Types

| Component | Constructor | Filterable | TextInput | Returns |
|---|---|---|---|---|
| MenuList | `New-MenuListComponent` | Yes | No | Item ID (string) |
| ResultTable | `New-ResultTableComponent` | Yes | No | Selected data row (PSCustomObject) |
| DetailCard | `New-DetailCardComponent` | No | No | — (Esc to dismiss) |
| HelpOverlay | `New-HelpOverlayComponent` | No | No | — (Esc to dismiss) |
| HealthDashboard | `New-HealthDashboardComponent` | No | No | — (Esc to dismiss) |
| WizardStep | `New-WizardStepComponent` | No | Yes (text/number/date/decimal) | User input (string/bool) |

### 4.7 Input Routing — 4 Modes

`Start-InputLoop` routes keystrokes through `Route-KeyPress` which selects behavior based on the current mode:

| Mode | Activation | Printable chars | Escape | Enter |
|---|---|---|---|---|
| Normal | Default (filter empty) | Enter filter (if Filterable); `q`/`Q` = Back; `/` = enter Command mode | `__back__` | Select |
| Filter | Typing in a filterable component | Append to filter buffer | Clear filter | Select match |
| Command | `/` pressed | Append to command buffer; single-letter `s/r/b/q` execute immediately | Exit command mode | Execute command |
| TextInput | Component has `TextInputMode = $true` | `TextInput` action to component | `__back__` | Select |

### 4.8 Slash Command Palette

`Invoke-SlashCommand` handles single-letter commands that execute immediately after `/`:

| Command | Action |
|---|---|
| `/h` | Show help overlay (from component's `HelpContent`) |
| `/h <query>` | Search all registry help for matching topics |
| `/s` | Show health dashboard (PU, Currency, Integrity, Graph status) |
| `/r` | Refresh NavState (reload entities, players, name index) |
| `/b` | Navigate back (same as Escape) |
| `/q` | Quit CLI entirely (returns `__quit__` signal) |

### 4.9 Engine Helper Functions (`cli-routing.ps1`)

These wrap the engine lifecycle for common view patterns:

| Function | Purpose |
|---|---|
| `Invoke-EngineRender` | Standard render callback: TopBar + Component Content + FilterBar + StatusBar |
| `Invoke-EngineCommand` | Standard command handler: dispatches `/h`, `/s`, `/r`, `/b`, `/q` |
| `Invoke-EngineFuzzySearch` | Engine-driven fuzzy picker via MenuListComponent + FuzzyCallback |
| `Invoke-EngineDetailCard` | Engine-driven detail card with breadcrumb push/pop |

`Invoke-EngineLifecycle` (`cli-wizard-steps.ps1`) is the general-purpose lifecycle wrapper used by all wizard steps and many workflow views (32 call sites).

### 4.10 Filter Prefixes and Typed Filtering

In filter mode, `Split-FilterQuery` parses `prefix:query` syntax. The prefix maps to a column name via the registry entry's `FilterPrefixes` hashtable, restricting the filter to a single column.

Example: typing `typ:NPC` in an entity list filters only the Type column for "NPC".

### 4.11 Tier Styles

`Get-TierStyle -Tier <1-5>` returns `@{ Color; Bold; Dim }` for visual hierarchy:

| Tier | Color | Bold | Dim | Usage |
|---|---|---|---|---|
| 1 (Active Focus) | Accent | Yes | No | Titles, active selections, pointers |
| 2 (Actionable) | Info | No | No | Subtitles, category names |
| 3 (Contextual) | Disabled | No | No | Hints, labels |
| 4 (Structural) | Disabled | No | Yes | Separators, borders |
| 5 (Chrome) | Disabled | No | No | Persistent bars |

---

## 5. Legacy UI Primitives (`cli-primitives.ps1` + `cli-menus.ps1`)

> **Deprecation notice**: `Show-ArrowMenu`, `Show-ResultTable`, `Show-HelpOverlay`, `Show-DetailCard`, `Show-FuzzySearch`, `Show-HelpScreen`, `Read-ArrowKey`, `Clear-MenuArea`, `Show-Banner`, `Show-Breadcrumb`, `Show-InfoBox` are deprecated. Core CLI paths use engine components (§4). These functions are retained for plugin compatibility (`margoworld`, `nerthusaddon`) and `migration-ui.ps1`. They will be removed in a future version once all external callers are ported.
>
> `Write-CLILine` and `Get-CLIColor` remain active — they are used between engine lifecycle calls for status messages.

### 5.1 Color Scheme

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

### 5.2 Show-ArrowMenu [DEPRECATED] (`cli-menus.ps1`)

Input: `-Items` (array of `PSCustomObject` with `ID`, `Label`, `Description`, `RoleTag`, `InfoText`, `Disabled`), optional `-Title`, optional `-ShowBack`, optional `-HelpContent [string[]]`, optional `-HelpTitle [string]`.

Returns: selected item's `ID` string, or `'__back__'`. Superseded by `New-MenuListComponent` + engine lifecycle.

### 5.3 Show-ResultTable [DEPRECATED] (`cli-menus.ps1`)

Input: `-Data` (array), `-Columns` (property names), `-Headers` (display names), optional `-Widths`, optional `-Title`.

Returns: selected row object or `$null`. Superseded by `New-ResultTableComponent` + engine lifecycle.

### 5.4 Read-ArrowKey [DEPRECATED]

Wraps `[Console]::ReadKey($true)` to return a normalized key object. Superseded by `Start-InputLoop`.

---

## 6. Fuzzy Search System (`cli-fuzzy.ps1`)

### 6.1 Candidate Generation

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

### 6.2 Filtering Pipeline

`Filter-FuzzyCandidates` applies a 3-stage filter:

1. **Prefix match** (case-insensitive `StartsWith`)
2. **Contains match** (case-insensitive `IndexOf`)
3. **Resolve-Name fallback** (BK-tree fuzzy matching from the name index, if available)

Prefix matches are ranked before contains matches. Results are capped at `MaxResults` (default 10).

The engine-driven fuzzy search (`Invoke-EngineFuzzySearch`) applies stages 1-2 immediately on each keystroke and triggers stage 3 after a 300ms debounce (`Invoke-FuzzyDebounce`). Stage 3 matches display with a `≈` prefix to indicate approximate results.

---

## 7. Wizard Auto-Generation (`cli-wizard.ps1`, `cli-wizard-steps.ps1`, `cli-wizard-preview.ps1`)

### 7.1 Step Type Resolution

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

### 7.2 Wizard Orchestration

`Invoke-Wizard -RegistryEntry <hashtable> -State <NavState>`:

1. Reads the target function's `[Parameter]` metadata via `Get-Command`
2. Filters out `$script:CommonParams` (WhatIf, Confirm, ErrorAction, etc.)
3. Applies overrides from the registry entry
4. Walks each step with back/forward navigation
5. Calls `Show-Preview` for -WhatIf confirmation
6. Executes the function with collected parameters

### 7.3 Step Types

| StepType | Input Method | Validation |
|---|---|---|
| `text` | Engine text input (`TextInputMode`) | Required check |
| `multitext` | Loop: add items one-by-one until empty | Builds `string[]` |
| `number` | Engine text input parsed as `[int]` | Numeric validation, retry with `ErrorMessage` |
| `decimal` | Engine text input parsed as `[decimal]` | Decimal validation, retry with `ErrorMessage` |
| `date` | Engine text input parsed as `[datetime]` | Date format check, retry with `ErrorMessage` |
| `yesno` | Engine selection (Tak/Nie) | Boolean conversion |
| `selection` | Engine selection from options list | Single selection |
| `fuzzy` | `Invoke-EngineFuzzySearch` with specified source | Returns candidate name |
| `multi-entry` | Fuzzy-pick loop with EntrySource | Builds array |
| `multi-entry-nested` | Nested entry loop with EntrySource | Builds structured array |

### 7.4 Engine Integration

All step types except `multitext` use `Invoke-EngineLifecycle` to run through the standard engine lifecycle. Text/number/date/decimal steps set `TextInputMode = $true` on the `WizardStepComponent`, routing printable chars to the component instead of the filter system. Validation errors are displayed by setting `ErrorMessage` on the component and retrying.

`__quit__` from a wizard step is treated as `__back__` (returns to previous step or cancels the wizard) — this is intentional for wizard context.

---

## 8. Menu Registry (`cli-registry.ps1`)

### 8.1 Structure

`$script:MenuOrder` defines the 7 top-level categories: `Sesje`, `Gracze i Postacie`, `Encje`, `Waluta`, `PU`, `Raporty i Narzędzia`, `Migracja`.

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
| `ColumnPriority` | No | `[int[]]` per-column responsive priority: 1=always, 2=medium, 3=hide first |
| `FilterOverrides` | No | Query filter UI config |
| `FilterPrefixes` | No | `[hashtable]` mapping prefix names to column names for typed filtering |
| `ColumnResolvers` | No | Computed column functions |
| `DataTransform` | No | Pre-display data transformation |
| `DetailFunction` | No | Custom detail card function |
| `PreChecks` | No | Info box checks shown before action |
| `InfoText` | No | Additional info text |
| `HelpBrief` | No | `[string]` one-line help summary shown in search results and step hints |
| `HelpFull` | No | `[string[]]` multi-line help content shown in `/h` overlay |

### 8.2 Adding a Menu Item

Add a hashtable to `$script:MenuRegistry` in `cli-registry.ps1`:

```powershell
@{
    ID       = 'my-action'
    Menu     = 'Encje'
    Label    = 'Moja akcja'
    Role     = 'N'
    Mode     = 'Wizard'        # or 'Query' or 'Workflow'
    Function = 'Invoke-MyAction'
    HelpBrief = 'Kreator: opis akcji.'
    HelpFull  = @(
        'Szczegółowy opis akcji'
        ''
        'Kroki:'
        '  1. Pierwszy krok'
        '  2. Drugi krok'
    )
    Overrides = @{
        'SomeParam' = @{ Type = 'fuzzy'; Source = 'entities' }
        'HiddenParam' = @{ Hidden = $true }
    }
}
```

For Query entries, also add `ColumnPriority` and `FilterPrefixes`:

```powershell
@{
    ID              = 'my-query'
    Menu            = 'Encje'
    Label           = 'Moje zapytanie'
    Mode            = 'Query'
    Function        = 'Get-MyData'
    Columns         = @('Name', 'Type', 'Status', 'Owner')
    Headers         = @('Nazwa', 'Typ', 'Status', 'Właściciel')
    ColumnPriority  = @(1, 2, 2, 3)
    FilterPrefixes  = @{ 'typ' = 'Type'; 'status' = 'Status'; 'wlasciciel' = 'Owner' }
    HelpBrief       = 'Zapytanie: opis.'
    HelpFull        = @('Opis zapytania', '', 'Dostępne filtry: typ:NPC, status:Aktywny')
}
```

---

## 9. Routing & Dispatch (`cli-routing.ps1`)

### 9.1 Plugin Menu Merge

`Merge-PluginMenuItems` is called once during CLI startup (Layer 5.5), after routing is loaded. It reads the module-scoped plugin data (`$script:PluginMenuItems`, `$script:PluginMenuCategories`, `$script:PluginHelpContent`) that was populated during `robot.psm1` Phase 2 plugin loading, and merges them into the CLI's live state:

1. **Categories** — appends plugin-declared categories to `$script:MenuOrder` (duplicates skipped)
2. **Menu items** — appends validated items to `$script:MenuRegistry` with collision detection:
   - Required fields: `ID`, `Label`, `Menu`
   - ID must not collide with existing registry entries
   - `Menu` must reference a category already in `$script:MenuOrder`
   - Mode-specific validation: Wizard requires `Function`, Workflow requires `WorkflowFunction`, Query requires matching `Columns`/`Headers` counts
   - Invalid items are skipped with a warning to stderr
3. **Help content** — for existing categories, appends body lines (blank separator + plugin lines); for new categories, adds the full help entry (requires both `Title` and `Body`)

### 9.2 Action Dispatch

`Invoke-MenuAction -ItemID <string> -State <NavState>` looks up the registry entry and dispatches by mode:

| Mode | Handler |
|---|---|
| `Wizard` | `Invoke-Wizard -RegistryEntry $Entry -State $State` |
| `Query` | `Invoke-QueryAction -Entry $Entry -State $State` |
| `Workflow` | `& $Entry.WorkflowFunction -State $State -Entry $Entry` |

All three branches propagate `__quit__` if the handler returns it. `Invoke-MenuAction` sets `$script:SuppressWarnings = $true` for the duration of dispatch to prevent stderr output from corrupting the TUI screen buffer, restoring it in a `finally` block.

### 9.3 Query Pipeline

`Invoke-QueryAction` executes:

1. Collect filter parameters via `FilterOverrides` (each rendered as a wizard step)
2. Apply smart defaults (e.g., `MinDate = 3 months ago` for date-based queries)
3. Execute the query function with splatted parameters
4. Apply `DataTransform` if defined
5. Apply `ColumnResolvers` for computed columns
6. Loop: `New-ResultTableComponent` → engine lifecycle → select row → `DetailFunction` or `Invoke-EngineDetailCard` → back

### 9.4 Menu Loop

`Show-MainMenu` renders top-level categories via `New-MenuListComponent` + engine lifecycle. `Show-SubMenu` renders items within a category the same way. Both support the full command palette (`/h`, `/s`, `/r`, `/b`, `/q`). The Migracja category dynamically prepends migration phase items from `Get-MigrationMenuItems`.

### 9.5 Migration Stubs

`cli-routing.ps1` defines stub functions `Get-MigrationMenuItems` (returns empty) and `Invoke-MigrationPhaseAction` (shows "not loaded" message). These are overridden by `cli-wizard-migration.ps1` when migration files are available.

---

## 10. Workflow Conventions

All workflow functions receive `$State` (NavState) and `$Entry` (registry entry) parameters.

Common patterns:
- **Guided wizard**: Chain `Invoke-EngineLifecycle` calls for custom step sequences
- **Diff review**: Fuzzy-pick entity → auto-gen edit wizard → preview → execute
- **Diagnostic display**: Call test function → `New-ResultTableComponent` → engine lifecycle
- **Fuzzy-pick → action**: `Invoke-EngineFuzzySearch` → process result → `Invoke-EngineDetailCard`

Workflows use `Refresh-NavState -State $State` to reload entities/players/name index after write operations. All workflows propagate `__quit__` from engine calls.

### 10.1 Economy Workflows (`cli-wf-economy.ps1`)

Three read-only analysis workflows in the `Waluta` category. All require Coordinator (`K`) role. Source: `private/cli/cli-wf-economy.ps1`.

| Function | Menu ID | Label | Description |
|---|---|---|---|
| `Invoke-EconomicSnapshotWorkflow` | `economic-snapshot` | Obraz gospodarki | Point-in-time economic snapshot: denomination filter (optional), supply breakdown (physical vs virtual per denomination), Gini coefficient, transaction volume, top holders table via `New-ResultTableComponent` |
| `Invoke-EconomicTimelineWorkflow` | `economic-timeline` | Oś czasu gospodarki | Monthly economic trends: date range selection (two `date` wizard steps), monthly table (total/physical/virtual supply + transfer count) via `New-ResultTableComponent` |
| `Invoke-MaterializationReportWorkflow` | `materialization-report` | Raport materializacji | Physical vs virtual currency analysis: summary stats, denomination breakdown, player-level physical wealth table, orphaned physical currency table (inactive characters with active currency) |

**Common structure**: All three workflows follow the pattern: optional wizard step(s) for filtering/range → call the corresponding `Get-*` function (`Get-EconomicSnapshot`, `Get-EconomicTimeline`, `Get-MaterializationReport`) with `-Quiet` → render summary via `Write-CLILine` → render detail tables via `Invoke-EngineLifecycle` with `New-ResultTableComponent` → wait for keypress. Error handling wraps the entire computation-and-display block in `try/catch` with `Write-CLILine` error output.

**Dependencies**: `cli-primitives.ps1` (Layer 1) for `Write-CLILine`/`Get-CLIColor`, `cli-wizard.ps1` (Layer 3) for `Invoke-WizardStep`, `cli-wizard-steps.ps1` for `Invoke-EngineLifecycle`, and the public economy functions (`Get-EconomicSnapshot`, `Get-EconomicTimeline`, `Get-MaterializationReport`, `ConvertFrom-CurrencyBaseUnit`).

---

## 11. NavState Object

The `NavState` PSCustomObject is created by `Invoke-RobotCLI` and threaded through all functions:

| Property | Type | Description |
|---|---|---|
| `BreadcrumbStack` | `Stack[string]` | Navigation path for breadcrumb display |
| `NameIndex` | `PSCustomObject` | Contains `Index`, `StemIndex`, `BKTree` for name resolution |
| `Players` | `array` | Pre-loaded player data |
| `Entities` | `array` | Pre-loaded entity data |
| `ResolveCache` | `hashtable` | Memoization cache for `Resolve-Name` calls |
| `Theme` | `string` | `'Dark'` or `'Light'` |
| `HealthCache` | `hashtable` | Background health check results (see §11.1) |

### 11.1 HealthCache

Populated at CLI startup and refreshed via `/r` command:

| Key | Value | Source |
|---|---|---|
| `PU` | Test result or `$null` | `Test-PlayerCharacterPUAssignment -Quiet` |
| `Currency` | Test result or `$null` | `Test-CurrencyReconciliation -Quiet` |
| `Integrity` | Test result or `$null` | `Test-SessionIntegrity -Quiet -Since (Get-Date).AddMonths(-2)` |
| `Graph` | Test result or `$null` | `Test-SessionGraphIntegrity -Quiet` |
| `CheckedAt` | `[datetime]` | Timestamp of last check |
| `Errors` | `[array]` | Exceptions captured during health checks |

Results are rendered as badges in the TopBar by `Render-TopBar` and shown in detail by `New-HealthDashboardComponent` (via `/s`).

---

## 12. Testing

Run all CLI tests:

```powershell
Invoke-Pester tests/cli-primitives.Tests.ps1, tests/cli-wizard.Tests.ps1, tests/cli-fuzzy.Tests.ps1, tests/cli-registry.Tests.ps1, tests/cli-help.Tests.ps1, tests/cli-engine.Tests.ps1, tests/cli-buffer.Tests.ps1, tests/cli-input.Tests.ps1, tests/cli-components.Tests.ps1
```

| Test File | Tests | Coverage |
|---|---|---|
| `cli-engine.Tests.ps1` | 27 | `Initialize-Screen`, `Build-Regions`, `Get-TierStyle`, `Test-MinimumSize`, ANSI helpers |
| `cli-buffer.Tests.ps1` | 30 | `New-ScreenBuffer`, `Set-BufferLine`, `Compare-BufferLine`, `New-Segment`, `New-PaddedLine`, `Render-BufferDiff` |
| `cli-input.Tests.ps1` | 53 | `New-InputAction`, `Route-KeyPress` (all 4 modes), `Split-FilterQuery`, `Reset-Filter`, `Invoke-SlashCommand` |
| `cli-components.Tests.ps1` | 118 | `New-MenuListComponent`, `New-ResultTableComponent`, `New-DetailCardComponent`, `New-WizardStepComponent`, `New-HelpOverlayComponent`, `Invoke-MenuFilter`, `Invoke-TableFilter`, `Resolve-VisibleColumns`, `Format-DetailValue`, `Search-HelpTopics` |
| `cli-registry.Tests.ps1` | 40 | `Menu Registry` integrity, `Get-MenuCategories`, `Get-MenuItems`, `Get-RegistryEntry`, `Merge-PluginMenuItems`, `Migration Phase Registry` |
| `cli-primitives.Tests.ps1` | 16 | `Get-CLIColor`, `Resolve-CLITheme`, banner art |
| `cli-fuzzy.Tests.ps1` | 16 | `Filter-FuzzyCandidates`, `Get-FuzzySearchCandidates` |
| `cli-wizard.Tests.ps1` | 13 | `CommonParams HashSet`, `Resolve-StepType` |
| `cli-help.Tests.ps1` | 6 | Help content completeness, key matching |
| **Total** | **319** | |

Tests cover pure logic functions only. Interactive UI functions (`Start-InputLoop`, component `Render` scriptblocks, etc.) are not tested as they require a live terminal with `[Console]::ReadKey`. Engine component constructors, filter logic, segment construction, input routing, and column resolution are fully covered.

Migration phase tests are conditionally skipped when migration files are not available in the test environment.

---

## 13. Edge Cases

| Scenario | Behavior |
|---|---|
| Terminal below 60x15 | `Initialize-Screen` returns `$false`; shows Polish-language size warning and waits for keypress |
| Terminal resized during input loop | `Test-TerminalResized` detects change; `Resize-Screen` rebuilds regions; `Initialize-Buffers` creates fresh buffers; `Render-FullBuffer` forces complete redraw |
| Paste sequence detected | `Test-PasteSequence` checks for <20ms between keystrokes; Enter keys during paste are ignored to prevent accidental selection |
| PS 5.1 Bold rendering | Bold segments with default/Info/White color are promoted to Accent color; Dim is suppressed entirely |
| `__quit__` in wizard context | Treated as `__back__` (returns to previous step or cancels wizard) to prevent accidental exit |
| `__quit__` in menu context | Bubbles up through `Show-SubMenu` and `Show-MainMenu` to exit CLI entirely |
| Slash command error | Caught silently; logged via `Add-OperationWarning` if available; never corrupts TUI output |
| Zero filter results | Components show "(brak wynikow)" in Content region; FilterBar shows match count in Warning color |
| Responsive column overflow | `Resolve-VisibleColumns` removes priority 3 columns first, then priority 2; priority 1 columns are always shown |
| Stage 3 fuzzy triggers during typing | `Invoke-FuzzyDebounce` waits 300ms of keystroke silence before triggering; aborts if any key becomes available |
| ISE or non-interactive terminal | `[Console]::KeyAvailable` check throws; `Invoke-RobotCLI` rethrows with Polish-language message |

---

## 14. Related Documents

- [PLUGINS.md](PLUGINS.md) - Plugin system (same hook/registry pattern)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Entity write operations wrapped by CLI wizards
- [SESSIONS.md](SESSIONS.md) - Session pipeline wrapped by session workflows

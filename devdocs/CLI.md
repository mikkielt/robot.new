# CLI System - Technical Reference

---

## Scope

This document covers the interactive CLI subsystem: `public/cli/invoke-robotcli.ps1` (entry point), the 19 private modules in `private/cli/` (UI primitives, progress reporting, fuzzy search, context-sensitive help, wizard auto-generation, wizard step factories, menu registry, routing, display, workflows, economy workflows, migration integration), the 9 engine files in `private/cli/engine/` (screen management, virtual buffer, input loop, chrome rendering, 6 component types), and the 10 test files in `tests/cli-*.Tests.ps1`.

Individual public functions that wizards wrap (e.g., `New-Player`, `Set-Entity`) are documented separately. Migration phase implementations are in the migration subsystem docs. The plugin system is in [PLUGINS.md](PLUGINS.md).

---

## Architecture Overview

```
Invoke-RobotCLI (public/cli/invoke-robotcli.ps1)
    |
    +-- Layer 1: cli-primitives.ps1       (leaf - no CLI deps)
    |   |   Colors, Write-CLILine, Read-ArrowKey [DEPRECATED]
    |   |   Progress subsystem: New-ProgressState, Start-ProgressStep,
    |   |       Update-ProgressStep, Complete-ProgressStep, Complete-ProgressGroup
    |   |   Workflow setup: Initialize-WorkflowScreen
    |   |   Legacy [DEPRECATED]: Clear-MenuArea, Show-Banner, Show-Breadcrumb, Show-InfoBox
    |   +-- cli-menus.ps1                 (chain-loaded by cli-primitives.ps1)
    |   |       Show-ArrowMenu [DEPRECATED], Show-ResultTable [DEPRECATED],
    |   |       Show-HelpOverlay [DEPRECATED]
    |   +-- engine/*.ps1                  (chain-loaded by cli-primitives.ps1, 9 files)
    |       +-- cli-engine.ps1            Screen/region management, tier styles,
    |       |                             ANSI helpers (Get-ANSIBold, Get-ANSIDim, Get-ANSIReset)
    |       +-- cli-buffer.ps1            Virtual buffer, diff-based rendering
    |       +-- cli-input.ps1             Input loop, key routing, filter/command modes,
    |       |                             Reset-Filter, Get-FilterText, Reset-CommandMode
    |       +-- cli-chrome.ps1            TopBar, FilterBar, StatusBar rendering
    |       +-- cli-menulist.ps1          MenuListComponent (arrow-nav + filter + fuzzy)
    |       +-- cli-table.ps1             ResultTableComponent (pagination + responsive columns)
    |       +-- cli-detail.ps1            DetailCardComponent (scrollable key-value card)
    |       +-- cli-overlays.ps1          HelpOverlayComponent, HealthDashboardComponent,
    |       |                             Render-HealthSection, Search-HelpTopics, Get-AutoStepHelp
    |       +-- cli-wizard-step.ps1       WizardStepComponent (text/selection/yesno input)
    |
    +-- Layer 2: cli-fuzzy.ps1            (depends on L1)
    |       Get-FuzzySearchCandidates, Filter-FuzzyCandidates, Show-FuzzySearch [DEPRECATED]
    |
    +-- Layer 2: cli-display.ps1          (depends on L1)
    |       Show-DetailCard [DEPRECATED], Format-DetailValidityRange [DEPRECATED]
    |
    +-- Layer 2: cli-help.ps1             (depends on L1)
    |       $script:HelpContent, Show-HelpScreen [DEPRECATED]
    |
    +-- Layer 3: cli-wizard.ps1           (depends on L1 + L2)
    |   |   $script:CommonParams, Resolve-StepType, Invoke-Wizard
    |   +-- cli-wizard-steps.ps1          (dot-sourced by cli-wizard.ps1)
    |   |       Invoke-EngineLifecycle, Invoke-WizardStep
    |   |       Step factories: New-WizardTextStep, New-WizardNumberStep,
    |   |           New-WizardDateStep, New-WizardChoiceStep, New-WizardFuzzyStep
    |   +-- cli-wizard-preview.ps1        (dot-sourced by cli-wizard.ps1)
    |           Show-Preview
    |
    +-- Layer 4: cli-registry.ps1         (pure data)
    |       $script:MenuOrder, $script:MenuRegistry (54 entries)
    |
    +-- Layer 5: cli-routing.ps1          (depends on all above)
    |       Get-MenuCategories, Get-MenuItems, Get-RegistryEntry,
    |       Merge-PluginMenuItems, Refresh-NavState, Refresh-HealthChecks,
    |       Invoke-EngineRender, Invoke-EngineCommand,
    |       Invoke-EngineFuzzySearch, Invoke-EngineDetailCard,
    |       Invoke-MenuAction, Invoke-QueryAction, Show-SubMenu, Show-MainMenu
    |
    +-- Layer 5.5: Plugin menu merge      (merges plugin items/categories/help)
    |       Merge-PluginMenuItems called after routing is loaded
    |
    +-- Layer 6: Workflows (depend on L1-L3)
    |   +-- cli-wf-session.ps1            Session edit + validation
    |   +-- cli-wf-player.ps1             Player/character create, edit, cards
    |   +-- cli-wf-entity.ps1             Entity create, edit, history, search
    |   |   +-- cli-display-entity.ps1    (dot-sourced by cli-wf-entity.ps1)
    |   |           Format-ValidityRange, Show-EntityCard
    |   +-- cli-wf-currency.ps1           Currency transfer + reconciliation display
    |   +-- cli-wf-economy.ps1            Economic snapshot, timeline, materialization
    |   +-- cli-wf-pu.ps1                 PU assignment + diagnostics
    |   +-- cli-wf-discord.ps1            Discord PU notification + announcement
    |   +-- cli-wf-reporting.ps1          Intel preview, name search, log fetch,
    |                                     log location report, location graph,
    |                                     session graph, compare participation,
    |                                     session leaderboard, migration reports
    |
    +-- Layer 6.5: Plugin CLI workflows   (dot-source plugin cli/*.ps1)
    |       Per loaded plugin: dot-source all .ps1 files from plugins/<name>/cli/
    |
    +-- Layer 7: cli-wizard-migration.ps1 (overrides stubs from L5)
            Get-MigrationMenuItems, Invoke-MigrationPhaseAction
```

All files are dot-sourced on demand when `Invoke-RobotCLI` is called (not at module import). They share `$script:` scope so variables and functions defined in earlier layers are accessible in later layers. Engine files are chain-loaded from within `cli-primitives.ps1` (Layer 1) in dependency order; this means the engine is available to all subsequent layers without a separate loading step in the entry point.

---

## File Structure

Engine files in `private/cli/engine/` (9 files, TUI engine):

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

Private CLI files in `private/cli/` (19 files, routing, workflows, legacy):

| File | Lines | Layer | Contents |
|---|---|---|---|
| `cli-primitives.ps1` | ~500 | 1 | Color scheme, theme detection, `Write-CLILine`, progress subsystem (`New-ProgressState`, `Start-ProgressStep`, `Update-ProgressStep`, `Complete-ProgressStep`, `Complete-ProgressGroup`), `Initialize-WorkflowScreen`, banner, breadcrumb; chain-loads `cli-menus.ps1` and all 9 `engine/*.ps1` files |
| `cli-menus.ps1` | -- | 1 | `Show-ArrowMenu`, `Show-ResultTable`, `Show-HelpOverlay` [DEPRECATED] (chain-loaded by `cli-primitives.ps1`) |
| `cli-fuzzy.ps1` | ~340 | 2 | Fuzzy search candidate generation, filtering; `Show-FuzzySearch` [DEPRECATED] |
| `cli-display.ps1` | ~210 | 2 | `Show-DetailCard` [DEPRECATED], `Format-DetailValidityRange` [DEPRECATED] |
| `cli-help.ps1` | ~120 | 2 | Help content dictionary (`$script:HelpContent`), `Show-HelpScreen` [DEPRECATED] |
| `cli-wizard.ps1` | ~650 | 3 | `$script:CommonParams`, step type resolution, `Invoke-Wizard`; dot-sources `cli-wizard-steps.ps1` and `cli-wizard-preview.ps1` |
| `cli-wizard-steps.ps1` | ~435 | 3 | `Invoke-EngineLifecycle`, `Invoke-WizardStep`, wizard step factories (`New-WizardTextStep`, `New-WizardNumberStep`, `New-WizardDateStep`, `New-WizardChoiceStep`, `New-WizardFuzzyStep`) (dot-sourced by `cli-wizard.ps1`) |
| `cli-wizard-preview.ps1` | -- | 3 | `Show-Preview` (dot-sourced by `cli-wizard.ps1`) |
| `cli-registry.ps1` | ~600 | 4 | Menu order array, menu registry (54 entries, pure data) |
| `cli-routing.ps1` | ~930 | 5 | Menu helpers (`Get-MenuCategories`, `Get-MenuItems`, `Get-RegistryEntry`), plugin menu merge, engine helper functions, action dispatch, query execution, main/sub menu loops, `Refresh-NavState`, `Refresh-HealthChecks` |
| `cli-wf-session.ps1` | ~150 | 6 | `Invoke-EditSessionWorkflow`, `Invoke-SessionValidation` |
| `cli-wf-player.ps1` | ~400 | 6 | `Invoke-NewPlayerWorkflow`, `Invoke-NewCharacterWorkflow`, `Invoke-EditCharacterWorkflow`, `Invoke-CharacterCardWorkflow`, `Show-CharacterCard`, `Show-PlayerCard` |
| `cli-wf-entity.ps1` | ~480 | 6 | `Invoke-NewEntityWorkflow`, `Invoke-EditEntityWorkflow`, `Invoke-EntityHistoryWorkflow`, `Invoke-EntitySearchWorkflow`; dot-sources `cli-display-entity.ps1` |
| `cli-display-entity.ps1` | -- | 6 | `Format-ValidityRange`, `Show-EntityCard` (dot-sourced by `cli-wf-entity.ps1`). `Show-EntityCard` surfaces `@info` as a first-class field (after Quantity, before Groups) and excludes it from the generic Tagi loop to avoid duplication. |
| `cli-wf-currency.ps1` | ~155 | 6 | `Invoke-CurrencyTransferWorkflow`, `Invoke-CurrencyReconciliationDisplay` |
| `cli-wf-economy.ps1` | ~240 | 6 | `Invoke-EconomicSnapshotWorkflow`, `Invoke-EconomicTimelineWorkflow`, `Invoke-MaterializationReportWorkflow` |
| `cli-wf-pu.ps1` | ~340 | 6 | `Invoke-PUAssignmentWorkflow`, `Invoke-PrePUDiagnostics`, `Invoke-PUDiagnosticsDisplay` |
| `cli-wf-discord.ps1` | ~130 | 6 | `Invoke-DiscordPUNotificationWorkflow`, `Invoke-DiscordAnnouncementWorkflow` |
| `cli-wf-reporting.ps1` | ~750 | 6 | `Invoke-IntelPreviewWorkflow`, `Invoke-NameSearchWorkflow`, `Invoke-FetchLogsWorkflow`, `Invoke-LogLocationReportWorkflow`, `Invoke-LocationGraphWorkflow`, `Invoke-CompareParticipationWorkflow`, `Invoke-SessionLeaderboardWorkflow`, `Invoke-SessionGraphWorkflow`, `Invoke-MigrationQuickCheck`, `Invoke-MigrationFullReport` |
| `cli-wizard-migration.ps1` | ~165 | 7 | `Get-MigrationMenuItems`, `Invoke-MigrationPhaseAction` |

Entry point: `public/cli/invoke-robotcli.ps1` exports `Invoke-RobotCLI`. It dot-sources CLI files in layer order: `cli-primitives.ps1` (Layer 1, which chain-loads `cli-menus.ps1` and all 9 engine files), then `cli-fuzzy.ps1`, `cli-display.ps1`, `cli-help.ps1` (Layer 2), `cli-wizard.ps1` (Layer 3, which chain-loads `cli-wizard-steps.ps1` and `cli-wizard-preview.ps1`), `cli-registry.ps1` (Layer 4), `cli-routing.ps1` (Layer 5). It then calls `Merge-PluginMenuItems` (Layer 5.5), dot-sources the 8 workflow files (Layer 6) and plugin `cli/*.ps1` files (Layer 6.5), and finally `cli-wizard-migration.ps1` (Layer 7). After loading, it validates terminal compatibility (`[Console]::KeyAvailable`), detects theme, pre-loads entity/player/name index data, runs health checks into `HealthCache`, and enters the main menu loop via `Show-MainMenu`.

Tests:

| File | Describe Blocks |
|---|---|
| `cli-primitives.Tests.ps1` | `Get-CLIColor`, `Resolve-CLITheme`, `Banner art` |
| `cli-progress.Tests.ps1` | `New-ProgressState`, `Start-ProgressStep`, `Update-ProgressStep`, `Complete-ProgressStep`, `Complete-ProgressGroup`, `Full lifecycle integration` |
| `cli-wizard.Tests.ps1` | `CommonParams HashSet`, `Resolve-StepType` |
| `cli-fuzzy.Tests.ps1` | `Filter-FuzzyCandidates`, `Get-FuzzySearchCandidates` |
| `cli-registry.Tests.ps1` | `Menu Registry`, `Get-MenuCategories`, `Get-MenuItems`, `Get-RegistryEntry`, `Merge-PluginMenuItems`, `Migration Phase Registry`, `Migration UI color resolution` |
| `cli-help.Tests.ps1` | `Help Content` (completeness, key matching) |
| `cli-engine.Tests.ps1` | `Initialize-Screen`, `Build-Regions`, `Get-TierStyle`, `Test-MinimumSize`, ANSI helpers |
| `cli-buffer.Tests.ps1` | `New-ScreenBuffer`, `Set-BufferLine`, `Compare-BufferLine`, `New-Segment`, `New-PaddedLine`, `Render-BufferDiff` |
| `cli-input.Tests.ps1` | `New-InputAction`, `Route-KeyPress`, `Split-FilterQuery`, `Reset-Filter`, `Invoke-SlashCommand` |
| `cli-components.Tests.ps1` | `New-MenuListComponent`, `New-ResultTableComponent`, `New-DetailCardComponent`, `New-WizardStepComponent`, `New-HelpOverlayComponent`, `Invoke-MenuFilter`, `Invoke-TableFilter`, `Resolve-VisibleColumns`, `Format-DetailValue`, `Search-HelpTopics` |

---

## TUI Engine Architecture

The TUI engine provides a retained-mode rendering system with virtual buffers, diff-based screen updates, and a unified input loop. It replaces the immediate-mode rendering of the legacy primitives (`Show-ArrowMenu`, `Show-ResultTable`, etc.) for all core CLI paths.

Every engine-driven view follows the same lifecycle:

```
Initialize-Screen -> Initialize-Buffers -> Render -> Start-InputLoop -> Restore-Cursor
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

The engine divides the terminal into 4 fixed regions calculated by `Build-Regions`:

| Region | Height | Contents |
|---|---|---|
| TopBar | 1 row | Breadcrumb path (left) + health badges (right) |
| Content | Variable | Component-rendered content (menu, table, card, overlay) |
| Filter | 1 row | Filter text + match count, or command palette input |
| StatusBar | 1 row | Contextual key hints |

Two screen-sized buffers (`$script:FrontBuffer` and `$script:BackBuffer`) hold arrays of segment arrays. Each segment is a hashtable:

```powershell
@{ Text = [string]; Color = [string]; Bold = [bool]; Dim = [bool] }
```

On each render cycle:
1. Components write segments into `$script:BackBuffer` via `Set-BufferLine`
2. `Render-BufferDiff` compares back vs front buffer line-by-line
3. Only changed lines are re-rendered to the terminal
4. Changed lines are copied from back to front buffer inline during the diff pass (no separate swap loop)

On PS 7+, Bold and Dim use ANSI escape sequences. On PS 5.1, Bold is simulated via the Accent ConsoleColor and Dim is suppressed.

Three ANSI helper functions in `cli-engine.ps1` provide escape sequence access with PS 5.1 fallback:

| Function | PS 7+ Return | PS 5.1 Return | Purpose |
|---|---|---|---|
| `Get-ANSIBold` | `\e[1m` | `''` (empty string) | Bold text formatting |
| `Get-ANSIDim` | `\e[2m` | `''` (empty string) | Dim text formatting |
| `Get-ANSIReset` | `\e[0m` | `''` (empty string) | Reset all formatting |

Availability is determined by `$script:SupportsANSI` (`$PSVersionTable.PSVersion.Major -ge 7`), checked once at load time.

Components are hashtables with standardized keys:

| Key | Type | Description |
|---|---|---|
| `Render` | `scriptblock` | `param($State, $ComponentRef)` -- writes segments into Content region |
| `HandleKey` | `scriptblock` | `param($Action, $State, $ComponentRef)` -- processes input, returns `@{ Type; Value }` |
| `StatusHints` | `string` | Key hint text for the StatusBar |
| `Filterable` | `bool` | Whether the component accepts filter input |
| `TextInputMode` | `bool` | Routes printable chars as TextInput instead of filter |
| `HelpContent` | `string[]` | Content for `/h` help overlay |

`HandleKey` returns `$null` for no-op (continue processing), or `@{ Type = 'Return'; Value = $result }` to exit the input loop with a value.

The 6 component types:

| Component | Constructor | Filterable | TextInput | Returns |
|---|---|---|---|---|
| MenuList | `New-MenuListComponent` | Yes | No | Item ID (string) |
| ResultTable | `New-ResultTableComponent` | Yes | No | Selected data row (PSCustomObject) |
| DetailCard | `New-DetailCardComponent` | No | No | -- (Esc to dismiss) |
| HelpOverlay | `New-HelpOverlayComponent` | No | No | -- (Esc to dismiss) |
| HealthDashboard | `New-HealthDashboardComponent` | No | No | -- (Esc to dismiss) |
| WizardStep | `New-WizardStepComponent` | No | Yes (text/number/date/decimal) | User input (string/bool) |

---

## Input Routing

`Start-InputLoop` routes keystrokes through `Route-KeyPress` which selects behavior based on the current mode:

| Mode | Activation | Printable chars | Escape | Enter |
|---|---|---|---|---|
| Normal | Default (filter empty) | Enter filter (if Filterable); `q`/`Q` = Back; `/` = enter Command mode | `__back__` | Select |
| Filter | Typing in a filterable component | Append to filter buffer | Clear filter | Select match |
| Command | `/` pressed | Append to command buffer; single-letter `s/r/b/q` execute immediately | Exit command mode | Execute command |
| TextInput | Component has `TextInputMode = $true` | `TextInput` action to component | `__back__` | Select |

Three helper functions in `cli-input.ps1` manage the input state machine:

| Function | Parameters | Description |
|---|---|---|
| `Reset-Filter` | -- | Clears `$script:FilterBuffer` and sets `$script:FilterActive = $false` |
| `Get-FilterText` | -- | Returns the current filter string from `$script:FilterBuffer.ToString()` |
| `Reset-CommandMode` | -- | Clears `$script:CommandBuffer` and sets `$script:CommandMode = $false` |

These are called by `Start-InputLoop` on entry and by `Route-KeyPress` on mode transitions (Escape in command mode, Backspace clearing last character, command execution).

`Invoke-SlashCommand` handles single-letter commands that execute immediately after `/`:

| Command | Action |
|---|---|
| `/h` | Show help overlay (from component's `HelpContent`) |
| `/h <query>` | Search all registry help for matching topics |
| `/s` | Show health dashboard (PU, Currency, Integrity, Graph status) |
| `/r` | Refresh NavState (reload entities, players, name index) |
| `/b` | Navigate back (same as Escape) |
| `/q` | Quit CLI entirely (returns `__quit__` signal) |

In filter mode, `Split-FilterQuery` parses `prefix:query` syntax. The prefix pattern is a precompiled regex at `$script:FilterPrefixRegex` (Polish-aware character class, `RegexOptions.Compiled`) to avoid per-call regex compilation. The prefix maps to a column name via the registry entry's `FilterPrefixes` hashtable, restricting the filter to a single column. For example, typing `typ:NPC` in an entity list filters only the Type column for "NPC".

---

## Engine Helper Functions

These functions in `cli-routing.ps1` wrap the engine lifecycle for common view patterns:

| Function | Purpose |
|---|---|
| `Invoke-EngineRender` | Standard render callback: TopBar + Component Content + FilterBar + StatusBar |
| `Invoke-EngineCommand` | Standard command handler: dispatches `/h`, `/s`, `/r`, `/b`, `/q` |
| `Invoke-EngineFuzzySearch` | Engine-driven fuzzy picker via MenuListComponent + FuzzyCallback |
| `Invoke-EngineDetailCard` | Engine-driven detail card with breadcrumb push/pop |

`Invoke-EngineLifecycle` (`cli-wizard-steps.ps1`) is the general-purpose lifecycle wrapper used by all wizard steps and many workflow views (32 call sites).

---

## Tier Styles

`Get-TierStyle -Tier <1-5>` returns `@{ Color; Bold; Dim }` for visual hierarchy:

| Tier | Color | Bold | Dim | Usage |
|---|---|---|---|---|
| 1 (Active Focus) | Accent | Yes | No | Titles, active selections, pointers |
| 2 (Actionable) | Info | No | No | Subtitles, category names |
| 3 (Contextual) | Disabled | No | No | Hints, labels |
| 4 (Structural) | Disabled | No | Yes | Separators, borders |
| 5 (Chrome) | Disabled | No | No | Persistent bars |

---

## UI Primitives

`$script:CLIColorScheme` maps semantic roles to Dark/Light ConsoleColor pairs. Red and Green are never used (colorblind safety -- symbols reinforce meaning alongside color).

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

Active primitives (`cli-primitives.ps1` and `cli-menus.ps1`):

| Function | Parameters | Description |
|---|---|---|
| `Write-CLILine` | `-Text [string]`, `-Color [string]`, `-NoNewline [switch]` | Consistent indented `Write-Host` wrapper (prepends 2-space indent). Used between engine lifecycle calls for status messages. |
| `Initialize-WorkflowScreen` | `-Title [string] (Mandatory)`, `-NoSeparator [switch]` | Clears terminal, renders title in Accent color, optional horizontal separator, blank line. Returns a hashtable of all standard CLI colors (`Accent`, `Disabled`, `Info`, `Warning`, `Success`, `Error`) for caller use. Used by workflow functions to set up a clean screen before non-engine rendering. |

Deprecated legacy primitives are retained for plugin compatibility (`margoworld`, `nerthusaddon`) and `migration-ui.ps1`. They will be removed in a future version once all external callers are ported. Core CLI paths use engine components.

| Function | File | Description |
|---|---|---|
| `Show-ArrowMenu` | `cli-menus.ps1` | Arrow-key navigable menu. Superseded by `New-MenuListComponent` + engine lifecycle. |
| `Show-ResultTable` | `cli-menus.ps1` | Paginated data table. Superseded by `New-ResultTableComponent` + engine lifecycle. |
| `Show-HelpOverlay` | `cli-menus.ps1` | Box-drawn help overlay with scroll. Superseded by engine `New-HelpOverlayComponent`. |
| `Show-DetailCard` | `cli-display.ps1` | Generic key-value card for any PSCustomObject. Superseded by `Invoke-EngineDetailCard`. |
| `Format-DetailValidityRange` | `cli-display.ps1` | Formats temporal range as `YYYY-MM-DD -- YYYY-MM-DD`. Used only by `Show-DetailCard`. |
| `Read-ArrowKey` | `cli-primitives.ps1` | Wraps `[Console]::ReadKey($true)`. Superseded by `Start-InputLoop`. |
| `Clear-MenuArea` | `cli-primitives.ps1` | Overwrites N lines with spaces at a given row. Superseded by engine buffer. |
| `Show-Banner` | `cli-primitives.ps1` | Renders ASCII banner art with version. Superseded by engine TopBar chrome. |
| `Show-Breadcrumb` | `cli-primitives.ps1` | Renders breadcrumb path with health badges. Superseded by engine TopBar chrome. |
| `Show-InfoBox` | `cli-primitives.ps1` | Renders pre-check info box. Superseded by engine overlay components. |

---

## Progress Subsystem

The progress subsystem provides Docker-style step-by-step progress reporting with animated spinners and elapsed time tracking. It renders directly to the terminal via `[Console]::SetCursorPosition` (not through the TUI engine buffer), making it suitable for use in workflows that operate outside the engine lifecycle. Implemented in `private/cli/cli-primitives.ps1`.

Module-level data:

| Variable | Type | Description |
|---|---|---|
| `$script:SpinnerFrames` | `char[]` (8 elements) | Braille animation frames (U+280B through U+2827), cycled by `Update-ProgressStep` |
| `$script:SpinnerStatic` | `char` | Static braille indicator (U+283F) shown during blocking calls without callbacks |

`New-ProgressState` creates a progress tracking state hashtable for a group of steps.

| Parameter | Type | Description |
|---|---|---|
| `Title` | `string` (Mandatory) | Group title rendered on the first line |
| `TotalSteps` | `int` (Mandatory) | Number of steps in this group |

Returns a `hashtable` with keys:

| Key | Type | Description |
|---|---|---|
| `Title` | `string` | Group title |
| `Steps` | `List[hashtable]` | Per-step state entries |
| `TotalSteps` | `int` | Total step count |
| `CurrentStep` | `int` | Current step index (starts at 0) |
| `StartRow` | `int` | Terminal row where the title was rendered |
| `GroupStart` | `Stopwatch` | Running stopwatch for total group elapsed time |
| `StepWatch` | `Stopwatch` | Per-step stopwatch (set by `Start-ProgressStep`) |
| `SpinnerIdx` | `int` | Current animation frame index |
| `Failed` | `bool` | Set to `$true` if any step completes with `-Failed` |

Side effect: renders the title line immediately on creation.

`Start-ProgressStep` begins a named progress step. Increments `CurrentStep`, starts a new `Stopwatch`, resets `SpinnerIdx`, and adds a step entry to `Steps`. Renders `[X/N] ... Label...` at the appropriate row.

| Parameter | Type | Description |
|---|---|---|
| `State` | `hashtable` (Mandatory) | Progress state from `New-ProgressState` |
| `Label` | `string` (Mandatory) | Human-readable step name |

`Update-ProgressStep` updates the current step's display in-place. Advances the spinner animation by one frame and optionally updates the detail text (e.g., `42/100`). Uses `[Console]::SetCursorPosition` to overwrite the existing line. No-op if `Steps` list is empty (guard against calls before `Start-ProgressStep`).

| Parameter | Type | Description |
|---|---|---|
| `State` | `hashtable` (Mandatory) | Progress state |
| `Detail` | `string` | Optional detail text shown to the right of the label |

`Complete-ProgressStep` marks the current step as done. Stops `StepWatch`, records elapsed time, and renders a checkmark (U+2713) or cross (U+2717) symbol.

| Parameter | Type | Description |
|---|---|---|
| `State` | `hashtable` (Mandatory) | Progress state |
| `Detail` | `string` | Optional final detail text |
| `Failed` | `switch` | If set, marks step as `Error` (cross symbol in Error color) instead of `Done` (checkmark in Success color) and sets `State.Failed = $true` |

Step entry fields updated: `Status` (to `Done` or `Error`), `Elapsed` (seconds as double), `Detail`.

`Complete-ProgressGroup` finalizes the entire progress group. Stops `GroupStart` stopwatch and updates the title line with right-aligned total elapsed time. Moves the cursor below the last step with a blank line.

| Parameter | Type | Description |
|---|---|---|
| `State` | `hashtable` (Mandatory) | Progress state |

Visual layout:

```
  Loading data                           2.4s    <- title line (elapsed added by Complete-ProgressGroup)
  [1/3] checkmark Entities          247   0.8s   <- completed step (checkmark)
  [2/3] spinner Players...         12/15         <- running step (spinner + detail)
  [3/3] cross Name index    ERROR         0.1s   <- failed step (cross)
```

- Counter format: `[CurrentStep/TotalSteps]`
- Running steps show the braille spinner and `Label...`
- Completed steps show checkmark/cross, label (no trailing `...`), optional detail, and elapsed time
- Lines are padded to terminal width to clear previous longer content

Usage pattern:

```powershell
$Progress = New-ProgressState -Title 'Loading data' -TotalSteps 3

Start-ProgressStep -State $Progress -Label 'Entities'
$Entities = Get-Entity -Quiet
Complete-ProgressStep -State $Progress -Detail "$($Entities.Count)"

Start-ProgressStep -State $Progress -Label 'Players'
$Players = Get-Player
Complete-ProgressStep -State $Progress -Detail "$($Players.Count)"

Start-ProgressStep -State $Progress -Label 'Name index'
try {
    $Index = Get-NameIndex -Players $Players -Entities $Entities
    Complete-ProgressStep -State $Progress -Detail "$($Index.Count) entries"
} catch {
    Complete-ProgressStep -State $Progress -Detail 'ERROR' -Failed
}

Complete-ProgressGroup -State $Progress
```

For long-running operations with callbacks, the caller passes a closure that calls `Update-ProgressStep`:

```powershell
$Callback = { param($C,$T,$D); Update-ProgressStep -State $Progress -Detail "$C/$T" }.GetNewClosure()
$Sessions = Get-Session -ProgressCallback $Callback
```

Consumers of the progress subsystem:

- `Refresh-NavState` (`cli-routing.ps1`) -- 4-step entity/player/name-index/type-index refresh
- `Refresh-HealthChecks` (`cli-routing.ps1`) -- 6-step health check sequence with per-check progress callbacks
- `Invoke-IntelPreviewWorkflow` (`cli-wf-reporting.ps1`) -- session loading
- `Invoke-FetchLogsWorkflow` (`cli-wf-reporting.ps1`) -- session loading + log fetch
- `Invoke-LogLocationReportWorkflow` (`cli-wf-reporting.ps1`) -- session loading + log analysis
- `Invoke-LocationGraphWorkflow` (`cli-wf-reporting.ps1`) -- graph building
- `Invoke-CompareParticipationWorkflow` (`cli-wf-reporting.ps1`) -- participation analysis
- `Invoke-SessionLeaderboardWorkflow` (`cli-wf-reporting.ps1`) -- leaderboard building
- `Invoke-SessionGraphWorkflow` (`cli-wf-reporting.ps1`) -- graph query execution

---

## Fuzzy Search System

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

For `locations`, `groups`, and `npcs` sources, `Get-FuzzySearchCandidates` uses `$State.EntityTypeIndex` (a hashtable of type to entity lists built at CLI startup and on refresh) for O(1) type-filtered access.

`Filter-FuzzyCandidates` applies a 3-stage filter:

1. Prefix match (case-insensitive `StartsWith`)
2. Contains match (case-insensitive `IndexOf`)
3. `Resolve-Name` fallback (BK-tree fuzzy matching from the name index, if available)

Prefix matches are ranked before contains matches. Results are capped at `MaxResults` (default 10).

A `HashSet[object]` tracks already-added candidates across stages to avoid O(n) `Contains` calls on the result list.

The engine-driven fuzzy search (`Invoke-EngineFuzzySearch`) applies stages 1-2 immediately on each keystroke and triggers stage 3 after a 300ms debounce (`Invoke-FuzzyDebounce`). Stage 3 matches display with a `~` prefix to indicate approximate results.

`Robot.FuzzyMatcher` (`lib/FuzzyMatcher.cs`) is a compiled fuzzy string matcher for CLI typeahead filtering. Pre-lowercases all candidate names at construction time (`ToLowerInvariant`), then uses `Ordinal` comparisons on pre-lowered strings to eliminate per-keystroke case conversion overhead.

API:

- Constructor `FuzzyMatcher(string[] names)` -- builds a normalized (lowered) name array. Null names are normalized to empty string. The caller retains the original candidate array and maps returned indices back.
- `Filter(string query, int maxResults)` -- two-stage filtering: (1) prefix match via `StartsWith` with `Ordinal` comparison, (2) contains match via `IndexOf` with `Ordinal` comparison. Returns `int[]` of indices into the original name array, capped at `maxResults`. A `HashSet<int>` deduplicates stage 2 results against stage 1 hits.
- `FindHighlight(string text, string query)` -- static method returning `int[2]` (`{startIndex, length}`) for match position rendering. Consumed by `Split-HighlightSegments` for ANSI color highlighting.

Consumers: CLI typeahead/search code -- `Invoke-FuzzyFilter` (`private/cli/cli-fuzzy.ps1`), `Invoke-MenuFilter` (`private/cli/engine/cli-menulist.ps1`).

---

## Wizard Auto-Generation

Source files: `cli-wizard.ps1`, `cli-wizard-steps.ps1`, `cli-wizard-preview.ps1`.

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

`Invoke-Wizard -RegistryEntry <hashtable> -State <NavState>`:

1. Reads the target function's `[Parameter]` metadata via `Get-Command`
2. Filters out `$script:CommonParams` (WhatIf, Confirm, ErrorAction, etc.)
3. Applies overrides from the registry entry
4. Walks each step with back/forward navigation
5. Calls `Show-Preview` for -WhatIf confirmation
6. Executes the function with collected parameters

Step types:

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

Five factory functions in `cli-wizard-steps.ps1` create `PSCustomObject` step definitions for use with `Invoke-WizardStep`. They reduce boilerplate when workflow functions need to define inline wizard steps (as opposed to using registry-driven auto-generation). All factories return a `PSCustomObject` with a standardized set of fields: `Name`, `Label`, `StepType`, `Required`, `Source`, `Options`, `SubSteps`, `EntrySource`, `Condition`, `Transform`, `Default`.

| Factory | Parameters | StepType | Description |
|---|---|---|---|
| `New-WizardTextStep` | `-Name (M)`, `-Label (M)`, `-Required`, `-Default` | `text` | Text input step |
| `New-WizardNumberStep` | `-Name (M)`, `-Label (M)`, `-Required`, `-Default` | `number` | Integer input step |
| `New-WizardDateStep` | `-Name (M)`, `-Label (M)`, `-Required`, `-Default` | `date` | Date input step (YYYY-MM-DD or YYYY-MM format) |
| `New-WizardChoiceStep` | `-Name (M)`, `-Label (M)`, `-Options (M)`, `-Required`, `-Default` | `choice` | Selection from options list |
| `New-WizardFuzzyStep` | `-Name (M)`, `-Label (M)`, `-Source (M)` | `fuzzy` | Fuzzy search step (always required) |

`(M)` = Mandatory parameter.

Example usage in a workflow:

```powershell
$MinDateStep = New-WizardDateStep -Name 'MinDate' -Label 'Od daty'
$MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
if ($MinDate -eq '__back__') { return }
```

`Show-Preview` displays a summary of collected wizard parameters via engine `DetailCardComponent`, asks for confirmation via engine `WizardStepComponent` (yesno), and executes the target function on confirmation. After successful execution, the result is displayed as an engine `DetailCardComponent` and `NavState` is refreshed.

| Parameter | Type | Description |
|---|---|---|
| `FunctionName` | `string` (Mandatory) | Target function to execute |
| `Parameters` | `OrderedDictionary` (Mandatory) | Collected wizard parameters |
| `State` | `object` (Mandatory) | NavState |

Returns `__quit__` on quit signal, `$null` on cancel, or the function's return value on success. Handles `Robot.OperationResult` responses by displaying structured result cards with status, changes, file paths, warnings, and undo hints.

All step types except `multitext` use `Invoke-EngineLifecycle` to run through the standard engine lifecycle. Text/number/date/decimal steps set `TextInputMode = $true` on the `WizardStepComponent`, routing printable chars to the component instead of the filter system. Validation errors are displayed by setting `ErrorMessage` on the component and retrying.

`__quit__` from a wizard step is treated as `__back__` (returns to previous step or cancels the wizard) -- this is intentional for wizard context.

---

## Menu Registry

`$script:MenuOrder` defines the 7 top-level categories: `Sesje`, `Gracze i Postacie`, `Encje`, `Waluta`, `PU`, `Raporty i Narzedzia`, `Migracja`.

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

Adding a menu item -- add a hashtable to `$script:MenuRegistry` in `cli-registry.ps1`:

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
        'Szczegolowy opis akcji'
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
    Headers         = @('Nazwa', 'Typ', 'Status', 'Wlasciciel')
    ColumnPriority  = @(1, 2, 2, 3)
    FilterPrefixes  = @{ 'typ' = 'Type'; 'status' = 'Status'; 'wlasciciel' = 'Owner' }
    HelpBrief       = 'Zapytanie: opis.'
    HelpFull        = @('Opis zapytania', '', 'Dostepne filtry: typ:NPC, status:Aktywny')
}
```

Two dictionary indexes are built from `$script:MenuRegistry` at load time for O(1) lookups:

| Variable | Type | Key | Purpose |
|---|---|---|---|
| `$script:MenuRegistryByID` | `Dictionary[string, hashtable]` (OrdinalIgnoreCase) | Entry `ID` | O(1) lookup by menu item ID (used by `Get-RegistryEntry`) |
| `$script:MenuRegistryByCategory` | `Dictionary[string, List[hashtable]]` (OrdinalIgnoreCase) | Entry `Menu` | O(1) category to items listing (used by `Get-MenuItems`, `Show-MainMenu` subcounts) |

Both indexes are updated by `Merge-PluginMenuItems` when plugin items are added. `Get-MenuItems` and `Get-RegistryEntry` use the indexes instead of linear scans over `$script:MenuRegistry`.

---

## Routing and Dispatch

Three registry access helpers:

| Function | Parameters | Returns | Description |
|---|---|---|---|
| `Get-MenuCategories` | -- | `string[]` | Returns `$script:MenuOrder` (ordered list of top-level category names) |
| `Get-MenuItems` | `-Category [string] (M)` | `PSCustomObject[]` | Returns menu items for a category from `$script:MenuRegistryByCategory` index. Each item has `ID`, `Label`, `Description`, `RoleTag`, `InfoText`, `Disabled` properties. |
| `Get-RegistryEntry` | `-ID [string] (M)` | `hashtable` or `$null` | Finds a registry entry by ID from `$script:MenuRegistryByID` index |

`Merge-PluginMenuItems` is called once during CLI startup (Layer 5.5), after routing is loaded. It reads the module-scoped plugin data (`$script:PluginMenuItems`, `$script:PluginMenuCategories`, `$script:PluginHelpContent`) that was populated during `robot.psm1` Phase 2 plugin loading, and merges them into the CLI's live state:

1. Categories -- appends plugin-declared categories to `$script:MenuOrder` (duplicates skipped)
2. Menu items -- appends validated items to `$script:MenuRegistry` with collision detection: required fields are `ID`, `Label`, `Menu`; ID must not collide with existing registry entries; `Menu` must reference a category already in `$script:MenuOrder`; mode-specific validation requires `Function` for Wizard, `WorkflowFunction` for Workflow, and matching `Columns`/`Headers` counts for Query; invalid items are skipped with a warning to stderr
3. Help content -- for existing categories, appends body lines (blank separator + plugin lines); for new categories, adds the full help entry (requires both `Title` and `Body`)

State refresh helpers:

| Function | Parameters | Description |
|---|---|---|
| `Refresh-NavState` | `-State [object] (M)` | Reloads entities, players, name index, and entity type index into NavState using the progress subsystem (4-step sequence). Clears `ResolveCache`. Called by `/r` command and after write operations. |
| `Refresh-HealthChecks` | `-State [object] (M)` | Runs all 4 health checks (PU, Currency, Integrity, Graph) with shared pre-computed sessions and entity state using the progress subsystem (6-step sequence: sessions, entity state, PU, currency, integrity, graph). Updates `HealthCache` with results, errors, and timestamp. Suppresses non-terminating errors during checks. |

`Invoke-MenuAction -ItemID <string> -State <NavState>` looks up the registry entry and dispatches by mode:

| Mode | Handler |
|---|---|
| `Wizard` | `Invoke-Wizard -RegistryEntry $Entry -State $State` |
| `Query` | `Invoke-QueryAction -Entry $Entry -State $State` |
| `Workflow` | `& $Entry.WorkflowFunction -State $State -Entry $Entry` |

All three branches propagate `__quit__` if the handler returns it. `Invoke-MenuAction` sets `$script:SuppressWarnings = $true` for the duration of dispatch to prevent stderr output from corrupting the TUI screen buffer, restoring it in a `finally` block.

`Invoke-QueryAction` executes:

1. Collect filter parameters via `FilterOverrides` (each rendered as a wizard step)
2. Apply smart defaults (e.g., `MinDate = 3 months ago` for date-based queries)
3. Execute the query function with splatted parameters
4. Apply `DataTransform` if defined
5. Apply `ColumnResolvers` for computed columns
6. Loop: `New-ResultTableComponent` -> engine lifecycle -> select row -> `DetailFunction` or `Invoke-EngineDetailCard` -> back

`Show-MainMenu` renders top-level categories via `New-MenuListComponent` + engine lifecycle. `Show-SubMenu` renders items within a category the same way. Both support the full command palette (`/h`, `/s`, `/r`, `/b`, `/q`). The Migracja category dynamically prepends migration phase items from `Get-MigrationMenuItems`.

`cli-routing.ps1` defines stub functions `Get-MigrationMenuItems` (returns empty) and `Invoke-MigrationPhaseAction` (shows "not loaded" message). These are overridden by `cli-wizard-migration.ps1` (Layer 7) when migration files are available.

`cli-wizard-migration.ps1` bridges the CLI menu with the migration subsystem:

| Function | Parameters | Description |
|---|---|---|
| `Get-MigrationMenuItems` | `-State [object]` | Returns dynamic menu items with status badges from `$script:PhaseRegistry` + `Get-MigrationState`/`Get-PhaseStatus`. Falls back to hardcoded phases 0-6 if no registry. Returns a "not available" disabled item when migration files are missing. |
| `Invoke-MigrationPhaseAction` | `-PhaseID [string]`, `-State [object]` | Extracts phase number from ID (`migration-phase-N`), looks up the phase function in the registry, renders phase header, and executes the phase function. Clears the engine-rendered screen before switching to console-mode output. |

---

## Workflow Conventions

All workflow functions receive `$State` (NavState) and `$Entry` (registry entry) parameters.

Common patterns:

- Guided wizard -- chain `Invoke-EngineLifecycle` calls for custom step sequences
- Diff review -- fuzzy-pick entity, auto-gen edit wizard, preview, execute
- Diagnostic display -- call test function, `New-ResultTableComponent`, engine lifecycle
- Fuzzy-pick to action -- `Invoke-EngineFuzzySearch`, process result, `Invoke-EngineDetailCard`
- Progress-driven data load -- `New-ProgressState`, `Start-ProgressStep` per data source, render results

Workflows use `Refresh-NavState -State $State` to reload entities/players/name index after write operations. All workflows propagate `__quit__` from engine calls.

Two display helpers for entity domain in `cli-display-entity.ps1` (dot-sourced by `cli-wf-entity.ps1`):

| Function | Parameters | Description |
|---|---|---|
| `Format-ValidityRange` | `$ValidFrom`, `$ValidTo` | Formats temporal range as `YYYY-MM-DD -- YYYY-MM-DD`, `od YYYY-MM-DD`, or `do YYYY-MM-DD`. Returns `$null` if both inputs are null. |
| `Show-EntityCard` | `-Entity`, `-State`, `-Row` | Renders a full entity detail card to the console with core fields (Type, Status, Location, Owner, Quantity), `@info` (surfaced as first-class field), Groups, Doors, Contains, Aliases with validity ranges, Overrides/tags, location history, and group history. Supports both direct entity and detail-card `-Row` parameter. |

Three read-only analysis workflows in the `Waluta` category (`cli-wf-economy.ps1`). All require Coordinator (`K`) role.

| Function | Menu ID | Label | Description |
|---|---|---|---|
| `Invoke-EconomicSnapshotWorkflow` | `economic-snapshot` | Obraz gospodarki | Point-in-time economic snapshot: denomination filter (optional), supply breakdown (physical vs virtual per denomination), Gini coefficient, transaction volume, top holders table via `New-ResultTableComponent` |
| `Invoke-EconomicTimelineWorkflow` | `economic-timeline` | Os czasu gospodarki | Monthly economic trends: date range selection (two `date` wizard steps), monthly table (total/physical/virtual supply + transfer count) via `New-ResultTableComponent` |
| `Invoke-MaterializationReportWorkflow` | `materialization-report` | Raport materializacji | Physical vs virtual currency analysis: summary stats, denomination breakdown, player-level physical wealth table, orphaned physical currency table (inactive characters with active currency) |

All three workflows follow the pattern: optional wizard step(s) for filtering/range, call the corresponding `Get-*` function (`Get-EconomicSnapshot`, `Get-EconomicTimeline`, `Get-MaterializationReport`) with `-Quiet`, render summary via `Write-CLILine`, render detail tables via `Invoke-EngineLifecycle` with `New-ResultTableComponent`, wait for keypress. Error handling wraps the entire computation-and-display block in `try/catch` with `Write-CLILine` error output.

Dependencies: `cli-primitives.ps1` (Layer 1) for `Write-CLILine`/`Get-CLIColor`, `cli-wizard.ps1` (Layer 3) for `Invoke-WizardStep`, `cli-wizard-steps.ps1` for `Invoke-EngineLifecycle`, and the public economy functions (`Get-EconomicSnapshot`, `Get-EconomicTimeline`, `Get-MaterializationReport`, `ConvertFrom-CurrencyBaseUnit`).

Ten reporting workflow functions in `cli-wf-reporting.ps1`. All use the progress subsystem for data loading and wizard step factories for user input.

| Function | Description |
|---|---|
| `Invoke-IntelPreviewWorkflow` | Intel targeting matrix: date range filter, session loading with progress, extract Intel entries, `ResultTableComponent` display |
| `Invoke-NameSearchWorkflow` | Standalone name search: `Invoke-EngineFuzzySearch` for entities, `Show-EntityCard` for result |
| `Invoke-FetchLogsWorkflow` | Mass log fetch: date range filter, session loading with progress, count URLs, confirmation, `Invoke-SessionLogFetch` with progress, summary display |
| `Invoke-LogLocationReportWorkflow` | Log location resolution: date filter, session + log loading with progress, `Get-NamedLogLocationReport`, summary stats, `ResultTableComponent` with detail cards for near-matches |
| `Invoke-LocationGraphWorkflow` | Location graph analysis: date filter, include-movement choice (`New-WizardChoiceStep`), `Get-LocationGraph` with progress, summary stats, node table via `ResultTableComponent` |
| `Invoke-CompareParticipationWorkflow` | Participation comparison: collect 2+ entity names via text steps, `Compare-SessionParticipation` with progress, overlap matrix and common sessions display |
| `Invoke-SessionLeaderboardWorkflow` | Session participation ranking: entity type filter (`New-WizardChoiceStep`), top-N input (`New-WizardTextStep`), `Get-SessionGraphLeaderboard` with progress, ranked table with Tier0/Tier1/Tier2 columns |
| `Invoke-SessionGraphWorkflow` | Session graph queries: mode selection (Sessions/CoParticipants/EntityTimeline/Summary), entity/session input, `Get-SessionGraph` with progress, mode-specific table or summary display |
| `Invoke-MigrationQuickCheck` | Migration quick diagnostics: loads `migration-shared.ps1` and calls `Invoke-QuickDiagnostics` |
| `Invoke-MigrationFullReport` | Migration full report: loads `migration-shared.ps1` and calls `Invoke-FullReport` |

All data-heavy workflows use `New-ProgressState` with progress callbacks, `New-Wizard*Step` factories for user input, and display results via `Invoke-EngineLifecycle` with `New-ResultTableComponent`. Error handling uses `Complete-ProgressStep -Failed` on exceptions before displaying the error.

`Render-HealthSection` in `cli-overlays.ps1` renders a single health check section row in the health dashboard:

| Parameter | Type | Description |
|---|---|---|
| `Row` | `int` | Buffer row to render at |
| `Label` | `string` | Section label (e.g., `PU`, `Waluta`) |
| `Data` | `object` | Health check result data (or `$null` for "no data") |
| `CheckFn` | `scriptblock` | `param($D)` -- returns warning count from the data object |

Returns the next available row (`$Row + 1`). Renders checkmark (Success color) for 0 warnings, warning icon (Warning color) for >0, or "(brak danych)" for `$null` data.

---

## NavState Object

The `NavState` PSCustomObject is created by `Invoke-RobotCLI` and threaded through all functions:

| Property | Type | Description |
|---|---|---|
| `BreadcrumbStack` | `Stack[string]` | Navigation path for breadcrumb display |
| `NameIndex` | `PSCustomObject` | Contains `Index`, `StemIndex`, `BKTree` for name resolution |
| `Players` | `array` | Pre-loaded player data |
| `Entities` | `array` | Pre-loaded entity data |
| `EntityTypeIndex` | `hashtable` | Entity type to `List[object]` index for O(1) type-filtered lookups |
| `ResolveCache` | `hashtable` | Memoization cache for `Resolve-Name` calls |
| `Theme` | `string` | `'Dark'` or `'Light'` |
| `HealthCache` | `hashtable` | Background health check results |

HealthCache is populated at CLI startup and refreshed via `/r` command or `Refresh-HealthChecks`:

| Key | Value | Source |
|---|---|---|
| `PU` | Test result or `$null` | `Test-PlayerCharacterPUAssignment -Quiet` |
| `Currency` | Test result or `$null` | `Test-CurrencyReconciliation -Quiet` |
| `Integrity` | Test result or `$null` | `Test-SessionIntegrity -Quiet -Since (Get-Date).AddMonths(-2)` |
| `Graph` | Test result or `$null` | `Test-SessionGraphIntegrity -Quiet` |
| `CheckedAt` | `[datetime]` | Timestamp of last check |
| `Errors` | `[array]` | Exceptions captured during health checks |
| `Skipped` | `[bool]` | `$true` when health checks were bypassed via `-NoHealthCheck` |

Results are rendered as badges in the TopBar by `Render-TopBar` and shown in detail by `New-HealthDashboardComponent` (via `/s`). When `Skipped` is `$true`, the dashboard shows a notice and allows the user to trigger checks via Enter.

---

## Testing

Run all CLI tests:

```powershell
Invoke-Pester tests/cli-primitives.Tests.ps1, tests/cli-progress.Tests.ps1, tests/cli-wizard.Tests.ps1, tests/cli-fuzzy.Tests.ps1, tests/cli-registry.Tests.ps1, tests/cli-help.Tests.ps1, tests/cli-engine.Tests.ps1, tests/cli-buffer.Tests.ps1, tests/cli-input.Tests.ps1, tests/cli-components.Tests.ps1
```

| Test File | Tests | Coverage |
|---|---|---|
| `cli-engine.Tests.ps1` | 27 | `Initialize-Screen`, `Build-Regions`, `Get-TierStyle`, `Test-MinimumSize`, ANSI helpers |
| `cli-buffer.Tests.ps1` | 30 | `New-ScreenBuffer`, `Set-BufferLine`, `Compare-BufferLine`, `New-Segment`, `New-PaddedLine`, `Render-BufferDiff` |
| `cli-input.Tests.ps1` | 53 | `New-InputAction`, `Route-KeyPress` (all 4 modes), `Split-FilterQuery`, `Reset-Filter`, `Invoke-SlashCommand` |
| `cli-components.Tests.ps1` | 118 | `New-MenuListComponent`, `New-ResultTableComponent`, `New-DetailCardComponent`, `New-WizardStepComponent`, `New-HelpOverlayComponent`, `Invoke-MenuFilter`, `Invoke-TableFilter`, `Resolve-VisibleColumns`, `Format-DetailValue`, `Search-HelpTopics` |
| `cli-registry.Tests.ps1` | 40 | `Menu Registry` integrity, `Get-MenuCategories`, `Get-MenuItems`, `Get-RegistryEntry`, `Merge-PluginMenuItems`, `Migration Phase Registry` |
| `cli-progress.Tests.ps1` | 26 | `New-ProgressState`, `Start-ProgressStep`, `Update-ProgressStep`, `Complete-ProgressStep`, `Complete-ProgressGroup`, full lifecycle integration |
| `cli-primitives.Tests.ps1` | 16 | `Get-CLIColor`, `Resolve-CLITheme`, banner art |
| `cli-fuzzy.Tests.ps1` | 16 | `Filter-FuzzyCandidates`, `Get-FuzzySearchCandidates` |
| `cli-wizard.Tests.ps1` | 13 | `CommonParams HashSet`, `Resolve-StepType` |
| `cli-help.Tests.ps1` | 6 | Help content completeness, key matching |
| Total | 345 | |

Tests cover pure logic functions only. Interactive UI functions (`Start-InputLoop`, component `Render` scriptblocks, etc.) require a live terminal with `[Console]::ReadKey` and are not tested. Engine component constructors, filter logic, segment construction, input routing, and column resolution are fully covered. Progress subsystem tests validate the data layer only -- terminal rendering (`Write-Host`, `[Console]::SetCursorPosition`) is mocked.

Migration phase tests are conditionally skipped when migration files are not available in the test environment.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Terminal below 60x15 | `Initialize-Screen` returns `$false`; shows Polish-language size warning and waits for keypress |
| Terminal resized during input loop | `Test-TerminalResized` detects change; `Resize-Screen` rebuilds regions; `Initialize-Buffers` creates fresh buffers; `Render-FullBuffer` forces complete redraw |
| Paste sequence detected | `Test-PasteSequence` checks for <20ms between keystrokes; Enter keys during paste are ignored to prevent accidental selection |
| PS 5.1 Bold rendering | Bold segments with default/Info/White color are promoted to Accent color; Dim is suppressed entirely |
| PS 5.1 ANSI helpers | `Get-ANSIBold`, `Get-ANSIDim`, `Get-ANSIReset` return empty strings (no escape sequences) |
| `__quit__` in wizard context | Treated as `__back__` (returns to previous step or cancels wizard) to prevent accidental exit |
| `__quit__` in menu context | Bubbles up through `Show-SubMenu` and `Show-MainMenu` to exit CLI entirely |
| Slash command error | Caught silently; logged via `Add-OperationWarning` if available; TUI output is preserved |
| Zero filter results | Components show "(brak wynikow)" in Content region; FilterBar shows match count in Warning color |
| Responsive column overflow | `Resolve-VisibleColumns` removes priority 3 columns first, then priority 2; priority 1 columns are always shown |
| Stage 3 fuzzy triggers during typing | `Invoke-FuzzyDebounce` waits 300ms of keystroke silence before triggering; aborts if any key becomes available |
| ISE or non-interactive terminal | `[Console]::KeyAvailable` check throws; `Invoke-RobotCLI` rethrows with Polish-language message |
| Progress step completed without prior Update | Works correctly -- `Complete-ProgressStep` is independent of `Update-ProgressStep` |
| Progress step fails | `Complete-ProgressStep -Failed` marks step as Error; subsequent steps can still proceed. `State.Failed` is set to `$true` but does not prevent further step execution |
| Empty progress Steps list | `Update-ProgressStep` and `Complete-ProgressStep` are no-ops when `Steps.Count -eq 0` (guard against calls before `Start-ProgressStep`) |
| Health checks skipped | `HealthCache.Skipped = $true`; dashboard shows "pominieto" notice; user can trigger checks via Enter in dashboard |
| Migration files missing | `Get-MigrationMenuItems` returns disabled "not available" item; `Invoke-MigrationPhaseAction` shows error and waits for keypress |

---

## Related Documents

- [PLUGINS.md](PLUGINS.md) - Plugin system (same hook/registry pattern)
- [ENTITY-WRITES.md](ENTITY-WRITES.md) - Entity write operations wrapped by CLI wizards
- [SESSIONS.md](SESSIONS.md) - Session pipeline wrapped by session workflows
